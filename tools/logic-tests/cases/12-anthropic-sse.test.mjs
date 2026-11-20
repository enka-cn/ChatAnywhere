/**
 * Anthropic Messages API 事件解析（packages/core_protocol/adapters/AnthropicSse.ets）
 *
 * 覆盖：message_start（input/cache_read token）→ content_block_start/delta/stop
 * （text / thinking / signature / tool_use）→ message_delta（stop_reason + output tokens）
 * → message_stop；以及 overloaded/api/rate_limit/authentication 错误中文映射与 ping 忽略。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_protocol/src/main/ets/adapters/AnthropicSse.ts';
const m = await tryImport(P);

if (!m) {
  skip('Anthropic 事件解析（全部用例）', missingReason(P));
  summarize();
} else {
  const types = (events) => events.map((e) => e.type);
  const freshState = () => new m.AnthropicSseState();

  test('message_start 记录 input_tokens 与 cache_read_input_tokens（本事件不产出统一事件）', () => {
    const st = freshState();
    const out = m.parseAnthropicSse(st, 'message_start',
      '{"type":"message_start","message":{"id":"msg_1","role":"assistant","usage":{"input_tokens":120,"cache_read_input_tokens":80,"output_tokens":1}}}');
    assert.deepEqual(out, []);
    assert.equal(st.inputTokens, 120);
    assert.equal(st.cachedTokens, 80);
  });

  test('content_block_delta(text_delta) → text_delta', () => {
    const out = m.parseAnthropicSse(freshState(), 'content_block_delta',
      '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}');
    assert.deepEqual(types(out), ['text_delta']);
    assert.equal(out[0].payload.delta, '你好');
  });

  test('content_block_delta(thinking_delta) → reasoning_delta（思考过程独立通道）', () => {
    const out = m.parseAnthropicSse(freshState(), 'content_block_delta',
      '{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"先分析"}}');
    assert.deepEqual(types(out), ['reasoning_delta']);
    assert.equal(out[0].payload.delta, '先分析');
  });

  test('content_block_delta(signature_delta) → reasoning_delta，vendorRawJson 带 anthropic 签名', () => {
    const out = m.parseAnthropicSse(freshState(), 'content_block_delta',
      '{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG_ABC"}}');
    assert.deepEqual(types(out), ['reasoning_delta']);
    const raw = JSON.parse(out[0].payload.vendorRawJson);
    assert.equal(raw.provider, 'anthropic');
    assert.equal(raw.signature, 'SIG_ABC');
  });

  test('tool_use：start(id/name) → delta(partial_json) → stop(end)，跨事件状态正确配对', () => {
    const st = freshState();
    const start = m.parseAnthropicSse(st, 'content_block_start',
      '{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}}');
    assert.deepEqual(types(start), ['tool_call_delta']);
    assert.equal(start[0].payload.phase, 'start');
    assert.equal(start[0].payload.callId, 'toolu_1');
    assert.equal(start[0].payload.toolName, 'get_weather');

    const delta = m.parseAnthropicSse(st, 'content_block_delta',
      '{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":"}}');
    assert.deepEqual(types(delta), ['tool_call_delta']);
    assert.equal(delta[0].payload.phase, 'delta');
    assert.equal(delta[0].payload.callId, 'toolu_1');
    assert.equal(delta[0].payload.argumentsDelta, '{"city":');

    const stop = m.parseAnthropicSse(st, 'content_block_stop', '{"type":"content_block_stop","index":1}');
    assert.deepEqual(types(stop), ['tool_call_delta']);
    assert.equal(stop[0].payload.phase, 'end');
    assert.equal(stop[0].payload.callId, 'toolu_1');
    assert.equal(stop[0].payload.toolName, 'get_weather');

    // 已清掉该 index，重复 stop 不再重复产出
    const again = m.parseAnthropicSse(st, 'content_block_stop', '{"type":"content_block_stop","index":1}');
    assert.deepEqual(again, []);
  });

  test('content_block_start(text block) 不产出工具事件', () => {
    const out = m.parseAnthropicSse(freshState(), 'content_block_start',
      '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}');
    assert.deepEqual(out, []);
  });

  test('message_delta 产出 usage_final：输出 token 来自本事件、输入/缓存来自 message_start', () => {
    const st = freshState();
    m.parseAnthropicSse(st, 'message_start',
      '{"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":80}}}');
    const out = m.parseAnthropicSse(st, 'message_delta',
      '{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}');
    assert.deepEqual(types(out), ['usage_final']);
    const usage = out[0].payload.usage;
    assert.equal(usage.inputTokens, 120);
    assert.equal(usage.cachedTokens, 80);
    assert.equal(usage.outputTokens, 42);
    assert.equal(usage.cacheHitRatio, 80 / 120);
    assert.equal(usage.reasoningTokens, 0);
  });

  test('message_delta stop_reason=max_tokens → 额外 error（可重试）', () => {
    const st = freshState();
    const out = m.parseAnthropicSse(st, 'message_delta',
      '{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":10}}');
    assert.deepEqual(types(out), ['usage_final', 'error']);
    assert.equal(out[1].payload.errorCode, 'max_tokens');
    assert.equal(out[1].payload.retriable, true);
  });

  test('message_stop → completed', () => {
    const out = m.parseAnthropicSse(freshState(), 'message_stop', '{"type":"message_stop"}');
    assert.deepEqual(types(out), ['completed']);
  });

  test('error(overloaded_error) → 中文「服务器繁忙」且可重试', () => {
    const out = m.parseAnthropicSse(freshState(), 'error',
      '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}');
    assert.deepEqual(types(out), ['error']);
    assert.equal(out[0].payload.message, '服务器繁忙，请稍后重试');
    assert.equal(out[0].payload.retriable, true);
  });

  test('error(authentication_error) → 密钥无效且不可重试', () => {
    const out = m.parseAnthropicSse(freshState(), 'error',
      '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}');
    assert.deepEqual(types(out), ['error']);
    assert.equal(out[0].payload.message, '密钥无效，请重新填写');
    assert.equal(out[0].payload.retriable, false);
  });

  test('event 名为空时回退 data.type', () => {
    const out = m.parseAnthropicSse(freshState(), '',
      '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"X"}}');
    assert.deepEqual(types(out), ['text_delta']);
  });

  test('ping 心跳与未知事件返回空数组；非法 JSON 不抛错', () => {
    assert.deepEqual(m.parseAnthropicSse(freshState(), 'ping', '{"type":"ping"}'), []);
    assert.deepEqual(m.parseAnthropicSse(freshState(), 'whatever', '{"type":"whatever"}'), []);
    assert.deepEqual(m.parseAnthropicSse(freshState(), 'content_block_delta', '{broken'), []);
  });

  test('reset 清空 input/cache/output 与工具映射', () => {
    const st = freshState();
    m.parseAnthropicSse(st, 'message_start', '{"type":"message_start","message":{"usage":{"input_tokens":9,"cache_read_input_tokens":3}}}');
    m.parseAnthropicSse(st, 'content_block_start',
      '{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t","name":"n"}}');
    st.reset();
    assert.equal(st.inputTokens, 0);
    assert.equal(st.cachedTokens, 0);
    assert.equal(st.outputTokens, 0);
    assert.equal(st.toolIds.size, 0);
  });

  summarize();
}
