/**
 * 轨迹树实现：只增不改日志 + 分支切换 + 活动路径 + fork + 归档 + 会话节点缓存。
 *
 * 职责边界：
 * - 落盘（RDB）由 NodeRepositoryApi 负责，本类只做「内存索引 + 树逻辑 + 缓存」；
 * - 活动路径沿 activeChildId 从根走到叶，缺失时取最新未归档子节点（见 util/TrajectoryLogic）。
 *
 * 数据红线：append 永不物理删除历史；archive 只写标记，原文与检索索引都还在。
 */
import { CanonicalItem, ConversationNode, NodeBrief } from './interfaces/ModelTypes';
import { RdbRepositoryApi } from './interfaces/RepositoryApi';
import { TrajectoryApi } from './interfaces/TrajectoryApi';
import { estimateNodeTokens } from './util/Tokens';
import { newNodeId, newItemId } from './util/Ids';
import {
  buildActivePath,
  resolveActiveLeafId,
  sortByCreated
} from './util/TrajectoryLogic';
import { toNodeRole } from './util/NodeCodec';
import { RootBranchStore } from './impl/InternalStoreInterfaces';

export class TrajectoryStore implements TrajectoryApi {
  private readonly repo: RdbRepositoryApi;
  private readonly rootBranch: RootBranchStore | null;

  /** sessionId → (nodeId → node) 内存索引。 */
  private index: Map<string, Map<string, ConversationNode>> = new Map<string, Map<string, ConversationNode>>();
  /** nodeId → sessionId 反查（避免遍历全部会话）。 */
  private nodeSession: Map<string, string> = new Map<string, string>();
  /** 已完整从 RDB 加载过节点的会话。 */
  private loaded: Set<string> = new Set<string>();
  /** sessionId → 根分支选择（内存镜像）。 */
  private rootActive: Map<string, string> = new Map<string, string>();

  constructor(repo: RdbRepositoryApi, rootBranch?: RootBranchStore) {
    this.repo = repo;
    this.rootBranch = rootBranch === undefined ? null : rootBranch;
  }

  // ---------------------------------------------------------------------------
  // 写入 / 读取
  // ---------------------------------------------------------------------------

  async append(node: ConversationNode): Promise<void> {
    if (node === null || node === undefined) {
      throw new Error('追加消息失败：消息内容为空');
    }
    await this.repo.saveNode(node);
    this.putInIndex(node);
  }

  async getNode(nodeId: string): Promise<ConversationNode | null> {
    const cached = this.findCached(nodeId);
    if (cached !== null) {
      return cached;
    }
    const loaded = await this.repo.loadNode(nodeId);
    if (loaded !== null) {
      this.putInIndex(loaded);
    }
    return loaded;
  }

  async sessionNodes(sessionId: string): Promise<ConversationNode[]> {
    if (!this.loaded.has(sessionId)) {
      const nodes = await this.repo.loadSessionNodes(sessionId);
      const sessionMap: Map<string, ConversationNode> = new Map<string, ConversationNode>();
      for (const node of nodes) {
        sessionMap.set(node.nodeId, node);
        this.nodeSession.set(node.nodeId, sessionId);
      }
      this.index.set(sessionId, sessionMap);
      this.loaded.add(sessionId);
    }
    const sessionMap = this.index.get(sessionId);
    if (sessionMap === undefined) {
      return [];
    }
    const list: ConversationNode[] = [];
    sessionMap.forEach((node: ConversationNode) => {
      list.push(node);
    });
    return sortByCreated(list);
  }

  // ---------------------------------------------------------------------------
  // 活动路径与分支
  // ---------------------------------------------------------------------------

  async activePath(sessionId: string): Promise<ConversationNode[]> {
    const nodes = await this.sessionNodes(sessionId);
    if (nodes.length === 0) {
      return [];
    }
    const rootActiveId = await this.resolveRootActiveId(sessionId);
    const leafId = resolveActiveLeafId(nodes, rootActiveId);
    if (leafId === null) {
      return [];
    }
    return buildActivePath(nodes, leafId);
  }

  async getActiveLeafId(sessionId: string): Promise<string | null> {
    const nodes = await this.sessionNodes(sessionId);
    if (nodes.length === 0) {
      return null;
    }
    const rootActiveId = await this.resolveRootActiveId(sessionId);
    return resolveActiveLeafId(nodes, rootActiveId);
  }

  async children(sessionId: string, parentId: string | null): Promise<NodeBrief[]> {
    return this.repo.loadChildren(sessionId, parentId);
  }

