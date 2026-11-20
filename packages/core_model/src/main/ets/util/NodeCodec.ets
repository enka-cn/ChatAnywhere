/**
 * 节点 / 会话的 JSON 编解码与检索文本抽取（纯函数，零平台依赖，可 Node 测试）。
 *
 * 设计要点：
 * - 节点整对象存 JSON 文本列（lossless 往返），其余列只是为了 SQL 查询方便；
 * - 解析一律容错：坏数据返回 null 或补默认值，绝不抛异常；
 * - FTS5 / LIKE 的查询串构造集中在 buildFtsQuery / likePattern，便于单测。
 */
import { CanonicalItem, ConversationNode, NodeBrief, NodeRole, SessionMeta } from '../interfaces/ModelTypes';

/** 检索文本最大长度（避免单节点索引过大）。 */
const SEARCH_TEXT_LIMIT: number = 20000;

/** 预览文本最大长度。 */
const PREVIEW_LIMIT: number = 160;

/** 判断是否为合法节点角色。 */
export function isNodeRole(value: string): boolean {
  return value === 'system' || value === 'user' || value === 'assistant' || value === 'tool';
}

/** 规范化为节点角色（非法值降级为 user）。 */
export function toNodeRole(value: string): NodeRole {
  if (value === 'system') {
    return 'system';
  }
  if (value === 'assistant') {
    return 'assistant';
  }
  if (value === 'tool') {
    return 'tool';
  }
  return 'user';
}

/** 节点序列化为 JSON 文本（写入 RDB / JSONL）。 */
export function nodeToJson(node: ConversationNode): string {
  return JSON.stringify(node);
}

/**
 * 反序列化时的宽松原始形状（字段全可选，避免对 `any` 的依赖）。
 * 解析后逐字段显式搬运到 ConversationNode，保证字段无损。
 */
interface RawNode {
  nodeId?: string;
  parentId?: string | null;
  sessionId?: string;
  role?: string;
  items?: CanonicalItem[];
  modelId?: string;
  providerId?: string;
  tokenEstimate?: number;
  createdAt?: number;
  activeChildId?: string;
  archived?: boolean;
  cachedTokens?: number;
  promptTokens?: number;
  completionTokens?: number;
  cacheHitRatio?: number;
}

/**
 * JSON 文本反序列化为节点；数据损坏返回 null（调用方跳过并记 lastError）。
 * 缺 items / tokenEstimate 时补默认值，保证下游不崩。
 */
export function nodeFromJson(text: string): ConversationNode | null {
  if (text === undefined || text === null || text.length === 0) {
    return null;
  }
  let raw: RawNode | null = null;
  try {
    raw = JSON.parse(text) as RawNode;
  } catch (e) {
    return null;
  }
  if (raw === null || raw === undefined) {
    return null;
  }
  const nodeId: string = raw.nodeId ?? '';
  const sessionId: string = raw.sessionId ?? '';
  if (nodeId.length === 0 || sessionId.length === 0) {
    return null;
  }
  const node: ConversationNode = {
    nodeId: nodeId,
    parentId: raw.parentId === undefined ? null : raw.parentId,
    sessionId: sessionId,
    role: toNodeRole(raw.role ?? 'user'),
    items: Array.isArray(raw.items) ? raw.items : [],
    tokenEstimate: typeof raw.tokenEstimate === 'number' ? raw.tokenEstimate : 0,
    createdAt: typeof raw.createdAt === 'number' ? raw.createdAt : 0
  };
  if (raw.modelId !== undefined) {
    node.modelId = raw.modelId;
  }
  if (raw.providerId !== undefined) {
    node.providerId = raw.providerId;
  }
  if (raw.activeChildId !== undefined) {
    node.activeChildId = raw.activeChildId;
  }
  if (raw.archived !== undefined) {
    node.archived = raw.archived;
  }
  if (raw.cachedTokens !== undefined) {
    node.cachedTokens = raw.cachedTokens;
  }
  if (raw.promptTokens !== undefined) {
    node.promptTokens = raw.promptTokens;
  }
  if (raw.completionTokens !== undefined) {
    node.completionTokens = raw.completionTokens;
  }
  if (raw.cacheHitRatio !== undefined) {
    node.cacheHitRatio = raw.cacheHitRatio;
  }
  return node;
}

