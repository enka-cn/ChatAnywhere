/**
 * 协议层工厂（唯一装配点）。
 *
 * 职责：
 * - 组装**真实模型目录**（ModelCatalog：厂商预设 + RDB 注册表的已启用模型，无占位模型）；
 * - 组装 3 个厂商 Adapter 与 rcp 流式客户端；
 * - `send()` 打通「取密钥 → 组装请求 → rcp 流式 → SSE 解析 → 厂商事件 → 统一事件」全链路；
 * - `cancel()` 生效、错误中文化并带 retriable 标记；
 * - `testConnection()`（支持输入框里尚未保存的新 Key）/ `listRemoteModels()`（真实 /models 探测）/
 *   `synthesizeTitle()`。
 *
 * 密钥不落在 Adapter 里：Adapter 只产 headers 骨架，由本层注入
 * （DeepSeek/OpenAI 用 `Authorization: Bearer`，Anthropic 用 `x-api-key`），
 * 这样 Adapter 保持纯逻辑、可被 QA 单测。
 */
import { ConversationNode } from '@app/core_model';
import {
  ConnectionTestResult, HttpRequestSpec, ModelProfile, ProtocolKind, RemoteModelInfo, RequestOptions, StreamEvent
} from './interfaces/ProtocolTypes';
import { ProviderAdapter } from './interfaces/ProviderAdapter';
import {
  CreateProtocolLayer, ModelCatalogApi, ProtocolDeps, ProtocolLayer, StreamCallbacks, StreamHandle
} from './interfaces/ProtocolLayer';
import { ModelCatalog } from './ModelCatalog';
import { DeepSeekResponsesAdapter } from './adapters/DeepSeekResponsesAdapter';
import { AnthropicAdapter } from './adapters/AnthropicAdapter';
import { OpenAICompatAdapter } from './adapters/OpenAICompatAdapter';
import { RcpStreamClient, RcpStreamSink, RcpStreamConn } from './impl/RcpStreamClient';
import { SseParser } from './SseParser';
import { SseFrame } from './interfaces/ProviderAdapter';
import { buildLocalTitle } from './util/TitleUtil';
import { mapHttpStatus } from './util/ErrorText';
import { modelIdsOf, modelsUrl, parseModelsResponse } from './util/RemoteModels';

/** Anthropic 探测 /models 所需的版本头（官方稳定值）。 */
const ANTHROPIC_VERSION: string = '2023-06-01';
/** /models 探测超时。 */
const MODELS_PROBE_TIMEOUT_MS: number = 20000;

/** 可取消的一次流式运行（StreamHandle 实现）。 */
export class ProtocolStreamRun implements StreamHandle {
  finished: Promise<void> = Promise.resolve();
  private canceled: boolean = false;
  private canceler: (() => void) | null = null;

  cancel(): void {
    if (this.canceled) {
      return;
    }
    this.canceled = true;
    if (this.canceler !== null) {
      this.canceler();
    }
  }

  isCanceled(): boolean {
    return this.canceled;
  }

  setCanceler(fn: () => void): void {
    this.canceler = fn;
    if (this.canceled) {
      fn();
    }
  }
}

/** 协议层实现。 */
export class ProtocolLayerImpl implements ProtocolLayer {
  readonly catalog: ModelCatalogApi;
  private readonly deps: ProtocolDeps;
  private readonly streamClient: RcpStreamClient = new RcpStreamClient();
  private readonly adapters: Map<string, ProviderAdapter> = new Map<string, ProviderAdapter>();

  constructor(deps: ProtocolDeps) {
    this.deps = deps;
    // v3.2：目录只含厂商预设 + RDB 注册表里用户勾选的真实模型；init() 由 AppServices await
    this.catalog = new ModelCatalog(deps);
    this.adapters.set('deepseek_responses', new DeepSeekResponsesAdapter());
    this.adapters.set('anthropic_messages', new AnthropicAdapter());
    this.adapters.set('openai_chat', new OpenAICompatAdapter());
  }

