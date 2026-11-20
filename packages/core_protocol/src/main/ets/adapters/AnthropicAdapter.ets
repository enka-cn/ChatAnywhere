/**
 * Anthropic Messages API 适配器（`POST {baseUrl}/v1/messages`）。
 *
 * 事实来源：docs/API_REFERENCE.md §12 与 Anthropic 官方稳定协议。
 *
 * 投影规则：
 * - `system` 提示词走顶层 `system` 字段；
 * - messages 必须 user/assistant 交替 → 相邻同角色消息合并（工具结果也是 user 消息）；
 * - 思维链回传必须带 `signature`（没有签名的 thinking 块会被拒绝，直接丢弃）；
 * - 图片/文件当前只有 fileId、没有 base64 → 降级为文字占位（不猜上传协议）；
 * - 异构厂商的 `web_search_call` 用 `fallbackSummary` 降级成文本；
 * - `webMode=server_managed`（DeepSeek 原厂托管）对 Anthropic 不适用，由 core_plugin 轨道 B 负责。
 */
import { CanonicalItem, ConversationNode, VendorRaw } from '@app/core_model';
import {
  ConnectionTestResult, HttpRequestSpec, ModelProfile, ProtocolKind, RequestOptions, StreamEvent, ToolSpec
} from '../interfaces/ProtocolTypes';
import { ProviderAdapter } from '../interfaces/ProviderAdapter';
import { AnthropicSseState, parseAnthropicSse } from './AnthropicSse';
import { bodySnippet, joinUrl } from '../util/UrlUtil';
import { getObj, getStr, newObjectRecord, parseRecord } from '../util/JsonLite';

/** Anthropic 要求 max_tokens 必填。 */
const DEFAULT_MAX_TOKENS: number = 4096;
const DEFAULT_MAX_TOKENS_THINKING: number = 8192;
const STREAM_TIMEOUT_MS: number = 1800000;
const PING_TIMEOUT_MS: number = 20000;
/** Anthropic 版本头（官方稳定值）。 */
const ANTHROPIC_VERSION: string = '2023-06-01';

export class AnthropicAdapter implements ProviderAdapter {
  readonly protocol: ProtocolKind = 'anthropic_messages';
  /** 跨事件状态（每次 buildRequest 重置）。 */
  private readonly state: AnthropicSseState = new AnthropicSseState();

  buildRequest(profile: ModelProfile, nodes: ConversationNode[], options: RequestOptions): HttpRequestSpec {
    this.state.reset();
    const body: Record<string, Object> = newObjectRecord();
    body['model'] = profile.modelId;
    body['stream'] = true;

    const thinkingEnabled: boolean = profile.supportsThinking && options.thinkingLevel !== 'off';
    let maxTokens: number = options.maxOutputTokens === undefined
      ? (thinkingEnabled ? DEFAULT_MAX_TOKENS_THINKING : DEFAULT_MAX_TOKENS) : options.maxOutputTokens;
    let budget: number = 0;
    if (thinkingEnabled) {
      // v3 六档 → Anthropic thinking budget（离线静态映射）
      const level = options.thinkingLevel;
      if (level === 'min') {
        budget = 1024;
      } else if (level === 'low') {
        budget = 2048;
      } else if (level === 'med') {
        budget = 4096;
      } else if (level === 'high') {
        budget = 8192;
      } else {
        budget = 16384;
      }
      // Anthropic 要求 max_tokens > thinking.budget_tokens
      if (maxTokens <= budget) {
        maxTokens = budget + 2048;
      }
      const thinking: Record<string, Object> = newObjectRecord();
      thinking['type'] = 'enabled';
      thinking['budget_tokens'] = budget;
      body['thinking'] = thinking;
    }
    body['max_tokens'] = maxTokens;

    // 官方限制：开启 thinking 时不能自定义 temperature。
    if (!thinkingEnabled && options.temperature !== undefined) {
      body['temperature'] = options.temperature;
    }
    // Top-P：字段名 `top_p`（Anthropic Messages 标准参数）。两个限制：
    // 1) extended thinking 下必须用默认采样参数 → thinking 开启时不传；
    // 2) temperature 与 top_p 只应改一个 → temperature 优先，只有它未设置时才透传 top_p。
    if (!thinkingEnabled && options.temperature === undefined
      && options.topP !== undefined && options.topP > 0 && options.topP <= 1) {
      body['top_p'] = options.topP;
    }

    const systemPrompt: string = options.systemPrompt === undefined ? '' : options.systemPrompt;
    if (systemPrompt.length > 0) {
      body['system'] = systemPrompt;
    }

    body['messages'] = this.buildMessages(nodes);

    // 工具：只投影客户端函数工具；服务端联网工具交给 core_plugin 轨道 B。
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
    headers.set('anthropic-version', ANTHROPIC_VERSION);
    // 浏览器直连场景需要；原生端不影响。
    headers.set('anthropic-dangerous-direct-browser-access', 'false');

    const spec: HttpRequestSpec = {
      url: joinUrl(profile.baseUrl, '/v1/messages'),
      method: 'POST',
      headers: headers,
      bodyJson: JSON.stringify(body),
      timeoutMs: STREAM_TIMEOUT_MS,
      stream: true
    };
    return spec;
  }

