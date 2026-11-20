/**
 * OpenAI Chat Completions 兼容适配器（任意 `/chat/completions` 端点）。
 *
 * 覆盖场景：OpenAI 官方、vLLM / Ollama / OneAPI / 各类中转站、以及用户自定义的 DeepSeek
 * Chat Completions 端点。事实来源：OpenAI Chat Completions 稳定协议 + docs/API_REFERENCE.md。
 *
 * 投影规则：
 * - `system` 提示词作为第一条 system 消息；
 * - 工具调用用 `tool_calls` + `role: tool` 配对；
 * - 异构厂商的 `web_search_call` 用 `fallbackSummary` 降级成 assistant 文本；
 * - `reasoning_content` 只对 DeepSeek 系端点回填（未知字段在严格端点上会 400）；
 * - `webMode=server_managed` 不适用于本协议，联网交由 core_plugin 轨道 B。
 */
import { CanonicalItem, ConversationNode, VendorRaw } from '@app/core_model';
import {
  ConnectionTestResult, HttpRequestSpec, ModelProfile, ProtocolKind, RequestOptions, StreamEvent, ToolSpec
} from '../interfaces/ProtocolTypes';
import { ProviderAdapter } from '../interfaces/ProviderAdapter';
import { OpenAiSseState, parseOpenAiSse } from './OpenAiSse';
import { bodySnippet, joinUrl } from '../util/UrlUtil';
import { modelsUrl } from '../util/RemoteModels';
import { asRecord, getStr, newObjectRecord, parseRecord } from '../util/JsonLite';

const STREAM_TIMEOUT_MS: number = 1800000;
const PING_TIMEOUT_MS: number = 20000;

export class OpenAICompatAdapter implements ProviderAdapter {
  readonly protocol: ProtocolKind = 'openai_chat';
  private readonly state: OpenAiSseState = new OpenAiSseState();

  buildRequest(profile: ModelProfile, nodes: ConversationNode[], options: RequestOptions): HttpRequestSpec {
    this.state.reset();
    const body: Record<string, Object> = newObjectRecord();
    body['model'] = profile.modelId;
    body['stream'] = true;
    // 只有带 include_usage 才能在流末尾拿到 usage（缓存命中率依赖它）。
    const streamOptions: Record<string, Object> = newObjectRecord();
    streamOptions['include_usage'] = true;
    body['stream_options'] = streamOptions;

    const messages: Object[] = [];
    const systemPrompt: string = options.systemPrompt === undefined ? '' : options.systemPrompt;
    if (systemPrompt.length > 0) {
      const systemMessage: Record<string, Object> = newObjectRecord();
      systemMessage['role'] = 'system';
      systemMessage['content'] = systemPrompt;
      messages.push(systemMessage);
    }
    for (const node of nodes) {
      this.projectNode(messages, node, profile);
    }
    body['messages'] = messages;

    if (options.maxOutputTokens !== undefined && options.maxOutputTokens > 0) {
      body['max_tokens'] = options.maxOutputTokens;
    }
    if (options.temperature !== undefined) {
      body['temperature'] = options.temperature;
    }

    // v3 六档思考 → `reasoning_effort`（Chat Completions 通用字段，OpenAI 兼容端点透传）：
    //   off → 不传；min | low → low；med → medium；high | xhigh → high。
    //   - `xhigh` 不用 `max`：OpenAI 官方只定义 minimal/low/medium/high，`max` 会 400；
    //     high 已是最高合法档（若自建端点确定支持 max，可在此处替换）。
    //   - `supportsThinking=false` 的端点完全不传（未知字段在严格端点上会 400）。
    let reasoningEffort: string = '';
    if (profile.supportsThinking && options.thinkingLevel !== 'off') {
      const level: string = options.thinkingLevel;
      if (level === 'min' || level === 'low') {
        reasoningEffort = 'low';
      } else if (level === 'med') {
        reasoningEffort = 'medium';
      } else if (level === 'high' || level === 'xhigh') {
        reasoningEffort = 'high';
      }
      if (reasoningEffort.length > 0) {
        body['reasoning_effort'] = reasoningEffort;
      }
    }
    // Top-P：字段名 `top_p`。推理模型（已发 reasoning_effort）普遍与 top_p 互斥（传了会 400），
    // 因此只在未启用 reasoning_effort 时透传。
    if (reasoningEffort.length === 0 && options.topP !== undefined
      && options.topP > 0 && options.topP <= 1) {
      body['top_p'] = options.topP;
    }

    const tools: Object[] = [];
    if (options.toolSpecs !== undefined) {
      for (const spec of options.toolSpecs) {
        tools.push(this.functionTool(spec));
      }
    }
    if (tools.length > 0) {
      body['tools'] = tools;
    }

    const headers: Map<string, string> = new Map<string, string>();
    headers.set('content-type', 'application/json');
    headers.set('accept', 'text/event-stream');

    const spec: HttpRequestSpec = {
      url: joinUrl(profile.baseUrl, '/chat/completions'),
      method: 'POST',
      headers: headers,
      bodyJson: JSON.stringify(body),
      timeoutMs: STREAM_TIMEOUT_MS,
      stream: true
    };
    return spec;
  }

