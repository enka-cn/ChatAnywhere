/**
 * v3 设计落地静态断言（Pura X Max 双栏/折叠、6 档思考、角色、SKILL.md 编辑器、附件、信源栏、记忆条隐藏）
 *
 * 只读扫描源码，不依赖 prepare 产物。与 `90-refactor-static.test.mjs` 互补：
 * - 90 守住 R2 重构基线（虚列表/上帝类拆分/入口/色值禁令/L3 隐藏）；
 * - 91 守住 v3 设计基线（38 色令牌精确值、Breakpoint 双栏、6 档映射、角色/附件/SKILL.md 接线）。
 *
 * 判定口径：「行数」= 非空行（与 Lead 基线一致）。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { verifyCodeMathColors } from './_theme.mjs';
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
const count = (text, re) => (text.match(re) || []).length;
const chatFiles = walk(CHAT_ETS, /\.(ets|ts)$/);

// ---------------------------------------------------------------------------
// 1) v3/v3.5 色板：64 键 + 设计稿精确色值
// ---------------------------------------------------------------------------
test('v3.7 色板：base/dark 各 64 键（含 12 code/math）且键集合一致，品牌/气泡/页面底色精确匹配设计稿', () => {
  const base = JSON.parse(read(path.join(RES, 'base', 'element', 'color.json')));
  const dark = JSON.parse(read(path.join(RES, 'dark', 'element', 'color.json')));
  const map = (json) => {
    const out = {};
    for (const item of json.color) out[item.name] = String(item.value).toUpperCase();
    return out;
  };
  const b = map(base);
  const d = map(dark);
  verifyCodeMathColors(assert, base, dark);
  assert.equal(Object.keys(b).length, 64, `base 颜色键 ${Object.keys(b).length} ≠ 64（v3.5：48 + 6 暗舱 effort_*）`);
  assert.deepEqual(Object.keys(b).sort(), Object.keys(d).sort(), '深浅色键集合不一致');
  assert.equal(Object.keys(b).filter((n) => n.startsWith('avatar_bg_')).length, 8, 'avatar_bg_* 不是 8 个');
  for (const key of ['effort_deck_top', 'effort_deck_bottom', 'effort_track', 'effort_bar_off',
    'effort_text_dim', 'effort_text_bright']) {
    assert.ok(Object.keys(b).includes(key), `base 缺少 v3.6 暗舱色键 ${key}`);
    assert.ok(Object.keys(d).includes(key), `dark 缺少 v3.6 暗舱色键 ${key}`);
  }
  const baseEffort = {
    effort_deck_top: '#F6F7FB', effort_deck_bottom: '#FFFFFF', effort_track: '#E6E9F2',
    effort_bar_off: '#DFE3EC', effort_text_dim: '#6B7280', effort_text_bright: '#111827'
  };
  const darkEffort = {
    effort_deck_top: '#11131B', effort_deck_bottom: '#181C28', effort_track: '#232836',
    effort_bar_off: '#2A2F3D', effort_text_dim: '#9CA3AF', effort_text_bright: '#FFFFFF'
  };
  const expect = (name, baseValue, darkValue) => {
    assert.equal(b[name], baseValue.toUpperCase(), `base ${name}`);
    assert.equal(d[name], darkValue.toUpperCase(), `dark ${name}`);
  };
  expect('brand', '#2563EB', '#4F83FF');
  expect('bubble_user', '#111827', '#2563EB');
  expect('bg_page', '#FFFFFF', '#0E1014');
  expect('violet', '#7C3AED', '#8B5CF6');
  expect('pink', '#EC4899', '#F472B6');
  for (const key of Object.keys(baseEffort)) {
    expect(key, baseEffort[key], darkEffort[key]);
  }
  console.log('  证据：64 键一致（violet/pink + 8 avatar_bg_* + 6 effort_* 日夜两套精确值）；brand #2563EB/#4F83FF，bubble_user #111827/#2563EB，bg_page #FFFFFF/#0E1014');
});

// ---------------------------------------------------------------------------
// 2) 颜色纪律：仅 LanEditorServer 内嵌 HTML 模板允许静态页色值
// ---------------------------------------------------------------------------
test('颜色纪律：除 LanEditorServer 内嵌 HTML 模板外，chat UI 源码 0 个硬编码 #RRGGBB', () => {
  const offenders = [];
  let exempt = 0;
  for (const file of chatFiles) {
    const text = read(file);
    const total = count(text, /#[0-9A-Fa-f]{6}\b/g);
    if (total === 0) continue;
    if (!/bridge[/\\]LanEditorServer\.ets$/.test(file)) {
      offenders.push(`${rel(file)}: ${total}`);
      continue;
    }
    const start = text.indexOf('renderEditPage(): string {');
    const tplStart = text.indexOf('return `', start);
    const tplEnd = text.indexOf('`;', tplStart);
    assert.ok(start >= 0 && tplStart > 0 && tplEnd > tplStart, 'LanEditorServer 模板定位失败');
    const inTemplate = count(text.slice(tplStart, tplEnd), /#[0-9A-Fa-f]{6}\b/g);
    assert.equal(inTemplate, total, 'LanEditorServer 存在模板外硬编码色值');
    exempt += total;
  }
  assert.deepEqual(offenders, [], `非豁免硬编码色值：\n${offenders.join('\n')}`);
  console.log(`  证据：扫描 ${chatFiles.length} 文件；仅内嵌 HTML 模板 ${exempt} 个色值，其余 0`);
});

// ---------------------------------------------------------------------------
// 3) 文案纪律
// ---------------------------------------------------------------------------
test('文案纪律：7 个教学/保姆关键词在 v3 UI 源码中 0 命中', () => {
  const keywords = ['小提示', '聊两句就', '会先在心里推理', '要不要联网', '问题想多深', '当前构建未启用', '端侧小脚本'];
  const hits = [];
  for (const file of chatFiles) {
    const text = read(file);
    for (const kw of keywords) if (text.includes(kw)) hits.push(`${rel(file)} ⇐ 「${kw}」`);
  }
  assert.deepEqual(hits, [], hits.join('\n'));
  console.log(`  证据：${keywords.length} 个关键词 × ${chatFiles.length} 个文件 = 0 命中`);
});

// ---------------------------------------------------------------------------
// 4) 响应式双栏：Breakpoint 基建 + 四个 Master-Detail 页面接入
// ---------------------------------------------------------------------------
test('双栏/折叠：Breakpoint.ets 存在、阈值 600vp、被 ≥3 个页面 import 且 Breakpoint.watch 出现 ≥3 次', () => {
  const bpPath = path.join(CHAT_ETS, 'app', 'Breakpoint.ets');
  assert.ok(existsSync(bpPath), 'app/Breakpoint.ets 不存在');
  const bp = read(bpPath);
  assert.ok(bp.includes('UNFOLDED_MIN_VP'), 'Breakpoint 缺少展开阈值常量');
  assert.ok(/UNFOLDED_MIN_VP[^=]*=\s*600/.test(bp), 'Breakpoint 展开阈值不是 600vp');

  const importers = chatFiles.filter((f) => /from\s+['"][^'"]*app\/Breakpoint['"]/.test(read(f)));
  assert.ok(importers.length >= 3, `Breakpoint 仅被 ${importers.length} 个文件 import（<3）`);
  let watchCalls = 0;
  for (const f of chatFiles) watchCalls += count(read(f), /Breakpoint\.watch\(/g);
  assert.ok(watchCalls >= 3, `Breakpoint.watch( 仅 ${watchCalls} 处（<3）`);
  for (const page of ['pages/ChatPage.ets', 'pages/SettingsPage.ets', 'pages/SkillManagerPage.ets', 'pages/SkillCreatorPage.ets']) {
    assert.ok(importers.some((f) => f.endsWith(page.replace(/\//g, path.sep))), `${page} 未接入 Breakpoint`);
  }
  console.log(`  证据：Breakpoint 被 ${importers.length} 个文件 import，Breakpoint.watch( ${watchCalls} 处，阈值 600vp`);
});

test('Master-Detail 侧栏宽度（v3.1 打磨）：Chat 232 / Skills 236 / Settings 220（Layout 令牌 + 页面引用）', () => {
  const theme = read(path.join(CHAT_ETS, 'app', 'Theme.ets'));
  assert.ok(/sidebarChat:\s*number\s*=\s*232/.test(theme), 'Layout.sidebarChat 不是 232');
  assert.ok(/sidebarSkills:\s*number\s*=\s*236/.test(theme), 'Layout.sidebarSkills 不是 236');
  assert.ok(/sidebarSettings:\s*number\s*=\s*220/.test(theme), 'Layout.sidebarSettings 不是 220');
  const expects = [
    ['pages/ChatPage.ets', /sidebarChat|232/],
    ['pages/SkillManagerPage.ets', /sidebarSkills|236/],
    ['pages/SettingsPage.ets', /sidebarSettings|220/]
  ];
  for (const [page, re] of expects) {
    assert.ok(re.test(read(path.join(CHAT_ETS, page))), `${page} 未使用对应侧栏宽度令牌`);
  }
  console.log('  证据：Layout.sidebarChat=232 / sidebarSkills=236 / sidebarSettings=220，三页均已引用');
});

// ---------------------------------------------------------------------------
// 5) 6 档思考：标签 / 类型联合 / 旧值仅保留在迁移分支
// ---------------------------------------------------------------------------
test('6 档思考：EffortLevels 含 关闭/Min/Low/Med/High/xHigh，ThinkingLevel 为 6 值联合', () => {
  const effort = read(path.join(CHAT_ETS, 'app', 'EffortLevels.ets'));
  for (const label of ['关闭', 'Min', 'Low', 'Med', 'High', 'xHigh']) {
    assert.ok(effort.includes(`'${label}'`), `EffortLevels 缺少短标签「${label}」`);
  }
  const types = read(path.join(REPO, 'packages', 'core_protocol', 'src', 'main', 'ets', 'interfaces', 'ProtocolTypes.ets'));
  const match = types.match(/export type ThinkingLevel\s*=\s*([^;]+);/);
  assert.ok(match, '未找到 ThinkingLevel 联合类型');
  const values = match[1].split('|').map((s) => s.trim().replace(/['"]/g, '')).filter(Boolean);
  assert.deepEqual(values, ['off', 'min', 'low', 'med', 'high', 'xhigh'], `ThinkingLevel=${values.join(',')}`);
  console.log('  证据：EffortLevels 6 档短标签齐全；ThinkingLevel = off|min|low|med|high|xhigh');
});

test('旧值迁移：带引号的 quick/deep 只允许出现在 EffortLevels.normalize 迁移分支', () => {
  const offenders = [];
  for (const file of chatFiles) {
    if (file.endsWith('EffortLevels.ets')) continue;
    const text = read(file);
    for (const legacy of ["'quick'", "'deep'", '"quick"', '"deep"']) {
      if (text.includes(legacy)) offenders.push(`${rel(file)} ⇐ ${legacy}`);
    }
  }
  assert.deepEqual(offenders, [], offenders.join('\n'));
  const effort = read(path.join(CHAT_ETS, 'app', 'EffortLevels.ets'));
  assert.ok(effort.includes("raw === 'quick'") && effort.includes("raw === 'deep'"), 'EffortLevels 缺少旧值迁移分支');
  console.log('  证据：旧 quick/deep 仅出现在 EffortLevels.normalize 迁移分支');
});

// ---------------------------------------------------------------------------
// 6) 页面接线：虚列表 / SKILL.md 编辑器 / 角色与提示词
// ---------------------------------------------------------------------------
test('ChatPage：LazyForEach + .cachedCount(6)，不再 ForEach(this.nodes', () => {
  const text = read(path.join(CHAT_ETS, 'pages', 'ChatPage.ets'));
  assert.ok(text.includes('LazyForEach('), 'ChatPage 未使用 LazyForEach');
  assert.ok(text.includes('.cachedCount(6)'), 'ChatPage 缺少 .cachedCount(6)');
  assert.equal(count(text, /ForEach\(this\.nodes/), 0, '主消息列表仍用 ForEach(this.nodes…)');
  console.log('  证据：ChatPage 使用 LazyForEach + cachedCount(6)，ForEach(this.nodes 0 次');
});

test('SkillCreatorPage：SKILL.md 编辑器接入 SkillMarkdownCodec（toMarkdown/toManifestJson/newTemplate）', () => {
  const text = read(path.join(CHAT_ETS, 'pages', 'SkillCreatorPage.ets'));
  assert.ok(text.includes('SkillMarkdownCodec'), 'SkillCreatorPage 未引用 SkillMarkdownCodec');
  assert.ok(text.includes('SkillMarkdownCodec.toMarkdown'), '未调用 toMarkdown');
  assert.ok(text.includes('SkillMarkdownCodec.toManifestJson'), '未调用 toManifestJson');
  assert.ok(text.includes('SkillMarkdownCodec.newTemplate'), '未使用 newTemplate');
  console.log('  证据：SkillCreatorPage 引用 SkillMarkdownCodec 的 toMarkdown/toManifestJson/newTemplate');
});

test('角色与提示词：设置中心接入 PersonaStore/requirePersonas（可经 SettingsPersonaView 委派）', () => {
  const settings = read(path.join(CHAT_ETS, 'pages', 'SettingsPage.ets'));
  const personaViewPath = path.join(CHAT_ETS, 'components', 'SettingsPersonaView.ets');
  const personaView = existsSync(personaViewPath) ? read(personaViewPath) : '';
  const direct = settings.includes('PersonaStore') || settings.includes('requirePersonas');
  const delegated = settings.includes('SettingsPersonaView') && (personaView.includes('PersonaStore') || personaView.includes('requirePersonas'));
  assert.ok(direct || delegated, '设置中心未接入角色/提示词（PersonaStore）');
  assert.ok(personaView.length > 0, '缺少 components/SettingsPersonaView.ets');
  console.log(`  证据：${direct ? 'SettingsPage 直接引用' : 'SettingsPage → SettingsPersonaView 委派'} PersonaStore/requirePersonas`);
});

// ---------------------------------------------------------------------------
// 7) 附件与运行时契约
// ---------------------------------------------------------------------------
test('ChatRuntimeApi：AttachmentRef / send(text, attachments?) / toggleSessionSkill / skillChips / personaName', () => {
  const api = read(path.join(CHAT_ETS, 'model', 'ChatRuntimeApi.ets'));
  assert.ok(api.includes('AttachmentRef'), '缺少 AttachmentRef');
  assert.ok(/send\(text:\s*string,\s*attachments\?/.test(api), 'send 未扩展 attachments 参数');
  assert.ok(api.includes('toggleSessionSkill'), '缺少 toggleSessionSkill');
  assert.ok(api.includes('skillChips'), 'snapshot 缺少 skillChips');
  assert.ok(api.includes('personaName'), 'snapshot 缺少 personaName');
  const chatPage = read(path.join(CHAT_ETS, 'pages', 'ChatPage.ets'));
  assert.ok(chatPage.includes('AttachmentRef') && chatPage.includes('pendingAttachments'), 'ChatPage 未接入附件');
  console.log('  证据：AttachmentRef/send(attachments)/toggleSessionSkill/skillChips/personaName 齐全，ChatPage 已接附件');
});

test('SkillMarkdownCodec：Index.ets 导出 + 三个静态方法齐全', () => {
  const index = read(path.join(REPO, 'packages', 'core_plugin', 'Index.ets'));
  assert.ok(index.includes('SkillMarkdownCodec'), 'core_plugin Index.ets 未导出 SkillMarkdownCodec');
  assert.ok(index.includes('SkillMarkdownResult'), 'core_plugin Index.ets 未导出 SkillMarkdownResult');
  const codec = read(path.join(REPO, 'packages', 'core_plugin', 'src', 'main', 'ets', 'SkillMarkdown.ets'));
  for (const method of ['static toMarkdown(', 'static toManifestJson(', 'static newTemplate(']) {
    assert.ok(codec.includes(method), `SkillMarkdownCodec 缺少 ${method}`);
  }
  console.log('  证据：Index.ets 导出 SkillMarkdownCodec/SkillMarkdownResult；三方法齐全');
});

// ---------------------------------------------------------------------------
// 8) 视觉一致性 + 行数约束
// ---------------------------------------------------------------------------
test('视觉：SymbolGlyph ≥60 处，app/Theme.ets 被 ≥15 个 UI 文件 import', () => {
  let symbolCount = 0;
  for (const file of chatFiles) symbolCount += count(read(file), /SymbolGlyph/g);
  assert.ok(symbolCount >= 60, `SymbolGlyph ${symbolCount} < 60`);
  const themePath = path.join(CHAT_ETS, 'app', 'Theme.ets');
  const importers = chatFiles.filter((f) => f !== themePath && /from\s+['"][^'"]*app\/Theme['"]/.test(read(f)));
  assert.ok(importers.length >= 15, `Theme 仅被 ${importers.length} 个文件 import（<15）`);
  console.log(`  证据：SymbolGlyph ${symbolCount} 处；Theme import ${importers.length} 个文件`);
});

test('架构约束：ChatRuntime 与 model/runtime/* 每个文件非空行 ≤500', () => {
  const facade = read(path.join(CHAT_ETS, 'model', 'ChatRuntime.ets'));
  assert.ok(nonBlank(facade) <= 500, `ChatRuntime 非空行 ${nonBlank(facade)} > 500`);
  const runtimeDir = path.join(CHAT_ETS, 'model', 'runtime');
  const runtimeFiles = readdirSync(runtimeDir).filter((n) => n.endsWith('.ets'));
  for (const n of runtimeFiles) {
    const nb = nonBlank(read(path.join(runtimeDir, n)));
    assert.ok(nb <= 500, `model/runtime/${n} 非空行 ${nb} > 500`);
  }
  console.log(`  证据：ChatRuntime 非空 ${nonBlank(facade)} 行；runtime/ ${runtimeFiles.length} 文件均 ≤500 行`);
});

// ---------------------------------------------------------------------------
// 9) v3.1 旗舰打磨（Gemini UI polish）：原生字号阶梯 + IconBtn 居中图标容器
// ---------------------------------------------------------------------------
test('v3.1 打磨：IconBtn 存在且被 5 个文件复用，完整字号/尺寸令牌为原生舒适阶梯', () => {
  const iconBtnPath = path.join(CHAT_ETS, 'components', 'IconBtn.ets');
  assert.ok(existsSync(iconBtnPath), '缺少 components/IconBtn.ets（居中图标按钮）');
  const iconBtn = read(iconBtnPath);
  assert.ok(iconBtn.includes('export struct IconBtn'), 'IconBtn 未导出 struct');
  assert.ok(iconBtn.includes('Stack({ alignContent: Alignment.Center })'), 'IconBtn 未使用 Stack 居中');
  assert.ok(iconBtn.includes('SymbolGlyph'), 'IconBtn 未使用 SymbolGlyph');
  assert.ok(iconBtn.includes('stateStyles'), 'IconBtn 缺少按压反馈 stateStyles');

  // 同目录组件用 './IconBtn'，页面用 '../components/IconBtn'：两者都要计入
  const importers = chatFiles.filter((f) => /from\s+['"][^'"]*IconBtn['"]/.test(read(f)));
  assert.ok(importers.length >= 5, `IconBtn 仅被 ${importers.length} 个文件 import（<5）`);
  for (const expected of [
    'pages/ChatPage.ets', 'pages/SettingsPage.ets', 'components/SessionDrawer.ets',
    'components/SourcePane.ets', 'components/StreamingMessage.ets'
  ]) {
    assert.ok(importers.some((f) => f.split(path.sep).join('/').endsWith(expected)),
      `${expected} 未复用 IconBtn`);
  }

  const theme = read(path.join(CHAT_ETS, 'app', 'Theme.ets'));
  const tokens = [
    // v3.1 尺寸/圆角
    ['topBarHeight', 48], ['topBarFoldedHeight', 44], ['chatMaxWidth', 680], ['sourcePaneWidth', 288],
    ['inputRadius', 24], ['radiusPill', 999],
    // v3.1 原生舒适字号阶梯（7 档）
    ['fontCaption', 11.5], ['fontSmall', 12.5], ['fontUi', 13.5], ['fontBody', 15],
    ['fontChat', 15.5], ['fontTitle', 16], ['fontHeadline', 17],
    // 行高
    ['lineChat', 26], ['lineBody', 23], ['lineTight', 20]
  ];
  for (const [name, value] of tokens) {
    const re = new RegExp(`${name}:\\s*number\\s*=\\s*${String(value).replace('.', '\\.')}`);
    assert.ok(re.test(theme), `Layout.${name} 不是 v3.1 期望值 ${value}`);
  }
  // 按压反馈令牌（IconBtn 的 stateStyles 依赖它，避免打磨回退成生硬按钮）
  assert.ok(/pressOpacity\s*:\s*number\s*=/.test(theme), '缺少 Layout.pressOpacity 按压反馈令牌');
  console.log(`  证据：IconBtn 被 ${importers.length} 个文件复用（5 个目标文件全覆盖）；字号 7 档 + 行高 3 档 + 尺寸/圆角令牌为 v3.1 原生阶梯`);
});

summarize();