  /** 取适配器（每次 send 都用新实例：Anthropic/OpenAI 的解析器带跨事件状态）。 */
  private createAdapter(protocol: ProtocolKind): ProviderAdapter | null {
    if (protocol === 'deepseek_responses') {
      return new DeepSeekResponsesAdapter();
    }
    if (protocol === 'anthropic_messages') {
      return new AnthropicAdapter();
    }
    if (protocol === 'openai_chat') {
      return new OpenAICompatAdapter();
    }
    return null;
  }

  adapter(protocol: string): ProviderAdapter | null {
    const found: ProviderAdapter | undefined = this.adapters.get(protocol);
    return found === undefined ? null : found;
  }

  send(profile: ModelProfile, nodes: ConversationNode[], options: RequestOptions,
    callbacks: StreamCallbacks): StreamHandle {
    const run: ProtocolStreamRun = new ProtocolStreamRun();
    run.finished = this.executeSend(profile, nodes, options, callbacks, run);
    return run;
  }

  /** 全链路：取密钥 → 组装请求 → rcp 流式 → SSE → 统一事件。 */
  private async executeSend(profile: ModelProfile, nodes: ConversationNode[], options: RequestOptions,
    callbacks: StreamCallbacks, run: ProtocolStreamRun): Promise<void> {
    const adapter: ProviderAdapter | null = this.createAdapter(profile.protocol);
    if (adapter === null) {
      callbacks.onError(`暂时不支持「${profile.label}」使用的协议，请换一个模型`, 'unsupported_protocol', false);
      return;
    }

    let key: string = '';
    try {
      const stored: string | null = await this.deps.secrets.get(profile.assetKeyAlias);
      key = stored === null ? '' : stored;
    } catch (e) {
      callbacks.onError('读取密钥失败，请到设置里重新保存一次密钥', 'secret_error', false);
      return;
    }
    if (key.length === 0) {
      callbacks.onError(`还没有填写「${profile.label}」的密钥，请先到设置里填写`, 'missing_key', false);
      return;
    }
    if (run.isCanceled()) {
      return;
    }

    let spec: HttpRequestSpec;
    try {
      spec = adapter.buildRequest(profile, nodes, options);
    } catch (e) {
      callbacks.onError('组装请求失败，请检查模型设置', 'build_request_error', false);
      return;
    }
    this.applyAuthHeaders(spec, profile, key);

    const parser: SseParser = new SseParser();
    const sink: RcpStreamSink = {
      onText: (text: string): void => {
        const frames: SseFrame[] = parser.feed(text);
        this.dispatchFrames(frames, adapter, callbacks);
      },
      onEnd: (): void => {
        const rest: SseFrame[] = parser.flush();
        this.dispatchFrames(rest, adapter, callbacks);
        callbacks.onDone();
      },
      onError: (message: string, errorCode: string, retriable: boolean): void => {
        callbacks.onError(message, errorCode, retriable);
      },
      onCancel: (): void => {
        // 用户主动停止：保留已生成内容，按正常结束收尾。
        const rest: SseFrame[] = parser.flush();
        this.dispatchFrames(rest, adapter, callbacks);
        callbacks.onDone();
      }
    };

    const conn: RcpStreamConn = this.streamClient.start(spec, sink);
    run.setCanceler(() => {
      conn.cancel();
    });
    try {
      await conn.finished;
    } catch (e) {
      // 流生命周期用 Promise 表示，错误已通过 onError 回调传递
    }
  }

  /** 按协议注入鉴权头（密钥不进 Adapter）。 */
  private applyAuthHeaders(spec: HttpRequestSpec, profile: ModelProfile, key: string): void {
    if (profile.protocol === 'anthropic_messages') {
      spec.headers.set('x-api-key', key);
    } else {
      spec.headers.set('authorization', `Bearer ${key}`);
    }
  }