  async switchBranch(sessionId: string, parentId: string | null, childId: string): Promise<void> {
    if (childId.length === 0) {
      throw new Error('切换分支失败：目标分支为空');
    }
    try {
      await this.repo.setActiveChild(sessionId, parentId, childId);
    } catch (e) {
      throw new Error(`切换分支失败：${(e as Error).message}`);
    }
    if (parentId === null) {
      this.rootActive.set(sessionId, childId);
      if (this.rootBranch !== null) {
        // RdbRepository 的 setActiveChild(null, …) 已写 sessions.active_root_id；
        // 这里再走一次可让其它持久化实现保持一致（幂等）。
        try {
          await this.rootBranch.setActiveRootChildId(sessionId, childId);
        } catch (e) {
          // 根分支选择只是偏好，写失败不影响本次内存切换
        }
      }
      return;
    }
    const parent = this.findCached(parentId);
    if (parent !== null) {
      parent.activeChildId = childId;
    }
  }

  async forkFrom(sourceNodeId: string, newRole: string, text: string): Promise<string> {
    const source = await this.getNode(sourceNodeId);
    if (source === null) {
      throw new Error('找不到要分叉的历史消息，可能已被清理');
    }
    const nodeId = newNodeId();
    const item: CanonicalItem = {
      id: newItemId(),
      kind: 'text',
      text: text,
      createdAt: Date.now()
    };
    const node: ConversationNode = {
      nodeId: nodeId,
      parentId: source.nodeId,
      sessionId: source.sessionId,
      role: toNodeRole(newRole),
      items: [item],
      tokenEstimate: 0,
      createdAt: Date.now()
    };
    if (source.modelId !== undefined) {
      node.modelId = source.modelId;
    }
    if (source.providerId !== undefined) {
      node.providerId = source.providerId;
    }
    node.tokenEstimate = estimateNodeTokens(node);
    await this.append(node);
    // 新分支立刻成为激活分支，用户切回旧分支通过 switchBranch 完成。
    await this.switchBranch(source.sessionId, source.nodeId, nodeId);
    return nodeId;
  }

  async archive(nodeIds: string[]): Promise<void> {
    if (nodeIds === undefined || nodeIds === null || nodeIds.length === 0) {
      return;
    }
    await this.repo.archiveNodes(nodeIds);
    for (const nodeId of nodeIds) {
      const cached = this.findCached(nodeId);
      if (cached !== null) {
        cached.archived = true;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 缓存
  // ---------------------------------------------------------------------------

  /** 使某会话的节点缓存失效（导入/外部写入后调用）。 */
  invalidate(sessionId: string): void {
    const sessionMap = this.index.get(sessionId);
    if (sessionMap !== undefined) {
      sessionMap.forEach((node: ConversationNode) => {
        this.nodeSession.delete(node.nodeId);
      });
    }
    this.index.delete(sessionId);
    this.loaded.delete(sessionId);
    this.rootActive.delete(sessionId);
  }

  /** 使全部缓存失效（切账号 / 全量导入后调用）。 */
  invalidateAll(): void {
    this.index.clear();
    this.nodeSession.clear();
    this.loaded.clear();
    this.rootActive.clear();
  }

  /** 缓存中的会话数（诊断用）。 */
  cachedSessionCount(): number {
    return this.loaded.size;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  private putInIndex(node: ConversationNode): void {
    let sessionMap = this.index.get(node.sessionId);
    if (sessionMap === undefined) {
      sessionMap = new Map<string, ConversationNode>();
      this.index.set(node.sessionId, sessionMap);
    }
    sessionMap.set(node.nodeId, node);
    this.nodeSession.set(node.nodeId, node.sessionId);
  }

  private findCached(nodeId: string): ConversationNode | null {
    const sessionId = this.nodeSession.get(nodeId);
    if (sessionId === undefined) {
      return null;
    }
    const sessionMap = this.index.get(sessionId);
    if (sessionMap === undefined) {
      return null;
    }
    const node = sessionMap.get(nodeId);
    return node === undefined ? null : node;
  }

  private async resolveRootActiveId(sessionId: string): Promise<string | null> {
    const cached = this.rootActive.get(sessionId);
    if (cached !== undefined) {
      return cached;
    }
    if (this.rootBranch === null) {
      return null;
    }
    try {
      const fromDb = await this.rootBranch.getActiveRootChildId(sessionId);
      if (fromDb !== null) {
        this.rootActive.set(sessionId, fromDb);
      }
      return fromDb;
    } catch (e) {
      // 读根分支失败时按「最新根节点」兜底，不影响对话
      return null;
    }
  }
}
