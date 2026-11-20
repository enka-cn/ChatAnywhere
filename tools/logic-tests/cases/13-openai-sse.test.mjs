/**
 * OpenAI Chat Completions 兼容端点事件解析（packages/core_protocol/adapters/OpenAiSse.ets）
 *
 * 覆盖：choices[0].delta.content / reasoning_content / tool_calls 增量、
 * 结束 [DONE]（与 Responses 的差异点）、finish_reason=length 截断提示、
 * usage（含 prompt_tokens_details.cached_tokens 与 DeepSeek 的 prompt_cache_hit_tokens）、
 * 流内 error 对象；并验证「工具未收尾时结束会补 end 事件」。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_protocol/src/main/ets/adapters/OpenAiSse.ts';
const m = await tryImport(P);

if (!m) {
  skip('OpenAI 兼容事件解析（全部用例）', missingReason(P));
  summarize();
} else {
  const types = (events) => events.map((e) => e.type);
  const freshState = () => new m.OpenAiSseState();

  test('choices[0].delta.content → text_delta', () => {
    const out = m.parseOpenAiSse(freshState(), '',
      '{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}');
    assert.deepEqual(types(out), ['text_delta']);
    assert.equal(out[0].payload.delta, '你好');
  });

  test('delta.reasoning_content → reasoning_delta；缺省时回退 delta.reasoning', () => {
    const a = m.parseOpenAiSse(freshState(), '',
      '{"choices":[{"index":0,"delta":{"reasoning_content":"想一想"}}]}');
    assert.deepEqual(types(a), ['reasoning_delta']);
    assert.equal(a[0].payload.delta, '想一想');
    const b = m.parseOpenAiSse(freshState(), '',
      '{"choices":[{"index":0,"delta":{"reasoning":"另一种写法"}}]}');
    assert.deepEqual(types(b), ['reasoning_delta']);
    assert.equal(b[0].payload.delta, '另一种写法');
  });

  test('tool_calls：首块（id/name）→ start，后续 arguments 增量 → delta 且 callId 来自状态', () => {
    const st = freshState();
    const first = m.parseOpenAiSse(st, '',
      '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}');
    assert.deepEqual(types(first), ['tool_call_delta']);
    assert.equal(first[0].payload.phase, 'start');
    assert.equal(first[0].payload.callId, 'call_1');
    assert.equal(first[0].payload.toolName, 'get_weather');

    const second = m.parseOpenAiSse(st, '',
      '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"city\\":\\"北京\\"}"}}]}}]}');
    assert.deepEqual(types(second), ['tool_call_delta']);
    assert.equal(second[0].payload.phase, 'delta');
    assert.equal(second[0].payload.callId, 'call_1');
    assert.equal(second[0].payload.argumentsDelta, '{"city":"北京"}');
  });

  test('finish_reason=stop 且有未收尾工具时补 tool_call_delta phase=end', () => {
    const st = freshState();
    m.parseOpenAiSse(st, '',
      '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_9","function":{"name":"f"}}]}}]}');
    const out = m.parseOpenAiSse(st, '',
      '{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}');
    assert.deepEqual(types(out), ['tool_call_delta']);
    assert.equal(out[0].payload.phase, 'end');
    assert.equal(out[0].payload.callId, 'call_9');
    assert.equal(st.toolIds.size, 0);
  });

  test('finish_reason=length → error(max_tokens, 可重试)', () => {
    const out = m.parseOpenAiSse(freshState(), '',
      '{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}');
    assert.deepEqual(types(out), ['error']);
    assert.equal(out[0].payload.errorCode, 'max_tokens');
    assert.equal(out[0].payload.retriable, true);
  });

  test('[DONE] → completed（Chat Completions 的终止帧，Responses API 没有）', () => {
    const out = m.parseOpenAiSse(freshState(), '', '[DONE]');
    assert.deepEqual(types(out), ['completed']);
  });

  test('[DONE] 时仍有未收尾工具 → 先补 end 事件再 completed', () => {
    const st = freshState();
    m.parseOpenAiSse(st, '',
      '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_2","function":{"name":"f"}}]}}]}');
    const out = m.parseOpenAiSse(st, '', '[DONE]');
    assert.deepEqual(types(out), ['tool_call_delta', 'completed']);
    assert.equal(out[0].payload.phase, 'end');
  });

  test('usage chunk：prompt_tokens/completion_tokens/prompt_tokens_details.cached_tokens → usage_final', () => {
    const out = m.parseOpenAiSse(freshState(), '',
      '{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":50,"prompt_tokens_details":{"cached_tokens":800}}}');
    assert.deepEqual(types(out), ['usage_final']);
    const u = out[0].payload.usage;
    assert.equal(u.inputTokens, 1000);
    assert.equal(u.outputTokens, 50);
    assert.equal(u.cachedTokens, 800);
    assert.equal(u.cacheHitRatio, 0.8);
  });

  test('DeepSeek Chat Completions 的 prompt_cache_hit_tokens 也被识别为缓存命中', () => {
    const out = m.parseOpenAiSse(freshState(), '',
      '{"choices":[],"usage":{"prompt_tokens":500,"completion_tokens":10,"prompt_cache_hit_tokens":400}}');
    assert.deepEqual(types(out), ['usage_final']);
    assert.equal(out[0].payload.usage.cachedTokens, 400);
  });

  test('流内 error 对象（invalid_api_key）→ 中文提示且不可重试', () => {
    const out = m.parseOpenAiSse(freshState(), '',
      '{"error":{"code":"invalid_api_key","message":"Incorrect API key provided"}}');
    assert.deepEqual(types(out), ['error']);
    assert.equal(out[0].payload.message, '密钥无效，请重新填写');
    assert.equal(out[0].payload.retriable, false);
  });

  test('额度不足 / 限流错误的中文与可重试标记', () => {
    const quota = m.parseOpenAiSse(freshState(), '', '{"error":{"code":"insufficient_quota"}}');
    assert.equal(quota[0].payload.message, '账户额度不足，请充值后再试');
    assert.equal(quota[0].payload.retriable, false);
    const rate = m.parseOpenAiSse(freshState(), '', '{"error":{"code":"rate_limit_exceeded"}}');
    assert.equal(rate[0].payload.message, '请求太频繁，请稍后再试');
    assert.equal(rate[0].payload.retriable, true);
  });

  test('空 data / 非法 JSON / usage 为 null 均不产出事件且不抛错', () => {
    assert.deepEqual(m.parseOpenAiSse(freshState(), '', ''), []);
    assert.deepEqual(m.parseOpenAiSse(freshState(), '', '{broken'), []);
    assert.deepEqual(m.parseOpenAiSse(freshState(), '', '{"choices":[{"index":0,"delta":{},"usage":null}]}'), []);
  });

  summarize();
}