  /** SSE 帧 → 厂商事件 → 统一事件（单帧解析失败不影响整条流）。 */
  private dispatchFrames(frames: SseFrame[], adapter: ProviderAdapter, callbacks: StreamCallbacks): void {
    for (const frame of frames) {
      let events: StreamEvent[] = [];
      try {
        events = adapter.parseSseEvent(frame.event, frame.data);
      } catch (e) {
        // 容错：未知/畸形事件直接跳过，绝不让解析问题打断整轮回答
        continue;
      }
      for (const event of events) {
        try {
          callbacks.onEvent(event);
        } catch (e) {
          // UI 回调异常不能影响网络流
        }
      }
    }
  }

  /**
   * 连接测试。
   * - 已选具体模型：发 1 token 的最小真实对话（同时验证密钥 + 模型名 + 地址）；
   * - 只验密钥（`profile.modelId` 为空，来自 `catalog.buildProfile(providerId, '')`）：
   *   改为 `GET /models` 探测，一次拿到密钥是否可用与可见模型数量。
   * @param apiKeyOverride 输入框里尚未保存的新 Key（优先于 Asset Store 中的旧 Key）
   */
  async testConnection(profile: ModelProfile, apiKeyOverride?: string): Promise<ConnectionTestResult> {
    const key: string = await this.resolveKey(profile, apiKeyOverride);
    if (key.length === 0) {
      const missing: ConnectionTestResult = {
        ok: false,
        latencyMs: 0,
        message: `还没有填写「${profile.label}」的密钥`
      };
      return missing;
    }
    const modelId: string = profile.modelId === undefined || profile.modelId === null ? '' : profile.modelId.trim();
    if (modelId.length === 0) {
      return this.probeModels(profile, key);
    }

    if (profile.protocol === 'deepseek_responses') {
      const adapter: DeepSeekResponsesAdapter = new DeepSeekResponsesAdapter();
      return this.runPing(adapter.buildPingRequest(profile), profile, key,
        (statusCode: number, body: string): ConnectionTestResult => adapter.parsePingResponse(statusCode, body));
    }
    if (profile.protocol === 'anthropic_messages') {
      const adapter: AnthropicAdapter = new AnthropicAdapter();
      return this.runPing(adapter.buildPingRequest(profile), profile, key,
        (statusCode: number, body: string): ConnectionTestResult => adapter.parsePingResponse(statusCode, body));
    }
    if (profile.protocol === 'openai_chat') {
      const adapter: OpenAICompatAdapter = new OpenAICompatAdapter();
      return this.runPing(adapter.buildPingRequest(profile), profile, key,
        (statusCode: number, body: string): ConnectionTestResult => adapter.parsePingResponse(statusCode, body));
    }
    const unsupported: ConnectionTestResult = {
      ok: false,
      latencyMs: 0,
      message: '这种接口暂时不支持连接测试'
    };
    return unsupported;
  }

  private async runPing(spec: HttpRequestSpec, profile: ModelProfile, key: string,
    parse: (statusCode: number, body: string) => ConnectionTestResult): Promise<ConnectionTestResult> {
    this.applyAuthHeaders(spec, profile, key);
    try {
      const resp = await this.streamClient.fetchOnce(spec);
      const parsed: ConnectionTestResult = parse(resp.statusCode, resp.body);
      parsed.latencyMs = resp.latencyMs;
      return parsed;
    } catch (e) {
      const err: Error = e as Error;
      const message: string = err.message === undefined ? '网络请求失败，请检查网络后重试' : err.message;
      const failed: ConnectionTestResult = { ok: false, latencyMs: 0, message: message };
      return failed;
    }
  }

