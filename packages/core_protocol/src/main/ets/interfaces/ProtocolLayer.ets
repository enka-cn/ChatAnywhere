/**
 * 协议层装配契约：入口 HAP 通过 createProtocolLayer(...) 拿到模型目录 + 流式发送能力。
 *
 * v3.2：模型目录不再内置占位模型。模型必须通过真实端点探测（`/models`）后写入
 * RDB 注册表，且只有用户勾选启用的模型才会出现在对话页与角色配置中。
 */
import { ConversationNode, ModelRegistryApi, SecretApi, SettingsApi } from '@app/core_model';
import {
  ConnectionTestResult, ModelProfile, RemoteModelInfo, RequestOptions, StreamEvent
} from './ProtocolTypes';
import { ProviderAdapter } from './ProviderAdapter';

/** 流式回调（ArkTS 不支持 AsyncIterable，改用回调）。 */
export interface StreamCallbacks {
  onEvent: (event: StreamEvent) => void;
  /** 致命错误（网络/鉴权/解析），之后不会再有 onEvent。 */
  onError: (message: string, errorCode: string, retriable: boolean) => void;
  /** 正常结束（含服务端 completed）。 */
  onDone: () => void;
}

/** 可取消的流句柄。 */
export interface StreamHandle {
  cancel(): void;
  /** 流结束后 resolve（用于 await 收尾，不会 reject）。 */
  readonly finished: Promise<void>;
}

/** 模型目录（真实探测模型 + 用户注册，v3.2）。 */
export interface ModelCatalogApi {
  /** 启动装载：从 RDB 注册表读取已启用模型并构建 ModelProfile（幂等）。 */
  init(): Promise<void>;

  /** 已启用（用户勾选）的真实模型；未拉取过模型时为空数组。 */
  listProfiles(): ModelProfile[];

  get(providerId: string, modelId: string): ModelProfile | null;

  /** 按 modelId 查找（切模型时可能只存了 modelId）。 */
  findByModelId(modelId: string): ModelProfile | null;

  /** 是否有任何已启用模型（false 时 UI 应引导去设置拉取模型）。 */
  hasModels(): boolean;

  /** 默认模型：优先默认厂商，无启用模型时返回 null。 */
  defaultProfile(): ModelProfile | null;

  /** 注册/覆盖一个模型（运行时临时用；不会落库）。 */
  register(profile: ModelProfile): void;

  /** 是否为内置厂商。 */
  isBuiltin(providerId: string): boolean;

  /** 内置厂商的协议元信息（设置页探测时用；未知厂商返回 null）。 */
  providerMeta(providerId: string): ProviderPreset | null;

  /** 用「厂商预设 + 模型 id」构造 ModelProfile（探测/测试连接时用）。 */
  buildProfile(providerId: string, modelId: string, baseUrl?: string): ModelProfile | null;

  /** 探测结果落库（RDB）：替换该厂商清单并保留已有启用状态，随后刷新内存目录。 */
  applyDiscoveredModels(providerId: string, models: RemoteModelInfo[]): Promise<void>;

  /** 勾选/取消勾选模型并落库。 */
  setModelEnabled(providerId: string, modelId: string, enabled: boolean): Promise<void>;
}

/** 内置厂商预设（不含任何具体模型 id）。 */
export interface ProviderPreset {
  providerId: string;
  /** 直白中文厂商名。 */
  label: string;
  protocol: string;
  defaultBaseUrl: string;
  assetKeyAlias: string;
  contextWindow: number;
  cacheMissToHitRatio: number;
  cacheIdleTtlSec: number;
  supportsServerWebTools: boolean;
  supportsThinking: boolean;
  supportsJsonSchema: boolean;
}

/** 协议层依赖。 */
export interface ProtocolDeps {
  secrets: SecretApi;
  settings: SettingsApi;
  /** v3.2 真实模型注册表（RDB）。 */
  models: ModelRegistryApi;
}

/** 协议层门面。 */
export interface ProtocolLayer {
  catalog: ModelCatalogApi;

  /** 发起一轮流式对话。 */
  send(profile: ModelProfile, nodes: ConversationNode[], options: RequestOptions,
    callbacks: StreamCallbacks): StreamHandle;

  /** 取适配器（测试/调试用）。 */
  adapter(protocol: string): ProviderAdapter | null;

  /**
   * 用一次极短的非流式请求测试密钥与连通性（设置页用）。
   * @param apiKeyOverride 输入框里尚未保存的新 Key（优先于 Asset Store 中的旧 Key）
   */
  testConnection(profile: ModelProfile, apiKeyOverride?: string): Promise<ConnectionTestResult>;

  /** 生成会话标题（优先用服务端 response.title，否则本地摘要）。 */
  synthesizeTitle(profile: ModelProfile, firstUserText: string, assistantText: string): Promise<string>;

  /**
   * 探测真实模型列表（DeepSeek GET /models、Anthropic GET /v1/models、OpenAI 兼容 GET {baseUrl}/models）。
   * @param apiKeyOverride 输入框里尚未保存的新 Key
   */
  listRemoteModels(profile: ModelProfile, apiKeyOverride?: string): Promise<RemoteModelInfo[]>;
}

export type CreateProtocolLayer = (deps: ProtocolDeps) => ProtocolLayer;
