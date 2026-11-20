/**
 * Anthropic Messages API 的 SSE 事件解析（纯逻辑，零平台依赖）。
 *
 * 事件序列（官方稳定协议）：
 *   message_start → (content_block_start → content_block_delta… → content_block_stop)*
 *   → message_delta → message_stop
 * 另有 `ping` 心跳与 `error` 错误事件。
 *
 * 本解析器带少量状态（输入 token 在 message_start 才给、输出 token 在 message_delta 才给、
 * tool_use 的 id/name 只在 content_block_start 出现一次），因此由适配器持有一个
 * AnthropicSseState 实例；每次新请求前调用 reset()。
 */
import { StreamEvent, StreamEventType, StreamPayload, UsageInfo } from '../interfaces/ProtocolTypes';
import { getNum, getObj, getStr, newObjectRecord, parseRecord, stringifyRecord } from '../util/JsonLite';

/** 一次消息流内需要跨事件保留的状态。 */
export class AnthropicSseState {
  inputTokens: number = 0;
  cachedTokens: number = 0;
  outputTokens: number = 0;
  /** content block index → tool_use id。 */
  toolIds: Map<number, string> = new Map<number, string>();
  /** content block index → tool_use name。 */
  toolNames: Map<number, string> = new Map<number, string>();

  reset(): void {
    this.inputTokens = 0;
    this.cachedTokens = 0;
    this.outputTokens = 0;
    this.toolIds.clear();
    this.toolNames.clear();
  }
}

function mkEvent(type: StreamEventType, payload: StreamPayload): StreamEvent {
  const event: StreamEvent = { type: type, payload: payload };
  return event;
}

/** Anthropic 错误类型 → 中文提示 + 是否可重试。 */
function mapAnthropicError(errorType: string, rawMessage: string): StreamPayload {
  let message: string = rawMessage;
  let retriable: boolean = false;
  if (errorType === 'overloaded_error') {
    message = '服务器繁忙，请稍后重试';
    retriable = true;
  } else if (errorType === 'api_error') {
    message = rawMessage.length > 0 ? rawMessage : '服务端内部错误，请稍后重试';
    retriable = true;
  } else if (errorType === 'rate_limit_error') {
    message = '请求太频繁，请稍后再试';
    retriable = true;
  } else if (errorType === 'authentication_error') {
    message = '密钥无效，请重新填写';
  } else if (errorType === 'permission_error') {
    message = '当前密钥没有访问权限';
  } else if (errorType === 'not_found_error') {
    message = '模型不存在或接口地址不对，请检查设置';
  } else if (errorType === 'invalid_request_error') {
    message = rawMessage.length > 0 ? `请求参数不被接受：${rawMessage}` : '请求参数不被接受';
  } else if (message.length === 0) {
    message = '服务端返回未知错误';
  }
  const payload: StreamPayload = {
    message: message,
    errorCode: errorType.length > 0 ? errorType : 'unknown_error',
    retriable: retriable
  };
  return payload;
}

/** 组装 usage_final 事件（缺字段按 0）。 */
function usageEvent(state: AnthropicSseState): StreamEvent {
  const input: number = state.inputTokens;
  const cached: number = state.cachedTokens;
  const output: number = state.outputTokens;
  const info: UsageInfo = {
    inputTokens: input,
    outputTokens: output,
    cachedTokens: cached,
    reasoningTokens: 0,
    cacheHitRatio: input > 0 ? cached / input : 0
  };
  const payload: StreamPayload = { usage: info };
  return mkEvent('usage_final', payload);
}

/**
 * 解析一个 Anthropic SSE 帧。
 * @param state 跨事件状态（由适配器持有）
 * @param eventName SSE `event:` 名（可为空，回退 data.type）
 * @param dataJson `data:` 文本
 */