  parseSseEvent(eventName: string, dataJson: string): StreamEvent[] {
    return parseOpenAiSse(this.state, eventName, dataJson);
  }

  /** 连接测试：直接发一个 1 token 的最小对话（能同时验证地址、密钥、模型名）。 */
  buildPingRequest(profile: ModelProfile): HttpRequestSpec {
    const body: Record<string, Object> = newObjectRecord();
    body['model'] = profile.modelId;
    body['max_tokens'] = 1;
    const messages: Object[] = [];
    const message: Record<string, Object> = newObjectRecord();
    message['role'] = 'user';
    message['content'] = 'hi';
    messages.push(message);
    body['messages'] = messages;
    body['stream'] = false;
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('content-type', 'application/json');
    headers.set('accept', 'application/json');
    const spec: HttpRequestSpec = {
      url: joinUrl(profile.baseUrl, '/chat/completions'),
      method: 'POST',
      headers: headers,
      bodyJson: JSON.stringify(body),
      timeoutMs: PING_TIMEOUT_MS,
      stream: false
    };
    return spec;
  }

  /**
   * 远端模型列表：`GET {baseUrl}/models`。
   * v3.2 起统一走 `util/RemoteModels.modelsUrl`（baseUrl 已含 `/v1` 时不重复拼接）。
   */
  buildModelsRequest(profile: ModelProfile): HttpRequestSpec {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('accept', 'application/json');
    const spec: HttpRequestSpec = {
      url: modelsUrl(profile.protocol, profile.baseUrl),
      method: 'GET',
      headers: headers,
      bodyJson: '',
      timeoutMs: PING_TIMEOUT_MS,
      stream: false
    };
    return spec;
  }

  parsePingResponse(statusCode: number, body: string): ConnectionTestResult {
    const result: ConnectionTestResult = {
      ok: statusCode === 200,
      latencyMs: 0,
      message: this.pingMessage(statusCode, body)
    };
    return result;
  }

  private pingMessage(statusCode: number, body: string): string {
    if (statusCode === 200) {
      return '连接正常，密钥可用';
    }
    if (statusCode === 401 || statusCode === 403) {
      return '密钥无效或没有访问权限，请重新填写';
    }
    if (statusCode === 402) {
      return '账户余额不足，请充值后再试';
    }
    if (statusCode === 404) {
      return '接口地址或模型不存在，请检查接口地址与模型名';
    }
    if (statusCode === 429) {
      return '请求太频繁，请稍后再试';
    }
    if (statusCode === 400) {
      const snippet: string = bodySnippet(body, 120);
      return snippet.length > 0 ? `请求被拒绝：${snippet}` : '请求被拒绝，请检查模型名与参数';
    }
    if (statusCode >= 500) {
      return '服务端暂时不可用，请稍后再试';
    }
    return `连接异常（HTTP ${statusCode}）`;
  }

  // ---------------------------------------------------------------- 消息投影

