/**
 * DeepSeek Responses API 的 SSE 事件解析（纯逻辑，零平台依赖）。
 *
 * 事实来源：docs/API_REFERENCE.md §1（2026-11-19 抓取官方文档）。
 * - 端点无状态、无 `[DONE]`；终止事件为 `response.completed` / `response.incomplete` / `response.failed`。
 * - `event:` 名与 `data.type` 相同；优先用 name，name 为空时回退 `data.type`。
 * - usage 只在终点事件里有效（初始事件 usage 恒为 null）：
 *   `input_tokens` / `output_tokens` / `input_tokens_details.cached_tokens` / `output_tokens_details.reasoning_tokens`。
 * - 标题在终点事件的 `response.title`（请求时用 `title:{enabled:true}` 开启）。
 * - 以下载荷官方未公布（标 [U]），解析全部容错：reasoning_text.delta/done、
 *   function_call_arguments.delta/done、web_search_call.in_progress/searching/completed。
 *   UI 状态以 `response.output_item.added`（含完整 action）与 `response.output_item.done`
 *   （含 sources/page/signature/error）为准，三件套仅当"进度心跳"。
 *
 * 未知事件一律返回空数组；字段缺失不抛错。
 */
import { StreamEvent, StreamEventType, StreamPayload, UsageInfo } from '../interfaces/ProtocolTypes';
import {
  getNum, getObj, getObjList, getStr, hasField, newObjectRecord, parseRecord, stringifyRecord
} from '../util/JsonLite';

/** 构造一个统一事件。 */
function mkEvent(type: StreamEventType, payload: StreamPayload): StreamEvent {
  const event: StreamEvent = { type: type, payload: payload };
  return event;
}

/** usage → UsageInfo（字段缺失按 0 处理，缓存率用 cached/input 计算）。 */
function toUsageInfo(usage: Record<string, Object> | null): UsageInfo | null {
  if (usage === null) {
    return null;
  }
  const inputTokens: number = getNum(usage, 'input_tokens', 0);
  const outputTokens: number = getNum(usage, 'output_tokens', 0);
  const inputDetails: Record<string, Object> | null = getObj(usage, 'input_tokens_details');
  const cachedTokens: number = inputDetails === null ? 0 : getNum(inputDetails, 'cached_tokens', 0);
  const outputDetails: Record<string, Object> | null = getObj(usage, 'output_tokens_details');
  const reasoningTokens: number = outputDetails === null ? 0 : getNum(outputDetails, 'reasoning_tokens', 0);
  const info: UsageInfo = {
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedTokens: cachedTokens,
    reasoningTokens: reasoningTokens,
    cacheHitRatio: inputTokens > 0 ? cachedTokens / inputTokens : 0
  };
  return info;
}

/** 从 web_search_call item 的 action.sources[] 提取精简来源数组（转成 JSON 字符串）。 */
function sourcesJsonFromItem(item: Record<string, Object> | null): string {
  const action: Record<string, Object> | null = getObj(item, 'action');
  const sources: Record<string, Object>[] = getObjList(action, 'sources');
  const out: Object[] = [];
  for (const one of sources) {
    const rec: Record<string, Object> = newObjectRecord();
    rec['title'] = getStr(one, 'title', '');
    rec['url'] = getStr(one, 'url', '');
    rec['snippet'] = getStr(one, 'snippet', '');
    const siteName: string = getStr(one, 'site_name', '');
    if (siteName.length > 0) {
      rec['siteName'] = siteName;
    }
    const publishedAt: string = getStr(one, 'published_at', '');
    if (publishedAt.length > 0) {
      rec['publishedAt'] = publishedAt;
    }
    out.push(rec);
  }
  try {
    return JSON.stringify(out);
  } catch (e) {
    return '';
  }
}

/** 把 web_search_call item 整体序列化，供上层原样落盘（vendorRaw）。 */
function itemJson(item: Record<string, Object> | null): string {
  if (item === null) {
    return '';
  }
  return stringifyRecord(item);
}

/** 联网工具失败/进度状态映射成直白中文（供 UI 兜底展示）。 */
export function deepSeekSearchStatusText(status: string): string {
  if (status === 'in_progress') {
    return '正在准备联网检索';
  }
  if (status === 'searching') {
    return '正在联网搜索';
  }
  if (status === 'completed') {
    return '联网检索完成';
  }
  if (status === 'failed') {
    return '联网检索失败';
  }
  if (status === 'incomplete') {
    return '联网检索未完成';
  }
  return '';
}

/** 终点事件里的错误码 → 中文提示。 */
function deepSeekErrorMessage(code: string, fallback: string): string {
  if (code === 'server_error') {
    return '模型生成中途出错，请重试';
  }
  if (code === 'invalid_request_error') {
    return '请求参数不被接受，请检查模型与设置';
  }
  if (code === 'insufficient_quota' || code === 'insufficient_balance') {
    return '账户额度不足，请充值后重试';
  }
  if (code === 'rate_limit_exceeded') {
    return '请求太频繁，请稍后再试';
  }
  if (code.length > 0) {
    return fallback.length > 0 ? fallback : `服务端返回错误（${code}）`;
  }
  return fallback.length > 0 ? fallback : '服务端返回未知错误';
}

