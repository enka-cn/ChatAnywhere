/**
 * 协议层装配契约：入口 HAP 通过 createProtocolLayer(...) 拿到模型目录 + 流式发送能力。
 */
import { ConversationNode, SecretApi, SettingsApi } from '@app/core_model';
import {
  ConnectionTestResult, ModelProfile, RequestOptions, StreamEvent
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

/** 模型目录（内置 + 用户自定义）。 */
export interface ModelCatalogApi {
  listProfiles(): ModelProfile[];
  get(providerId: string, modelId: string): ModelProfile | null;
  /** 按 modelId 查找（切模型时可能只存了 modelId）。 */
  findByModelId(modelId: string): ModelProfile | null;
  defaultProfile(): ModelProfile;
  /** 注册/覆盖自定义厂商模型。 */
  register(profile: ModelProfile): void;
  /** 是否为内置厂商。 */
  isBuiltin(providerId: string): boolean;
}

/** 协议层依赖。 */
export interface ProtocolDeps {
  secrets: SecretApi;
  settings: SettingsApi;
}

/** 协议层门面。 */
export interface ProtocolLayer {
  catalog: ModelCatalogApi;

  /** 发起一轮流式对话。 */
  send(profile: ModelProfile, nodes: ConversationNode[], options: RequestOptions,
    callbacks: StreamCallbacks): StreamHandle;

  /** 取适配器（测试/调试用）。 */
  adapter(protocol: string): ProviderAdapter | null;

  /** 用一次极短的非流式请求测试密钥与连通性（设置页用）。 */
  testConnection(profile: ModelProfile): Promise<ConnectionTestResult>;

  /** 生成会话标题（优先用服务端 response.title，否则本地摘要）。 */
  synthesizeTitle(profile: ModelProfile, firstUserText: string, assistantText: string): Promise<string>;

  /** 探测模型列表（OpenAI 兼容端点 /models）。 */
  listRemoteModels(profile: ModelProfile): Promise<string[]>;
}

export type CreateProtocolLayer = (deps: ProtocolDeps) => ProtocolLayer;
