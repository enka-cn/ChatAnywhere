/**
 * 轨迹树纯逻辑（packages/core_model/util/TrajectoryLogic.ets）
 *
 * 覆盖：活动路径解析（沿 activeChildId 走、默认取最新未归档子节点、分支切换）、
 * 根→叶回溯、子树判定（防环）、排序与索引工具。
 * 这些是「编辑历史提问生成新分支并自由切换」DoD 的核心逻辑。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_model/src/main/ets/util/TrajectoryLogic.ts';
const m = await tryImport(P);

if (!m) {
  skip('轨迹树逻辑（全部用例）', missingReason(P));
  summarize();
} else {
  function node(nodeId, parentId, createdAt, extra = {}) {
    return {
      nodeId, parentId, sessionId: 's1', role: 'user', items: [], tokenEstimate: 0, createdAt, ...extra
    };
  }

  test('pickDefaultChild：空候选返回 null', () => {
    assert.equal(m.pickDefaultChild([]), null);
  });

  test('pickDefaultChild：默认取最新创建的子节点', () => {
    const picked = m.pickDefaultChild([node('a', null, 100), node('b', null, 300), node('c', null, 200)]);
    assert.equal(picked.nodeId, 'b');
  });

  test('pickDefaultChild：优先未归档节点（即使归档节点更新）', () => {
    const picked = m.pickDefaultChild([
      node('old', null, 100),
      node('newArchived', null, 300, { archived: true })
    ]);
    assert.equal(picked.nodeId, 'old');
  });

  test('pickDefaultChild：全部归档时退化为取最新', () => {
    const picked = m.pickDefaultChild([node('x', null, 100, { archived: true }), node('y', null, 200, { archived: true })]);
    assert.equal(picked.nodeId, 'y');
  });

  test('pickDefaultChild：createdAt 相同用 nodeId 字典序兜底（结果稳定）', () => {
    assert.equal(m.pickDefaultChild([node('a2', null, 100), node('a1', null, 100)]).nodeId, 'a2');
  });

  test('sortByCreated：按 createdAt 升序，且不修改入参数组', () => {
    const input = [node('b', null, 200), node('a', null, 100)];
    const sorted = m.sortByCreated(input);
    assert.deepEqual(sorted.map((n) => n.nodeId), ['a', 'b']);
    assert.deepEqual(input.map((n) => n.nodeId), ['b', 'a']);
  });

  test('indexNodes / groupByParent：根节点归到空串 key', () => {
    const nodes = [node('r', null, 1), node('c1', 'r', 2), node('c2', 'r', 3)];
    const idx = m.indexNodes(nodes);
    assert.equal(idx.size, 3);
    assert.equal(idx.get('c1').parentId, 'r');
    const groups = m.groupByParent(nodes);
    assert.equal(groups.get('').length, 1);
    assert.equal(groups.get('r').length, 2);
  });

  test('resolveActiveLeafId：空会话返回 null', () => {
    assert.equal(m.resolveActiveLeafId([], null), null);
  });

  test('resolveActiveLeafId：沿 activeChildId 走到叶子（根 active 指定）', () => {
    const nodes = [
      node('r', null, 1, { activeChildId: 'a' }),
      node('a', 'r', 2, { activeChildId: 'c' }),
      node('b', 'a', 3),
      node('c', 'a', 4)
    ];
    assert.equal(m.resolveActiveLeafId(nodes, 'r'), 'c');
  });

  test('resolveActiveLeafId：切换分支（parent.activeChildId 指向另一支）', () => {
    const nodes = [
      node('r', null, 1),
      node('a', 'r', 2),
      node('b', 'a', 3),
      node('c', 'a', 4)
    ];
    // 默认取最新 → c
    assert.equal(m.resolveActiveLeafId(nodes, null), 'c');
    // 用户切到 b 分支
    nodes[1].activeChildId = 'b';
    assert.equal(m.resolveActiveLeafId(nodes, null), 'b');
  });

  test('resolveActiveLeafId：activeChildId 指向不存在节点时回退默认子节点', () => {
    const nodes = [node('r', null, 1, { activeChildId: 'ghost' }), node('a', 'r', 2), node('b', 'r', 3)];
    assert.equal(m.resolveActiveLeafId(nodes, 'r'), 'b');
  });

  test('resolveActiveLeafId：rootActiveId 指向非根节点时忽略，改用默认根', () => {
    const nodes = [node('r1', null, 1), node('r2', null, 2), node('a', 'r2', 3)];
    assert.equal(m.resolveActiveLeafId(nodes, 'a'), 'a'); // 默认根取最新 r2 → 再到 a
  });

  test('resolveActiveLeafId：数据异常（无根节点）时退化为最早节点，不返回 null', () => {
    const nodes = [node('x', 'missing', 5), node('y', 'missing', 3)];
    assert.equal(m.resolveActiveLeafId(nodes, null), 'y');
  });

  test('buildActivePath：从叶子回溯出「根 → 叶」节点链', () => {
    const nodes = [node('r', null, 1), node('a', 'r', 2), node('b', 'a', 3)];
    const path = m.buildActivePath(nodes, 'b');
    assert.deepEqual(path.map((n) => n.nodeId), ['r', 'a', 'b']);
  });

  test('buildActivePath：叶子不存在 / 空数组返回空路径', () => {
    assert.deepEqual(m.buildActivePath([node('r', null, 1)], 'ghost'), []);
    assert.deepEqual(m.buildActivePath([], 'r'), []);
  });

  test('buildActivePath：父子成环时安全截断（不会死循环）', () => {
    const nodes = [node('a', 'b', 1), node('b', 'a', 2)];
    const path = m.buildActivePath(nodes, 'a');
    assert.deepEqual(path.map((n) => n.nodeId), ['b', 'a']);
  });

  test('isDescendant：子树判定（含隔代）', () => {
    const nodes = [node('r', null, 1), node('a', 'r', 2), node('b', 'a', 3), node('x', null, 4)];
    assert.equal(m.isDescendant(nodes, 'r', 'b'), true);
    assert.equal(m.isDescendant(nodes, 'a', 'r'), false);
    assert.equal(m.isDescendant(nodes, 'r', 'x'), false);
    assert.equal(m.isDescendant(nodes, 'ghost', 'b'), false);
  });

  test('isDescendant：parentId=null 时只对根节点返回 true', () => {
    const nodes = [node('r', null, 1), node('a', 'r', 2)];
    assert.equal(m.isDescendant(nodes, null, 'r'), true);
    assert.equal(m.isDescendant(nodes, null, 'a'), false);
  });

  summarize();
}
