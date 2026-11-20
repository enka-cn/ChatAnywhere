/**
 * ID 生成（packages/core_model/util/Ids.ets）
 *
 * 纯函数：前缀格式、唯一性、批量生成不碰撞。append-only 轨迹依赖 nodeId 唯一。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_model/src/main/ets/util/Ids.ts';
const Ids = await tryImport(P);

if (!Ids) {
  skip('ID 生成（全部用例）', missingReason(P));
  summarize();
} else {
  const { newId, newSessionId, newNodeId, newItemId, newRunId } = Ids;

  test('newId 生成 <prefix>_<base36time>_<counter+rand> 形式', () => {
    const id = newId('nd');
    assert.match(id, /^nd_[0-9a-z]+_[0-9a-z]+$/);
  });

  test('newId 尊重自定义前缀', () => {
    assert.ok(newId('skill').startsWith('skill_'));
    assert.ok(newId('x_y').startsWith('x_y_'));
  });

  test('连续生成 500 个 id 不重复（append-only 轨迹的 nodeId 唯一性前提）', () => {
    const seen = new Set();
    for (let i = 0; i < 500; i += 1) {
      seen.add(newId('nd'));
    }
    assert.equal(seen.size, 500);
  });

  test('newSessionId / newNodeId / newItemId / newRunId 前缀正确', () => {
    assert.match(newSessionId(), /^ses_/);
    assert.match(newNodeId(), /^nd_/);
    assert.match(newItemId(), /^it_/);
    assert.match(newRunId(), /^run_/);
  });

  test('不同类型 id 互不相同', () => {
    const all = new Set([newSessionId(), newNodeId(), newItemId(), newRunId()]);
    assert.equal(all.size, 4);
  });

  summarize();
}
