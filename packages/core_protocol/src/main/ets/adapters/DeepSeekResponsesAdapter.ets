/**
 * DeepSeek Responses API 适配器。
 *
 * 事实来源：docs/API_REFERENCE.md §1、§3（2026-11-19 抓取官方文档）。
 *
 * 关键约束（违反即 400，务必保留）：
 * - 端点为 `POST {baseUrl}/responses`（**无 `/v1`**），无状态：每轮必须回传完整 `input`。
 * - 终止事件是 `response.completed` / `response.incomplete` / `response.failed`，**没有 `[DONE]`**。
 * - 同厂商多轮必须把 `web_search_call` item 原样回传（保留 `kind` / `action` / `page` / `signature`）。
 * - 异构厂商历史用 `fallbackSummary` 降级成纯文本，严禁把未知字段塞进 input。
 * - `input` 以 assistant 的 message 或 reasoning item 结尾 → 400（不支持续写）。
 * - 声明联网工具（`deepseek_web_search` / `deepseek_read_url`）时：
 *   `tool_choice` 绝不能指定这两个；带 allowed_domains/blocked_domains/after/lang 过滤 → 400，
 *   因此有过滤条件时不声明服务端联网工具（改由 core_plugin 轨道 B 独立清洗）。
 * - 官方未公布 `other tools cannot be used together with ... or title yet` 的确切边界，
 *   本实现对"联网工具 / 函数工具 / title"三者采取互斥的保守策略（见 buildRequest 注释）。
 */
import { CanonicalItem, ConversationNode, VendorRaw } from '@app/core_model';
import {
  ConnectionTestResult, HttpRequestSpec, ModelProfile, ProtocolKind, RequestOptions, StreamEvent, ToolSpec,
  WebToolOption
} from '../interfaces/ProtocolTypes';
import { ProviderAdapter } from '../interfaces/ProviderAdapter';
import { parseDeepSeekSse } from './DeepSeekSse';
import { bodySnippet, joinUrl } from '../util/UrlUtil';
import {
  asRecord, getObj, getObjList, getStr, newObjectRecord, parseRecord
} from '../util/JsonLite';

/** 默认最大输出 token（DeepSeek 上限 384K，这里保守取 8K）。 */
const DEFAULT_MAX_OUTPUT_TOKENS: number = 8192;
/** 流式请求超时（rcp 的 transferMs 由 RcpStreamClient 另设大值）。 */
const STREAM_TIMEOUT_MS: number = 1800000;
/** 连接测试超时。 */
const PING_TIMEOUT_MS: number = 20000;

export class DeepSeekResponsesAdapter implements ProviderAdapter {
  readonly protocol: ProtocolKind = 'deepseek_responses';