  private projectNode(messages: Object[], node: ConversationNode, profile: ModelProfile): void {
    if (node.role === 'system') {
      const text: string = this.joinTexts(node.items);
      if (text.length > 0) {
        this.appendTextMessage(messages, 'system', text);
      }
      return;
    }
    if (node.role === 'user') {
      const text: string = this.buildUserText(node.items, profile);
      this.appendTextMessage(messages, 'user', text);
      return;
    }
    if (node.role === 'assistant') {
      this.projectAssistant(messages, node, profile);
      return;
    }
    // role === 'tool'
    for (const item of node.items) {
      if (item.kind === 'tool_result' || item.kind === 'text') {
        const content: string = item.text === undefined ? '' : item.text;
        const toolCallId: string = item.callId === undefined ? item.id : item.callId;
        const message: Record<string, Object> = newObjectRecord();
        message['role'] = 'tool';
        message['tool_call_id'] = toolCallId;
        message['content'] = content;
        messages.push(message);
      }
    }
  }

  private projectAssistant(messages: Object[], node: ConversationNode, profile: ModelProfile): void {
    let text: string = '';
    const toolCalls: Object[] = [];
    let reasoning: string = '';
    for (const item of node.items) {
      const kind: string = item.kind;
      if (kind === 'text') {
        const one: string = item.text === undefined ? '' : item.text;
        if (one.length > 0) {
          text = text.length > 0 ? `${text}\n${one}` : one;
        }
      } else if (kind === 'reasoning') {
        if (this.supportsReasoningContent(profile)) {
          const one: string = item.text === undefined ? '' : item.text;
          if (one.length > 0) {
            reasoning = reasoning.length > 0 ? `${reasoning}\n${one}` : one;
          }
        }
      } else if (kind === 'tool_call') {
        const call: Record<string, Object> = newObjectRecord();
        call['id'] = item.callId === undefined ? item.id : item.callId;
        call['type'] = 'function';
        const fn: Record<string, Object> = newObjectRecord();
        fn['name'] = item.toolName === undefined ? '' : item.toolName;
        fn['arguments'] = item.argumentsJson === undefined ? '{}' : item.argumentsJson;
        call['function'] = fn;
        toolCalls.push(call);
      } else if (kind === 'web_search_call') {
        const fallback: string = this.fallbackText(item);
        if (fallback.length > 0) {
          text = text.length > 0 ? `${text}\n${fallback}` : fallback;
        }
      } else if (kind === 'checkpoint_summary') {
        const one: string = item.text === undefined ? '' : item.text;
        if (one.length > 0) {
          this.appendTextMessage(messages, 'user', `[对话记忆摘要] ${one}`);
        }
      }
    }
    if (text.length === 0 && toolCalls.length === 0) {
      return;
    }
    const message: Record<string, Object> = newObjectRecord();
    message['role'] = 'assistant';
    message['content'] = text;
    if (reasoning.length > 0) {
      message['reasoning_content'] = reasoning;
    }
    if (toolCalls.length > 0) {
      message['tool_calls'] = toolCalls;
    }
    messages.push(message);
  }

  private buildUserText(items: CanonicalItem[], profile: ModelProfile): string {
    let text: string = '';
    for (const item of items) {
      const kind: string = item.kind;
      let piece: string = '';
      if (kind === 'text') {
        piece = item.text === undefined ? '' : item.text;
      } else if (kind === 'checkpoint_summary') {
        const one: string = item.text === undefined ? '' : item.text;
        piece = one.length > 0 ? `[对话记忆摘要] ${one}` : '';
      } else if (kind === 'image') {
        const mime: string = item.mimeType === undefined ? '图片' : item.mimeType;
        piece = `[${mime}：当前通道未上传图片数据，仅保留占位说明]`;
      } else if (kind === 'file_ref') {
        const mime: string = item.mimeType === undefined ? '文件' : item.mimeType;
        piece = `[附件：${mime}]`;
      } else if (kind === 'web_search_call' || kind === 'tool_result' || kind === 'tool_call') {
        piece = this.fallbackText(item);
      }
      if (piece.length > 0) {
        text = text.length > 0 ? `${text}\n${piece}` : piece;
      }
    }
    return text;
  }

