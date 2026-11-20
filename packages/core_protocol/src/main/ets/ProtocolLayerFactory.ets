/**
 * 协议层工厂（唯一装配点）。
 *
 * 职责：
 * - 组装模型目录（内置 + 设置页里的自定义端点）；
 * - 组装 3 个厂商 Adapter 与 rcp 流式客户端；
 * - `send()` 打通「取密钥 → 组装请求 → rcp 流式 → SSE 解析 → 厂商事件 → 统一事件」全链路；
 * - `cancel()` 生效、错误中文化并带 retriable 标记；
 * - `testConnection()` / `listRemoteModels()` / `synthesizeTitle()`。
 *
 * 密钥不落在 Adapter 里：Adapter 只产 headers 骨架，由本层注入
 * （DeepSeek/OpenAI 用 `Authorization: Bearer`，Anthropic 用 `x-api-key`），
 * 这样 Adapter 保持纯逻辑、可被 QA 单测。
 */
import { ConversationNode, SettingsKeys } from '@app/core_model';
import {
  ConnectionTestResult, HttpRequestSpec, ModelProfile, ProtocolKind, RequestOptions, StreamEvent
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
import { joinUrl } from './util/UrlUtil';

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
  private readonly modelCatalog: ModelCatalog;
  private readonly streamClient: RcpStreamClient = new RcpStreamClient();
  private readonly adapters: Map<string, ProviderAdapter> = new Map<string, ProviderAdapter>();

  constructor(deps: ProtocolDeps) {
    this.deps = deps;
    this.modelCatalog = new ModelCatalog();
    this.catalog = this.modelCatalog;
    this.adapters.set('deepseek_responses', new DeepSeekResponsesAdapter());
    this.adapters.set('anthropic_messages', new AnthropicAdapter());
    this.adapters.set('openai_chat', new OpenAICompatAdapter());
    // 异步补齐设置页里的自定义端点（失败不影响内置模型）
    this.loadCustomProfilesFromSettings();
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

  /** 连接测试：各协议用自己的"最小真实请求"，比 /models 更能验证模型名。 */
  async testConnection(profile: ModelProfile): Promise<ConnectionTestResult> {
    let key: string = '';
    try {
      const stored: string | null = await this.deps.secrets.get(profile.assetKeyAlias);
      key = stored === null ? '' : stored;
    } catch (e) {
      const failed: ConnectionTestResult = {
        ok: false,
        latencyMs: 0,
        message: '读取密钥失败，请重新保存一次密钥'
      };
      return failed;
    }
    if (key.length === 0) {
      const missing: ConnectionTestResult = {
        ok: false,
        latencyMs: 0,
        message: `还没有填写「${profile.label}」的密钥`
      };
      return missing;
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
   * 探测可用模型列表（OpenAI 兼容 `/models`）。
   * 失败返回空数组（设置页不应因此报错）。
   */
  async listRemoteModels(profile: ModelProfile): Promise<string[]> {
    const empty: string[] = [];
    let key: string = '';
    try {
      const stored: string | null = await this.deps.secrets.get(profile.assetKeyAlias);
      key = stored === null ? '' : stored;
    } catch (e) {
      return empty;
    }
    if (key.length === 0) {
      return empty;
    }
    let spec: HttpRequestSpec;
    if (profile.protocol === 'openai_chat') {
      spec = new OpenAICompatAdapter().buildModelsRequest(profile);
    } else {
      const headers: Map<string, string> = new Map<string, string>();
      headers.set('accept', 'application/json');
      spec = {
        url: joinUrl(profile.baseUrl, '/models'),
        method: 'GET',
        headers: headers,
        bodyJson: '',
        timeoutMs: 20000,
        stream: false
      };
    }
    this.applyAuthHeaders(spec, profile, key);
    try {
      const resp = await this.streamClient.fetchOnce(spec);
      if (resp.statusCode !== 200) {
        return empty;
      }
      return new OpenAICompatAdapter().parseModelsResponse(resp.body);
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

  /** 从设置页读取自定义端点并注册（构造时异步执行一次）。 */
  private async loadCustomProfilesFromSettings(): Promise<void> {
    try {
      const customModelId: string = await this.deps.settings.getString(SettingsKeys.CUSTOM_MODEL_ID, '');
      const customBaseUrl: string = await this.deps.settings.getString(SettingsKeys.CUSTOM_BASE_URL, '');
      if (customModelId.length > 0) {
        const base: string = customBaseUrl.length > 0 ? customBaseUrl : 'https://api.openai.com/v1';
        const custom: ModelProfile = {
          providerId: 'custom',
          modelId: customModelId,
          protocol: 'openai_chat',
          baseUrl: base,
          assetKeyAlias: 'openaiCompat.apiKey',
          contextWindow: 128000,
          cacheMissToHitRatio: 4,
          cacheIdleTtlSec: 600,
          supportsServerWebTools: false,
          supportsThinking: true,
          supportsJsonSchema: true,
          label: '自定义兼容接口',
          builtin: false
        };
        this.modelCatalog.register(custom);
      }
      const anthropicBaseUrl: string = await this.deps.settings.getString(SettingsKeys.ANTHROPIC_BASE_URL, '');
      if (anthropicBaseUrl.length > 0) {
        const profiles: ModelProfile[] = this.modelCatalog.listProfiles();
        for (const one of profiles) {
          if (one.providerId === 'anthropic') {
            const override: ModelProfile = {
              providerId: one.providerId,
              modelId: one.modelId,
              protocol: one.protocol,
              baseUrl: anthropicBaseUrl,
              assetKeyAlias: one.assetKeyAlias,
              contextWindow: one.contextWindow,
              cacheMissToHitRatio: one.cacheMissToHitRatio,
              cacheIdleTtlSec: one.cacheIdleTtlSec,
              supportsServerWebTools: one.supportsServerWebTools,
              supportsThinking: one.supportsThinking,
              supportsJsonSchema: one.supportsJsonSchema,
              label: one.label,
              builtin: one.builtin
            };
            this.modelCatalog.register(override);
          }
        }
      }
    } catch (e) {
      // 设置读取失败不影响内置模型
    }
  }
}

/** 工厂入口（契约 CreateProtocolLayer）。 */
export const createProtocolLayer: CreateProtocolLayer = (deps: ProtocolDeps): ProtocolLayer => {
  return new ProtocolLayerImpl(deps);
};
