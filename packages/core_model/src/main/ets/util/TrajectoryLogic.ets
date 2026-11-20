/**
 * 轨迹树纯逻辑（零平台依赖，可 Node 测试）。
 *
 * 树形规则（Blueprint §1.2 / §3.1）：
 * - 节点通过 parentId 组成树，parentId === null 为根；
 * - 同一 parent 下的激活子节点记在 parent.activeChildId；
 * - 会话根的选择单独存（根没有父节点可挂 activeChildId），由 rootActiveId 传入；
 * - 没记录激活子节点时默认选「最新创建且未归档」的子节点，保证续聊落在最后一条上。
 */
import { ConversationNode } from '../interfaces/ModelTypes';

/** 默认子节点选择：优先未归档，其次最新创建；平局取 nodeId 较大者。 */
export function pickDefaultChild(candidates: ConversationNode[]): ConversationNode | null {
  if (candidates.length === 0) {
    return null;
  }
  const alive: ConversationNode[] = [];
  for (const c of candidates) {
    if (c.archived !== true) {
      alive.push(c);
    }
  }
  const pool = alive.length > 0 ? alive : candidates;
  let best: ConversationNode = pool[0];
  for (const c of pool) {
    if (c.createdAt > best.createdAt) {
      best = c;
      continue;
    }
    if (c.createdAt === best.createdAt && c.nodeId > best.nodeId) {
      best = c;
    }
  }
  return best;
}

/** 按 createdAt 升序、nodeId 升序排序（返回新数组）。 */
export function sortByCreated(nodes: ConversationNode[]): ConversationNode[] {
  const copy: ConversationNode[] = [];
  for (const n of nodes) {
    copy.push(n);
  }
  copy.sort((a: ConversationNode, b: ConversationNode): number => {
    const diff = a.createdAt - b.createdAt;
    if (diff !== 0) {
      return diff;
    }
    if (a.nodeId === b.nodeId) {
      return 0;
    }
    return a.nodeId < b.nodeId ? -1 : 1;
  });
  return copy;
}

/** 节点 id → 节点。 */
export function indexNodes(nodes: ConversationNode[]): Map<string, ConversationNode> {
  const map: Map<string, ConversationNode> = new Map<string, ConversationNode>();
  for (const n of nodes) {
    map.set(n.nodeId, n);
  }
  return map;
}

/** parentId（null 记为 ''）→ 子节点数组。 */
export function groupByParent(nodes: ConversationNode[]): Map<string, ConversationNode[]> {
  const map: Map<string, ConversationNode[]> = new Map<string, ConversationNode[]>();
  for (const n of nodes) {
    const key = n.parentId === null ? '' : n.parentId;
    const bucket = map.get(key);
    if (bucket === undefined) {
      map.set(key, [n]);
    } else {
      bucket.push(n);
    }
  }
  return map;
}

/**
 * 解析会话的活动叶子节点 id。
 * 从根开始沿 activeChildId 走；缺失或指向不存在的节点时用默认子节点。
 * 空会话返回 null。
 */
export function resolveActiveLeafId(nodes: ConversationNode[], rootActiveId: string | null): string | null {
  if (nodes === undefined || nodes === null || nodes.length === 0) {
    return null;
  }
  const byId = indexNodes(nodes);
  const children = groupByParent(nodes);
  const roots = children.get('');
  if (roots === undefined || roots.length === 0) {
    // 数据异常（没有根）时退化为：取最早创建的节点作为起点，避免返回 null 丢上下文。
    const sorted = sortByCreated(nodes);
    return sorted[0].nodeId;
  }
  let current: ConversationNode | null = null;
  if (rootActiveId !== null && rootActiveId.length > 0) {
    const picked = byId.get(rootActiveId);
    if (picked !== undefined && picked.parentId === null) {
      current = picked;
    }
  }
  if (current === null) {
    current = pickDefaultChild(roots);
  }
  let guard: number = 0;
  while (current !== null && guard < 100000) {
    guard += 1;
    const kids = children.get(current.nodeId);
    if (kids === undefined || kids.length === 0) {
      return current.nodeId;
    }
    let next: ConversationNode | null = null;
    const activeId: string | undefined = current.activeChildId;
    if (activeId !== undefined && activeId !== null && activeId.length > 0) {
      const picked = byId.get(activeId);
      if (picked !== undefined && picked.parentId === current.nodeId) {
        next = picked;
      }
    }
    if (next === null) {
      next = pickDefaultChild(kids);
    }
    if (next === null) {
      return current.nodeId;
    }
    current = next;
  }
  return current === null ? null : current.nodeId;
}

/** 从叶子沿 parentId 回溯出「根 → 叶子」的节点链（发模型的上下文）。 */
export function buildActivePath(nodes: ConversationNode[], leafId: string): ConversationNode[] {
  if (nodes === undefined || nodes === null || nodes.length === 0) {
    return [];
  }
  const byId = indexNodes(nodes);
  const chain: ConversationNode[] = [];
  const visited: Set<string> = new Set<string>();
  let cursor: string | null = leafId;
  while (cursor !== null && cursor.length > 0) {
    if (visited.has(cursor)) {
      break;
    }
    visited.add(cursor);
    const node = byId.get(cursor);
    if (node === undefined) {
      break;
    }
    chain.push(node);
    cursor = node.parentId;
  }
  chain.reverse();
  return chain;
}

/**
 * 判断 nodeId 是否在 parentId 的子树内（防止误操作造成环）。
 * parentId === null 时只对根节点返回 true。
 */
export function isDescendant(nodes: ConversationNode[], parentId: string | null, nodeId: string): boolean {
  const byId = indexNodes(nodes);
  if (parentId === null) {
    const root = byId.get(nodeId);
    return root !== undefined && root.parentId === null;
  }
  let cursor: string | null = nodeId;
  const visited: Set<string> = new Set<string>();
  while (cursor !== null && cursor.length > 0) {
    if (cursor === parentId) {
      return true;
    }
    if (visited.has(cursor)) {
      return false;
    }
    visited.add(cursor);
    const node = byId.get(cursor);
    if (node === undefined) {
      return false;
    }
    cursor = node.parentId;
  }
  return false;
}