  private joinTexts(items: CanonicalItem[]): string {
    let text: string = '';
    for (const item of items) {
      if (item.kind === 'text') {
        const one: string = item.text === undefined ? '' : item.text;
        if (one.length > 0) {
          text = text.length > 0 ? `${text}\n${one}` : one;
        }
      }
    }
    return text;
  }

  /** 相邻同角色纯文本消息合并（部分兼容端点要求 user/assistant 严格交替）。 */
  private appendTextMessage(messages: Object[], role: string, text: string): void {
    if (text.length === 0) {
      return;
    }
    const lastIndex: number = messages.length - 1;
    if (lastIndex >= 0) {
      const last: Record<string, Object> | null = asRecord(messages[lastIndex]);
      if (last !== null) {
        const lastRole: string = getStr(last, 'role', '');
        const hasToolCalls: boolean = last['tool_calls'] !== undefined;
        if (lastRole === role && !hasToolCalls) {
          const prev: string = getStr(last, 'content', '');
          last['content'] = prev.length > 0 ? `${prev}\n${text}` : text;
          return;
        }
      }
    }
    const message: Record<string, Object> = newObjectRecord();
    message['role'] = role;
    message['content'] = text;
    messages.push(message);
  }

  private functionTool(spec: ToolSpec): Record<string, Object> {
    const tool: Record<string, Object> = newObjectRecord();
    tool['type'] = 'function';
    const fn: Record<string, Object> = newObjectRecord();
    fn['name'] = spec.name;
    fn['description'] = spec.description;
    const schema: Record<string, Object> | null = parseRecord(spec.parametersJson);
    if (schema !== null) {
      fn['parameters'] = schema;
    } else {
      const empty: Record<string, Object> = newObjectRecord();
      empty['type'] = 'object';
      const props: Record<string, Object> = newObjectRecord();
      empty['properties'] = props;
      fn['parameters'] = empty;
    }
    tool['function'] = fn;
    return tool;
  }

  /** DeepSeek 系 Chat Completions 端点才接受 `reasoning_content` 字段。 */
  private supportsReasoningContent(profile: ModelProfile): boolean {
    return profile.providerId.indexOf('deepseek') >= 0 || profile.modelId.indexOf('deepseek') >= 0;
  }

  private fallbackText(item: CanonicalItem): string {
    const summary: string = item.fallbackSummary === undefined ? '' : item.fallbackSummary;
    if (summary.length > 0) {
      return summary;
    }
    const vr: VendorRaw | undefined = item.vendorRaw;
    if (vr !== undefined) {
      if (vr.pageMeta !== undefined && vr.pageMeta.url.length > 0) {
        return `[网页：${vr.pageMeta.title}（${vr.pageMeta.url}）]`;
      }
      if (vr.sources !== undefined && vr.sources.length > 0) {
        const titles: string[] = [];
        for (const one of vr.sources) {
          if (one.title.length > 0) {
            titles.push(one.title);
          }
        }
        if (titles.length > 0) {
          return `[联网检索来源 ${vr.sources.length} 条] ${titles.join('；')}`;
        }
        return `[联网检索来源 ${vr.sources.length} 条]`;
      }
    }
    const text: string = item.text === undefined ? '' : item.text;
    return text;
  }

  /** 解析 /models 响应（`{"data":[{"id":...}]}` 或纯数组）。 */
  parseModelsResponse(body: string): string[] {
    const out: string[] = [];
    const rec: Record<string, Object> | null = parseRecord(body);
    if (rec !== null) {
      const data: Object = rec['data'];
      if (Array.isArray(data)) {
        const arr: Object[] = data as Object[];
        for (const one of arr) {
          const item: Record<string, Object> | null = asRecord(one);
          if (item !== null) {
            const id: string = getStr(item, 'id', '');
            if (id.length > 0) {
              out.push(id);
            }
          }
        }
      }
      return out;
    }
    try {
      const arr: Object[] = JSON.parse(body) as Object[];
      if (Array.isArray(arr)) {
        for (const one of arr) {
          if (typeof one === 'string') {
            out.push(one as string);
          }
        }
      }
    } catch (e) {
      return out;
    }
    return out;
  }
}
