/**
 * 真实模型目录（packages/core_protocol/ModelCatalog.ets，v3.2 去占位模型）
 *
 * v3.2 契约：
 * - 目录启动为空（无任何硬编码模型 id），只有 RDB 注册表里 enabled=true 的模型才出现；
 * - 三厂商预设只含 providerId/协议/默认地址/缓存经济性/能力标志；
 * - `buildProfile` 组合预设与模型 id；`applyDiscoveredModels` 落库并保留已勾选状态；
 * - `hasModels()/defaultProfile()` 在无模型时分别返回 false/null（UI 据此引导去设置）。
 */
import { test, assert, testAsync, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_protocol/src/main/ets/ModelCatalog.ts';
const m = await tryImport(P);

function makeDeps(initial = {}) {
  const settings = new Map(Object.entries(initial.settings || {}));
  let records = (initial.records || []).map((r) => ({ ...r }));
  const models = {
    async saveDiscoveredModels(providerId, next) {
      records = records.filter((r) => r.providerId !== providerId).concat(next.map((r) => ({ ...r })));
    },
    async loadModels() {
      return records.map((r) => ({ ...r }));
    },
    async setModelEnabled(providerId, modelId, enabled) {
      records = records.map((r) => (r.providerId === providerId && r.modelId === modelId ? { ...r, enabled } : r));
    },
    async removeProviderModels(providerId) {
      records = records.filter((r) => r.providerId !== providerId);
    }
  };
  const settingsApi = {
    async getString(key, defaultValue) { return settings.has(key) ? settings.get(key) : defaultValue; },
    async putString(key, value) { settings.set(key, value); },
    async getNumber(key, defaultValue) { return defaultValue; },
    async putNumber() { },
    async getBool(key, defaultValue) { return defaultValue; },
    async putBool() { },
    async remove() { }
  };
  const secrets = {
    async has() { return false; },
    async get() { return null; },
    async put() { },
    async listAliases() { return []; },
    async remove() { }
  };
  return { deps: { secrets, settings: settingsApi, models }, inspect: () => records, settingsMap: settings };
}
const record = (providerId, modelId, enabled, displayName = '') => ({
  providerId, modelId, displayName, metaJson: '', enabled, discoveredAt: 1
});

if (!m || !m.ModelCatalog) {
  skip('真实模型目录（全部用例）', missingReason(P));
  summarize();
} else {
  const { ModelCatalog } = m;
  const fresh = (initial = {}) => new ModelCatalog(makeDeps(initial).deps);

  await testAsync('默认目录为空：无任何硬编码占位模型，hasModels=false / defaultProfile=null', async () => {
    const catalog = fresh();
    await catalog.init();
    assert.deepEqual(catalog.listProfiles(), []);
    assert.equal(catalog.hasModels(), false);
    assert.equal(catalog.defaultProfile(), null);
    assert.equal(catalog.get('deepseek', 'any-model'), null);
    assert.equal(catalog.findByModelId('any-model'), null);
  });

  test('三厂商预设：providerId/协议/地址/缓存经济性/能力标志（不含模型 id）', () => {
    const catalog = fresh();
    for (const [providerId, protocol, label] of [
      ['deepseek', 'deepseek_responses', '深度求索'],
      ['anthropic', 'anthropic_messages', '克劳德'],
      ['openai_compat', 'openai_chat', '自定义兼容接口']
    ]) {
      const meta = catalog.providerMeta(providerId);
      assert.ok(meta, `${providerId} 预设缺失`);
      assert.equal(meta.providerId, providerId);
      assert.equal(meta.protocol, protocol);
      assert.equal(meta.label, label);
      assert.ok(meta.defaultBaseUrl.startsWith('https://'));
      assert.ok(meta.contextWindow > 0);
      assert.ok(meta.cacheMissToHitRatio > 0);
      assert.ok(meta.assetKeyAlias.length > 0 && !meta.assetKeyAlias.startsWith('sk-'));
    }
    assert.equal(catalog.providerMeta('deepseek').cacheMissToHitRatio, 50);
    assert.equal(catalog.providerMeta('deepseek').contextWindow, 1000000);
    assert.equal(catalog.providerMeta('anthropic').contextWindow, 200000);
    assert.equal(catalog.providerMeta('unknown_vendor'), null);
  });

  test('isBuiltin：三类预设为内置，未知/空为 false', () => {
    const catalog = fresh();
    assert.equal(catalog.isBuiltin('deepseek'), true);
    assert.equal(catalog.isBuiltin('anthropic'), true);
    assert.equal(catalog.isBuiltin('openai_compat'), true);
    assert.equal(catalog.isBuiltin('my_vendor'), false);
    assert.equal(catalog.isBuiltin(''), false);
  });

  test('providerMeta 返回副本：调用方修改不污染预设', () => {
    const catalog = fresh();
    const meta = catalog.providerMeta('deepseek');
    meta.label = '被改坏';
    meta.contextWindow = 1;
    assert.equal(catalog.providerMeta('deepseek').label, '深度求索');
    assert.equal(catalog.providerMeta('deepseek').contextWindow, 1000000);
  });

  test('buildProfile：预设 + 模型 id 组合全部字段；空 modelId 为探测用 profile；未知厂商 null', () => {
    const catalog = fresh();
    const p = catalog.buildProfile('deepseek', 'model-x');
    assert.equal(p.providerId, 'deepseek');
    assert.equal(p.modelId, 'model-x');
    assert.equal(p.protocol, 'deepseek_responses');
    assert.equal(p.baseUrl, 'https://api.deepseek.com');
    assert.equal(p.contextWindow, 1000000);
    assert.equal(p.cacheMissToHitRatio, 50);
    assert.equal(p.label, '深度求索 · model-x');
    assert.equal(p.builtin, true);
    assert.equal(p.supportsThinking, true);

    const probe = catalog.buildProfile('deepseek', '');
    assert.equal(probe.modelId, '');
    assert.equal(probe.label, '深度求索');

    const custom = catalog.buildProfile('openai_compat', 'm', 'https://proxy.example.com/v1');
    assert.equal(custom.baseUrl, 'https://proxy.example.com/v1');

    assert.equal(catalog.buildProfile('unknown', 'm'), null);
    assert.equal(catalog.buildProfile('', 'm'), null);
  });

  test('buildProfile：OpenAI 兼容端点的思考能力按模型名保守推断', () => {
    const catalog = fresh();
    const think = (id) => catalog.buildProfile('openai_compat', id).supportsThinking;
    assert.equal(think('gpt-5-mini'), true);
    assert.equal(think('deepseek-r1'), true);
    assert.equal(think('o3-mini'), true);
    assert.equal(think('qwq-32b'), true);
    assert.equal(think('gpt-4o'), false);
    assert.equal(think(''), false);
  });

  testAsync('init：从 fake 注册表装载 enabled 模型（disabled 不出现），defaultProfile 按预设顺序', async () => {
    const catalog = fresh({
      records: [
        record('deepseek', 'flash-x', true, '极速X'),
        record('deepseek', 'pro-y', false),
        record('anthropic', 'claude-z', true),
        record('unknown_vendor', 'ghost-model', true)
      ]
    });
    await catalog.init();
    const profiles = catalog.listProfiles();
    assert.equal(profiles.length, 2, JSON.stringify(profiles.map((p) => p.modelId)));
    assert.ok(profiles.some((p) => p.modelId === 'flash-x' && p.label === '极速X'));
    assert.ok(profiles.some((p) => p.modelId === 'claude-z'));
    assert.equal(catalog.hasModels(), true);
    assert.equal(catalog.defaultProfile().modelId, 'flash-x');
    assert.equal(catalog.get('deepseek', 'flash-x').label, '极速X');
    assert.equal(catalog.get('deepseek', 'pro-y'), null);
    assert.equal(catalog.findByModelId('claude-z').providerId, 'anthropic');
  });

  testAsync('applyDiscoveredModels：落库去重、新模型默认未勾选、保留已有勾选状态', async () => {
    const harness = makeDeps();
    const catalog = new ModelCatalog(harness.deps);
    await catalog.init();

    await catalog.applyDiscoveredModels('deepseek', [
      { modelId: 'm1', displayName: '模型一', metaJson: '' },
      { modelId: 'm2', displayName: '', metaJson: '' },
      { modelId: 'm1', displayName: '重复', metaJson: '' }
    ]);
    assert.equal(harness.inspect().length, 2, '同 modelId 应去重');
    assert.ok(harness.inspect().every((r) => r.enabled === false), '新发现模型默认未勾选');
    assert.deepEqual(catalog.listProfiles(), [], '未勾选模型不进入目录');

    await catalog.setModelEnabled('deepseek', 'm1', true);
    assert.equal(catalog.listProfiles().length, 1);
    assert.equal(catalog.defaultProfile().modelId, 'm1');
    assert.equal(catalog.defaultProfile().label, '模型一');

    // 再次探测：m1 保持勾选，m2 仍未勾选，新增 m3 默认未勾选
    await catalog.applyDiscoveredModels('deepseek', [
      { modelId: 'm1', displayName: '模型一', metaJson: '' },
      { modelId: 'm2', displayName: '', metaJson: '' },
      { modelId: 'm3', displayName: '', metaJson: '' }
    ]);
    const enabledIds = catalog.listProfiles().map((p) => p.modelId);
    assert.deepEqual(enabledIds, ['m1']);
    const stored = harness.inspect().filter((r) => r.providerId === 'deepseek');
    assert.equal(stored.length, 3);
    assert.equal(stored.find((r) => r.modelId === 'm1').enabled, true);
    assert.equal(stored.find((r) => r.modelId === 'm3').enabled, false);

    // 未知厂商直接忽略
    await catalog.applyDiscoveredModels('unknown', [{ modelId: 'x' }]);
    assert.equal(catalog.listProfiles().length, 1);

    // 取消勾选后目录移除
    await catalog.setModelEnabled('deepseek', 'm1', false);
    assert.deepEqual(catalog.listProfiles(), []);
    assert.equal(catalog.defaultProfile(), null);
  });

  testAsync('defaultProfile：无启用模型返回 null；仅有非首预设厂商时回退该模型', async () => {
    const onlyAnthropic = fresh({ records: [record('anthropic', 'claude-z', true)] });
    await onlyAnthropic.init();
    assert.equal(onlyAnthropic.defaultProfile().providerId, 'anthropic');

    const none = fresh();
    await none.init();
    assert.equal(none.defaultProfile(), null);
  });

  testAsync('register：运行时临时注册进入目录（不落库），同键覆盖', async () => {
    const harness = makeDeps();
    const catalog = new ModelCatalog(harness.deps);
    await catalog.init();
    const profile = catalog.buildProfile('deepseek', 'runtime-model');
    catalog.register(profile);
    assert.equal(catalog.listProfiles().length, 1);
    assert.equal(catalog.get('deepseek', 'runtime-model').modelId, 'runtime-model');
    assert.equal(harness.inspect().length, 0, 'register 不应落库');

    const overridden = { ...profile, label: '临时覆盖名' };
    catalog.register(overridden);
    assert.equal(catalog.listProfiles().length, 1);
    assert.equal(catalog.get('deepseek', 'runtime-model').label, '临时覆盖名');
  });

  testAsync('自定义端点地址：init 从设置读取 custom/anthropic baseUrl，re-init 跟随设置变化', async () => {
    const harness = makeDeps({
      settings: {
        'provider.custom.baseUrl': 'https://proxy.example.com/v1',
        'provider.anthropic.baseUrl': 'https://claude-proxy.example.com'
      },
      records: [record('anthropic', 'claude-z', true)]
    });
    const catalog = new ModelCatalog(harness.deps);
    await catalog.init();
    assert.equal(catalog.buildProfile('openai_compat', 'm').baseUrl, 'https://proxy.example.com/v1');
    assert.equal(catalog.buildProfile('anthropic', 'claude-z').baseUrl, 'https://claude-proxy.example.com');
    assert.equal(catalog.providerMeta('anthropic').defaultBaseUrl, 'https://claude-proxy.example.com');

    harness.settingsMap.set('provider.custom.baseUrl', 'https://proxy2.example.com/v1');
    await catalog.init();
    assert.equal(catalog.buildProfile('openai_compat', 'm').baseUrl, 'https://proxy2.example.com/v1');
    // 已装载的 profile 也应跟随新地址
    assert.equal(catalog.listProfiles()[0].baseUrl, 'https://claude-proxy.example.com');
  });

  summarize();
}
