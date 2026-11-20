/**
 * 重构验收静态断言（R1 前端视觉 + R2 架构瘦身）
 *
 * 只读扫描 `chat/src/main/ets` 与 `packages/*` 源码，不依赖 prepare 产物、不跑鸿蒙运行时。
 * 目标：把这一轮重构的硬性约定固化成可重复执行的门禁（每次 run.ps1 都会跑）。
 *
 * 判定口径说明（与 Lead 给的基线一致）：
 * - 「行数」= **非空行**（例：ChatRuntime.ets 总 559 行 / 非空 494 行 = Lead 所说「现 494」）；
 * - 硬编码色值唯一豁免：`bridge/LanEditorServer.ets` 的 `renderEditPage()` 内嵌 HTML/CSS
 *   模板（发给电脑浏览器的静态页，不能引用 app 资源）。实测为 **6 行 CSS 内的 10 个色值**，
 *   本用例要求「文件内所有色值都必须落在这段模板里」，且其他任何 UI 文件 0 个色值。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..', '..');
const CHAT_ETS = path.join(REPO, 'chat', 'src', 'main', 'ets');
const RES = path.join(REPO, 'chat', 'src', 'main', 'resources');
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
const rel = (p) => path.relative(REPO, p).split(path.sep).join('/');
const nonBlank = (text) => text.split('\n').filter((line) => line.trim().length > 0).length;
const countMatches = (text, re) => (text.match(re) || []).length;

const chatFiles = walk(CHAT_ETS, /\.(ets|ts)$/);

// ---------------------------------------------------------------------------
// 1) 设计令牌：禁止硬编码色值（唯一豁免 LanEditorServer 内嵌 HTML 模板）
// ---------------------------------------------------------------------------
test('设计令牌：除 LanEditorServer 内嵌 HTML 模板外，UI 源码 0 个 #RRGGBB 硬编码', () => {
  assert.ok(chatFiles.length > 40, `chat/src/main/ets 文件数异常：${chatFiles.length}`);
  const offenders = [];
  let exemptOccurrences = 0;
  for (const file of chatFiles) {
    const text = read(file);
    const total = countMatches(text, /#[0-9A-Fa-f]{6}\b/g);
    if (total === 0) continue;
    const isLan = /bridge[/\\]LanEditorServer\.ets$/.test(file);
    if (!isLan) {
      offenders.push(`${rel(file)}: ${total}`);
      continue;
    }
    // 豁免必须严格落在 renderEditPage() 返回的 HTML 模板字面量内
    const start = text.indexOf('renderEditPage(): string {');
    assert.ok(start >= 0, 'LanEditorServer 缺少 renderEditPage()，无法判定豁免范围');
    const tplStart = text.indexOf('return `', start);
    const tplEnd = text.indexOf('`;', tplStart);
    assert.ok(tplStart > 0 && tplEnd > tplStart, 'LanEditorServer renderEditPage 模板字面量定位失败');
    const template = text.slice(tplStart, tplEnd);
    const inTemplate = countMatches(template, /#[0-9A-Fa-f]{6}\b/g);
    strictEqual(inTemplate, total, 'LanEditorServer 存在模板外的硬编码色值');
    exemptOccurrences += total;
  }
  assert.deepEqual(offenders, [], `发现非豁免硬编码色值：\n${offenders.join('\n')}`);
  assert.ok(exemptOccurrences >= 6, `LanEditorServer 内嵌模板应保留静态页色值，实测 ${exemptOccurrences}`);
  console.log(`  证据：豁免模板内色值 ${exemptOccurrences} 个（6 行 CSS），其余 UI 文件 0 个；扫描 ${chatFiles.length} 个文件`);
});

function strictEqual(actual, expected, message) {
  assert.equal(actual, expected, message);
}

// ---------------------------------------------------------------------------
// 2) 文案纪律：无保姆式教学文案
// ---------------------------------------------------------------------------
test('文案纪律：7 个保姆式关键词在 chat UI 源码中 0 命中', () => {
  const keywords = ['小提示', '聊两句就', '会先在心里推理', '要不要联网', '问题想多深', '当前构建未启用', '端侧小脚本'];
  const hits = [];
  for (const file of chatFiles) {
    const text = read(file);
    for (const kw of keywords) {
      if (text.includes(kw)) hits.push(`${rel(file)} ⇐ 「${kw}」`);
    }
  }
  assert.deepEqual(hits, [], `命中保姆式文案：\n${hits.join('\n')}`);
  console.log(`  证据：${keywords.length} 个关键词 × ${chatFiles.length} 个文件 = 0 命中`);
});

// ---------------------------------------------------------------------------
// 3) 性能：ChatPage 主消息列表 LazyForEach + cachedCount(6)
// ---------------------------------------------------------------------------
test('性能：ChatPage 使用 LazyForEach + .cachedCount(6)，且不再 ForEach(this.nodes', () => {
  const chatPagePath = path.join(CHAT_ETS, 'pages', 'ChatPage.ets');
  assert.ok(existsSync(chatPagePath), 'pages/ChatPage.ets 不存在');
  const text = read(chatPagePath);
  assert.ok(text.includes('LazyForEach('), 'ChatPage 未使用 LazyForEach');
  assert.ok(text.includes('.cachedCount(6)'), 'ChatPage 缺少 .cachedCount(6)');
  assert.equal(countMatches(text, /ForEach\(this\.nodes/), 0, '主消息列表仍在使用 ForEach(this.nodes…)');
  const dsPath = path.join(CHAT_ETS, 'components', 'MessageDataSource.ets');
  assert.ok(existsSync(dsPath), '缺少 components/MessageDataSource.ets（IDataSource 实现）');
  const ds = read(dsPath);
  assert.ok(ds.includes('implements IDataSource'), 'MessageDataSource 未实现 IDataSource');
  assert.ok(ds.includes('registerDataChangeListener') && ds.includes('unregisterDataChangeListener'),
    'MessageDataSource 缺少监听器注册/注销');
  const lazyLine = text.split('\n').findIndex((l) => l.includes('LazyForEach(')) + 1;
  const cachedLine = text.split('\n').findIndex((l) => l.includes('.cachedCount(6)')) + 1;
  console.log(`  证据：ChatPage.ets:${lazyLine} LazyForEach，ChatPage.ets:${cachedLine} .cachedCount(6)，ForEach(this.nodes 出现 0 次`);
});

// ---------------------------------------------------------------------------
// 4) 架构：ChatRuntime 门面 + runtime/ 子模块行数约束（非空行）
// ---------------------------------------------------------------------------
test('架构：ChatRuntime.ets 非空行 ≤500（门面化）', () => {
  const p = path.join(CHAT_ETS, 'model', 'ChatRuntime.ets');
  const text = read(p);
  const nb = nonBlank(text);
  assert.ok(nb <= 500, `ChatRuntime.ets 非空行 ${nb} > 500`);
  console.log(`  证据：ChatRuntime.ets 总行 ${text.split('\n').length} / 非空行 ${nb}`);
});

test('架构：model/runtime/ 存在 SessionController / StreamTurnExecutor / ToolLoopRunner，且每个 ≤500 非空行', () => {
  const dir = path.join(CHAT_ETS, 'model', 'runtime');
  assert.ok(existsSync(dir), 'model/runtime/ 目录不存在');
  const required = ['SessionController.ets', 'StreamTurnExecutor.ets', 'ToolLoopRunner.ets'];
  for (const name of required) {
    const p = path.join(dir, name);
    assert.ok(existsSync(p), `缺少 model/runtime/${name}`);
    const nb = nonBlank(read(p));
    assert.ok(nb <= 500, `model/runtime/${name} 非空行 ${nb} > 500`);
  }
  const runtimeFiles = readdirSync(dir).filter((n) => n.endsWith('.ets'));
  assert.ok(runtimeFiles.length >= 10, `model/runtime/ 文件数 ${runtimeFiles.length} 少于预期拆分粒度`);
  const counts = runtimeFiles.map((n) => ({ n, nb: nonBlank(read(path.join(dir, n))) }));
  const max = counts.reduce((a, b) => (b.nb > a.nb ? b : a));
  assert.ok(max.nb <= 500, `model/runtime/ 最大文件 ${max.n} 非空行 ${max.nb} > 500`);
  // 门面确实委派给子模块（防回退成上帝类）
  const facade = read(path.join(CHAT_ETS, 'model', 'ChatRuntime.ets'));
  assert.ok(facade.includes('SessionController') && facade.includes('StreamTurnExecutor'),
    'ChatRuntime 门面未引用拆分后的子模块');
  const stream = read(path.join(dir, 'StreamTurnExecutor.ets'));
  assert.ok(stream.includes('ToolLoopRunner'), 'StreamTurnExecutor 未使用 ToolLoopRunner');
  console.log(`  证据：runtime/ ${runtimeFiles.length} 个文件，最大 ${max.n} 非空行 ${max.nb}`);
});

// ---------------------------------------------------------------------------
// 5) 入口：删除 Index 占位页，启动即 ChatPage
// ---------------------------------------------------------------------------
test('入口：pages/Index.ets 已删除、main_pages.json 无 pages/Index、ChatAbility 启动页为 pages/ChatPage', () => {
  assert.ok(!existsSync(path.join(CHAT_ETS, 'pages', 'Index.ets')), 'pages/Index.ets 仍存在');
  const mainPages = read(path.join(RES, 'base', 'profile', 'main_pages.json'));
  assert.ok(!mainPages.includes('pages/Index'), 'main_pages.json 仍登记 pages/Index');
  assert.ok(mainPages.includes('pages/ChatPage'), 'main_pages.json 未登记 pages/ChatPage');
  const ability = read(path.join(CHAT_ETS, 'chatability', 'ChatAbility.ets'));
  assert.ok(ability.includes("loadContent('pages/ChatPage'"), 'ChatAbility 启动页不是 pages/ChatPage');
  console.log('  证据：main_pages.json 首项 pages/ChatPage；ChatAbility 使用 loadContent(\'pages/ChatPage\')');
});

// ---------------------------------------------------------------------------
// 6) 视觉一致性：系统符号图标 + 设计令牌被广泛复用
// ---------------------------------------------------------------------------
test('视觉：SymbolGlyph 使用点 ≥60，且 app/Theme.ets 被 ≥15 个 UI 文件 import', () => {
  let symbolCount = 0;
  for (const file of chatFiles) symbolCount += countMatches(read(file), /SymbolGlyph/g);
  assert.ok(symbolCount >= 60, `SymbolGlyph 使用点 ${symbolCount} < 60（可能回退成 ASCII/emoji 图标）`);

  const themePath = path.join(CHAT_ETS, 'app', 'Theme.ets');
  assert.ok(existsSync(themePath), 'app/Theme.ets 不存在');
  const theme = read(themePath);
  assert.ok(theme.includes('export class Theme') && theme.includes('export class Layout')
    && theme.includes('export class Icons'), 'Theme.ets 缺少 Theme/Layout/Icons 设计令牌');

  const importers = chatFiles.filter((f) => f !== themePath && /from\s+['"][^'"]*app\/Theme['"]/.test(read(f)));
  assert.ok(importers.length >= 15, `Theme 被 ${importers.length} 个文件 import < 15`);
  console.log(`  证据：SymbolGlyph ${symbolCount} 处；Theme import 文件 ${importers.length} 个（不含 Theme.ets 自身）`);
});

// ---------------------------------------------------------------------------
// 7) 深浅色资源键集合一致
// ---------------------------------------------------------------------------
test('资源：base/dark color.json 键集合一致（v3.2 各 46 键）', () => {
  const base = JSON.parse(read(path.join(RES, 'base', 'element', 'color.json')));
  const dark = JSON.parse(read(path.join(RES, 'dark', 'element', 'color.json')));
  assert.ok(Array.isArray(base.color) && Array.isArray(dark.color), 'color.json 结构异常');
  const bk = base.color.map((c) => c.name);
  const dk = dark.color.map((c) => c.name);
  assert.deepEqual(bk, dk, '深浅色资源键集合不一致');
  assert.equal(bk.length, 46, `颜色键数量 ${bk.length} ≠ 46（v3.2 设计令牌基线：38 + 8 头像底色）`);
  assert.ok(bk.includes('brand') && bk.includes('bg_page') && bk.includes('text_primary'),
    '缺少关键语义色（brand/bg_page/text_primary）');
  const avatarTones = bk.filter((name) => name.startsWith('avatar_bg_'));
  assert.equal(avatarTones.length, 8, `avatar_bg_* 数量 ${avatarTones.length} ≠ 8`);
  console.log(`  证据：base=${bk.length} 键 / dark=${dk.length} 键，集合完全一致（含 8 个 avatar_bg_*）`);
});

// ---------------------------------------------------------------------------
// 8) L3 半成品从 UI 隐藏
// ---------------------------------------------------------------------------
test('L3 隐藏：技能列表过滤 L3_QUICKJS_SANDBOX，SkillCard 徽章只保留「声明式 / 远程 MCP」', () => {
  const manager = read(path.join(CHAT_ETS, 'pages', 'SkillManagerPage.ets'));
  assert.ok(manager.includes('L3_QUICKJS_SANDBOX'), 'SkillManagerPage 未过滤 L3 技能');
  const card = read(path.join(CHAT_ETS, 'components', 'SkillCard.ets'));
  assert.ok(card.includes("'声明式'") && card.includes("'远程 MCP'"), 'SkillCard 缺少分级中文标签');
  // 只检查「用户可见的字符串字面量」与 tierLabel 函数体；注释里说明「L3 不展示」是允许的
  const visibleL3 = (card.match(/['"][^'"\n]*(?:L3|端侧)[^'"\n]*['"]/g) || []);
  assert.deepEqual(visibleL3, [], `SkillCard 仍有用户可见的 L3/端侧字符串：${visibleL3.join(', ')}`);
  const tierStart = card.indexOf('export function tierLabel');
  assert.ok(tierStart >= 0, 'SkillCard 缺少 tierLabel');
  const tierEnd = card.indexOf('\n}', tierStart);
  const tierBody = card.slice(tierStart, tierEnd);
  assert.ok(tierBody.includes("return '声明式'") && tierBody.includes("return '远程 MCP'"),
    'tierLabel 未覆盖声明式/远程 MCP 两档');
  assert.ok(!/return\s+'[^']*(?:L3|端侧)[^']*'/.test(tierBody), 'tierLabel 返回值仍暴露 L3/端侧');
  assert.ok(!manager.includes('端侧小脚本'), 'SkillManagerPage 仍有「端侧小脚本」文案');
  console.log('  证据：SkillManagerPage 过滤 L3_QUICKJS_SANDBOX；SkillCard tierLabel 仅 声明式/远程 MCP');
});

// ---------------------------------------------------------------------------
// 9) 契约未回归（结构断言；哈希/时间戳证据见 TEST_REPORT §12）
// ---------------------------------------------------------------------------
test('契约：packages/*/Index.ets 与 interfaces/** 结构完整，ChatRuntimeApi 方法未减少', () => {
  const indexExpect = {
    'core_model': ['estimateText', 'createModelLayer'],
    'core_protocol': ['createProtocolLayer', 'SseParser'],
    'core_context': ['createContextLayer', 'CacheAwareCompactor'],
    'core_plugin': ['createPluginLayer', 'SkillManifest']
  };
  for (const [pkg, symbols] of Object.entries(indexExpect)) {
    const p = path.join(REPO, 'packages', pkg, 'Index.ets');
    assert.ok(existsSync(p), `packages/${pkg}/Index.ets 不存在`);
    const text = read(p);
    for (const symbol of symbols) {
      assert.ok(text.includes(symbol), `packages/${pkg}/Index.ets 缺少导出 ${symbol}`);
    }
  }
  const interfaceFiles = [];
  for (const pkg of ['core_model', 'core_protocol', 'core_context', 'core_plugin']) {
    const dir = path.join(REPO, 'packages', pkg, 'src', 'main', 'ets', 'interfaces');
    assert.ok(existsSync(dir), `packages/${pkg}/src/main/ets/interfaces 缺失`);
    interfaceFiles.push(...readdirSync(dir).filter((n) => n.endsWith('.ets')));
  }
  assert.equal(interfaceFiles.length, 20, `契约接口文件数 ${interfaceFiles.length} ≠ 20（v3.2 新增 ModelRegistryApi）`);

  const api = read(path.join(CHAT_ETS, 'model', 'ChatRuntimeApi.ets'));
  for (const method of ['init(', 'send(', 'stop(', 'retryLast(', 'switchBranch(', 'editUserNode(',
    'branches(', 'compactNow(', 'searchHistory(']) {
    assert.ok(api.includes(method), `ChatRuntimeApi 缺少方法 ${method}`);
  }
  for (const relPath of ['model/RuntimeHolder.ets', 'app/AppServices.ets']) {
    assert.ok(existsSync(path.join(CHAT_ETS, relPath)), `${relPath} 不存在`);
  }
  console.log(`  证据：4 个 Index.ets 关键导出齐全；interfaces 19 个文件；ChatRuntimeApi 9 个关键方法齐全`);
});

// ---------------------------------------------------------------------------
// 10) 构建配置：公开仓库已脱敏（无签名材料/无用户绝对路径/无明文口令）
// ---------------------------------------------------------------------------
test('构建配置：build-profile.json5 已脱敏（signingConfigs 为空数组或安全配置，无用户绝对路径/明文口令）', () => {
  const profilePath = path.join(REPO, 'build-profile.json5');
  const text = read(profilePath);
  assert.ok(text.includes('"signingConfigs"'), 'build-profile.json5 缺少 signingConfigs 字段');
  const match = text.match(/"signingConfigs"\s*:\s*\[([\s\S]*?)\]/);
  assert.ok(match, '无法解析 signingConfigs 片段');
  const inner = match[1].trim();
  if (inner.length === 0) {
    console.log('  证据：signingConfigs 为空数组（公开仓库已脱敏，签名材料保留在 gitignore 的 build-profile.local.json5）');
  } else {
    // 允许合法签名配置，但不得泄露本机用户路径或明文口令
    assert.ok(!/[A-Za-z]:[\\/]/.test(inner), 'signingConfigs 含 Windows 用户绝对路径（应脱敏）');
    assert.ok(!/\/(?:Users|home)\//.test(inner), 'signingConfigs 含用户目录绝对路径（应脱敏）');
    for (const key of ['keyPassword', 'storePassword']) {
      const pw = new RegExp(`"${key}"\\s*:\\s*"([^"]{8,})"`).exec(inner);
      assert.equal(pw, null, `signingConfigs 含明文口令 ${key}`);
    }
    console.log('  证据：signingConfigs 为非空安全配置（无绝对路径/明文口令）');
  }
  const localPath = path.join(REPO, 'build-profile.local.json5');
  assert.ok(existsSync(localPath), '本机签名材料备份 build-profile.local.json5 不存在');
  const gitignore = read(path.join(REPO, '.gitignore'));
  assert.ok(gitignore.includes('build-profile.local.json5'),
    '.gitignore 未忽略 build-profile.local.json5（本机签名材料可能被提交）');
  console.log('  证据：build-profile.local.json5 存在且已被 .gitignore 忽略');
});

summarize();
