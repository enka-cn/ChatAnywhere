/**
 * 内置模型目录（packages/core_protocol/ModelCatalog.ets）
 *
 * 覆盖：Blueprint §3.2 的 cacheMissToHitRatio（deepseek-flash=50 / v4-pro=30 / 其它≈4）、
 * contextWindow、协议种类、中文 label、密钥别名（不得明文 Key）、注册/覆盖/内置判定。
 * 这些字段直接驱动压缩引擎的经济性决策与设置页展示。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_protocol/src/main/ets/ModelCatalog.ts';
const m = await tryImport(P);

if (!m || !m.ModelCatalog) {
  skip('模型目录（全部用例）', missingReason(P));
  summarize();
} else {
  const fresh = () => new m.ModelCatalog();

  test('内置目录包含 DeepSeek / Anthropic / OpenAI 兼容共 5 个模型', () => {
    const catalog = fresh();
    const profiles = catalog.listProfiles();
    assert.equal(profiles.length, 5);
    assert.ok(profiles.some((p) => p.modelId === 'deepseek-flash'));
    assert.ok(profiles.some((p) => p.modelId === 'deepseek-v4-pro'));
    assert.ok(profiles.some((p) => p.providerId === 'anthropic'));
    assert.ok(profiles.some((p) => p.protocol === 'openai_chat'));
  });

  test('deepseek-flash：缓存价差 50、窗口 1M、Responses 协议、支持服务端联网', () => {
    const p = fresh().get('deepseek', 'deepseek-flash');
    assert.ok(p);
    assert.equal(p.cacheMissToHitRatio, 50);
    assert.equal(p.contextWindow, 1000000);
    assert.equal(p.protocol, 'deepseek_responses');
    assert.equal(p.supportsServerWebTools, true);
    assert.equal(p.supportsThinking, true);
    assert.equal(p.baseUrl, 'https://api.deepseek.com');
  });

  test('deepseek-v4-pro：缓存价差 30', () => {
    assert.equal(fresh().get('deepseek', 'deepseek-v4-pro').cacheMissToHitRatio, 30);
  });

  test('Anthropic 模型：缓存价差 4、不支持服务端原厂联网工具', () => {
    const p = fresh().get('anthropic', 'claude-sonnet-4-5');
    assert.ok(p);
    assert.equal(p.cacheMissToHitRatio, 4);
    assert.equal(p.protocol, 'anthropic_messages');
    assert.equal(p.supportsServerWebTools, false);
    assert.ok(p.contextWindow > 0);
    assert.ok(p.cacheIdleTtlSec > 0);
  });

  test('OpenAI 兼容端点：可自定义 baseUrl，非内置厂商', () => {
    const catalog = fresh();
    const p = catalog.get('openai_compat', 'gpt-4.1-mini');
    assert.ok(p);
    assert.equal(p.protocol, 'openai_chat');
    assert.equal(p.builtin, false);
    assert.equal(catalog.isBuiltin('openai_compat'), false);
  });

  test('所有 profile 的 label 为直白中文、只存密钥别名不存明文 Key', () => {
    for (const p of fresh().listProfiles()) {
      assert.ok(p.label.length > 0, `${p.modelId} 缺中文 label`);
      assert.ok(/[\u4e00-\u9fff]/.test(p.label), `${p.modelId} 的 label 应为中文：${p.label}`);
      assert.ok(p.assetKeyAlias.length > 0);
      assert.ok(!p.assetKeyAlias.toLowerCase().startsWith('sk-'), '不得在 manifest 里存明文 Key');
      assert.ok(p.contextWindow > 0);
      assert.ok(p.cacheMissToHitRatio > 0);
    }
  });

  test('get：精确命中，未知组合返回 null', () => {
    const catalog = fresh();
    assert.equal(catalog.get('deepseek', 'deepseek-flash').modelId, 'deepseek-flash');
    assert.equal(catalog.get('deepseek', '不存在'), null);
    assert.equal(catalog.get('未知厂商', 'deepseek-flash'), null);
  });

  test('findByModelId / findByProtocol', () => {
    const catalog = fresh();
    assert.equal(catalog.findByModelId('claude-opus-4-5').providerId, 'anthropic');
    assert.equal(catalog.findByModelId('不存在'), null);
    assert.equal(catalog.findByProtocol('deepseek_responses').providerId, 'deepseek');
    assert.equal(catalog.findByProtocol('anthropic_messages').providerId, 'anthropic');
  });

  test('defaultProfile：恒为非空，默认 deepseek-flash', () => {
    const catalog = fresh();
    const p = catalog.defaultProfile();
    assert.ok(p);
    assert.equal(p.providerId, 'deepseek');
    assert.equal(p.modelId, 'deepseek-flash');
  });

  test('register：同 provider+model 覆盖不新增；新 provider 追加', () => {
    const catalog = fresh();
    const before = catalog.listProfiles().length;
    const flash = catalog.get('deepseek', 'deepseek-flash');
    const overridden = { ...flash, baseUrl: 'https://proxy.example.com', label: '自定义中转' };
    catalog.register(overridden);
    assert.equal(catalog.listProfiles().length, before);
    assert.equal(catalog.get('deepseek', 'deepseek-flash').baseUrl, 'https://proxy.example.com');

    catalog.register({ ...flash, providerId: 'my_vendor', modelId: 'my-model', builtin: false });
    assert.equal(catalog.listProfiles().length, before + 1);
    assert.equal(catalog.get('my_vendor', 'my-model').modelId, 'my-model');
  });

  test('isBuiltin / builtinCount：内置厂商与内置模型计数', () => {
    const catalog = fresh();
    assert.equal(catalog.isBuiltin('deepseek'), true);
    assert.equal(catalog.isBuiltin('anthropic'), true);
    assert.equal(catalog.isBuiltin('openai_compat'), false);
    assert.equal(catalog.builtinCount(), 4); // deepseek 2 + anthropic 2
  });

  test('resetToBuiltin：清掉自定义注册后恢复默认目录', () => {
    const catalog = fresh();
    const flash = catalog.get('deepseek', 'deepseek-flash');
    catalog.register({ ...flash, providerId: 'tmp_vendor', modelId: 'tmp-model' });
    assert.equal(catalog.listProfiles().length, 6);
    catalog.resetToBuiltin();
    assert.equal(catalog.listProfiles().length, 5);
    assert.equal(catalog.get('tmp_vendor', 'tmp-model'), null);
  });

  summarize();
}