/** 把 web_search_call item 转成 web_search_status 事件（added/done 共用）。 */
function webSearchEvent(item: Record<string, Object> | null, fallbackStatus: string): StreamEvent[] {
  const out: StreamEvent[] = [];
  if (item === null) {
    return out;
  }
  const status: string = getStr(item, 'status', fallbackStatus);
  const payload: StreamPayload = {
    searchStatus: status,
    itemId: getStr(item, 'id', ''),
    vendorRawJson: itemJson(item),
    sourcesJson: sourcesJsonFromItem(item),
    text: deepSeekSearchStatusText(status)
  };
  out.push(mkEvent('web_search_status', payload));
  return out;
}

/** 从终点事件的 response 对象里取 usage / title / 完成态。 */
function terminalEvents(resp: Record<string, Object> | null, isCompleted: boolean): StreamEvent[] {
  const out: StreamEvent[] = [];
  if (resp === null) {
    return out;
  }
  const usage: UsageInfo | null = toUsageInfo(getObj(resp, 'usage'));
  if (usage !== null) {
    const usagePayload: StreamPayload = { usage: usage };
    out.push(mkEvent('usage_final', usagePayload));
  }
  // 标题：官方明确"流式 → 终点事件里的 response.title"。
  const title: string = getStr(resp, 'title', '');
  if (title.length > 0) {
    const titlePayload: StreamPayload = { title: title };
    out.push(mkEvent('title_generated', titlePayload));
  }
  if (isCompleted) {
    const donePayload: StreamPayload = {};
    out.push(mkEvent('completed', donePayload));
  }
  return out;
}

/**
 * 解析一个 DeepSeek Responses SSE 帧。
 * @param eventName SSE 的 `event:` 名（可为空）
 * @param dataJson `data:` 拼接后的文本
 */