  buildRequest(profile: ModelProfile, nodes: ConversationNode[], options: RequestOptions): HttpRequestSpec {
    const body: Record<string, Object> = newObjectRecord();
    body['model'] = profile.modelId;
    body['stream'] = true;

    // 1) 历史投影为 Responses API 的 input item 数组
    const input: Object[] = [];
    for (const node of nodes) {
      this.projectNode(input, node, profile);
    }
    this.ensureEndsWithUser(input);
    body['input'] = input;

    // 2) system 提示词走顶层 instructions（而不是塞进 input，保持前缀稳定）
    const instructions: string = options.systemPrompt === undefined ? '' : options.systemPrompt;
    if (instructions.length > 0) {
      body['instructions'] = instructions;
    }

    // 3) 思考档位（v3 六档）→ DeepSeek reasoning.effort
    //    官方允许值：none | low | high | max（docs/API_REFERENCE.md §0 / §1.2）。
    //    `medium` 是文档列明的输入端别名（服务端归一化为 high）→ med→medium 合法且等价于 high；
    //    xhigh 显式映射 `max` 以保留第 6 档语义（文档默认归一化 xhigh→high，两者都是合法输入）。
    if (profile.supportsThinking) {
      const reasoning: Record<string, Object> = newObjectRecord();
      const level = options.thinkingLevel;
      if (level === 'off') {
        reasoning['effort'] = 'none';
      } else if (level === 'min' || level === 'low') {
        reasoning['effort'] = 'low';
      } else if (level === 'med') {
        reasoning['effort'] = 'medium';
      } else if (level === 'high') {
        reasoning['effort'] = 'high';
      } else {
        reasoning['effort'] = 'max';
      }
      body['reasoning'] = reasoning;
    }

    // 4) 输出长度与采样（思考模式下 temperature 无效，但传了不报错）
    const maxOut: number = options.maxOutputTokens === undefined ? DEFAULT_MAX_OUTPUT_TOKENS
      : options.maxOutputTokens;
    if (maxOut > 0) {
      body['max_output_tokens'] = maxOut;
    }
    if (options.temperature !== undefined) {
      body['temperature'] = options.temperature;
    }
    // 4.1) Top-P 透传：字段名 `top_p`（docs/API_REFERENCE.md §1.2 / §1.2 行为说明）。
    //      注意各模型在思考模式下会被服务端归一化或忽略（flash 低于 0.95 按 0.95；v4-pro 带工具恒 0.95），
    //      这属于官方行为，不会 400，因此有值就透传。
    if (options.topP !== undefined && options.topP > 0 && options.topP <= 1) {
      body['top_p'] = options.topP;
    }

    // 5) 工具：联网工具（服务端）与函数工具（客户端）按官方限制互斥
    const tools: Object[] = [];
    const webDeclared: boolean = this.appendWebTools(tools, profile, options);
    let functionToolCount: number = 0;
    if (!webDeclared && options.toolSpecs !== undefined) {
      for (const spec of options.toolSpecs) {
        tools.push(this.functionTool(spec));
        functionToolCount++;
      }
    }
    if (tools.length > 0) {
      body['tools'] = tools;
      // 注意：即使只有函数工具也不显式传 tool_choice（默认 auto 即可），
      // 且绝不能把 tool_choice 指向 deepseek_web_search / deepseek_read_url（400）。
    }

    // 6) 标题：官方建议只在会话第一轮开启；带工具时保守不开启（官方错误文案含 title 互斥）
    const noTools: boolean = tools.length === 0;
    if (noTools && this.isFirstRound(nodes)) {
      const titleOption: Record<string, Object> = newObjectRecord();
      titleOption['enabled'] = true;
      body['title'] = titleOption;
    }

    const headers: Map<string, string> = new Map<string, string>();
    headers.set('content-type', 'application/json');
    headers.set('accept', 'text/event-stream');

    const spec: HttpRequestSpec = {
      url: joinUrl(profile.baseUrl, '/responses'),
      method: 'POST',
      headers: headers,
      bodyJson: JSON.stringify(body),
      timeoutMs: STREAM_TIMEOUT_MS,
      stream: true
    };
    return spec;
  }

  parseSseEvent(eventName: string, dataJson: string): StreamEvent[] {
    return parseDeepSeekSse(eventName, dataJson);
  }

  /** 连接测试：发一个 1 token 的最小非流式请求（比 /models 更能验证模型名与密钥）。 */
  buildPingRequest(profile: ModelProfile): HttpRequestSpec {
    const body: Record<string, Object> = newObjectRecord();
    body['model'] = profile.modelId;
    body['input'] = '你好';
    body['max_output_tokens'] = 1;
    body['stream'] = false;
    const reasoning: Record<string, Object> = newObjectRecord();
    reasoning['effort'] = 'none';
    body['reasoning'] = reasoning;
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('content-type', 'application/json');
    headers.set('accept', 'application/json');
    const spec: HttpRequestSpec = {
      url: joinUrl(profile.baseUrl, '/responses'),
      method: 'POST',
      headers: headers,
      bodyJson: JSON.stringify(body),
      timeoutMs: PING_TIMEOUT_MS,
      stream: false
    };
    return spec;
  }

  parsePingResponse(statusCode: number, body: string): ConnectionTestResult {
    const message: string = this.pingMessage(statusCode, body);
    const result: ConnectionTestResult = {
      ok: statusCode === 200,
      latencyMs: 0,
      message: message
    };
    return result;
  }

  /** HTTP 状态码 → 直白中文诊断。 */
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
      return '接口地址不存在，请检查模型接口地址';
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

  // ---------------------------------------------------------------- 请求投影

  /** 把一条轨迹节点投影为 0..N 个 Responses input item。 */
  private projectNode(out: Object[], node: ConversationNode, profile: ModelProfile): void {
    if (node.role === 'system') {
      // system 由 options.systemPrompt（instructions）统一承载，这里跳过避免重复。
      return;
    }
    if (node.role === 'user') {
      const message: Object | null = this.buildContentMessage('user', node.items, profile);
      if (message !== null) {
        out.push(message);
      }
      return;
    }
    if (node.role === 'assistant') {
      this.projectAssistant(out, node, profile);
      return;
    }
    // role === 'tool'：function_call_output（call_id 必须配对）
    this.projectToolNode(out, node);
  }

