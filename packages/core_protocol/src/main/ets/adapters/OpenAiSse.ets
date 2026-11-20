/**
 * OpenAI Chat Completions 兼容端点的 SSE 解析（纯逻辑，零平台依赖）。
 *
 * 兼容范围：OpenAI 官方、vLLM / Ollama / OneAPI 等任意 `/chat/completions` 兼容服务。
 *
 * - 终止：`data: [DONE]`（与 Responses API 不同）。
 * - 文本：`choices[0].delta.content`；
 * - 思维链：`choices[0].delta.reasoning_content`（DeepSeek 系）或 `delta.reasoning`（部分兼容实现）；
 * - 工具调用：`choices[0].delta.tool_calls[]`（首块带 id/name，后续只带 arguments 增量）；
 * - 用量：`usage`（需要请求带 `stream_options.include_usage=true`）：
 *   `prompt_tokens` / `completion_tokens` / `prompt_tokens_details.cached_tokens`
 *   或 DeepSeek 的 `prompt_cache_hit_tokens`。
 */
import { StreamEvent, StreamEventType, StreamPayload, UsageInfo } from '../interfaces/ProtocolTypes';
import { getNum, getObj, getObjList, getStr, parseRecord } from '../util/JsonLite';

/** 一次流内需要保留的状态（tool_calls 的 index → id 只在首块出现）。 */
export class OpenAiSseState {
  toolIds: Map<number, string> = new Map<number, string>();
  toolNames: Map<number, string> = new Map<number, string>();

  reset(): void {
    this.toolIds.clear();
    this.toolNames.clear();
  }
}

function mkEvent(type: StreamEventType, payload: StreamPayload): StreamEvent {
  const event: StreamEvent = { type: type, payload: payload };
  return event;
}

/** 把已开启但未收尾的工具调用逐个发 end 事件。 */
function closeOpenTools(state: OpenAiSseState, out: StreamEvent[]): void {
  const indexes: number[] = [];
  state.toolIds.forEach((value: string, key: number) => {
    indexes.push(key);
  });
  for (const index of indexes) {
    const id: string | undefined = state.toolIds.get(index);
    const name: string | undefined = state.toolNames.get(index);
    if (id !== undefined) {
      const payload: StreamPayload = {
        phase: 'end',
        callId: id,
        toolName: name === undefined ? '' : name
      };
      out.push(mkEvent('tool_call_delta', payload));
    }
    state.toolIds.delete(index);
    state.toolNames.delete(index);
  }
}

/** usage → UsageInfo。 */
function toUsageInfo(usage: Record<string, Object> | null): UsageInfo | null {
  if (usage === null) {
    return null;
  }
  const inputTokens: number = getNum(usage, 'prompt_tokens', getNum(usage, 'input_tokens', 0));
  const outputTokens: number = getNum(usage, 'completion_tokens', getNum(usage, 'output_tokens', 0));
  const details: Record<string, Object> | null = getObj(usage, 'prompt_tokens_details');
  let cachedTokens: number = details === null ? 0 : getNum(details, 'cached_tokens', 0);
  if (cachedTokens === 0) {
    // DeepSeek Chat Completions 用 prompt_cache_hit_tokens。
    cachedTokens = getNum(usage, 'prompt_cache_hit_tokens', 0);
  }
  const outDetails: Record<string, Object> | null = getObj(usage, 'completion_tokens_details');
  const reasoningTokens: number = outDetails === null ? 0 : getNum(outDetails, 'reasoning_tokens', 0);
  const info: UsageInfo = {
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedTokens: cachedTokens,
    reasoningTokens: reasoningTokens,
    cacheHitRatio: inputTokens > 0 ? cachedTokens / inputTokens : 0
  };
  return info;
}

/** 兼容端点错误对象 → 中文提示。 */
function errorPayload(code: string, rawMessage: string, retriableDefault: boolean): StreamPayload {
  let message: string = rawMessage;
  let retriable: boolean = retriableDefault;
  if (code === 'invalid_api_key' || code === 'authentication_error' || code === 'unauthorized') {
    message = '密钥无效，请重新填写';
    retriable = false;
  } else if (code === 'insufficient_quota' || code === 'insufficient_balance') {
    message = '账户额度不足，请充值后再试';
    retriable = false;
  } else if (code === 'rate_limit_exceeded' || code === 'rate_limit_error') {
    message = '请求太频繁，请稍后再试';
    retriable = true;
  } else if (code === 'invalid_request_error' || code === 'context_length_exceeded') {
    message = rawMessage.length > 0 ? `请求参数不被接受：${rawMessage}` : '请求参数不被接受';
    retriable = code === 'context_length_exceeded';
  } else if (code === 'server_error' || code === 'overloaded_error') {
    message = rawMessage.length > 0 ? rawMessage : '服务端暂时出错，请稍后重试';
    retriable = true;
  } else if (message.length === 0) {
    message = '服务端返回未知错误';
  }
  const payload: StreamPayload = {
    message: message,
    errorCode: code.length > 0 ? code : 'unknown_error',
    retriable: retriable
  };
  return payload;
}

