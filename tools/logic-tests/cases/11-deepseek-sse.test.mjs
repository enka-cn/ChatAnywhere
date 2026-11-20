/**
 * DeepSeek Responses API 事件解析（packages/core_protocol/adapters/DeepSeekSse.ets）
 *
 * fixture 逐字依据 docs/API_REFERENCE.md §1.3–1.5（2026-11-19 官方文档抓取）：
 * - 无 [DONE]，终止事件 response.completed / incomplete / failed；
 * - usage 只在终点事件，缓存命中在 input_tokens_details.cached_tokens；
 * - title 在终点事件的 response.title；
 * - web_search_call 的 action.sources 需保留 site_name/published_at，read_link 需保留 signature。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_protocol/src/main/ets/adapters/DeepSeekSse.ts';
const m = await tryImport(P);

if (!m) {
  skip('DeepSeek 事件解析（全部用例）', missingReason(P));
  summarize();
} else {
  const types = (events) => events.map((e) => e.type);

  test('response.output_text.delta → text_delta，携带增量与 itemId', () => {
    const out = m.parseDeepSeekSse('response.output_text.delta',
      '{"type":"response.output_text.delta","content_index":0,"delta":"Hello","item_id":"it_1","output_index":0,"sequence_number":4}');
    assert.deepEqual(types(out), ['text_delta']);
    assert.equal(out[0].payload.delta, 'Hello');
    assert.equal(out[0].payload.itemId, 'it_1');
  });

  test('response.reasoning_text.delta → reasoning_delta（思维链不混进正文）', () => {
    const out = m.parseDeepSeekSse('response.reasoning_text.delta',
      '{"type":"response.reasoning_text.delta","item_id":"rs_1","output_index":0,"content_index":0,"delta":"先想一下"}');
    assert.deepEqual(types(out), ['reasoning_delta']);
    assert.equal(out[0].payload.delta, '先想一下');
  });

  test('event 名为空时回退 data.type（真实 rcp 分片可能丢 event 行）', () => {
    const out = m.parseDeepSeekSse('', '{"type":"response.output_text.delta","delta":"Hi"}');
    assert.deepEqual(types(out), ['text_delta']);
    assert.equal(out[0].payload.delta, 'Hi');
  });

  test('output_item.added(function_call) → tool_call_delta phase=start', () => {
    const out = m.parseDeepSeekSse('response.output_item.added',
      '{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","status":"in_progress","call_id":"call_1","name":"get_weather"},"output_index":1,"sequence_number":5}');
    assert.deepEqual(types(out), ['tool_call_delta']);
    assert.equal(out[0].payload.phase, 'start');
    assert.equal(out[0].payload.callId, 'call_1');
    assert.equal(out[0].payload.toolName, 'get_weather');
  });

  test('function_call_arguments.delta / done → phase=delta / end 且参数完整', () => {
    const deltaOut = m.parseDeepSeekSse('response.function_call_arguments.delta',
      '{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"{\\"loc"}');
    assert.deepEqual(types(deltaOut), ['tool_call_delta']);
    assert.equal(deltaOut[0].payload.phase, 'delta');
    assert.equal(deltaOut[0].payload.argumentsDelta, '{"loc');

    const doneOut = m.parseDeepSeekSse('response.function_call_arguments.done',
      '{"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":1,"arguments":"{\\"location\\":\\"Beijing\\"}"}');
    assert.deepEqual(types(doneOut), ['tool_call_delta']);
    assert.equal(doneOut[0].payload.phase, 'end');
    assert.equal(doneOut[0].payload.argumentsDelta, '{"location":"Beijing"}');
  });

  test('function_call_arguments.delta/done 不得把 item_id 当 call_id 发出（修复回归）', () => {
    // 语义：真正的 call_id 只在 output_item.added/done 给出；增量事件只带 itemId。
    const deltaOut = m.parseDeepSeekSse('response.function_call_arguments.delta',
      '{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{"}');
    assert.equal(deltaOut[0].payload.callId, undefined);
    assert.equal(deltaOut[0].payload.itemId, 'fc_1');
    const doneOut = m.parseDeepSeekSse('response.function_call_arguments.done',
      '{"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{}"}');
    assert.equal(doneOut[0].payload.callId, undefined);
    assert.equal(doneOut[0].payload.itemId, 'fc_1');
  });

  test('web_search_call 三件套作为进度心跳：searching → web_search_status（中文文案）', () => {
    const out = m.parseDeepSeekSse('response.web_search_call.searching',
      '{"type":"response.web_search_call.searching","item_id":"ws_1","output_index":0}');
    assert.deepEqual(types(out), ['web_search_status']);
    assert.equal(out[0].payload.searchStatus, 'searching');
    assert.equal(out[0].payload.text, '正在联网搜索');
  });

  test('output_item.added(web_search_call) 保留 action.sources 字段（site_name→siteName、published_at→publishedAt）', () => {
    const json = JSON.stringify({
      type: 'response.output_item.added',
      item: {
        type: 'web_search_call', id: 'ws_1', status: 'in_progress', kind: 'search',
        action: {
          type: 'search', queries: ['DeepSeek V4.1'],
          sources: [{
            type: 'url', url: 'https://example.com/news', title: '示例新闻', snippet: '摘要',
            site_name: 'Example News', published_at: '2026-01-02T03:04:05+00:00'
          }]
        }
      },
      output_index: 0
    });
    const out = m.parseDeepSeekSse('response.output_item.added', json);
    assert.deepEqual(types(out), ['web_search_status']);
    assert.equal(out[0].payload.searchStatus, 'in_progress');
    const sources = JSON.parse(out[0].payload.sourcesJson);
    assert.equal(sources.length, 1);
    assert.equal(sources[0].title, '示例新闻');
    assert.equal(sources[0].url, 'https://example.com/news');
    assert.equal(sources[0].siteName, 'Example News');
    assert.equal(sources[0].publishedAt, '2026-01-02T03:04:05+00:00');
  });

  test('output_item.done(read_link) 原样保留 signature 与 page（同厂商多轮回传关键）', () => {
    const json = JSON.stringify({
      type: 'response.output_item.done',
      item: {
        type: 'web_search_call', id: 'ws_2', status: 'completed', kind: 'read_link',
        page: { url: 'https://example.com/a', title: '文章 A', published_at: '2026-02-03T00:00:00+00:00' },
        signature: 'ENC_SIGNATURE_XYZ',
        action: { type: 'open_page', sources: [] }
      },
      output_index: 0
    });
    const out = m.parseDeepSeekSse('response.output_item.done', json);
    assert.deepEqual(types(out), ['web_search_status']);
    assert.equal(out[0].payload.searchStatus, 'completed');
    const raw = JSON.parse(out[0].payload.vendorRawJson);
    assert.equal(raw.signature, 'ENC_SIGNATURE_XYZ');
    assert.equal(raw.page.url, 'https://example.com/a');
    assert.equal(raw.kind, 'read_link');
  });

  test('response.completed：usage_final（含 cached_tokens）+ title + completed 三事件', () => {
    const json = JSON.stringify({
      type: 'response.completed',
      response: {
        id: 'resp_1', status: 'completed', model: 'deepseek-flash', title: '自动生成的标题',
        usage: {
          input_tokens: 3475,
          input_tokens_details: { cached_tokens: 512 },
          output_tokens: 54,
          output_tokens_details: { reasoning_tokens: 0, safety_tokens: 0 },
          total_tokens: 3529,
          server_tool_use: { tool_search: 1, tool_fetch: 0, tool_image_search: 0 }
        }
      },
      sequence_number: 17
    });
    const out = m.parseDeepSeekSse('response.completed', json);
    assert.deepEqual(types(out), ['usage_final', 'title_generated', 'completed']);
    const usage = out[0].payload.usage;
    assert.equal(usage.inputTokens, 3475);
    assert.equal(usage.outputTokens, 54);
    assert.equal(usage.cachedTokens, 512);
    assert.equal(usage.cacheHitRatio, 512 / 3475);
    assert.equal(out[1].payload.title, '自动生成的标题');
  });

  test('response.completed 无 title 时不产出 title_generated（自行兜底标题）', () => {
    const json = JSON.stringify({
      type: 'response.completed',
      response: { id: 'r', status: 'completed', usage: { input_tokens: 10, output_tokens: 2 } }
    });
    const out = m.parseDeepSeekSse('response.completed', json);
    assert.deepEqual(types(out), ['usage_final', 'completed']);
    assert.equal(out[0].payload.usage.cachedTokens, 0);
  });

  test('response.completed 的 usage 为 null 时只产出 completed（不伪造 usage）', () => {
    const out = m.parseDeepSeekSse('response.completed',
      '{"type":"response.completed","response":{"id":"r","status":"completed","usage":null}}');
    assert.deepEqual(types(out), ['completed']);
  });

  test('response.failed(server_error) → error，中文提示且可重试', () => {
    const out = m.parseDeepSeekSse('response.failed',
      '{"type":"response.failed","response":{"id":"r","status":"failed","error":{"code":"server_error","message":"boom"}}}');
    assert.deepEqual(types(out), ['error']);
    assert.equal(out[0].payload.errorCode, 'server_error');
    assert.equal(out[0].payload.message, '模型生成中途出错，请重试');
    assert.equal(out[0].payload.retriable, true);
  });

  test('response.failed(invalid_request_error) 标记不可重试（400 类不应重试）', () => {
    const out = m.parseDeepSeekSse('response.failed',
      '{"type":"response.failed","response":{"id":"r","status":"failed","error":{"code":"invalid_request_error","message":"bad param"}}}');
    assert.deepEqual(types(out), ['error']);
    assert.equal(out[0].payload.retriable, false);
  });

  test('response.incomplete(max_output_tokens) → error + completed（不要卡住 UI）', () => {
    const out = m.parseDeepSeekSse('response.incomplete',
      '{"type":"response.incomplete","response":{"id":"r","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}');
    assert.deepEqual(types(out), ['error', 'completed']);
    assert.equal(out[0].payload.errorCode, 'incomplete');
    assert.equal(out[0].payload.retriable, true);
  });

  test('未知事件（created/in_progress/content_part.*) 返回空数组', () => {
    assert.deepEqual(m.parseDeepSeekSse('response.created', '{"type":"response.created","response":{}}'), []);
    assert.deepEqual(m.parseDeepSeekSse('response.output_text.done', '{"type":"response.output_text.done","text":"全文"}'), []);
    assert.deepEqual(m.parseDeepSeekSse('response.content_part.done', '{"type":"response.content_part.done"}'), []);
  });

  test('非法 JSON / 空 data 返回空数组，绝不抛错', () => {
    assert.deepEqual(m.parseDeepSeekSse('response.output_text.delta', '{oops'), []);
    assert.deepEqual(m.parseDeepSeekSse('response.output_text.delta', ''), []);
    assert.deepEqual(m.parseDeepSeekSse('', ''), []);
  });

  test('顶层 error 事件 → 中文 error 事件', () => {
    const out = m.parseDeepSse
      ? []
      : m.parseDeepSeekSse('error', '{"type":"error","error":{"code":"rate_limit_exceeded","message":"slow down"}}');
    assert.deepEqual(types(out), ['error']);
    assert.equal(out[0].payload.message, '请求太频繁，请稍后再试');
  });

  test('isDeepSeekTerminalEvent 只认三个终止事件（无 [DONE]）', () => {
    assert.equal(m.isDeepSeekTerminalEvent('response.completed'), true);
    assert.equal(m.isDeepSeekTerminalEvent('response.incomplete'), true);
    assert.equal(m.isDeepSeekTerminalEvent('response.failed'), true);
    assert.equal(m.isDeepSeekTerminalEvent('response.output_text.delta'), false);
    assert.equal(m.isDeepSeekTerminalEvent('[DONE]'), false);
  });

  test('extractDeepSeekTitle 兼容顶层 title 与 response.title', () => {
    assert.equal(m.extractDeepSeekTitle('{"title":"顶层标题"}'), '顶层标题');
    assert.equal(m.extractDeepSeekTitle('{"response":{"title":"终点标题"}}'), '终点标题');
    assert.equal(m.extractDeepSeekTitle('{"response":{}}'), '');
    assert.equal(m.extractDeepSeekTitle('not json'), '');
  });

  summarize();
}