  /** user / developer 消息：文本与图片合成一条 message item。 */
  private buildContentMessage(role: string, items: CanonicalItem[], profile: ModelProfile): Object | null {
    const parts: Object[] = [];
    for (const item of items) {
      const kind: string = item.kind;
      if (kind === 'text' || kind === 'checkpoint_summary') {
        const text: string = item.text === undefined ? '' : item.text;
        const finalText: string = kind === 'checkpoint_summary' ? `[对话记忆摘要] ${text}` : text;
        if (finalText.length > 0) {
          parts.push(this.textPart(role === 'assistant' ? 'output_text' : 'input_text', finalText));
        }
      } else if (kind === 'image') {
        const imagePart: Object | null = this.imagePart(item, profile);
        if (imagePart !== null) {
          parts.push(imagePart);
        }
      } else if (kind === 'file_ref') {
        const mime: string = item.mimeType === undefined ? '文件' : item.mimeType;
        parts.push(this.textPart('input_text', `[附件：${mime}]`));
      } else if (kind === 'web_search_call') {
        const fallback: string = this.fallbackText(item);
        if (fallback.length > 0) {
          parts.push(this.textPart('input_text', fallback));
        }
      } else if (kind === 'tool_result' || kind === 'tool_call') {
        // user 消息里通常不会出现，容错降级为文本。
        const fallback: string = this.fallbackText(item);
        if (fallback.length > 0) {
          parts.push(this.textPart('input_text', fallback));
        }
      }
    }
    if (parts.length === 0) {
      return null;
    }
    return this.messageItem(role, parts);
  }

  /** assistant 节点：按 item 顺序产出 reasoning / message / function_call / web_search_call。 */
  private projectAssistant(out: Object[], node: ConversationNode, profile: ModelProfile): void {
    let parts: Object[] = [];
    for (const item of node.items) {
      const kind: string = item.kind;
      if (kind === 'text') {
        const text: string = item.text === undefined ? '' : item.text;
        if (text.length > 0) {
          parts.push(this.textPart('output_text', text));
        }
        continue;
      }
      if (kind === 'image' || kind === 'file_ref') {
        // 官方明确：assistant 消息里的图片会 400 → 直接跳过（降级为无图）。
        continue;
      }
      // 其余 item 类型不能塞进 message.content，先把已累积的文本冲出。
      if (parts.length > 0) {
        out.push(this.messageItem('assistant', parts));
        parts = [];
      }
      if (kind === 'reasoning') {
        const text: string = item.text === undefined ? '' : item.text;
        if (text.length > 0) {
          out.push(this.reasoningItem(item, text));
        }
      } else if (kind === 'tool_call') {
        out.push(this.functionCallItem(item));
      } else if (kind === 'web_search_call') {
        if (this.isSameProvider(item, profile)) {
          out.push(this.webSearchItem(item));
        } else {
          const fallback: string = this.fallbackText(item);
          if (fallback.length > 0) {
            out.push(this.messageItem('assistant', [this.textPart('output_text', fallback)]));
          }
        }
      } else if (kind === 'checkpoint_summary') {
        const text: string = item.text === undefined ? '' : item.text;
        if (text.length > 0) {
          out.push(this.messageItem('developer', [this.textPart('input_text', `[对话记忆摘要] ${text}`)]));
        }
      } else if (kind === 'tool_result') {
        out.push(this.functionCallOutputItem(item));
      }
    }
    if (parts.length > 0) {
      out.push(this.messageItem('assistant', parts));
    }
  }

  /** tool 节点：tool_result → function_call_output。 */
  private projectToolNode(out: Object[], node: ConversationNode): void {
    for (const item of node.items) {
      if (item.kind === 'tool_result') {
        out.push(this.functionCallOutputItem(item));
      } else if (item.kind === 'text') {
        const text: string = item.text === undefined ? '' : item.text;
        if (text.length > 0) {
          out.push(this.functionCallOutputItem(item));
        }
      }
    }
  }