/** 单条 item 参与检索的文本。 */
function itemSearchText(item: CanonicalItem): string {
  // 注意：ArkTS 不允许对象展开 / for-in，这里显式按 kind 取字段。
  if (item.kind === 'text' || item.kind === 'reasoning' || item.kind === 'checkpoint_summary') {
    return item.text ?? '';
  }
  if (item.kind === 'tool_call') {
    return `${item.toolName ?? ''} ${item.argumentsJson ?? ''}`;
  }
  if (item.kind === 'tool_result') {
    return item.text ?? '';
  }
  if (item.kind === 'web_search_call') {
    let out: string = '';
    const raw = item.vendorRaw;
    if (raw !== undefined && raw !== null) {
      if (raw.pageMeta !== undefined && raw.pageMeta !== null) {
        out += `${raw.pageMeta.title} ${raw.pageMeta.url} `;
      }
      if (raw.sources !== undefined && raw.sources !== null) {
        for (const s of raw.sources) {
          out += `${s.title} ${s.snippet} ${s.url} `;
        }
      }
    }
    if (item.fallbackSummary !== undefined && item.fallbackSummary !== null) {
      out += item.fallbackSummary;
    }
    return out;
  }
  if (item.kind === 'file_ref' || item.kind === 'image') {
    return `${item.fileId ?? ''} ${item.mimeType ?? ''}`;
  }
  return item.text ?? '';
}

/** 抽取节点全文（存 nodes.content_text，供 FTS5 与 LIKE 检索）。 */
export function nodeSearchText(node: ConversationNode): string {
  const parts: string[] = [];
  if (Array.isArray(node.items)) {
    for (const item of node.items) {
      const t = itemSearchText(item);
      if (t.length > 0) {
        parts.push(t);
      }
    }
  }
  let out = parts.join('\n');
  if (out.length > SEARCH_TEXT_LIMIT) {
    out = out.substring(0, SEARCH_TEXT_LIMIT);
  }
  return out;
}

/** 节点预览（分支菜单 / 检索结果展示）。 */
export function nodePreview(node: ConversationNode): string {
  if (!Array.isArray(node.items)) {
    return '';
  }
  let fallback: string = '';
  for (const item of node.items) {
    const raw = item.text ?? '';
    const text = raw.replace(/\s+/g, ' ').trim();
    if (text.length === 0) {
      continue;
    }
    if (item.kind === 'text' || item.kind === 'checkpoint_summary') {
      return text.length <= PREVIEW_LIMIT ? text : `${text.substring(0, PREVIEW_LIMIT)}…`;
    }
    if (fallback.length === 0) {
      fallback = text;
    }
  }
  if (fallback.length === 0) {
    return '';
  }
  return fallback.length <= PREVIEW_LIMIT ? fallback : `${fallback.substring(0, PREVIEW_LIMIT)}…`;
}

/** 构造 NodeBrief（子节点数由调用方统计）。 */
export function briefFromNode(node: ConversationNode, childCount: number): NodeBrief {
  const brief: NodeBrief = {
    nodeId: node.nodeId,
    parentId: node.parentId,
    role: node.role,
    createdAt: node.createdAt,
    preview: nodePreview(node),
    childCount: childCount
  };
  if (node.activeChildId !== undefined) {
    brief.activeChildId = node.activeChildId;
  }
  if (node.archived !== undefined) {
    brief.archived = node.archived;
  }
  return brief;
}

/**
 * 构造 FTS5 MATCH 查询串：按空白切词，逐词用双引号包裹，用 OR 连接。
 * 去掉会破坏 FTS5 语法的字符；短于 3 字的词丢弃（trigram 分词器要求 ≥3 字，
 * 短词交给 LIKE 兜底，避免 MATCH 直接报错把索引降级掉）。
 */