  parseSseEvent(eventName: string, dataJson: string): StreamEvent[] {
    return parseAnthropicSse(this.state, eventName, dataJson);
  }

  buildPingRequest(profile: ModelProfile): HttpRequestSpec {
    const body: Record<string, Object> = newObjectRecord();
    body['model'] = profile.modelId;
    body['max_tokens'] = 1;
    const content: Object[] = [];
    const textPart: Record<string, Object> = newObjectRecord();
    textPart['type'] = 'text';
    textPart['text'] = 'hi';
    content.push(textPart);
    const message: Record<string, Object> = newObjectRecord();
    message['role'] = 'user';
    message['content'] = content;
    const messages: Object[] = [message];
    body['messages'] = messages;
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('content-type', 'application/json');
    headers.set('accept', 'application/json');
    headers.set('anthropic-version', ANTHROPIC_VERSION);
    const spec: HttpRequestSpec = {
      url: joinUrl(profile.baseUrl, '/v1/messages'),
      method: 'POST',
      headers: headers,
      bodyJson: JSON.stringify(body),
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
    if (statusCode === 404) {
      return '模型不存在或接口地址不对，请检查设置';
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

  /** 投影成 Anthropic messages 数组（相邻同角色合并）。 */
  private buildMessages(nodes: ConversationNode[]): Object[] {
    const messages: Object[] = [];
    let pendingRole: string = '';
    let pendingParts: Object[] = [];
    for (const node of nodes) {
      if (node.role === 'system') {
        continue;
      }
      const role: string = node.role === 'assistant' ? 'assistant' : 'user';
      const parts: Object[] = this.buildParts(node);
      if (parts.length === 0) {
        continue;
      }
      if (pendingRole.length === 0) {
        pendingRole = role;
        pendingParts = parts;
        continue;
      }
      if (pendingRole === role) {
        for (const part of parts) {
          pendingParts.push(part);
        }
      } else {
        messages.push(this.messageItem(pendingRole, pendingParts));
        pendingRole = role;
        pendingParts = parts;
      }
    }
    if (pendingRole.length > 0) {
      messages.push(this.messageItem(pendingRole, pendingParts));
    }
    return messages;
  }

  /** 单个节点的内容块。 */
  private buildParts(node: ConversationNode): Object[] {
    const parts: Object[] = [];
    for (const item of node.items) {
      const kind: string = item.kind;
      if (kind === 'text') {
        const text: string = item.text === undefined ? '' : item.text;
        if (text.length > 0) {
          parts.push(this.textBlock(text));
        }
      } else if (kind === 'checkpoint_summary') {
        const text: string = item.text === undefined ? '' : item.text;
        if (text.length > 0) {
          parts.push(this.textBlock(`[对话记忆摘要] ${text}`));
        }
      } else if (kind === 'reasoning') {
        // 没有签名的 thinking 块回传会被拒绝 → 直接丢弃（不影响最终回答）。
        const block: Object | null = this.thinkingBlock(item);
        if (block !== null) {
          parts.push(block);
        }
      } else if (kind === 'tool_call') {
        parts.push(this.toolUseBlock(item));
      } else if (kind === 'tool_result') {
        parts.push(this.toolResultBlock(item));
      } else if (kind === 'web_search_call') {
        const fallback: string = this.fallbackText(item);
        if (fallback.length > 0) {
          parts.push(this.textBlock(fallback));
        }
      } else if (kind === 'image') {
        const mime: string = item.mimeType === undefined ? '图片' : item.mimeType;
        parts.push(this.textBlock(`[${mime}：当前通道未上传图片数据，仅保留占位说明]`));
      } else if (kind === 'file_ref') {
        const mime: string = item.mimeType === undefined ? '文件' : item.mimeType;
        parts.push(this.textBlock(`[附件：${mime}]`));
      }
    }
    return parts;
  }

  private textBlock(text: string): Record<string, Object> {
    const block: Record<string, Object> = newObjectRecord();
    block['type'] = 'text';
    block['text'] = text;
    return block;
  }

  private messageItem(role: string, parts: Object[]): Record<string, Object> {
    const message: Record<string, Object> = newObjectRecord();
    message['role'] = role;
    message['content'] = parts;
    return message;
  }

  private thinkingBlock(item: CanonicalItem): Object | null {
    const vr: VendorRaw | undefined = item.vendorRaw;
    const text: string = item.text === undefined ? '' : item.text;
    if (vr === undefined || vr.signature === undefined || vr.signature.length === 0) {
      return null;
    }
    if (text.length === 0) {
      return null;
    }
    const block: Record<string, Object> = newObjectRecord();
    block['type'] = 'thinking';
    block['thinking'] = text;
    block['signature'] = vr.signature;
    return block;
  }

  private toolUseBlock(item: CanonicalItem): Record<string, Object> {
    const block: Record<string, Object> = newObjectRecord();
    block['type'] = 'tool_use';
    block['id'] = item.callId === undefined ? item.id : item.callId;
    block['name'] = item.toolName === undefined ? '' : item.toolName;
    const argsJson: string = item.argumentsJson === undefined ? '{}' : item.argumentsJson;
    const input: Record<string, Object> | null = parseRecord(argsJson);
    block['input'] = input === null ? newObjectRecord() : input;
    return block;
  }

  private toolResultBlock(item: CanonicalItem): Record<string, Object> {
    const block: Record<string, Object> = newObjectRecord();
    block['type'] = 'tool_result';
    block['tool_use_id'] = item.callId === undefined ? item.id : item.callId;
    block['content'] = item.text === undefined ? '' : item.text;
    if (item.isError === true) {
      block['is_error'] = true;
    }
    return block;
  }

  private functionTool(spec: ToolSpec): Record<string, Object> {
    const tool: Record<string, Object> = newObjectRecord();
    tool['name'] = spec.name;
    tool['description'] = spec.description;
    const schema: Record<string, Object> | null = parseRecord(spec.parametersJson);
    if (schema !== null) {
      tool['input_schema'] = schema;
    } else {
      const empty: Record<string, Object> = newObjectRecord();
      empty['type'] = 'object';
      const props: Record<string, Object> = newObjectRecord();
      empty['properties'] = props;
      tool['input_schema'] = empty;
    }
    return tool;
  }

  /** 异构厂商 / 已卸载载荷的降级文本。 */
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

  /** 诊断用：读取响应体里的错误信息（非流式）。 */
  describeErrorBody(body: string): string {
    const rec: Record<string, Object> | null = parseRecord(body);
    if (rec === null) {
      return bodySnippet(body, 120);
    }
    const error: Record<string, Object> | null = getObj(rec, 'error');
    return getStr(error, 'message', bodySnippet(body, 120));
  }
}
