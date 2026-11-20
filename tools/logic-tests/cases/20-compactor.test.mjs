/**
 * 缓存感知压缩器（packages/core_context/CacheAwareCompactor.ets）
 *
 * 覆盖 QA 清单：四类 trigger（idle_cache_expired / model_switched / attention_threshold /
 * low_ratio_economic）、policy=off 语义、break-even 公式 round((alpha/(1-alpha))*R)=round(3R)、
 * compactToCheckpoint 的保留窗口/归档清单/摘要降级、pickPrunableNodeIds 的尾部保留与去重。
 *
 * 口径（实现已冻结）：attention 0.7（aggressive 0.5）、low_ratio 0.6（aggressive 0.45）、
 * 仅 R<=10 走 low_ratio_economic、usage<0.9 时优先只裁剪大载荷、空闲判定 idleMs > ttlMs。
 */
import { test, assert, testAsync, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_context/src/main/ets/CacheAwareCompactor.ts';
const m = await tryImport(P);

if (!m || !m.CacheAwareCompactor) {
  skip('缓存感知压缩器（全部用例）', missingReason(P));
  summarize();
} else {
  const { CacheAwareCompactor } = m;
  const compactor = new CacheAwareCompactor();
  let seq = 0;

  /** 构造一条活动路径节点；tokens 直接写 tokenEstimate（估算器优先用它）。 */
  function mkNode(id, parentId, role, tokens, opts = {}) {
    seq += 1;
    return {
      nodeId: id,
      parentId,
      sessionId: 's1',
      role,
      items: opts.items || [],
      tokenEstimate: tokens,
      createdAt: opts.createdAt ?? seq
    };
  }
  /** 构造 n 个节点、每个 tokens 个 token 的线性路径。 */
  function chain(n, tokens) {
    const nodes = [];
    for (let i = 0; i < n; i += 1) {
      nodes.push(mkNode(`n${i}`, i === 0 ? null : `n${i - 1}`, i % 2 === 0 ? 'user' : 'assistant', tokens));
    }
    return nodes;
  }
  function input(over = {}) {
    return {
      contextWindowTokens: 10000,
      cacheMissToHitRatio: 50,
      cacheIdleTtlSec: 3600,
      supportsServerWebTools: true,
      ...over
    };
  }
  const NOW = Date.now();

  test('空对话不触发压缩，break-even 仍按公式给出（R=50 → 150 轮）', () => {
    const d = compactor.evaluate(input(), [], NOW, false);
    assert.equal(d.shouldCompact, false);
    assert.equal(d.trigger, 'none');
    assert.equal(d.estimatedBreakEvenTurns, 150); // round(0.75/0.25*50)
    assert.equal(d.usageRatio, 0);
    assert.ok(d.reasonText.length > 0, '必须有直白中文原因');
  });

  test('常规用量（0.5）且未空闲/未换模型 → 不压缩（保护前缀缓存）', () => {
    const d = compactor.evaluate(input(), chain(5, 1000), NOW, false);
    assert.equal(d.shouldCompact, false);
    assert.equal(d.trigger, 'none');
    assert.equal(d.usageRatio, 0.5);
    assert.ok(d.reasonText.includes('缓存'));
  });

  test('idle_cache_expired：空闲超过 cacheIdleTtlSec → 零沉没成本压缩', () => {
    const d = compactor.evaluate(input({ cacheIdleTtlSec: 3600 }), chain(3, 1000),
      Date.now() - 2 * 3600 * 1000, false);
    assert.equal(d.shouldCompact, true);
    assert.equal(d.trigger, 'idle_cache_expired');
    assert.equal(d.pruneToolPayloadsOnly, false);
    assert.ok(d.reasonText.includes('缓存'));
  });

  test('空闲未超时（只过了 1 秒）不触发 idle 压缩', () => {
    const d = compactor.evaluate(input(), chain(3, 1000), Date.now() - 1000, false);
    assert.equal(d.shouldCompact, false);
    assert.equal(d.trigger, 'none');
  });

  test('cacheIdleTtlSec=0 视为「无过期窗口」，不触发 idle 压缩', () => {
    const d = compactor.evaluate(input({ cacheIdleTtlSec: 0 }), chain(3, 1000), Date.now() - 999999999, false);
    assert.equal(d.trigger, 'none');
  });

  test('model_switched：切换异构模型 → 原缓存必然作废，免费压缩窗口', () => {
    const d = compactor.evaluate(input(), chain(3, 1000), NOW, true);
    assert.equal(d.shouldCompact, true);
    assert.equal(d.trigger, 'model_switched');
  });

  test('idle 优先于 model_switched（两者同时满足时报缓存已过期）', () => {
    const d = compactor.evaluate(input(), chain(3, 1000), Date.now() - 2 * 3600 * 1000, true);
    assert.equal(d.trigger, 'idle_cache_expired');
  });

  test('attention_threshold：用量 > 70% 触发质量红线，且 <90% 时只裁剪大载荷', () => {
    const d = compactor.evaluate(input({ cacheMissToHitRatio: 50 }), chain(5, 1500), NOW, false);
    assert.equal(d.shouldCompact, true);
    assert.equal(d.trigger, 'attention_threshold');
    assert.equal(d.usageRatio, 0.75);
    assert.equal(d.pruneToolPayloadsOnly, true);
    assert.ok(d.reasonText.includes('75%'));
  });

  test('attention_threshold：用量 > 90% 时必须真正改写摘要（不再只裁剪载荷）', () => {
    const d = compactor.evaluate(input(), chain(5, 1900), NOW, false);
    assert.equal(d.shouldCompact, true);
    assert.equal(d.trigger, 'attention_threshold');
    assert.equal(d.pruneToolPayloadsOnly, false);
  });

  test('low_ratio_economic：低缓存倍率模型（R=4<=10）在 60% 窗口触发经济性压缩', () => {
    const d = compactor.evaluate(input({ cacheMissToHitRatio: 4 }), chain(5, 1300), NOW, false);
    assert.equal(d.shouldCompact, true);
    assert.equal(d.trigger, 'low_ratio_economic');
    assert.equal(d.estimatedBreakEvenTurns, 12); // round(3*4)
  });

  test('high_ratio 模型（R=50）在 65% 用量不触发 economic 压缩（缓存太值钱）', () => {
    const d = compactor.evaluate(input({ cacheMissToHitRatio: 50 }), chain(5, 1300), NOW, false);
    assert.equal(d.shouldCompact, false);
    assert.equal(d.trigger, 'none');
  });

  test('policy=off：常规用量永不压缩，但与「关掉」原因一起返回', () => {
    const d = compactor.evaluate(input(), chain(5, 1000), NOW, false, 'off');
    assert.equal(d.shouldCompact, false);
    assert.equal(d.trigger, 'none');
    assert.ok(d.reasonText.includes('关掉'));
  });

  test('policy=off：超过质量红线仍然压缩（硬红线优先于用户开关）', () => {
    const d = compactor.evaluate(input(), chain(5, 1600), NOW, false, 'off');
    assert.equal(d.shouldCompact, true);
    assert.equal(d.trigger, 'attention_threshold');
    assert.equal(d.pruneToolPayloadsOnly, true);
  });

  test('policy=aggressive：阈值提前（55% 触发 attention，48% 触发 low_ratio）', () => {
    const a = compactor.evaluate(input({ cacheMissToHitRatio: 50 }), chain(2, 2750), NOW, false, 'aggressive');
    assert.equal(a.trigger, 'attention_threshold');
    assert.equal(a.usageRatio, 0.55);

    const b = compactor.evaluate(input({ cacheMissToHitRatio: 4 }), chain(2, 2400), NOW, false, 'aggressive');
    assert.equal(b.trigger, 'low_ratio_economic');
    assert.equal(b.usageRatio, 0.48);
  });

  test('breakEvenTurns 公式 = round(3R)，R<=0 时归 0', () => {
    assert.equal(CacheAwareCompactor.breakEvenTurns(50), 150);
    assert.equal(CacheAwareCompactor.breakEvenTurns(30), 90);
    assert.equal(CacheAwareCompactor.breakEvenTurns(4), 12);
    assert.equal(CacheAwareCompactor.breakEvenTurns(0), 0);
    assert.equal(CacheAwareCompactor.breakEvenTurns(-5), 0);
  });

  test('决策里 usageRatio = tokens / contextWindow（记忆条数据源）', () => {
    const d = compactor.evaluate(input({ contextWindowTokens: 20000 }), chain(4, 2500), NOW, false);
    assert.equal(d.usageRatio, 0.5);
  });

  // ---------------- compactToCheckpoint ----------------
  await testAsync('compactToCheckpoint：保留最近 8 个节点，归档更早节点并生成 checkpoint_summary', async () => {
    const nodes = chain(10, 100);
    const summarizer = { summarize: async () => '这是整理后的对话摘要。' };
    const outcome = await compactor.compactToCheckpoint('s1', nodes, summarizer);

    assert.equal(outcome.archivedNodeIds.length, 2); // 10 - 8
    assert.deepEqual(outcome.archivedNodeIds, ['n0', 'n1']);
    assert.equal(outcome.beforeTokens, 1000);
    assert.equal(outcome.checkpoint.sessionId, 's1');
    assert.equal(outcome.checkpoint.role, 'assistant');
    assert.equal(outcome.checkpoint.parentId, null); // nodes[0].parentId
    assert.equal(outcome.checkpoint.items.length, 1);
    assert.equal(outcome.checkpoint.items[0].kind, 'checkpoint_summary');
    assert.equal(outcome.checkpoint.items[0].text, '这是整理后的对话摘要。');
    assert.ok(outcome.checkpoint.tokenEstimate > 0);
    // after = 保留节点 token(800) + checkpoint 估算
    assert.equal(outcome.afterTokens, 800 + outcome.checkpoint.tokenEstimate);
  });

  await testAsync('compactToCheckpoint：对话太短（1 个节点）时抛中文错误，不误清空上下文', async () => {
    let err = null;
    try {
      await compactor.compactToCheckpoint('s1', chain(1, 100), { summarize: async () => 'x' });
    } catch (e) {
      err = e;
    }
    assert.ok(err, '应当抛错');
    assert.ok(String(err.message).includes('还不够长'));
  });

  await testAsync('compactToCheckpoint：空节点列表抛中文错误', async () => {
    let err = null;
    try {
      await compactor.compactToCheckpoint('s1', [], { summarize: async () => 'x' });
    } catch (e) {
      err = e;
    }
    assert.ok(err && String(err.message).includes('没有可以整理'));
  });

  await testAsync('compactToCheckpoint：摘要器异常时本地降级摘要兜底，不打断聊天', async () => {
    const nodes = [
      mkNode('u1', null, 'user', 100, { items: [{ id: 'i1', kind: 'text', text: '帮我查一下天气' }] }),
      mkNode('a1', 'u1', 'assistant', 100, { items: [{ id: 'i2', kind: 'text', text: '好的我来看看' }] }),
      mkNode('u2', 'a1', 'user', 100),
      mkNode('a2', 'u2', 'assistant', 100),
      mkNode('u3', 'a2', 'user', 100),
      mkNode('a3', 'u3', 'assistant', 100),
      mkNode('u4', 'a3', 'user', 100),
      mkNode('a4', 'u4', 'assistant', 100),
      mkNode('u5', 'a4', 'user', 100),
      mkNode('a5', 'u5', 'assistant', 100)
    ];
    const outcome = await compactor.compactToCheckpoint('s1', nodes, {
      summarize: async () => {
        throw new Error('网络断了');
      }
    });
    const text = outcome.checkpoint.items[0].text;
    assert.ok(text.length > 0);
    assert.ok(text.includes('用户'), '降级摘要应包含角色与原文要点');
    assert.ok(text.includes('帮我查一下天气'));
  });

  // ---------------- pickPrunableNodeIds ----------------
  test('pickPrunableNodeIds：只返回保留窗口之前的 tool/web 大载荷节点', () => {
    const nodes = [
      mkNode('n0', null, 'assistant', 10, { items: [{ id: 'i0', kind: 'tool_call', toolName: 'f' }] }),
      mkNode('n1', 'n0', 'user', 10),
      mkNode('n2', 'n1', 'assistant', 10, { items: [{ id: 'i2', kind: 'web_search_call' }] }),
      mkNode('n3', 'n2', 'tool', 10, { items: [{ id: 'i3', kind: 'tool_result', payloadPruned: true }] }),
      mkNode('n4', 'n3', 'user', 10),
      mkNode('n5', 'n4', 'assistant', 10)
    ];
    assert.deepEqual(compactor.pickPrunableNodeIds(nodes, 4), ['n0']); // limit=2，仅 n0 命中
    assert.deepEqual(compactor.pickPrunableNodeIds(nodes, 0), ['n0', 'n2']); // n3 已裁剪过，跳过
  });

  test('pickPrunableNodeIds：节点数少于保留数时不裁剪任何载荷', () => {
    const nodes = [
      mkNode('n0', null, 'assistant', 10, { items: [{ id: 'i0', kind: 'tool_call', toolName: 'f' }] }),
      mkNode('n1', 'n0', 'user', 10)
    ];
    assert.deepEqual(compactor.pickPrunableNodeIds(nodes, 4), []);
  });

  summarize();
}