export function parseAnthropicSse(state: AnthropicSseState, eventName: string, dataJson: string): StreamEvent[] {
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

  if (type === 'message_start') {
    const message: Record<string, Object> | null = getObj(env, 'message');
    const usage: Record<string, Object> | null = getObj(message, 'usage');
    state.inputTokens = getNum(usage, 'input_tokens', 0);
    state.cachedTokens = getNum(usage, 'cache_read_input_tokens', 0);
    return out;
  }

  if (type === 'content_block_start') {
    const index: number = getNum(env, 'index', -1);
    const block: Record<string, Object> | null = getObj(env, 'content_block');
    const blockType: string = getStr(block, 'type', '');
    if (blockType === 'tool_use') {
      const id: string = getStr(block, 'id', '');
      const name: string = getStr(block, 'name', '');
      if (index >= 0) {
        state.toolIds.set(index, id);
        state.toolNames.set(index, name);
      }
      const payload: StreamPayload = {
        phase: 'start',
        callId: id,
        toolName: name,
        argumentsDelta: ''
      };
      out.push(mkEvent('tool_call_delta', payload));
    }
    return out;
  }

  if (type === 'content_block_delta') {
    const index: number = getNum(env, 'index', -1);
    const delta: Record<string, Object> | null = getObj(env, 'delta');
    const deltaType: string = getStr(delta, 'type', '');
    if (deltaType === 'text_delta') {
      const text: string = getStr(delta, 'text', '');
      if (text.length > 0) {
        const payload: StreamPayload = { delta: text };
        out.push(mkEvent('text_delta', payload));
      }
      return out;
    }
    if (deltaType === 'thinking_delta') {
      const thinking: string = getStr(delta, 'thinking', '');
      if (thinking.length > 0) {
        const payload: StreamPayload = { delta: thinking };
        out.push(mkEvent('reasoning_delta', payload));
      }
      return out;
    }
    if (deltaType === 'signature_delta') {
      // 签名不产出文本，但必须交给上层落盘：多轮回传 thinking 块需要它。
      const signature: string = getStr(delta, 'signature', '');
      if (signature.length > 0) {
        const raw: Record<string, Object> = newObjectRecord();
        raw['provider'] = 'anthropic';
        raw['signature'] = signature;
        const payload: StreamPayload = { vendorRawJson: stringifyRecord(raw) };
        out.push(mkEvent('reasoning_delta', payload));
      }
      return out;
    }
    if (deltaType === 'input_json_delta') {
      const partial: string = getStr(delta, 'partial_json', '');
      const callId: string = index >= 0 && state.toolIds.get(index) !== undefined
        ? (state.toolIds.get(index) as string) : '';
      const payload: StreamPayload = {
        phase: 'delta',
        callId: callId,
        argumentsDelta: partial
      };
      out.push(mkEvent('tool_call_delta', payload));
      return out;
    }
    return out;
  }

  if (type === 'content_block_stop') {
    const index: number = getNum(env, 'index', -1);
    const id: string | undefined = index >= 0 ? state.toolIds.get(index) : undefined;
    if (id !== undefined) {
      const name: string | undefined = state.toolNames.get(index);
      const payload: StreamPayload = {
        phase: 'end',
        callId: id,
        toolName: name === undefined ? '' : name
      };
      out.push(mkEvent('tool_call_delta', payload));
      state.toolIds.delete(index);
      state.toolNames.delete(index);
    }
    return out;
  }

  if (type === 'message_delta') {
    const usage: Record<string, Object> | null = getObj(env, 'usage');
    if (usage !== null) {
      const outputTokens: number = getNum(usage, 'output_tokens', -1);
      if (outputTokens >= 0) {
        state.outputTokens = outputTokens;
      }
      const inputTokens: number = getNum(usage, 'input_tokens', -1);
      if (inputTokens >= 0) {
        state.inputTokens = inputTokens;
      }
      const cacheRead: number = getNum(usage, 'cache_read_input_tokens', -1);
      if (cacheRead >= 0) {
        state.cachedTokens = cacheRead;
      }
    }
    out.push(usageEvent(state));
    const delta: Record<string, Object> | null = getObj(env, 'delta');
    const stopReason: string = getStr(delta, 'stop_reason', '');
    if (stopReason === 'max_tokens') {
      const payload: StreamPayload = {
        message: '回答达到长度上限被截断，可提高“最大输出长度”后再试',
        errorCode: 'max_tokens',
        retriable: true
      };
      out.push(mkEvent('error', payload));
    }
    return out;
  }

  if (type === 'message_stop') {
    const payload: StreamPayload = {};
    out.push(mkEvent('completed', payload));
    return out;
  }

  if (type === 'error') {
    const error: Record<string, Object> | null = getObj(env, 'error');
    const errorType: string = getStr(error, 'type', '');
    const rawMessage: string = getStr(error, 'message', '');
    out.push(mkEvent('error', mapAnthropicError(errorType, rawMessage)));
    return out;
  }

  // ping / 未知事件：忽略。
  return out;
}
