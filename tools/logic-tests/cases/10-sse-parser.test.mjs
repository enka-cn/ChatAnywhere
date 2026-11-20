/**
 * SSE 增量解析器（packages/core_protocol/SseParser.ets）
 *
 * 传输层语义：字节流 → 帧。重点覆盖 QA 清单：单帧、多行 data、CRLF、跨分片半帧、
 * 注释行、多帧一次到达、flush 残留；以及 id 粘滞 / retry / 单独 CR / reset。
 * 注意：解析器不得对 `[DONE]` 做厂商语义特判（Responses 无 [DONE]）。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_protocol/src/main/ets/SseParser.ts';
const mod = await tryImport(P);

if (!mod || !mod.SseParser) {
  skip('SSE 解析器（全部用例）', missingReason(P));
  summarize();
} else {
  const { SseParser } = mod;
  const fresh = () => new SseParser();

  test('单帧：event + 单行 data + 空行闭合', () => {
    const p = fresh();
    const frames = p.feed('event: response.output_text.delta\ndata: {"delta":"Hello"}\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].event, 'response.output_text.delta');
    assert.equal(frames[0].data, '{"delta":"Hello"}');
  });

  test('多行 data 按出现顺序用 \\n 拼接', () => {
    const p = fresh();
    const frames = p.feed('event: x\ndata: 第一行\ndata: 第二行\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].data, '第一行\n第二行');
  });

  test('CRLF 行结束符正确切行且不残留 \\r', () => {
    const p = fresh();
    const frames = p.feed('event: ping\r\ndata: 1\r\n\r\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].event, 'ping');
    assert.equal(frames[0].data, '1');
  });

  test('CRLF 被拆到两个分片（第一片以 \\r 结尾）也能正确解析', () => {
    const p = fresh();
    const first = p.feed('event: ping\r');
    assert.deepEqual(first, []); // \r 在末尾：等待下一片确认是否 CRLF
    const second = p.feed('\ndata: 1\r\n\r\n');
    assert.equal(second.length, 1);
    assert.equal(second[0].event, 'ping');
    assert.equal(second[0].data, '1');
  });

  test('单独 CR 作为行结束符（老式 SSE）：末尾 CR 需 flush 才吐出（兼容 CRLF 被拆片的既定取舍）', () => {
    const p = fresh();
    // 末尾的 \r 可能是一个被拆开的 CRLF 的前半，解析器会等下一片；流结束时由 flush 兜底。
    assert.deepEqual(p.feed('event: e\rdata: v\r\r'), []);
    const frames = p.flush();
    assert.equal(frames.length, 1);
    assert.equal(frames[0].event, 'e');
    assert.equal(frames[0].data, 'v');
  });

  test('单独 CR 帧后紧跟新分片时上一帧立即吐出（不丢帧、无需 flush）', () => {
    const p = fresh();
    assert.deepEqual(p.feed('event: e\rdata: v\r\r'), []);
    const second = p.feed('event: f\rdata: w\r\r');
    assert.equal(second.length, 1);
    assert.equal(second[0].event, 'e');
    assert.equal(second[0].data, 'v');
    const rest = p.flush();
    assert.equal(rest.length, 1);
    assert.equal(rest[0].event, 'f');
  });

  test('跨分片半行：event 与 data 分两次到达才闭合', () => {
    const p = fresh();
    assert.deepEqual(p.feed('event: resp'), []);
    assert.deepEqual(p.feed('onse.output_text.delta\ndata: {"delta":"你'), []);
    const frames = p.feed('好"}\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].event, 'response.output_text.delta');
    assert.equal(frames[0].data, '{"delta":"你好"}');
  });

  test('一个分片内到达多帧全部返回', () => {
    const p = fresh();
    const frames = p.feed('event: a\ndata: 1\n\nevent: b\ndata: 2\n\n');
    assert.equal(frames.length, 2);
    assert.equal(frames[0].event, 'a');
    assert.equal(frames[1].event, 'b');
  });

  test('注释行（: keep-alive）被忽略且不影响后续帧', () => {
    const p = fresh();
    const frames = p.feed(': keep-alive\n\nevent: a\ndata: 1\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].event, 'a');
  });

  test('event 与 data 之间的注释行不打断当前帧', () => {
    const p = fresh();
    const frames = p.feed('event: a\n: heartbeat\ndata: 1\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].data, '1');
  });

  test('未知字段被忽略', () => {
    const p = fresh();
    const frames = p.feed('event: a\nfoo: bar\ndata: 1\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].data, '1');
  });

  test('data 值只去掉一个前导空格（SSE 规范）', () => {
    const p = fresh();
    const frames = p.feed('data:  x\n\n'); // "data: " + " x"
    assert.equal(frames[0].data, ' x');
  });

  test('只有 event 没有 data 也会产出帧（心跳类事件）', () => {
    const p = fresh();
    const frames = p.feed('event: ping\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].event, 'ping');
    assert.equal(frames[0].data, '');
  });

  test('id 跨帧粘滞（SSE 规范 last-event-id）', () => {
    const p = fresh();
    const a = p.feed('id: 7\ndata: a\n\n');
    const b = p.feed('data: b\n\n');
    assert.equal(a[0].id, '7');
    assert.equal(b[0].id, '7');
  });

  test('id 含 NUL 字符时按规范忽略', () => {
    const p = fresh();
    const frames = p.feed('id: bad\u0000id\ndata: a\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].id, undefined);
  });

  test('retry 字段解析为毫秒数字', () => {
    const p = fresh();
    const frames = p.feed('retry: 3000\ndata: a\n\n');
    assert.equal(frames[0].retry, 3000);
  });

  test('flush 冲出未以空行闭合的残留帧', () => {
    const p = fresh();
    const frames = p.feed('event: a\ndata: 1');
    assert.deepEqual(frames, []);
    const rest = p.flush();
    assert.equal(rest.length, 1);
    assert.equal(rest[0].event, 'a');
    assert.equal(rest[0].data, '1');
  });

  test('flush 对残留末尾单独 \\r 做容错', () => {
    const p = fresh();
    p.feed('data: 1\r');
    const rest = p.flush();
    assert.equal(rest.length, 1);
    assert.equal(rest[0].data, '1');
  });

  test('flush 在无残留时返回空数组（可重复调用）', () => {
    const p = fresh();
    assert.deepEqual(p.flush(), []);
    assert.deepEqual(p.flush(), []);
  });

  test('reset 清空残留状态，之后不会吐出旧帧', () => {
    const p = fresh();
    p.feed('event: a\ndata: 1');
    p.reset();
    assert.deepEqual(p.flush(), []);
    const frames = p.feed('event: b\ndata: 2\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].event, 'b');
  });

  test('空串 / undefined / null 分片安全返回空数组', () => {
    const p = fresh();
    assert.deepEqual(p.feed(''), []);
    assert.deepEqual(p.feed(undefined), []);
    assert.deepEqual(p.feed(null), []);
  });

  test('传输层不特判 [DONE]：[DONE] 被当普通 data 帧返回（厂商语义由适配器处理）', () => {
    const p = fresh();
    const frames = p.feed('data: [DONE]\n\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0].data, '[DONE]');
  });

  summarize();
}
