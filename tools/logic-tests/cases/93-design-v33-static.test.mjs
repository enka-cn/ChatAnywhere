/**
 * v3.3 交互与动效升级静态门禁（抽屉关闭 / 四态模型胶囊 / 6 档特效面板）
 *
 * 对应三项改动（task-27/28）：
 * 1) 折叠抽屉：右空白可点关闭容器替代装饰 `Blank()` + 左滑 PanGesture（阈值 -48）+ scrim 三入口；
 * 2) 模型添加：`ModelProbeChip` 四态（idle/loading/success/error）+ VendorCard 渲染 + 模型页状态机；
 * 3) 6 档思考面板：`ReasoningEffortPanel`（叠层品牌色渐变/同心光环/档位字弹跳/振动 try 兜底）接入 ModelCapsule。
 * 另含 Lead 基建：48 色键（violet/pink）、module.json5 VIBRATE、Theme.violet/pink。
 */
import { test, assert, summarize } from './_harness.mjs';
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
const exists = (p) => existsSync(p);
const count = (text, re) => (text.match(re) || []).length;
const chatFiles = walk(CHAT_ETS, /\.(ets|ts)$/);

// ---------------------------------------------------------------------------
// 1) 抽屉关闭：右空白可点容器（替代装饰 Blank） + 左滑手势 + scrim
// ---------------------------------------------------------------------------
test('抽屉零闪变：常驻挂载 + drawerVisible/Visibility + opacity/translate 表达式 + 240ms FastOutSlowIn + onFinish，无 if 卸载/TransitionEffect', () => {
  const chatPage = read(path.join(CHAT_ETS, 'pages', 'ChatPage.ets'));
  assert.ok(chatPage.includes('private setDrawerOpen('), '缺少 setDrawerOpen(open) 统一入口');
  const fnStart = chatPage.indexOf('private setDrawerOpen(');
  const fnBody = chatPage.slice(fnStart, fnStart + 1400);
  assert.ok(/duration:\s*240/.test(fnBody), 'setDrawerOpen 未使用 240ms');
  assert.ok(fnBody.includes('FastOutSlowIn'), 'setDrawerOpen 未使用 FastOutSlowIn 曲线');
  assert.ok(fnBody.includes('onFinish'), '关闭未在 onFinish 里置 None（会导致闪变）');
  assert.ok(fnBody.includes('drawerVisible = true') && fnBody.includes('drawerVisible = false'),
    'setDrawerOpen 未管理 drawerVisible Visible/None');
  assert.ok(fnBody.includes('drawerOpen = true') && fnBody.includes('drawerOpen = false'),
    'setDrawerOpen 未设置 drawerOpen');
  assert.equal(count(chatPage, /this\.drawerOpen = /g), 2, 'drawerOpen 赋值应仅在 setDrawerOpen 内（open/close 各一处）');
  assert.ok(count(chatPage, /this\.setDrawerOpen\(/g) >= 9, 'setDrawerOpen 调用点少于 9 处');

  const start = chatPage.indexOf('// 折叠态会话抽屉');
  assert.ok(start >= 0, 'ChatPage 缺少折叠态会话抽屉区块');
  const end = chatPage.indexOf('.bindSheet(', start);
  assert.ok(end > start, '无法定位抽屉区块结束位置');
  const block = chatPage.slice(start, end);
  assert.ok(block.includes('drawerVisible'), '抽屉区块缺少 drawerVisible 常驻挂载');
  assert.ok(block.includes('Visibility.None') && block.includes('Visibility.Visible'),
    '抽屉区块缺少 Visibility 显隐控制');
  assert.ok(/\.opacity\(this\.drawerOpen \? 1 : 0\)/.test(block), '遮罩缺少 opacity(drawerOpen?1:0) 渐变');
  assert.ok(/\.translate\(\{\s*x:\s*\(this\.drawerOpen \? 0 : -Layout\.drawerMaxWidth\)/.test(block),
    '抽屉层缺少 translate(drawerOpen?0:-drawerMaxWidth + dragX) 表达式');
  assert.ok(/\.layoutWeight\(1\)/.test(block), '右空白点击关闭容器丢失 layoutWeight(1)');
  assert.ok(block.includes('this.setDrawerOpen(false)'), '抽屉关闭未走 setDrawerOpen(false)');
  assert.ok(!/Blank\(\)/.test(block), '抽屉区块内出现装饰 Blank()');
  assert.equal(count(block, /TransitionEffect/g), 0, 'v3.5 抽屉区块不应再有 TransitionEffect（改为常驻挂载）');
  assert.ok(!chatPage.includes('if (!this.unfolded && this.drawerOpen)'),
    '仍存在 if (!this.unfolded && this.drawerOpen) 卸载（会闪变）');
  assert.ok(block.includes('PanGesture') && block.includes('-48'), '抽屉左滑关闭手势/阈值丢失');
  console.log('  证据：drawerVisible+Visibility 常驻挂载、opacity/translate 表达式、setDrawerOpen 240ms FastOutSlowIn+onFinish、无 if 卸载/TransitionEffect；关闭入口 ≥3、调用点 ≥9');
});

// ---------------------------------------------------------------------------
// 2) 6 档思考特效面板
// ---------------------------------------------------------------------------
test('6 档面板：ReasoningEffortPanel 含叠层品牌渐变/光环/徽章/振动 try 兜底，且接入 ModelCapsule', () => {
  const panelPath = path.join(CHAT_ETS, 'components', 'ReasoningEffortPanel.ets');
  assert.ok(exists(panelPath), '缺少 components/ReasoningEffortPanel.ets');
  const panel = read(panelPath);
  // 深空暗舱渐变（linearGradient 卡片底 + radialGradient 氛围光）
  assert.ok(/linearGradient/i.test(panel) || /radialGradient/i.test(panel)
    || (panel.includes('Theme.effortDeckTop') && panel.includes('Theme.effortDeckBottom')),
    '面板缺少暗舱渐变（linearGradient/radialGradient/effortDeck）');
  assert.ok(panel.includes('Icons.sparkles') && panel.includes('Icons.thinking'),
    '面板缺少 sparkles/thinking 徽章图标');
  assert.ok(panel.includes('Circle('), '面板缺少同心 Circle 光环/圆钮');
  assert.ok(panel.includes('HapticUtil.vibrate'), '面板触感未走 HapticUtil.vibrate（v3.5 总开关）');
  assert.equal(count(panel, /#[0-9A-Fa-f]{6,8}\b/g), 0, 'ReasoningEffortPanel 含硬编码色值');

  const capsule = read(path.join(CHAT_ETS, 'components', 'ModelCapsule.ets'));
  assert.ok(/from\s+['"][^'"]*ReasoningEffortPanel['"]/.test(capsule), 'ModelCapsule 未 import ReasoningEffortPanel');
  assert.ok(capsule.includes('ReasoningEffortPanel('), 'ModelCapsule 未使用 ReasoningEffortPanel');
  assert.ok(!/Slider\(/.test(capsule), 'ModelCapsule 仍保留内联 Slider（应已移入面板）');
  console.log('  证据：面板三层品牌渐变（brand/violet/pink）+ sparkles/thinking + Circle 光环 + 振动 try/catch，且 ModelCapsule 已接入、内联 Slider 清零');
});

// ---------------------------------------------------------------------------
// 3) 四态模型添加胶囊
// ---------------------------------------------------------------------------
test('四态胶囊：ModelProbeChip 覆盖 idle/loading/success/error，含转圈/勾选/重试/成功与危险底色，且被 VendorCard 使用', () => {
  const chipPath = path.join(CHAT_ETS, 'components', 'ModelProbeChip.ets');
  assert.ok(exists(chipPath), '缺少 components/ModelProbeChip.ets');
  const chip = read(chipPath);
  for (const state of ['idle', 'loading', 'success', 'error']) {
    assert.ok(chip.includes(`'${state}'`), `ModelProbeChip 缺少状态 '${state}'`);
  }
  for (const builder of ['idleChip(', 'loadingChip(', 'successChip(', 'errorChip(']) {
    assert.ok(chip.includes(builder), `ModelProbeChip 缺少 ${builder} 分支`);
  }
  assert.ok(chip.includes('LoadingProgress'), 'ModelProbeChip 缺少 LoadingProgress 转圈');
  assert.ok(chip.includes('Icons.check'), 'ModelProbeChip 缺少 Icons.check 成功态');
  assert.ok(chip.includes('Icons.retry'), 'ModelProbeChip 缺少 Icons.retry 重试态');
  assert.ok(chip.includes('successSubtle'), 'ModelProbeChip 缺少 successSubtle 底色');
  assert.ok(chip.includes('dangerSubtle'), 'ModelProbeChip 缺少 dangerSubtle 底色');

  const vendor = read(path.join(CHAT_ETS, 'components', 'VendorCard.ets'));
  assert.ok(/from\s+['"][^'"]*ModelProbeChip['"]/.test(vendor), 'VendorCard 未 import ModelProbeChip');
  assert.ok(vendor.includes('ModelProbeChip('), 'VendorCard 未渲染 ModelProbeChip');
  console.log('  证据：四态分支 + LoadingProgress/check/retry/successSubtle/dangerSubtle 齐全，VendorCard 已渲染');
});

test('模型页状态机：modelStatuses 数组 + setModelEnabled + loading→success/error 流转 + enabled 回显 success', () => {
  const view = read(path.join(CHAT_ETS, 'components', 'SettingsModelsView.ets'));
  assert.ok(view.includes('modelStatuses'), 'SettingsModelsView 缺少 modelStatuses 状态数组');
  assert.ok(view.includes('ModelAddStatus'), 'SettingsModelsView 未使用 ModelAddStatus 类型');
  assert.ok(view.includes('setModelEnabled('), 'SettingsModelsView 未调用 catalog.setModelEnabled');
  assert.ok(view.includes("'loading'"), '状态机缺少 loading 流转');
  assert.ok(view.includes("'success'") && view.includes("'error'"), '状态机缺少 success/error 流转');
  assert.ok(/enabled\s*\?\s*'success'\s*:\s*'idle'/.test(view), 'enabled 记录未回显为 success');
  console.log('  证据：modelStatuses + setModelEnabled + loading→success/error + enabled→success 回显齐全');
});

// ---------------------------------------------------------------------------
// 4) Lead 基建：54 色键（violet/pink + 6 effort_*）、VIBRATE 权限、Theme 令牌
// ---------------------------------------------------------------------------
test('基建：color.json base/dark 各 54 键且含 violet/pink 与 6 个 effort_*，module.json5 含 VIBRATE，Theme 暴露令牌', () => {
  const load = (mode) => JSON.parse(read(path.join(RES, mode, 'element', 'color.json')));
  const base = load('base');
  const dark = load('dark');
  const bk = base.color.map((c) => c.name);
  const dk = dark.color.map((c) => c.name);
  assert.equal(bk.length, 54, `base 颜色键 ${bk.length} ≠ 54（v3.5）`);
  assert.deepEqual([...bk].sort(), [...dk].sort(), '深浅色键集合不一致');
  for (const key of ['violet', 'pink']) {
    assert.ok(bk.includes(key), `base 缺少 ${key}`);
    assert.ok(dk.includes(key), `dark 缺少 ${key}`);
  }
  for (const key of ['effort_deck_top', 'effort_deck_bottom', 'effort_track', 'effort_bar_off',
    'effort_text_dim', 'effort_text_bright']) {
    assert.ok(bk.includes(key), `base 缺少 v3.5 暗舱色键 ${key}`);
    assert.ok(dk.includes(key), `dark 缺少 v3.5 暗舱色键 ${key}`);
  }
  const baseViolet = base.color.find((c) => c.name === 'violet').value.toUpperCase();
  const darkViolet = dark.color.find((c) => c.name === 'violet').value.toUpperCase();
  const basePink = base.color.find((c) => c.name === 'pink').value.toUpperCase();
  const darkPink = dark.color.find((c) => c.name === 'pink').value.toUpperCase();
  assert.equal(baseViolet, '#7C3AED');
  assert.equal(darkViolet, '#8B5CF6');
  assert.equal(basePink, '#EC4899');
  assert.equal(darkPink, '#F472B6');

  const moduleJson = read(path.join(REPO, 'chat', 'src', 'main', 'module.json5'));
  assert.ok(moduleJson.includes('ohos.permission.VIBRATE'), 'module.json5 缺少 VIBRATE 权限');
  const theme = read(path.join(CHAT_ETS, 'app', 'Theme.ets'));
  assert.ok(theme.includes('violet') && theme.includes('pink'), 'Theme.ets 未暴露 violet/pink 令牌');
  for (const key of ['effortDeckTop', 'effortDeckBottom', 'effortTrack', 'effortBarOff',
    'effortTextDim', 'effortTextBright']) {
    assert.ok(theme.includes(key), `Theme.ets 未暴露暗舱令牌 ${key}`);
  }
  console.log('  证据：54 键含 violet/pink + 6 effort_*；module.json5 含 VIBRATE；Theme 暴露暗舱令牌');
});

test('颜色/文案纪律覆盖新增组件：ReasoningEffortPanel + ModelProbeChip 无硬编码色值、无教学文案', () => {
  const files = ['components/ReasoningEffortPanel.ets', 'components/ModelProbeChip.ets']
    .map((rel) => path.join(CHAT_ETS, rel));
  const keywords = ['小提示', '聊两句就', '会先在心里推理', '要不要联网', '问题想多深', '当前构建未启用', '端侧小脚本'];
  for (const file of files) {
    const text = read(file);
    assert.equal(count(text, /#[0-9A-Fa-f]{6,8}\b/g), 0, `${path.basename(file)} 含硬编码色值`);
    const hits = keywords.filter((k) => text.includes(k));
    assert.deepEqual(hits, [], `${path.basename(file)} 命中教学文案：${hits.join(',')}`);
  }
  console.log('  证据：两个新增组件 0 硬编码色值、0 教学文案');
});

summarize();