  /**
   * 真实模型探测：DeepSeek `GET {baseUrl}/models`、Anthropic `GET {baseUrl}/v1/models`、
   * OpenAI 兼容 `GET {baseUrl}/models`（baseUrl 已含 /v1 时不重复拼接）。
   * 任何失败（无 Key / 非 200 / 网络异常 / 非法 JSON）都返回空数组，不抛错。
   * @param apiKeyOverride 输入框里尚未保存的新 Key
   */
  async listRemoteModels(profile: ModelProfile, apiKeyOverride?: string): Promise<RemoteModelInfo[]> {
    const empty: RemoteModelInfo[] = [];
    const key: string = await this.resolveKey(profile, apiKeyOverride);
    if (key.length === 0) {
      return empty;
    }
    try {
      const resp = await this.streamClient.fetchOnce(this.buildModelsSpec(profile, key));
      if (resp.statusCode !== 200) {
        return empty;
      }
      return parseModelsResponse(resp.body);
    } catch (e) {
      return empty;
    }
  }

  /**
   * 生成会话标题。
   * 服务端标题（DeepSeek `response.title`）会通过 `title_generated` 事件先行下发；
   * 本方法只做本地兜底：取首条用户提问的前 16 字。
   */
  async synthesizeTitle(profile: ModelProfile, firstUserText: string, assistantText: string): Promise<string> {
    return buildLocalTitle(firstUserText, assistantText);
  }

  // ---------------------------------------------------------------- 内部

  /** 取密钥：优先用调用方传入的未保存新 Key；都没有返回空串。 */
  private async resolveKey(profile: ModelProfile, apiKeyOverride?: string): Promise<string> {
    if (apiKeyOverride !== undefined && apiKeyOverride !== null) {
      const trimmed: string = apiKeyOverride.trim();
      if (trimmed.length > 0) {
        return trimmed;
      }
    }
    try {
      const stored: string | null = await this.deps.secrets.get(profile.assetKeyAlias);
      if (stored === null || stored === undefined) {
        return '';
      }
      return stored.trim();
    } catch (e) {
      return '';
    }
  }

  /** 组装 `/models` 探测请求（含各协议鉴权头）。 */
  private buildModelsSpec(profile: ModelProfile, key: string): HttpRequestSpec {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('accept', 'application/json');
    if (profile.protocol === 'anthropic_messages') {
      headers.set('x-api-key', key);
      headers.set('anthropic-version', ANTHROPIC_VERSION);
    } else {
      headers.set('authorization', `Bearer ${key}`);
    }
    const spec: HttpRequestSpec = {
      url: modelsUrl(profile.protocol, profile.baseUrl),
      method: 'GET',
      headers: headers,
      bodyJson: '',
      timeoutMs: MODELS_PROBE_TIMEOUT_MS,
      stream: false
    };
    return spec;
  }

  /** 只验密钥：/models 探测并把可见模型 id 回显给设置页。 */
  private async probeModels(profile: ModelProfile, key: string): Promise<ConnectionTestResult> {
    try {
      const resp = await this.streamClient.fetchOnce(this.buildModelsSpec(profile, key));
      if (resp.statusCode !== 200) {
        const info = mapHttpStatus(resp.statusCode, resp.body);
        const failed: ConnectionTestResult = { ok: false, latencyMs: resp.latencyMs, message: info.message };
        return failed;
      }
      const models: RemoteModelInfo[] = parseModelsResponse(resp.body);
      const ids: string[] = modelIdsOf(models);
      const message: string = ids.length > 0
        ? `连接正常，探测到 ${ids.length} 个可用模型` : '连接正常，但该地址没有返回模型列表';
      const ok: ConnectionTestResult = {
        ok: true,
        latencyMs: resp.latencyMs,
        message: message,
        modelIds: ids
      };
      return ok;
    } catch (e) {
      const err: Error = e as Error;
      const message: string = err.message === undefined ? '网络请求失败，请检查网络后重试' : err.message;
      const failed: ConnectionTestResult = { ok: false, latencyMs: 0, message: message };
      return failed;
    }
  }
}

/** 工厂入口（契约 CreateProtocolLayer）。 */
export const createProtocolLayer: CreateProtocolLayer = (deps: ProtocolDeps): ProtocolLayer => {
  return new ProtocolLayerImpl(deps);
};
