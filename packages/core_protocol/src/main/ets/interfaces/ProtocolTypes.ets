/**
 * 多厂商协议类型契约（DeepSeek Responses / Anthropic Messages / OpenAI Chat Completions）。
 *
 * ArkTS 说明：蓝图里的 `payload: Record<string, Object>` 改为显式 `StreamPayload`，
 * 因为 ArkTS 禁止 Record 对象字面量且显式字段更安全（见 docs/DEV_GUIDE.md §2）。
 */

/** 协议种类。 */
export type ProtocolKind = 'deepseek_responses' | 'anthropic_messages' | 'openai_chat' | 'gemini';

/**
 * 思考强度 6 档（v3 设计）：关闭 / Min / Low / Med / High / xHigh。
 * 由各厂商 Adapter 离线静态映射到自家参数（DeepSeek reasoning.effort、Anthropic thinking budget、
 * OpenAI 兼容端点透传）。旧存储值 quick/deep 由 UI 层迁移为 med/high。
 */
export type ThinkingLevel = 'off' | 'min' | 'low' | 'med' | 'high' | 'xhigh';

/** 联网模式（与 Blueprint 双轨引擎一致）。 */
export type WebMode = 'off' | 'server_managed' | 'standalone_clean';

/** 模型配置：必须携带缓存价差倍率与上下文窗口，供压缩引擎做经济性决策。 */
export interface ModelProfile {
  /** 不可变 ID，避免孤立历史会话。 */
  providerId: string;
  /** 如 'deepseek-flash' | 'deepseek-v4-pro'。 */
  modelId: string;
  protocol: ProtocolKind;
  baseUrl: string;
  /** Asset Store Kit 中的密钥别名（非明文 Key）。 */
  assetKeyAlias: string;
  /** 如 1_000_000。 */
  contextWindow: number;
  /** 缓存未命中/命中价差倍率：deepseek-flash=50, deepseek-v4-pro=30。 */
  cacheMissToHitRatio: number;
  /** 估算服务端缓存自然过期秒数（用于过期窗口压缩）。 */
  cacheIdleTtlSec: number;
  supportsServerWebTools: boolean;
  supportsThinking: boolean;
  supportsJsonSchema: boolean;
  /** UI 展示用中文名，如「深度求索·极速」。 */
  label: string;
  /** 是否为内置厂商（决定设置页能否删除）。 */
  builtin?: boolean;
}

/** 发送给模型的工具声明（由 core_plugin 的 toolSchema 投影而来）。 */
export interface ToolSpec {
  name: string;
  description: string;
  /** JSON Schema 字符串。 */
  parametersJson: string;
  skillId?: string;
}

/** 联网工具选项（Adapter 负责翻译成各厂商参数）。 */
export interface WebToolOption {
  mode: WebMode;
  includeDomains?: string[];
  excludeDomains?: string[];
  /** after:YYYY-MM-DD */
  afterDate?: string;
  /** lang:zh,en */
  languages?: string[];
}

/** 单次请求选项。 */
export interface RequestOptions {
  thinkingLevel: ThinkingLevel;
  webMode: WebMode;
  maxOutputTokens?: number;
  temperature?: number;
  /** Top-P 采样（v3 角色配置项；不支持的厂商 Adapter 忽略即可）。 */
  topP?: number;
  /** 已装配的四层提示词。 */
  systemPrompt?: string;
  toolSpecs?: ToolSpec[];
  webTool?: WebToolOption;
  /** 内部运行 id（日志/取消）。 */
  runId?: string;
}

/** 本轮用量。 */
export interface UsageInfo {
  inputTokens: number;
  outputTokens: number;
  /** 缓存命中的输入 token。 */
  cachedTokens: number;
  reasoningTokens?: number;
  /** cachedTokens / inputTokens。 */
  cacheHitRatio: number;
}

/** 流式事件类型（对齐 Blueprint §3.2）。 */
export type StreamEventType = 'reasoning_delta' | 'text_delta' | 'tool_call_delta' | 'web_search_status' |
  'usage_final' | 'title_generated' | 'completed' | 'error';

/** tool_call 生命周期阶段。 */
export type ToolCallPhase = 'start' | 'delta' | 'end';

/** 统一事件载荷（显式字段，禁止动态 Record）。 */
export interface StreamPayload {
  /** text_delta / reasoning_delta 增量。 */
  delta?: string;
  /** 累计文本（便于 UI 直接替换整块）。 */
  text?: string;
  /** tool_call_delta。 */
  callId?: string;
  toolName?: string;
  argumentsDelta?: string;
  phase?: ToolCallPhase;
  /** web_search_status：'searching' | 'completed' | 'failed' 等原厂状态。 */
  searchStatus?: string;
  /** 联网检索命中的来源（已清洗）。 */
  sourcesJson?: string;
  /** 原厂 item 的 JSON（web_search_call 需原样回传时使用）。 */
  vendorRawJson?: string;
  itemId?: string;
  /** usage_final。 */
  usage?: UsageInfo;
  /** title_generated。 */
  title?: string;
  /** error。 */
  message?: string;
  errorCode?: string;
  retriable?: boolean;
}

/** 统一流式事件。 */
export interface StreamEvent {
  type: StreamEventType;
  payload: StreamPayload;
}

/** HTTP 请求描述（Adapter 产物，由 RcpStreamClient 执行）。 */
export interface HttpRequestSpec {
  url: string;
  method: string;
  /** 头字段用 Map，避免 ArkTS 的 Record 字面量限制。 */
  headers: Map<string, string>;
  /** 已序列化的 JSON body。 */
  bodyJson: string;
  timeoutMs: number;
  /** 是否以流式方式接收（SSE）。 */
  stream: boolean;
}

/** 连接测试结果（设置页「测试连接」）。 */
export interface ConnectionTestResult {
  ok: boolean;
  latencyMs: number;
  /** 直白中文诊断信息。 */
  message: string;
  /** 可选：从服务端探测到的模型列表。 */
  modelIds?: string[];
}
