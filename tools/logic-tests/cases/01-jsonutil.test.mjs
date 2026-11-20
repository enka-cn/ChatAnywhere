/**
 * JsonUtil 安全取值（packages/core_model/util/JsonUtil.ets）
 *
 * ArkTS 禁止 Record 对象字面量，动态 JSON 统一走这里；本用例验证「类型不符 / 缺字段 /
 * 嵌套非法」时都返回默认值而不是抛错（服务端字段缺失不能把 App 打挂）。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_model/src/main/ets/util/JsonUtil.ts';
const J = await tryImport(P);

if (!J) {
  skip('JsonUtil（全部用例）', missingReason(P));
  summarize();
} else {
  const {
    newStringRecord, newObjectRecord, newNumberRecord,
    getString, getNumber, getBool, getStringList, getRecord, getRecordList, hasKey
  } = J;

  test('newStringRecord 生成可 JSON.stringify 的空对象（不是 Map）', () => {
    const rec = newStringRecord();
    assert.equal(JSON.stringify(rec), '{}');
    rec.k = 'v';
    assert.equal(JSON.stringify(rec), '{"k":"v"}');
  });

  test('newObjectRecord / newNumberRecord 可逐项赋值', () => {
    const o = newObjectRecord();
    o.a = 1;
    o.b = 'x';
    assert.equal(o.a, 1);
    assert.equal(o.b, 'x');
    const n = newNumberRecord();
    n.t = 3;
    assert.equal(n.t, 3);
  });

  test('getString 命中字符串返回原值', () => {
    assert.equal(getString({ a: 'x' }, 'a', 'dft'), 'x');
  });

  test('getString 缺字段 / 类型不符 / 空对象返回默认值', () => {
    assert.equal(getString({}, 'a', 'dft'), 'dft');
    assert.equal(getString({ a: 42 }, 'a', 'dft'), 'dft');
    assert.equal(getString({ a: null }, 'a', 'dft'), 'dft');
    assert.equal(getString(null, 'a', 'dft'), 'dft');
    assert.equal(getString(undefined, 'a', 'dft'), 'dft');
  });

  test('getNumber 接受数字与数字字符串', () => {
    assert.equal(getNumber({ n: 42 }, 'n', -1), 42);
    assert.equal(getNumber({ n: '42.5' }, 'n', -1), 42.5);
    assert.equal(getNumber({ n: 0 }, 'n', -1), 0);
  });

  test('getNumber 对非数字 / 缺字段返回默认值（不返回 NaN）', () => {
    assert.equal(getNumber({ n: 'abc' }, 'n', 7), 7);
    assert.equal(getNumber({ n: true }, 'n', 7), 7);
    assert.equal(getNumber({}, 'n', 7), 7);
    assert.equal(getNumber(null, 'n', 7), 7);
  });

  test('getBool 只认布尔值', () => {
    assert.equal(getBool({ b: true }, 'b', false), true);
    assert.equal(getBool({ b: false }, 'b', true), false);
    assert.equal(getBool({ b: 'true' }, 'b', false), false);
    assert.equal(getBool({}, 'b', true), true);
  });

  test('getStringList 过滤非字符串项，非数组返回空数组', () => {
    assert.deepEqual(getStringList({ l: ['a', 1, 'b', null] }, 'l'), ['a', 'b']);
    assert.deepEqual(getStringList({ l: 'a' }, 'l'), []);
    assert.deepEqual(getStringList({}, 'l'), []);
    assert.deepEqual(getStringList(null, 'l'), []);
  });

  test('getRecord 只认普通对象（数组 / null / 标量均返回 null）', () => {
    assert.deepEqual(getRecord({ o: { x: 1 } }, 'o'), { x: 1 });
    assert.equal(getRecord({ o: [1, 2] }, 'o'), null);
    assert.equal(getRecord({ o: null }, 'o'), null);
    assert.equal(getRecord({ o: 'str' }, 'o'), null);
    assert.equal(getRecord({}, 'o'), null);
  });

  test('getRecordList 过滤非对象项', () => {
    const list = getRecordList({ l: [{ a: 1 }, 2, null, { b: 2 }] }, 'l');
    assert.equal(list.length, 2);
    assert.equal(list[0].a, 1);
    assert.equal(list[1].b, 2);
    assert.deepEqual(getRecordList({ l: {} }, 'l'), []);
  });

  test('hasKey 区分「键存在且非空」与 undefined / null', () => {
    assert.equal(hasKey({ a: 0 }, 'a'), true);
    assert.equal(hasKey({ a: false }, 'a'), true);
    assert.equal(hasKey({ a: null }, 'a'), false);
    assert.equal(hasKey({ a: undefined }, 'a'), false);
    assert.equal(hasKey({}, 'a'), false);
    assert.equal(hasKey(null, 'a'), false);
  });

  test('嵌套读取：getRecord 后继续 getString（服务端 usage 等嵌套结构）', () => {
    const body = { usage: { input_tokens: 7, detail: { cached_tokens: 0 } } };
    const usage = getRecord(body, 'usage');
    assert.ok(usage);
    assert.equal(getNumber(usage, 'input_tokens', -1), 7);
    const detail = getRecord(usage, 'detail');
    assert.ok(detail);
    assert.equal(getNumber(detail, 'cached_tokens', -1), 0);
  });

  summarize();
}
