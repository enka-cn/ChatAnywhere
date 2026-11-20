/**
 * v3.2 真机反馈修复静态门禁（三项 Bug 根因 + 契约落盘）
 *
 * 对应 v3.2 三项真机反馈：
 * 1) 模型/密钥页「保存后状态不刷新」根因 = 按值传参的 `@Builder`；修复 = 独立 `@Component VendorCard`；
 * 2) 「模型列表是假的」根因 = ModelCatalog 内置占位模型；修复 = 去占位 + 真实 `/models` 探测 + RDB 注册表；
 * 3) 「记忆整理不透明」修复 = RuntimeSnapshot 5 个整理指标 + 设置页记忆卡（前后 Token/摘要/立即整理）。
 * 另含：角色二级列表 + 10 图标 × 8 配色头像、无模型引导、静态度量不变量。
 */
import { test, assert, summarize } from './_harness.mjs';
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..', '..');
const CHAT_ETS = path.join(REPO, 'chat', 'src', 'main', 'ets');
const RES = path.join(REPO, 'chat', 'src', 'main', 'resources');
const PKG = path.join(REPO, 'packages');
const SKIP_DIRS = new Set(['oh_modules', 'build', 'node_modules']);

function walk(dir, exts) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) {
      if (SKIP_DIRS.has(name)) continue;
      out.push(...walk(full, exts));
    } else if (exts.test(name)) {
      out.push(full);
    }
  }
  return out;
}
const read = (p) => readFileSync(p, 'utf8');
const exists = (p) => existsSync(p);

// ---------------------------------------------------------------------------
// 1) Bug #2 根因：ModelCatalog 去占位模型 + 真实探测/注册表联动
// ---------------------------------------------------------------------------
test('去占位模型：ModelCatalog 不含任何具体模型 id，且具备 v3.2 真实目录 API', () => {
  const p = path.join(PKG, 'core_protocol', 'src', 'main', 'ets', 'ModelCatalog.ets');
  assert.ok(exists(p), 'ModelCatalog.ets 不存在');
  const source = read(p);
  for (const modelId of ['deepseek-flash', 'deepseek-v4-pro', 'claude-sonnet', 'claude-opus', 'gpt-4.1-mini']) {
    assert.ok(!source.includes(modelId), `ModelCatalog 仍硬编码模型 id：${modelId}`);
  }
  for (const method of ['async init(', 'listProfiles(', 'hasModels(', 'defaultProfile(',
    'providerMeta(', 'buildProfile(', 'async applyDiscoveredModels(', 'async setModelEnabled(']) {
    assert.ok(source.includes(method), `ModelCatalog 缺少 v3.2 API：${method}`);
  }
  // 三厂商预设仍保留（仅 providerId/协议/地址/能力，不含模型 id）
  for (const providerId of ["'deepseek'", "'anthropic'", "'openai_compat'"]) {
    assert.ok(source.includes(providerId), `ModelCatalog 缺少厂商预设 ${providerId}`);
  }
  console.log('  证据：ModelCatalog 0 个硬编码模型 id；init/hasModels/defaultProfile/buildProfile/applyDiscoveredModels/setModelEnabled 齐全');
});

test('真实探测纯逻辑：RemoteModels 的 parseModelsResponse/modelsUrl 已从 core_protocol 导出', () => {
  const p = path.join(PKG, 'core_protocol', 'src', 'main', 'ets', 'util', 'RemoteModels.ets');
  assert.ok(exists(p), 'util/RemoteModels.ets 不存在');
  const source = read(p);
  assert.ok(source.includes('export function parseModelsResponse'), '缺少 parseModelsResponse');
  assert.ok(source.includes('export function modelsUrl'), '缺少 modelsUrl');
  const index = read(path.join(PKG, 'core_protocol', 'Index.ets'));
  for (const name of ['parseModelsResponse', 'modelsUrl', 'openAiCompatModelsUrl', 'modelIdsOf']) {
    assert.ok(index.includes(name), `core_protocol Index.ets 未导出 ${name}`);
  }
  console.log('  证据：RemoteModels 解析/URL 组装纯函数已被 core_protocol 公开导出');
});

test('RDB 注册表：provider_models 建表 + ModelRegistryApi 4 方法 + core_model 导出', () => {
  const rdb = read(path.join(PKG, 'core_model', 'src', 'main', 'ets', 'impl', 'RdbRepository.ets'));
  assert.ok(/CREATE TABLE IF NOT EXISTS provider_models/.test(rdb), 'RdbRepository 缺少 provider_models 建表');
  for (const method of ['saveDiscoveredModels(', 'loadModels(', 'setModelEnabled(', 'removeProviderModels(']) {
    assert.ok(rdb.includes(method), `RdbRepository 缺少注册表方法 ${method}`);
  }
  const apiPath = path.join(PKG, 'core_model', 'src', 'main', 'ets', 'interfaces', 'ModelRegistryApi.ets');
  assert.ok(exists(apiPath), '缺少 interfaces/ModelRegistryApi.ets');
  const api = read(apiPath);
  for (const sig of ['saveDiscoveredModels(', 'loadModels(', 'setModelEnabled(', 'removeProviderModels(']) {
    assert.ok(api.includes(sig), `ModelRegistryApi 缺少 ${sig}`);
  }
  const index = read(path.join(PKG, 'core_model', 'Index.ets'));
  assert.ok(index.includes('ProviderModelRecord') && index.includes('ModelRegistryApi'),
    'core_model Index.ets 未导出 ProviderModelRecord/ModelRegistryApi');
  console.log('  证据：provider_models 建表 + 4 方法契约 + core_model 导出齐全');
});