export function buildFtsQuery(query: string): string {
  if (query === undefined || query === null) {
    return '';
  }
  const cleaned = query.replace(/["'()*:^{}\[\]\\]/g, ' ');
  const words = cleaned.split(/\s+/);
  const parts: string[] = [];
  for (const w of words) {
    const t = w.trim();
    if (t.length < 3) {
      continue;
    }
    parts.push(`"${t}"`);
    if (parts.length >= 8) {
      break;
    }
  }
  return parts.join(' OR ');
}

/** LIKE 兜底查询串（转义 % _ \，配合 `ESCAPE '\'` 使用）。 */
export function likePattern(query: string): string {
  const escaped = query.replace(/[\\%_]/g, '\\$&');
  return `%${escaped}%`;
}

/** 命中片段：围绕首个命中位置截取 window*2 字符；未命中取开头。 */
export function makeSnippet(text: string, query: string, window: number): string {
  if (text === undefined || text === null || text.length === 0) {
    return '';
  }
  const plain = text.replace(/\s+/g, ' ').trim();
  if (plain.length === 0) {
    return '';
  }
  const span = window > 0 ? window : 24;
  const q = query === undefined || query === null ? '' : query.trim();
  let idx: number = -1;
  if (q.length > 0) {
    idx = plain.toLowerCase().indexOf(q.toLowerCase());
  }
  if (idx < 0) {
    return plain.length <= span * 2 ? plain : `${plain.substring(0, span * 2)}…`;
  }
  const start = idx - span < 0 ? 0 : idx - span;
  const endRaw = idx + q.length + span;
  const end = endRaw > plain.length ? plain.length : endRaw;
  const prefix = start > 0 ? '…' : '';
  const suffix = end < plain.length ? '…' : '';
  return `${prefix}${plain.substring(start, end)}${suffix}`;
}

/** 会话元信息原始形状（导入时宽松解析）。 */
export interface RawSessionMeta {
  sessionId?: string;
  title?: string;
  createdAt?: number;
  updatedAt?: number;
  modelId?: string;
  providerId?: string;
  pinned?: boolean;
  nodeCount?: number;
  totalTokens?: number;
}

/** 宽松原始会话元信息 → 会话元信息；缺 sessionId 返回 null。 */
export function sessionMetaFromRaw(raw: RawSessionMeta): SessionMeta | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  const sessionId: string = raw.sessionId ?? '';
  if (sessionId.length === 0) {
    return null;
  }
  const now = Date.now();
  const meta: SessionMeta = {
    sessionId: sessionId,
    title: raw.title ?? '导入的会话',
    createdAt: typeof raw.createdAt === 'number' ? raw.createdAt : now,
    updatedAt: typeof raw.updatedAt === 'number' ? raw.updatedAt : now
  };
  if (raw.modelId !== undefined) {
    meta.modelId = raw.modelId;
  }
  if (raw.providerId !== undefined) {
    meta.providerId = raw.providerId;
  }
  if (raw.pinned !== undefined) {
    meta.pinned = raw.pinned;
  }
  if (raw.nodeCount !== undefined) {
    meta.nodeCount = raw.nodeCount;
  }
  if (raw.totalTokens !== undefined) {
    meta.totalTokens = raw.totalTokens;
  }
  return meta;
}

/** 会话元信息转 JSON（manifest.json 用）。 */
export function sessionMetaToJsonArray(sessions: SessionMeta[]): string {
  return JSON.stringify(sessions);
}

/** JSONL 行切分：过滤空行与 Windows CRLF 残留 \r。 */
export function splitJsonLines(text: string): string[] {
  const out: string[] = [];
  if (text === undefined || text === null || text.length === 0) {
    return out;
  }
  const lines = text.split('\n');
  for (const line of lines) {
    const t = line.trim();
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}