  /** 官方限制：input 不能以 assistant message / reasoning item 结尾（不支持续写）。 */
  private ensureEndsWithUser(input: Object[]): void {
    if (input.length === 0) {
      input.push(this.messageItem('user', [this.textPart('input_text', '你好')]));
      return;
    }
    const last: Record<string, Object> | null = asRecord(input[input.length - 1]);
    if (last === null) {
      input.push(this.messageItem('user', [this.textPart('input_text', '请继续。')]));
      return;
    }
    const type: string = getStr(last, 'type', '');
    const role: string = getStr(last, 'role', '');
    const badEnd: boolean = (type === 'message' && role !== 'user')
      || type === 'reasoning' || type === 'function_call' || type === 'web_search_call';
    if (badEnd) {
      input.push(this.messageItem('user', [this.textPart('input_text', '请继续。')]));
    }
  }

  // ------------------------------------------------------------ item 构造器

  private textPart(partType: string, text: string): Record<string, Object> {
    const part: Record<string, Object> = newObjectRecord();
    part['type'] = partType;
    part['text'] = text;
    return part;
  }

  private messageItem(role: string, parts: Object[]): Record<string, Object> {
    const item: Record<string, Object> = newObjectRecord();
    item['type'] = 'message';
    item['role'] = role;
    item['content'] = parts;
    return item;
  }

  private reasoningItem(item: CanonicalItem, text: string): Record<string, Object> {
    const rec: Record<string, Object> = newObjectRecord();
    rec['type'] = 'reasoning';
    if (item.id.length > 0) {
      rec['id'] = item.id;
    }
    const part: Record<string, Object> = newObjectRecord();
    part['type'] = 'reasoning_text';
    part['text'] = text;
    const content: Object[] = [part];
    rec['content'] = content;
    // 明文 reasoning 不返回 encrypted_content；若上游确实带了签名则一并回传。
    const vr: VendorRaw | undefined = item.vendorRaw;
    if (vr !== undefined && vr.signature !== undefined && vr.signature.length > 0) {
      rec['signature'] = vr.signature;
    }
    return rec;
  }

  private functionCallItem(item: CanonicalItem): Record<string, Object> {
    const rec: Record<string, Object> = newObjectRecord();
    rec['type'] = 'function_call';
    if (item.id.length > 0) {
      rec['id'] = item.id;
    }
    rec['call_id'] = item.callId === undefined ? item.id : item.callId;
    rec['name'] = item.toolName === undefined ? '' : item.toolName;
    rec['arguments'] = item.argumentsJson === undefined ? '{}' : item.argumentsJson;
    return rec;
  }

  private functionCallOutputItem(item: CanonicalItem): Record<string, Object> {
    const rec: Record<string, Object> = newObjectRecord();
    rec['type'] = 'function_call_output';
    rec['call_id'] = item.callId === undefined ? item.id : item.callId;
    rec['output'] = item.text === undefined ? '' : item.text;
    return rec;
  }

  /** 同厂商 web_search_call 原样回传：保留 kind / action / page / signature。 */
  private webSearchItem(item: CanonicalItem): Record<string, Object> {
    const vr: VendorRaw | undefined = item.vendorRaw;
    const rec: Record<string, Object> = newObjectRecord();
    rec['type'] = 'web_search_call';
    rec['id'] = item.id;
    if (vr !== undefined && vr.status !== undefined && vr.status.length > 0) {
      rec['status'] = vr.status;
    }
    if (vr !== undefined && vr.searchKind !== undefined) {
      rec['kind'] = vr.searchKind;
    }
    const action: Record<string, Object> = newObjectRecord();
    let actionType: string = 'search';
    if (vr !== undefined && vr.pageMeta !== undefined) {
      actionType = 'open_page';
    }
    action['type'] = actionType;
    if (actionType === 'search') {
      // 契约里没存 action.queries，只能给空数组（不影响 signature 还原网页正文）。
      const queries: Object[] = [];
      action['queries'] = queries;
    }
    const sources: Object[] = [];
    if (vr !== undefined && vr.sources !== undefined) {
      for (const one of vr.sources) {
        const source: Record<string, Object> = newObjectRecord();
        source['type'] = 'url';
        source['url'] = one.url;
        source['title'] = one.title;
        source['snippet'] = one.snippet;
        if (one.siteName !== undefined && one.siteName.length > 0) {
          source['site_name'] = one.siteName;
        }
        sources.push(source);
      }
    }
    action['sources'] = sources;
    rec['action'] = action;
    if (vr !== undefined && vr.pageMeta !== undefined) {
      const page: Record<string, Object> = newObjectRecord();
      page['url'] = vr.pageMeta.url;
      page['title'] = vr.pageMeta.title;
      if (vr.pageMeta.publishedAt !== undefined && vr.pageMeta.publishedAt.length > 0) {
        page['published_at'] = vr.pageMeta.publishedAt;
      }
      rec['page'] = page;
    }
    // signature 必须原样回传（read_link 的网页正文靠它还原）。
    if (vr !== undefined && vr.signature !== undefined && vr.signature.length > 0) {
      rec['signature'] = vr.signature;
    }
    return rec;
  }

