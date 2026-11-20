/**
 * 6 档思考强度纯逻辑（chat/src/main/ets/app/EffortLevels.ets）
 *
 * 覆盖 v3 设计基线：关闭/Min/Low/Med/High/xHigh 六档短标签、默认 med、
 * 索引/取档容错、旧值 quick→med / deep→high 迁移（与 core_protocol ThinkingLevel 6 值对齐）。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'chat/src/main/ets/app/EffortLevels.ts';
const E = await tryImport(P);

if (!E || !E.EffortLevels) {
  skip('6 档思考强度（全部用例）', missingReason(P));
  summarize();
} else {
  const EL = E.EffortLevels;

  test('六档短标签与顺序 = 关闭/Min/Low/Med/High/xHigh', () => {
    assert.deepEqual(EL.ALL.map((x) => x.level), ['off', 'min', 'low', 'med', 'high', 'xhigh']);
    assert.deepEqual(EL.ALL.map((x) => x.short), ['关闭', 'Min', 'Low', 'Med', 'High', 'xHigh']);
  });

  test('默认档位为 med（与协议层默认一致）', () => {
    assert.equal(EL.DEFAULT, 'med');
  });

  test('indexOf：六档索引 0..5；未知值回退默认档索引', () => {
    assert.deepEqual(EL.ALL.map((x) => EL.indexOf(x.level)), [0, 1, 2, 3, 4, 5]);
    assert.equal(EL.indexOf('unknown'), EL.indexOf('med'));
    assert.equal(EL.indexOf(null), EL.indexOf('med'));
  });

  test('byIndex：越界回退默认档；byLevel/short 取到对应标签', () => {
    assert.equal(EL.byIndex(0).short, '关闭');
    assert.equal(EL.byIndex(5).short, 'xHigh');
    assert.equal(EL.byIndex(-1).level, 'med');
    assert.equal(EL.byIndex(99).level, 'med');
    assert.equal(EL.byLevel('xhigh').short, 'xHigh');
    assert.equal(EL.short('min'), 'Min');
  });

  test('normalize：六档原样透传；旧值 quick→med、deep→high；其它回退 med', () => {
    for (const level of ['off', 'min', 'low', 'med', 'high', 'xhigh']) {
      assert.equal(EL.normalize(level), level);
    }
    assert.equal(EL.normalize('quick'), 'med');
    assert.equal(EL.normalize('deep'), 'high');
    assert.equal(EL.normalize('whatever'), 'med');
    assert.equal(EL.normalize(''), 'med');
    assert.equal(EL.normalize(null), 'med');
  });

  summarize();
}
