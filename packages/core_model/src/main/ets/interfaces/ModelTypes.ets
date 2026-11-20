/**
 * 统一 Item / 节点 / 会话数据契约。
 *
 * 设计约束（来自 Blueprint §1、§3.1）：
 * - 内部状态以 DeepSeek Responses API 的 Item 语义为核心，禁止扁平 messages[] 模型；
 * - 树形分支通过 parentId + activeChildId 表达，轨迹只增不改；
 * - 原样回传的 web_search_call 必须保留在 vendorRaw，跨厂商时用 fallbackSummary 降级投影。
 *
 * ArkTS 提示：此处只有 interface / type，可在 Node 端做逻辑测试。
 */

/** Item 种类（对齐 Responses API 的 output item 语义）。 */
export type ItemKind = 'text' | 'reasoning' | 'image' | 'file_ref' | 'tool_call' | 'tool_result' |
  'web_search_call' | 'checkpoint_summary';

/** 节点角色。 */
export type NodeRole = 'system' | 'user' | 'assistant' | 'tool';

/** DeepSeek 原厂联网子类型（web_search_call 的 kind 字段）。 */
export type SearchKind = 'search' | 'deep_search' | 'read_link' | 'image_search' | 'deep_image_search';

/** 网页元信息。 */
export interface PageMeta {
  url: string;
  title: string;
  publishedAt?: string;
}

/** 模型引用来源（已清洗）。 */
export interface SourceRef {
  title: string;
  url: string;
  snippet: string;
  siteName?: string;
  /** 相关度（DeepSeek 官方优质结果阈值 1.5）。 */
  rerankScore?: number;
  /** 权威度（>=3 为极权威）。 */
  authority?: number;
}

/** 厂商原始载荷，必须在同厂商多轮中原样回传（尤其 signature）。 */
export interface VendorRaw {
  provider: string;
  searchKind?: SearchKind;
  /** read_link 的加密网页签名，同厂商多轮必须原样回传。 */
  signature?: string;
  pageMeta?: PageMeta;
  sources?: SourceRef[];
  /** 原始 item 的 type 字符串，便于诊断与回传。 */
  rawType?: string;
  /** 服务端返回的调用 id / status 等需要回传的字段。 */
  status?: string;
}

/** 会话轨迹中的最小语义单元。 */
export interface CanonicalItem {
  id: string;
  kind: ItemKind;
  /** text / reasoning / checkpoint_summary 的正文。 */
  text?: string;
  /** tool_call / tool_result 的配对 id。 */
  callId?: string;
  /** tool_call 名称。 */
  toolName?: string;
  /** tool_call 参数（原始 JSON 字符串，避免 ArkTS 动态对象）。 */
  argumentsJson?: string;
  /** image / file_ref 优先使用 Files API file_id，避免大 Base64。 */
  fileId?: string;
  mimeType?: string;
  /** tool_result 是否为错误。 */
  isError?: boolean;
  /** 厂商标记 + 原样回传数据。 */
  vendorRaw?: VendorRaw;
  /** 跨模型切换时供异构 Adapter 降级投影的精简摘要。 */
  fallbackSummary?: string;
  /** 大载荷已卸载（原文仍在 RDB，不在活跃上下文中发送）。 */
  payloadPruned?: boolean;
  /** 创建时间（ms）。 */
  createdAt?: number;
}

/** 轨迹节点：一次模型往返（user / assistant / tool）。 */
export interface ConversationNode {
  nodeId: string;
  parentId: string | null;
  sessionId: string;
  role: NodeRole;
  items: CanonicalItem[];
  modelId?: string;
  providerId?: string;
  /** 本地估算 token（用于记忆条与压缩决策）。 */
  tokenEstimate: number;
  createdAt: number;
  /** 同一 parent 下激活的子节点，用于分支切换。 */
  activeChildId?: string;
  /** 已被压缩归档：仍在 RDB 与 FTS5，永不作物理删除。 */
  archived?: boolean;
  /** 本轮服务端返回的缓存命中 token 数。 */
  cachedTokens?: number;
  promptTokens?: number;
  completionTokens?: number;
  /** 本轮缓存命中率 0..1。 */
  cacheHitRatio?: number;
}

/** 会话元信息。 */
export interface SessionMeta {
  sessionId: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  modelId?: string;
  providerId?: string;
  pinned?: boolean;
  nodeCount?: number;
  totalTokens?: number;
}

/** 节点摘要（列表页/分支菜单用，避免加载全部 items）。 */
export interface NodeBrief {
  nodeId: string;
  parentId: string | null;
  role: NodeRole;
  createdAt: number;
  activeChildId?: string;
  archived?: boolean;
  preview: string;
  childCount: number;
}