/**
 * 解析一个 Chat Completions SSE 帧。
 * @param state 跨事件状态（由适配器持有）
 * @param eventName SSE `event:` 名（Chat Completions 通常不设，为空）
 * @param dataJson `data:` 文本（可能为 `[DONE]`）
 */
export function parseOpenAiSse(state: OpenAiSseState, eventName: string, dataJson: string): StreamEvent[] {
  const out: StreamEvent[] = [];
  if (dataJson === undefined || dataJson === null) {
    return out;
  }
  const text: string = dataJson.trim();
  if (text.length === 0) {
    return out;
  }
  if (text === '[DONE]') {
    closeOpenTools(state, out);
    const payload: StreamPayload = {};
    out.push(mkEvent('completed', payload));
    return out;
  }
  const env: Record<string, Object> | null = parseRecord(text);
  if (env === null) {
    return out;
  }

  // 流内错误对象（OpenAI 兼容端点有时在 200 的流里回 error）
  const errObj: Record<string, Object> | null = getObj(env, 'error');
  if (errObj !== null) {
    const code: string = getStr(errObj, 'code', getStr(errObj, 'type', 'server_error'));
    const rawMessage: string = getStr(errObj, 'message', '');
    out.push(mkEvent('error', errorPayload(code, rawMessage, true)));
    return out;
  }
  if (eventName === 'error') {
    const code: string = getStr(env, 'code', 'server_error');
    const rawMessage: string = getStr(env, 'message', '');
    out.push(mkEvent('error', errorPayload(code, rawMessage, true)));
    return out;
  }

  // 增量发生在 choices[0]；usage 在最后一个 chunk（可能 choices 为空数组）
  const choices: Record<string, Object>[] = getObjList(env, 'choices');
  if (choices.length > 0) {
    const choice: Record<string, Object> = choices[0];
    const delta: Record<string, Object> | null = getObj(choice, 'delta');
    if (delta !== null) {
      const content: string = getStr(delta, 'content', '');
      if (content.length > 0) {
        const payload: StreamPayload = { delta: content };
        out.push(mkEvent('text_delta', payload));
      }
      let reasoning: string = getStr(delta, 'reasoning_content', '');
      if (reasoning.length === 0) {
        reasoning = getStr(delta, 'reasoning', '');
      }
      if (reasoning.length > 0) {
        const payload: StreamPayload = { delta: reasoning };
        out.push(mkEvent('reasoning_delta', payload));
      }
      const toolCalls: Record<string, Object>[] = getObjList(delta, 'tool_calls');
      for (const call of toolCalls) {
        const index: number = getNum(call, 'index', 0);
        const id: string = getStr(call, 'id', '');
        const fn: Record<string, Object> | null = getObj(call, 'function');
        const name: string = getStr(fn, 'name', '');
        const args: string = getStr(fn, 'arguments', '');
        if (id.length > 0 || name.length > 0) {
          if (id.length > 0) {
            state.toolIds.set(index, id);
          }
          if (name.length > 0) {
            state.toolNames.set(index, name);
          }
          const knownId: string | undefined = state.toolIds.get(index);
          const knownName: string | undefined = state.toolNames.get(index);
          const payload: StreamPayload = {
            phase: 'start',
            callId: knownId === undefined ? '' : knownId,
            toolName: knownName === undefined ? '' : knownName,
            argumentsDelta: args
          };
          out.push(mkEvent('tool_call_delta', payload));
        } else if (args.length > 0) {
          const knownId: string | undefined = state.toolIds.get(index);
          const payload: StreamPayload = {
            phase: 'delta',
            callId: knownId === undefined ? '' : knownId,
            argumentsDelta: args
          };
          out.push(mkEvent('tool_call_delta', payload));
        }
      }
    }
    const finishReason: string = getStr(choice, 'finish_reason', '');
    if (finishReason.length > 0) {
      closeOpenTools(state, out);
      if (finishReason === 'length') {
        const payload: StreamPayload = {
          message: '回答达到长度上限被截断，可提高“最大输出长度”后再试',
          errorCode: 'max_tokens',
          retriable: true
        };
        out.push(mkEvent('error', payload));
      }
    }
  }

  const usage: UsageInfo | null = toUsageInfo(getObj(env, 'usage'));
  if (usage !== null) {
    const payload: StreamPayload = { usage: usage };
    out.push(mkEvent('usage_final', payload));
  }
  return out;
}
