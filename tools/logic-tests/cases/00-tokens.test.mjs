/**
 * Token 估算 / 缓存命中率 / 上下文占用比例（packages/core_model/util/Tokens.ets）
 *
 * 覆盖 QA 清单要求：中文 / 英文 / 空串；cacheHitRatio；contextUsageRatio。
 * 数值口径来自实现注释：中文 ≈ 1.5 字/token、ASCII ≈ 4 字符/token、每 item 结构开销 4 token、每节点 6 token。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_model/src/main/ets/util/Tokens.ts';
const tokens = await tryImport(P);

if (!tokens) {
  skip('Token 估算（全部用例）', missingReason(P));
  summarize();
} else {
  const { estimateText, estimateItemTokens, estimateNodeTokens, estimateNodesTokens, contextUsageRatio, cacheHitRatio } = tokens;

  // ---------------- estimateText ----------------
  test('空字符串 token 估算为 0', () => {
    assert.equal(estimateText(''), 0);
    assert.equal(estimateText(undefined), 0);
    assert.equal(estimateText(null), 0);
  });

  test('纯中文按 1.5 字/token 向上取整（4 字 → 3 token）', () => {
    assert.equal(estimateText('你好世界'), 3);
    assert.equal(estimateText('你好'), 2);
  });

  test('纯英文按 4 字符/token 向上取整（5 字符 → 2 token）', () => {
    assert.equal(estimateText('hello'), 2);
    assert.equal(estimateText('hello world'), 3); // 11 / 4 = 2.75 → 3
  });

  test('单字符文本至少计 1 token', () => {
    assert.equal(estimateText('a'), 1);
  });

  test('中英混排分别按各自系数累加（你好abcde → 3 token）', () => {
    // 2/1.5 + 5/4 = 1.3333 + 1.25 = 2.5833 → ceil = 3
    assert.equal(estimateText('你好abcde'), 3);
  });

  test('空白字符按 ASCII 口径计入（3 空格 → 1 token）', () => {
    assert.equal(estimateText('   '), 1);
  });

  // ---------------- estimateItemTokens ----------------
  test('text item 含 4 token 结构开销', () => {
    assert.equal(estimateItemTokens({ id: 'i1', kind: 'text', text: '你好世界' }), 7);
  });

  test('reasoning / checkpoint_summary 与 text 同口径', () => {
    assert.equal(estimateItemTokens({ id: 'i1', kind: 'reasoning', text: '你好世界' }), 7);
    assert.equal(estimateItemTokens({ id: 'i2', kind: 'checkpoint_summary', text: '你好世界' }), 7);
  });

  test('tool_call 统计工具名 + 参数 JSON', () => {
    assert.equal(estimateItemTokens({ id: 'i1', kind: 'tool_call', toolName: 'w', argumentsJson: '{}' }), 6);
  });

  test('tool_result 错误态额外 +2 token', () => {
    assert.equal(estimateItemTokens({ id: 'i1', kind: 'tool_result', text: 'ok' }), 5);
    assert.equal(estimateItemTokens({ id: 'i1', kind: 'tool_result', text: 'ok', isError: true }), 7);
  });

  test('web_search_call 统计每条来源标题与摘要', () => {
    const item = {
      id: 'i1',
      kind: 'web_search_call',
      vendorRaw: { provider: 'deepseek', sources: [{ title: 't', url: 'u', snippet: 's' }] }
    };
    assert.equal(estimateItemTokens(item), 14); // 4 + 8 + 1 + 1
  });

  test('image 固定 256 token，file_ref 按 fileId 计', () => {
    assert.equal(estimateItemTokens({ id: 'i1', kind: 'image' }), 256);
    assert.equal(estimateItemTokens({ id: 'i2', kind: 'file_ref', fileId: 'f_1' }), 5);
  });

  // ---------------- estimateNodeTokens / estimateNodesTokens ----------------
  test('空节点 6 token 基础开销', () => {
    assert.equal(estimateNodeTokens({ nodeId: 'n', parentId: null, sessionId: 's', role: 'user', items: [], tokenEstimate: 0, createdAt: 0 }), 6);
  });

  test('节点 = 6 + 各 item 之和（hi → 6+4+1=11）', () => {
    const node = { nodeId: 'n', parentId: null, sessionId: 's', role: 'user', items: [{ id: 'i', kind: 'text', text: 'hi' }], tokenEstimate: 0, createdAt: 0 };
    assert.equal(estimateNodeTokens(node), 11);
  });

  test('批量估算优先使用已落库的 tokenEstimate（>0 时不再重算）', () => {
    const nodes = [
      { nodeId: 'n1', parentId: null, sessionId: 's', role: 'user', items: [], tokenEstimate: 100, createdAt: 0 },
      { nodeId: 'n2', parentId: 'n1', sessionId: 's', role: 'assistant', items: [], tokenEstimate: 0, createdAt: 0 }
    ];
    assert.equal(estimateNodesTokens(nodes), 106); // 100 + (6 + 0)
  });

  test('空节点数组估算为 0', () => {
    assert.equal(estimateNodesTokens([]), 0);
  });

  // ---------------- contextUsageRatio ----------------
  test('上下文占用比例 = tokens / contextWindow', () => {
    assert.equal(contextUsageRatio(500, 1000), 0.5);
    assert.equal(contextUsageRatio(0, 1000), 0);
  });

  test('上下文占用比例上限截断为 1', () => {
    assert.equal(contextUsageRatio(2000, 1000), 1);
  });

  test('contextWindow 非法（0 / 负数）时占用比例为 0，不产生 NaN/Infinity', () => {
    assert.equal(contextUsageRatio(100, 0), 0);
    assert.equal(contextUsageRatio(100, -5), 0);
  });

  // ---------------- cacheHitRatio ----------------
  test('缓存命中率 = cachedTokens / promptTokens', () => {
    assert.equal(cacheHitRatio(50, 100), 0.5);
    assert.equal(cacheHitRatio(0, 100), 0);
  });

  test('缓存命中率截断到 [0, 1]', () => {
    assert.equal(cacheHitRatio(200, 100), 1);
    assert.equal(cacheHitRatio(-5, 100), 0);
  });

  test('promptTokens 为 0 时命中率为 0（不产生 NaN）', () => {
    assert.equal(cacheHitRatio(100, 0), 0);
    assert.equal(cacheHitRatio(0, 0), 0);
  });

  summarize();
}