  /** 图片：仅 flash 系支持 input_image；无 fileId 时降级成文字占位。 */
  private imagePart(item: CanonicalItem, profile: ModelProfile): Object | null {
    const supportsVision: boolean = profile.modelId.indexOf('flash') >= 0;
    if (supportsVision && item.fileId !== undefined && item.fileId.length > 0) {
      const part: Record<string, Object> = newObjectRecord();
      part['type'] = 'input_image';
      part['file_id'] = item.fileId;
      return part;
    }
    const mime: string = item.mimeType === undefined ? '图片' : item.mimeType;
    return this.textPart('input_text', `[${mime}，当前模型无法直接查看图片内容]`);
  }

  private functionTool(spec: ToolSpec): Record<string, Object> {
    const tool: Record<string, Object> = newObjectRecord();
    tool['type'] = 'function';
    tool['name'] = spec.name;
    tool['description'] = spec.description;
    const schema: Record<string, Object> | null = parseRecord(spec.parametersJson);
    if (schema !== null) {
      tool['parameters'] = schema;
    } else {
      const empty: Record<string, Object> = newObjectRecord();
      empty['type'] = 'object';
      const props: Record<string, Object> = newObjectRecord();
      empty['properties'] = props;
      tool['parameters'] = empty;
    }
    return tool;
  }

  /**
   * 是否声明服务端联网工具。
   * 只有 server_managed 且无任何过滤条件时才声明：带 allowed_domains / blocked_domains /
   * after / lang 过滤会直接 400（由 core_plugin 轨道 B 负责过滤场景）。
   */
  private appendWebTools(tools: Object[], profile: ModelProfile, options: RequestOptions): boolean {
    if (!profile.supportsServerWebTools) {
      return false;
    }
    if (options.webMode !== 'server_managed') {
      return false;
    }
    const web: WebToolOption | undefined = options.webTool;
    if (web !== undefined) {
      if (web.includeDomains !== undefined && web.includeDomains.length > 0) {
        return false;
      }
      if (web.excludeDomains !== undefined && web.excludeDomains.length > 0) {
        return false;
      }
      if (web.afterDate !== undefined && web.afterDate.length > 0) {
        return false;
      }
      if (web.languages !== undefined && web.languages.length > 0) {
        return false;
      }
    }
    const search: Record<string, Object> = newObjectRecord();
    search['type'] = 'deepseek_web_search';
    tools.push(search);
    const readUrl: Record<string, Object> = newObjectRecord();
    readUrl['type'] = 'deepseek_read_url';
    tools.push(readUrl);
    return true;
  }

  // --------------------------------------------------------------- 小工具

  private isSameProvider(item: CanonicalItem, profile: ModelProfile): boolean {
    const vr: VendorRaw | undefined = item.vendorRaw;
    if (vr === undefined) {
      return false;
    }
    if (vr.provider === profile.providerId) {
      return true;
    }
    return profile.protocol === 'deepseek_responses' && vr.provider === 'deepseek';
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

  /** 第一轮判定（用于 title 开关）：历史里用户消息不超过 1 条。 */
  private isFirstRound(nodes: ConversationNode[]): boolean {
    let userCount: number = 0;
    for (const node of nodes) {
      if (node.role === 'user') {
        userCount++;
      }
    }
    return userCount <= 1;
  }

  /** 诊断用：从终点事件里读取服务端标题（供非流式调用方复用）。 */
  extractTitleFromBody(body: string): string {
    const rec: Record<string, Object> | null = parseRecord(body);
    if (rec === null) {
      return '';
    }
    const title: string = getStr(rec, 'title', '');
    if (title.length > 0) {
      return title;
    }
    const resp: Record<string, Object> | null = getObj(rec, 'response');
    if (resp !== null) {
      return getStr(resp, 'title', '');
    }
    return '';
  }

  /** 诊断用：web_search_call item 的 sources 数量。 */
  countSources(body: string): number {
    const rec: Record<string, Object> | null = parseRecord(body);
    if (rec === null) {
      return 0;
    }
    const action: Record<string, Object> | null = getObj(rec, 'action');
    return getObjList(action, 'sources').length;
  }
}