// ---------------------------------------------------------------------------
// 2) Bug #1 根因：按值传参 @Builder → 独立 @Component VendorCard
// ---------------------------------------------------------------------------
test('模型页：不再用按值传参 @Builder vendorCard，改用独立 @Component VendorCard（状态实时刷新）', () => {
  const view = read(path.join(CHAT_ETS, 'components', 'SettingsModelsView.ets'));
  assert.ok(!/@Builder\s+vendorCard\s*\(/.test(view), 'SettingsModelsView 仍存在按值传参的 @Builder vendorCard');
  assert.ok(view.includes("from './VendorCard'") || view.includes('from "./VendorCard"'),
    'SettingsModelsView 未 import 独立 VendorCard 组件');
  const cardPath = path.join(CHAT_ETS, 'components', 'VendorCard.ets');
  assert.ok(exists(cardPath), '缺少 components/VendorCard.ets');
  const card = read(cardPath);
  assert.ok(card.includes('@Component') && card.includes('export struct VendorCard'), 'VendorCard 不是独立 @Component');
  assert.ok(card.includes('@Prop'), 'VendorCard 未用 @Prop 接收状态（父级更新后应即时刷新）');
  console.log('  证据：按值 @Builder vendorCard 已消除；SettingsModelsView 复用独立 @Component VendorCard');
});

test('模型页：测试连接/拉取模型支持未保存新 Key（第二参数），探测结果落库', () => {
  const view = read(path.join(CHAT_ETS, 'components', 'SettingsModelsView.ets'));
  const proto = read(path.join(PKG, 'core_protocol', 'src', 'main', 'ets', 'interfaces', 'ProtocolLayer.ets'));
  assert.ok(proto.includes('testConnection(profile: ModelProfile, apiKeyOverride?: string)'),
    'ProtocolLayer.testConnection 缺第二参数 apiKeyOverride');
  assert.ok(proto.includes('listRemoteModels(profile: ModelProfile, apiKeyOverride?: string)'),
    'ProtocolLayer.listRemoteModels 缺第二参数 apiKeyOverride');
  for (const marker of ['testConnection(', 'listRemoteModels(', 'applyDiscoveredModels', 'override.length > 0 ? override : undefined']) {
    assert.ok(view.includes(marker), `SettingsModelsView 缺少 ${marker}`);
  }
  console.log('  证据：testConnection/listRemoteModels 第二参数 + applyDiscoveredModels 落库链路齐全');
});

// ---------------------------------------------------------------------------
// 3) Bug #3：记忆透明化（5 个指标 + 立即整理 + 前后 Token/摘要）
// ---------------------------------------------------------------------------
test('记忆透明化：RuntimeSnapshot 5 个整理指标 + SettingsMemoryView 记忆卡与立即整理', () => {
  const api = read(path.join(CHAT_ETS, 'model', 'ChatRuntimeApi.ets'));
  for (const field of ['lastCompactionAt', 'lastCompactionBeforeTokens', 'lastCompactionAfterTokens', 'lastCompactionSummary']) {
    assert.ok(api.includes(field), `RuntimeSnapshot 缺少 ${field}`);
  }
  const memory = read(path.join(CHAT_ETS, 'components', 'SettingsMemoryView.ets'));
  for (const marker of ['getChatRuntime', 'compactNow', 'lastCompactionBeforeTokens',
    'lastCompactionAfterTokens', 'lastCompactionSummary']) {
    assert.ok(memory.includes(marker), `SettingsMemoryView 缺少 ${marker}`);
  }
  console.log('  证据：RuntimeSnapshot 整理指标 + 设置页记忆卡（前后 Token/摘要/立即整理）已接线');
});

// ---------------------------------------------------------------------------
// 4) 无模型引导 + 真实模型胶囊 / 角色头像
// ---------------------------------------------------------------------------
test('无模型引导：ChatRuntime 提供 hasModel，ChatPage 据此引导且可跳转 Settings category=models', () => {
  const api = read(path.join(CHAT_ETS, 'model', 'ChatRuntimeApi.ets'));
  assert.ok(api.includes('hasModel'), 'RuntimeSnapshot 缺少 hasModel');
  const chatPage = read(path.join(CHAT_ETS, 'pages', 'ChatPage.ets'));
  assert.ok(chatPage.includes('snapshot.hasModel'), 'ChatPage 未使用 snapshot.hasModel 做无模型引导');
  assert.ok(/category:\s*'models'/.test(chatPage), 'ChatPage 无模型引导未跳转 Settings category=models');
  console.log('  证据：hasModel 引导 + category:\'models\' 跳转已接线');
});

test('角色二级列表与头像：PersonaProfile 含 avatarIcon/avatarTone，PersonaAvatars 10 图标 × 8 配色', () => {
  const store = read(path.join(CHAT_ETS, 'app', 'PersonaStore.ets'));
  assert.ok(store.includes('avatarIcon') && store.includes('avatarTone'),
    'PersonaProfile 缺少 avatarIcon/avatarTone');
  // 旧数据兼容：sanitize 对缺失头像字段给默认值
  assert.ok(/avatarIcon:\s*src\.avatarIcon[^,]*\?\?\s*/.test(store) || store.includes("avatarIcon: src.avatarIcon === undefined"),
    'PersonaStore.sanitize 未兼容旧数据（avatarIcon 默认值）');

  const avatarsPath = path.join(CHAT_ETS, 'app', 'PersonaAvatars.ets');
  assert.ok(exists(avatarsPath), '缺少 app/PersonaAvatars.ets');
  const avatars = read(avatarsPath);
  assert.ok(avatars.includes('iconOf(') && avatars.includes('toneOf('), 'PersonaAvatars 缺少 iconOf/toneOf');
  const iconsSection = avatars.slice(avatars.indexOf('ICONS'), avatars.indexOf('TONES'));
  const tonesSection = avatars.slice(avatars.indexOf('TONES'));
  assert.equal((iconsSection.match(/key:\s*'/g) || []).length, 10, 'PersonaAvatars 图标不是 10 个');
  assert.equal((tonesSection.match(/key:\s*'/g) || []).length, 8, 'PersonaAvatars 配色不是 8 个');

  const personaView = read(path.join(CHAT_ETS, 'components', 'SettingsPersonaView.ets'));
  assert.ok(personaView.includes('PersonaAvatars'), 'SettingsPersonaView 未引用 PersonaAvatars');
  assert.ok(personaView.includes('selectedId'), 'SettingsPersonaView 缺少 list/detail 选择状态');
  assert.ok(personaView.includes('openDetail(') && personaView.includes('backToList('),
    'SettingsPersonaView 缺少列表↔详情二级切换');
  console.log('  证据：PersonaProfile avatarIcon/avatarTone + sanitize 兼容；PersonaAvatars 10×8 + iconOf/toneOf；角色二级切换完整');
});

test('头像配色资源：base/dark 各 46 键且含 8 个 avatar_bg_*，深浅色一致', () => {
  const load = (mode) => JSON.parse(read(path.join(RES, mode, 'element', 'color.json')));
  const bk = load('base').color.map((c) => c.name);
  const dk = load('dark').color.map((c) => c.name);
  assert.equal(bk.length, 46, `base 颜色键 ${bk.length} ≠ 46`);
  assert.deepEqual([...bk].sort(), [...dk].sort(), '深浅色键集合不一致');
  assert.equal(bk.filter((n) => n.startsWith('avatar_bg_')).length, 8, 'avatar_bg_* 不是 8 个');
  console.log('  证据：46 键（38 + 8 avatar_bg_*）base/dark 一致');
});

// ---------------------------------------------------------------------------
// 5) 契约与文档化
// ---------------------------------------------------------------------------
test('角色「跟随当前模型」语义：空 modelId 表示跟随当前模型（设置页/运行时一致）', () => {
  const personaView = read(path.join(CHAT_ETS, 'components', 'SettingsPersonaView.ets'));
  const controller = read(path.join(CHAT_ETS, 'model', 'runtime', 'SettingsController.ets'));
  assert.ok(personaView.includes('跟随当前模型'), 'SettingsPersonaView 缺少「跟随当前模型」选项');
  assert.ok(controller.includes('跟随当前模型'), 'SettingsController 未处理「空 modelId=跟随当前模型」语义');
  console.log('  证据：空 modelId=跟随当前模型，设置页与运行时一致');
});

test('公开构建配置已脱敏：build-profile.local.json5 存在且被 .gitignore 忽略（仓库不含签名材料）', () => {
  const profile = read(path.join(REPO, 'build-profile.json5'));
  assert.ok(/"signingConfigs"\s*:\s*\[\s*\]/.test(profile), 'build-profile.json5 的 signingConfigs 未脱敏为空数组');
  assert.ok(exists(path.join(REPO, 'build-profile.local.json5')), '缺少本机签名材料备份 build-profile.local.json5');
  assert.ok(read(path.join(REPO, '.gitignore')).includes('build-profile.local.json5'),
    '.gitignore 未忽略 build-profile.local.json5');
  console.log('  证据：signingConfigs=[]；本机签名材料仅在 gitignore 的 build-profile.local.json5');
});

summarize();