export function parseDeepSeekSse(eventName: string, dataJson: string): StreamEvent[] {
  const out: StreamEvent[] = [];
  const env: Record<string, Object> | null = parseRecord(dataJson);
  if (env === null) {
    return out;
  }
  let type: string = eventName;
  if (type.length === 0) {
    type = getStr(env, 'type', '');
  }
  if (type.length === 0) {
    return out;
  }

  // 1) 文本增量（最终回答）
  if (type === 'response.output_text.delta') {
    const delta: string = getStr(env, 'delta', '');
    if (delta.length > 0) {
      const payload: StreamPayload = { delta: delta, itemId: getStr(env, 'item_id', '') };
      out.push(mkEvent('text_delta', payload));
    }
    return out;
  }

  // 2) 思维链增量
  if (type === 'response.reasoning_text.delta' || type === 'response.reasoning_summary_text.delta') {
    const delta: string = getStr(env, 'delta', '');
    if (delta.length > 0) {
      const payload: StreamPayload = { delta: delta, itemId: getStr(env, 'item_id', '') };
      out.push(mkEvent('reasoning_delta', payload));
    }
    return out;
  }

  // 3) output item 开始：联网块与函数调用需要立即上屏
  if (type === 'response.output_item.added') {
    const item: Record<string, Object> | null = getObj(env, 'item');
    if (item === null) {
      return out;
    }
    const itemType: string = getStr(item, 'type', '');
    if (itemType === 'web_search_call') {
      return webSearchEvent(item, 'in_progress');
    }
    if (itemType === 'function_call') {
      const payload: StreamPayload = {
        phase: 'start',
        callId: getStr(item, 'call_id', ''),
        toolName: getStr(item, 'name', ''),
        itemId: getStr(item, 'id', ''),
        vendorRawJson: itemJson(item)
      };
      out.push(mkEvent('tool_call_delta', payload));
    }
    return out;
  }

  // 4) output item 结束：自愈来源/签名/函数参数（官方保证这里一定有全量）
  if (type === 'response.output_item.done') {
    const item: Record<string, Object> | null = getObj(env, 'item');
    if (item === null) {
      return out;
    }
    const itemType: string = getStr(item, 'type', '');
    if (itemType === 'web_search_call') {
      return webSearchEvent(item, 'completed');
    }
    if (itemType === 'function_call') {
      const payload: StreamPayload = {
        phase: 'end',
        callId: getStr(item, 'call_id', ''),
        toolName: getStr(item, 'name', ''),
        argumentsDelta: getStr(item, 'arguments', ''),
        itemId: getStr(item, 'id', ''),
        vendorRawJson: itemJson(item)
      };
      out.push(mkEvent('tool_call_delta', payload));
    }
    return out;
  }

  // 5) 函数调用参数增量（载荷 [U]，容错）
  //    注意：这两个事件只带 item_id（item id），没有 call_id；不能把 item_id 当 callId 发出去，
  //    否则上层会把已配对的 call_id 覆盖掉（function_call_output 必须用真正的 call_id）。
  if (type === 'response.function_call_arguments.delta') {
    const delta: string = getStr(env, 'delta', '');
    if (delta.length > 0) {
      const payload: StreamPayload = {
        phase: 'delta',
        argumentsDelta: delta,
        itemId: getStr(env, 'item_id', '')
      };
      out.push(mkEvent('tool_call_delta', payload));
    }
    return out;
  }
  if (type === 'response.function_call_arguments.done') {
    const payload: StreamPayload = {
      phase: 'end',
      argumentsDelta: getStr(env, 'arguments', ''),
      itemId: getStr(env, 'item_id', '')
    };
    out.push(mkEvent('tool_call_delta', payload));
    return out;
  }

  // 6) 服务端联网三件套：只当进度心跳
  if (type === 'response.web_search_call.in_progress' || type === 'response.web_search_call.searching'
    || type === 'response.web_search_call.completed') {
    const status: string = type === 'response.web_search_call.in_progress' ? 'in_progress'
      : (type === 'response.web_search_call.searching' ? 'searching' : 'completed');
    const itemId: string = getStr(env, 'item_id', '');
    const payload: StreamPayload = { searchStatus: status, itemId: itemId, text: deepSeekSearchStatusText(status) };
    out.push(mkEvent('web_search_status', payload));
    return out;
  }

  // 7) 终点事件
  if (type === 'response.completed') {
    return terminalEvents(getObj(env, 'response'), true);
  }
  if (type === 'response.incomplete') {
    const resp: Record<string, Object> | null = getObj(env, 'response');
    const before: StreamEvent[] = terminalEvents(resp, false);
    for (const one of before) {
      out.push(one);
    }
    const details: Record<string, Object> | null = getObj(resp, 'incomplete_details');
    const reason: string = details === null ? '' : getStr(details, 'reason', '');
    let message: string = '回答未生成完整内容';
    if (reason === 'max_output_tokens') {
      message = '回答达到长度上限被截断，可提高“最大输出长度”或先整理对话记忆';
    } else if (reason === 'content_filter') {
      message = '部分内容被安全策略过滤，回答不完整';
    }
    const errorPayload: StreamPayload = { message: message, errorCode: 'incomplete', retriable: true };
    out.push(mkEvent('error', errorPayload));
    const donePayload: StreamPayload = {};
    out.push(mkEvent('completed', donePayload));
    return out;
  }
  if (type === 'response.failed') {
    const resp: Record<string, Object> | null = getObj(env, 'response');
    const before: StreamEvent[] = terminalEvents(resp, false);
    for (const one of before) {
      out.push(one);
    }
    const error: Record<string, Object> | null = getObj(resp, 'error');
    const code: string = error === null ? 'server_error' : getStr(error, 'code', 'server_error');
    const rawMessage: string = error === null ? '' : getStr(error, 'message', '');
    const errorPayload: StreamPayload = {
      message: deepSeekErrorMessage(code, rawMessage),
      errorCode: code.length > 0 ? code : 'server_error',
      retriable: code !== 'invalid_request_error'
    };
    out.push(mkEvent('error', errorPayload));
    return out;
  }

  // 8) 顶层 error 事件（HTTP 200 之外的流内错误）
  if (type === 'error' || type === 'response.error') {
    const errObj: Record<string, Object> | null = getObj(env, 'error');
    const error: Record<string, Object> = errObj === null ? env : errObj;
    const code: string = getStr(error, 'code', 'server_error');
    const rawMessage: string = getStr(error, 'message', '');
    const errorPayload: StreamPayload = {
      message: deepSeekErrorMessage(code, rawMessage),
      errorCode: code.length > 0 ? code : 'server_error',
      retriable: code !== 'invalid_request_error'
    };
    out.push(mkEvent('error', errorPayload));
    return out;
  }

  // 9) 防御性：若服务端单独发 response.title（官方文档未列，兜底支持）
  if (type === 'response.title') {
    const title: string = getStr(env, 'title', '');
    if (title.length > 0) {
      const titlePayload: StreamPayload = { title: title };
      out.push(mkEvent('title_generated', titlePayload));
    }
    return out;
  }

  // 10) 其余（created / in_progress / content_part.* / output_text.done /
  //     reasoning_text.done / annotation.added ...）不产生统一事件。
  return out;
}

/**
 * 端点事件是否为终止事件（用于诊断"流为什么还没结束"）。
 */
export function isDeepSeekTerminalEvent(eventName: string): boolean {
  return eventName === 'response.completed' || eventName === 'response.incomplete'
    || eventName === 'response.failed';
}

/**
 * 判断响应里是否带标题（供非流式调用方复用）。
 * 容错：非法 JSON / 空 body（例如网关返回 HTML 错误页）一律返回空串，绝不抛错。
 */
export function extractDeepSeekTitle(bodyJson: string): string {
  const rec: Record<string, Object> | null = parseRecord(bodyJson);
  if (rec === null) {
    return '';
  }
  const title: string = getStr(rec, 'title', '');
  if (title.length > 0) {
    return title;
  }
  const resp: Record<string, Object> | null = getObj(rec, 'response');
  if (resp !== null && hasField(resp, 'title')) {
    return getStr(resp, 'title', '');
  }
  return '';
}
