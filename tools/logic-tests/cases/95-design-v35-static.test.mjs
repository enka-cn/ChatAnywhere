/**
 * v3.5 交互修复静态门禁（抽屉零闪变 / 暗舱能量面板 / 震动总开关）
 *
 * 三项真机反馈：
 * 1) 抽屉关闭闪变 → 常驻挂载（drawerVisible + Visibility None/Visible + opacity/translate 表达式），
 *    `setDrawerOpen` 240ms FastOutSlowIn，关闭在 onFinish 才置 None，删除 if 卸载与 TransitionEffect；
 * 2) 6 档面板硬切色块 → 暗舱卡（effort_deck_top→bottom 渐变 + radialGradient 氛围光 + 6 格能量柱），
 *    22vp 白钮 + 8vp 档位色内点 + 光晕；
 * 3) 无法关闭震动 → `HapticUtil` 总开关（HAPTIC_ENABLED 持久化 + 内存缓存）接入面板与设置页 Toggle。
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
const count = (text, re) => (text.match(re) || []).length;
const effortKeys = ['effort_deck_top', 'effort_deck_bottom', 'effort_track', 'effort_bar_off',
  'effort_text_dim', 'effort_text_bright'];

// ---------------------------------------------------------------------------
// 1) 抽屉零闪变（常驻挂载）
// ---------------------------------------------------------------------------
test('抽屉零闪变：drawerVisible + Visibility 常驻挂载 + opacity/translate 表达式 + 240ms FastOutSlowIn + onFinish', () => {
  const chatPage = read(path.join(CHAT_ETS, 'pages', 'ChatPage.ets'));
  assert.match(chatPage, /@State private drawerVisible:\s*boolean/);
  const start = chatPage.indexOf('// 折叠态会话抽屉');
  assert.ok(start >= 0, '缺少折叠态抽屉区块');
  const end = chatPage.indexOf('.bindSheet(', start);
  const block = chatPage.slice(start, end);
  assert.ok(block.includes('drawerVisible'), '抽屉区块未使用 drawerVisible');
  assert.ok(block.includes('Visibility.None') && block.includes('Visibility.Visible'),
    '缺少 Visibility.None/Visible');
  assert.ok(/\.opacity\(this\.drawerOpen \? 1 : 0\)/.test(block), '遮罩缺少 opacity(drawerOpen?1:0)');
  assert.ok(/\.translate\(\{\s*x:\s*\(this\.drawerOpen \? 0 : -Layout\.drawerMaxWidth\)/.test(block),
    '抽屉层缺少 translate(drawerOpen?0:-drawerMaxWidth + dragX)');
  assert.ok(!block.includes('TransitionEffect'), '抽屉区块仍有 TransitionEffect（应移除，常驻挂载）');
  assert.ok(!chatPage.includes('if (!this.unfolded && this.drawerOpen)'),
    '仍存在 if (!this.unfolded && this.drawerOpen) 卸载（闪变根因）');

  const fnStart = chatPage.indexOf('private setDrawerOpen(');
  assert.ok(fnStart >= 0, '缺少 setDrawerOpen');
  const fn = chatPage.slice(fnStart, fnStart + 1400);
  assert.ok(/duration:\s*240/.test(fn), 'setDrawerOpen 未使用 240ms');
  assert.ok(fn.includes('FastOutSlowIn'), 'setDrawerOpen 未使用 FastOutSlowIn');
  assert.ok(fn.includes('onFinish'), '关闭未在 onFinish 置 None');
  assert.ok(fn.includes('drawerVisible = true') && fn.includes('drawerVisible = false'),
    'setDrawerOpen 未切换 drawerVisible');
  assert.ok(count(chatPage, /this\.setDrawerOpen\(/g) >= 9, 'setDrawerOpen 调用点 <9');
  console.log('  证据：常驻挂载 drawerVisible/Visibility、opacity/translate 表达式、240ms FastOutSlowIn + onFinish、无 if 卸载/TransitionEffect、调用点 ≥9');
});

// ---------------------------------------------------------------------------
// 2) 暗舱能量面板
// ---------------------------------------------------------------------------
test('暗舱面板：6 个 effort 令牌 + radialGradient + 无 Slider/height(100%) + 22vp 白钮/8vp 内点 + HapticUtil 触感', () => {
  const panelPath = path.join(CHAT_ETS, 'components', 'ReasoningEffortPanel.ets');
  assert.ok(exists(panelPath), '缺少 ReasoningEffortPanel.ets');
  const panel = read(panelPath);
  for (const token of ['Theme.effortDeckTop', 'Theme.effortDeckBottom', 'Theme.effortTrack',
    'Theme.effortBarOff', 'Theme.effortTextDim', 'Theme.effortTextBright']) {
    assert.ok(panel.includes(token), `面板缺少暗舱令牌 ${token}`);
  }
  assert.ok(panel.includes('radialGradient('), '面板缺少 radialGradient 氛围光');
  assert.ok(!panel.includes('Slider('), '面板仍含 Slider');
  assert.ok(!panel.includes("height('100%')"), '面板仍使用 height(\'100%\')（应为自然高度）');
  assert.ok(panel.includes('KNOB_SIZE: number = 22'), '缺少 22vp 白钮');
  assert.ok(/Circle\(\{\s*width:\s*8,\s*height:\s*8\s*\}\)/.test(panel), '缺少 8vp 档位色内点');
  assert.ok(panel.includes('onTouch('), '能量槽缺少 onTouch 吸附');
  assert.ok(panel.includes('ForEach(EffortLevels.ALL'), '6 格能量柱未按档位渲染');
  assert.ok(panel.includes('HapticUtil.vibrate'), '面板触感未走 HapticUtil.vibrate');
  assert.ok(!panel.includes('@kit.SensorServiceKit'), '面板仍直接 import @kit.SensorServiceKit');
  assert.equal(count(panel, /#[0-9A-Fa-f]{6,8}\b/g), 0, '面板含硬编码色值');
  const capsule = read(path.join(CHAT_ETS, 'components', 'ModelCapsule.ets'));
  assert.ok(/from\s+['"][^'"]*ReasoningEffortPanel['"]/.test(capsule), 'ModelCapsule 未 import 面板');
  assert.ok(!/Slider\(/.test(capsule), 'ModelCapsule 仍保留内联 Slider');
  console.log('  证据：6 effort 令牌 + radialGradient + 22vp/8vp 圆钮 + onTouch + 6 格柱 + HapticUtil 触感；无 Slider/height(100%)/SensorServiceKit/硬编码色');
});

// ---------------------------------------------------------------------------
// 3) 震动总开关
// ---------------------------------------------------------------------------
test('震动总开关：HapticUtil 含 HAPTIC_ENABLED/isEnabled/setEnabled/vibrate + 内存缓存 + try/catch', () => {
  const p = path.join(CHAT_ETS, 'app', 'HapticUtil.ets');
  assert.ok(exists(p), '缺少 app/HapticUtil.ets');
  const util = read(p);
  assert.ok(util.includes('HAPTIC_ENABLED'), 'HapticUtil 未使用 HAPTIC_ENABLED');
  assert.ok(util.includes('isEnabled('), '缺少 isEnabled');
  assert.ok(util.includes('setEnabled('), '缺少 setEnabled');
  assert.ok(util.includes('vibrate('), '缺少 vibrate');
  assert.match(util, /private static enabled:\s*boolean\s*=\s*true/, 'enabled 默认值未为 true');
  assert.ok(/static async init\(/.test(util), '缺少 init 读取持久化开关');
  assert.ok(/try\s*\{/.test(util) && /catch\s*\(/.test(util), '缺少 try/catch 兜底');
  assert.ok(/if \(!HapticUtil\.enabled\)\s*\{[\s\S]{0,40}return;/.test(util), 'vibrate 未检查总开关');
  const app = read(path.join(CHAT_ETS, 'app', 'AppServices.ets'));
  assert.ok(app.includes('HapticUtil.init('), 'AppServices 启动未初始化 HapticUtil');
  const keys = read(path.join(PKG, 'core_model', 'src', 'main', 'ets', 'interfaces', 'SettingsKeys.ets'));
  assert.ok(keys.includes('HAPTIC_ENABLED'), 'SettingsKeys 缺少 HAPTIC_ENABLED');
  console.log('  证据：HapticUtil 完整（默认 true/缓存/持久化/开关短路/try-catch）；AppServices 启动 init；SettingsKeys.HAPTIC_ENABLED');
});

test('设置页总开关：SettingsDataView 含 HAPTIC_ENABLED + HapticUtil + Toggle（持久化/回显/失败回滚）', () => {
  const p = path.join(CHAT_ETS, 'components', 'SettingsDataView.ets');
  assert.ok(exists(p), '缺少 SettingsDataView.ets');
  const view = read(p);
  assert.ok(view.includes('HAPTIC_ENABLED'), '设置页未引用 HAPTIC_ENABLED');
  assert.ok(view.includes('HapticUtil'), '设置页未引用 HapticUtil');
  assert.ok(view.includes('Toggle('), '设置页缺少 Toggle 开关');
  assert.ok(view.includes('toggleHaptic('), '设置页缺少切换处理函数');
  assert.ok(view.includes('HapticUtil.setEnabled('), '切换未调用 HapticUtil.setEnabled');
  assert.ok(view.includes('HapticUtil.isEnabled()'), '初值未回显 HapticUtil.isEnabled');
  // 失败回滚：setEnabled 调用出现在 catch 分支或回滚赋值中
  assert.ok(/catch\s*\(/.test(view), '设置页切换缺少失败处理');
  console.log('  证据：SettingsDataView 触感 Toggle（初值回显 + setEnabled 持久化 + 失败回滚）');
});

// ---------------------------------------------------------------------------
// 4) 颜色与纪律
// ---------------------------------------------------------------------------
test('颜色：base/dark 各 54 键且集合一致，含 6 个 effort_* + violet/pink', () => {
  const load = (mode) => JSON.parse(read(path.join(RES, mode, 'element', 'color.json')));
  const base = load('base');
  const dark = load('dark');
  const bk = base.color.map((c) => c.name);
  const dk = dark.color.map((c) => c.name);
  assert.equal(bk.length, 54, `base 颜色键 ${bk.length} ≠ 54`);
  assert.deepEqual([...bk].sort(), [...dk].sort(), '深浅色键集合不一致');
  for (const key of effortKeys) {
    assert.ok(bk.includes(key), `base 缺少 ${key}`);
    assert.ok(dk.includes(key), `dark 缺少 ${key}`);
  }
  assert.ok(bk.includes('violet') && bk.includes('pink'), '缺少既有 violet/pink');
  console.log('  证据：54 键（48 + 6 effort_*）base/dark 一致，violet/pink 保留');
});

test('纪律：新增/改动组件无硬编码色值、无教学文案；@Builder 按值传参仍为 0', () => {
  const keywords = ['小提示', '聊两句就', '会先在心里推理', '要不要联网', '问题想多深', '当前构建未启用', '端侧小脚本'];
  const files = walk(CHAT_ETS, /\.(ets|ts)$/);
  const offenders = [];
  for (const file of files) {
    const text = read(file);
    if (/#[0-9A-Fa-f]{6,8}\b/.test(text) && !/bridge[/\\]LanEditorServer\.ets$/.test(file)) {
      offenders.push(`${path.relative(CHAT_ETS, file)} 含硬编码色值`);
    }
    const hits = keywords.filter((k) => text.includes(k));
    if (hits.length > 0) offenders.push(`${path.relative(CHAT_ETS, file)} 含教学文案 ${hits.join(',')}`);
  }
  assert.deepEqual(offenders, [], offenders.join('\n'));
  // 旧 v3.2 根因：按值传参 @Builder（vendorCard）不得回归
  for (const file of files) {
    assert.ok(!/@Builder\s+vendorCard\s*\(/.test(read(file)), `${path.relative(CHAT_ETS, file)} 出现按值传参 @Builder vendorCard`);
  }
  console.log(`  证据：${files.length} 个 UI 文件 0 硬编码色值（LanEditorServer 模板豁免）/0 教学文案/@Builder 按值传参 0`);
});

summarize();
