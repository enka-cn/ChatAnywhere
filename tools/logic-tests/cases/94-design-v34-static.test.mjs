/**
 * v3.4 交互修复静态门禁（抽屉退场动画 / 取消模型 / 能量槽面板）
 *
 * 对应 v3.4 三项真机反馈：
 * 1) 抽屉关闭无退场动画 → `setDrawerOpen(open)` 统一收口（animateTo 220ms）+ 两个直接子节点挂
 *    `TransitionEffect.OPACITY` / `TransitionEffect.move(TransitionEdge.START)`；
 * 2) 模型添加只能加不能取消 → ModelProbeChip success 可点击取消；SettingsModelsView `toggleModel`
 *    双向（success → loading → catalog.unregister → reload → idle）+ 活跃模型自动切换/清空；
 * 3) 6 档面板 Slider 手感差 → 重做为能量槽（onAreaChange + onTouch 吸附 + 渐变填充 + 发光圆钮 + 6 格能量柱）。
 * 另含 Lead 契约：`ModelCatalogApi.unregister`、`AppServices.clearActiveProfile`、颜色仍 48 键。
 */
import { test, assert, summarize } from './_harness.mjs';
import { verifyCodeMathColors } from './_theme.mjs';
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
const count = (text, re) => (text.match(re) || []).length;

// ---------------------------------------------------------------------------
// 1) 抽屉退场动画
// ---------------------------------------------------------------------------
test('抽屉单一位移（v3.6）：drawerTranslateX/scrimOpacity + clamp 跟手 + 从当前位移动画 + 240ms/onFinish，无 drawerDragX/drawerOpen', () => {
  const chatPage = read(path.join(CHAT_ETS, 'pages', 'ChatPage.ets'));
  assert.ok(chatPage.includes('@State private drawerTranslateX'), '缺少 drawerTranslateX');
  assert.ok(chatPage.includes('@State private scrimOpacity'), '缺少 scrimOpacity');
  assert.equal(count(chatPage, /drawerDragX/g), 0, 'v3.6 不应再有 drawerDragX');
  assert.equal(count(chatPage, /drawerOpen/g), 0, 'v3.6 不应再有 drawerOpen 位移状态');
  assert.ok(count(chatPage, /drawerTranslateX/g) >= 4, 'drawerTranslateX 出现次数 <4');
  assert.ok(count(chatPage, /scrimOpacity/g) >= 2, 'scrimOpacity 出现次数 <2');

  const start = chatPage.indexOf('// 折叠态会话抽屉');
  assert.ok(start >= 0, '缺少折叠态抽屉区块');
  const end = chatPage.indexOf('.bindSheet(', start);
  const block = chatPage.slice(start, end);
  assert.ok(block.includes('drawerVisible'), '抽屉区块缺少 drawerVisible');
  assert.ok(block.includes('Visibility.None') && block.includes('Visibility.Visible'), '缺少 Visibility');
  assert.ok(/\.opacity\(this\.scrimOpacity\)/.test(block), '遮罩缺少 opacity(scrimOpacity)');
  assert.ok(/\.translate\(\{\s*x:\s*this\.drawerTranslateX\s*\}\)/.test(block), '抽屉层缺少 translate(drawerTranslateX)');
  assert.ok(/Math\.max\(-width,\s*Math\.min\(0,\s*e\.offsetX\)\)/.test(block), 'onActionUpdate 未 clamp');
  assert.ok(/this\.scrimOpacity = 1 \+ this\.drawerTranslateX \/ width/.test(block), '拖动未同步 scrimOpacity');
  assert.ok(/this\.drawerTranslateX < -width \* 0\.25/.test(block), 'onActionEnd 未使用 1/4 阈值');
  assert.ok(/velocityX < -800/.test(block), 'onActionEnd 未使用速度阈值');
  assert.ok(block.includes('onFinish'), '收起动画缺少 onFinish');
  assert.equal(count(block, /TransitionEffect/g), 0, '抽屉区块不应有 TransitionEffect');
  assert.ok(!/Blank\(\)/.test(block), '抽屉区块内出现装饰 Blank()');
  assert.ok(/\.layoutWeight\(1\)/.test(block), '右空白点击关闭容器丢失 layoutWeight(1)');
  assert.ok(block.includes('this.setDrawerOpen(false)'), '抽屉关闭未走 setDrawerOpen(false)');

  const fnStart = chatPage.indexOf('private setDrawerOpen(');
  const fnBody = chatPage.slice(fnStart, fnStart + 1600);
  assert.ok(/duration:\s*240/.test(fnBody), 'setDrawerOpen 未使用 240ms');
  assert.ok(fnBody.includes('FastOutSlowIn'), 'setDrawerOpen 未使用 FastOutSlowIn');
  assert.ok(fnBody.includes('onFinish'), '关闭未在 onFinish 置 None');
  assert.ok(count(chatPage, /this\.setDrawerOpen\(/g) >= 8, 'setDrawerOpen 调用点少于 8 处');
  console.log('  证据：drawerTranslateX 单一位移 + scrimOpacity 同步 + clamp 跟手 + 从当前位移收起（1/4 或 velocityX<-800）+ onFinish/Visibility；无 drawerDragX/drawerOpen');
});

// ---------------------------------------------------------------------------
// 2) 能量槽面板（删除 Slider）
// ---------------------------------------------------------------------------
test('能量槽面板（v3.5 暗舱）：无 Slider，含 6 个 effort 令牌 + radialGradient + onTouch 吸附 + 22vp 白钮/8vp 内点 + 6 格能量柱 + 自然高度', () => {
  const panelPath = path.join(CHAT_ETS, 'components', 'ReasoningEffortPanel.ets');
  assert.ok(existsSync(panelPath), '缺少 components/ReasoningEffortPanel.ets');
  const panel = read(panelPath);
  assert.ok(!panel.includes('Slider('), 'ReasoningEffortPanel 仍含 Slider');
  for (const token of ['Theme.effortDeckTop', 'Theme.effortDeckBottom', 'Theme.effortTrack',
    'Theme.effortBarOff', 'Theme.effortTextDim', 'Theme.effortTextBright']) {
    assert.ok(panel.includes(token), `面板缺少暗舱令牌 ${token}`);
  }
  assert.ok(panel.includes('radialGradient('), '面板缺少右上 radialGradient 氛围光');
  assert.ok(panel.includes('onTouch('), '能量槽缺少 onTouch 拖动手感');
  assert.ok(panel.includes('onAreaChange('), '能量槽缺少 onAreaChange 记录宽度');
  assert.ok(panel.includes('KNOB_SIZE: number = 22'), '缺少 22vp 白钮尺寸常量');
  assert.ok(panel.includes('Circle('), '能量槽缺少圆钮（Circle）');
  assert.ok(/Circle\(\{\s*width:\s*8,\s*height:\s*8\s*\}\)/.test(panel), '缺少中心 8vp 档位色圆点');
  assert.ok(panel.includes('linearGradient'), '能量槽缺少渐变光轨');
  // 6 格阶梯能量柱
  const barStart = panel.indexOf('energyBars()');
  const barBlock = panel.slice(barStart, barStart + 900);
  assert.ok(barStart >= 0, '缺少 energyBars 能量柱');
  assert.ok(barBlock.includes('ForEach(EffortLevels.ALL'), '能量柱未按 6 档渲染');
  assert.ok(barBlock.includes('Theme.effortBarOff'), '能量柱未使用暗底 effortBarOff');
  // 自然高度 + 无硬编码色 + 触感走 HapticUtil（不再直接 import SensorServiceKit）
  assert.ok(!panel.includes("height('100%')"), '面板仍使用 height(\'100%\')');
  assert.equal(count(panel, /#[0-9A-Fa-f]{6,8}\b/g), 0, '面板含硬编码色值');
  assert.ok(panel.includes('HapticUtil.vibrate'), '面板触感未走 HapticUtil.vibrate');
  assert.ok(!panel.includes('@kit.SensorServiceKit'), '面板仍直接 import @kit.SensorServiceKit');
  console.log(`  证据：6 effort 令牌 + radialGradient + onTouch/onAreaChange + 22vp/8vp 圆钮 + 6 格 ForEach 能量柱；无 Slider/height('100%')/硬编码色/SensorServiceKit（${panel.split('\n').length} 行）`);
});

// ---------------------------------------------------------------------------
// 3) 模型胶囊「取消添加」链路
// ---------------------------------------------------------------------------
test('取消添加：ModelProbeChip success 可点击取消、loading 不可点击；VendorCard 透传 notice', () => {
  const chip = read(path.join(CHAT_ETS, 'components', 'ModelProbeChip.ets'));
  const successStart = chip.indexOf('successChip(');
  const successEnd = chip.indexOf('errorChip(', successStart);
  const successBlock = chip.slice(successStart, successEnd);
  assert.ok(/\.onClick\(/.test(successBlock), 'successChip 未恢复可点击（取消）');
  assert.ok(successBlock.includes('onTap('), 'successChip 点击未回调 onTap');

  const loadingStart = chip.indexOf('loadingChip(');
  const loadingEnd = chip.indexOf('successChip(', loadingStart);
  const loadingBlock = chip.slice(loadingStart, loadingEnd);
  assert.ok(!/\.onClick\(/.test(loadingBlock), 'loadingChip 不应有点击（防连点）');

  const vendor = read(path.join(CHAT_ETS, 'components', 'VendorCard.ets'));
  assert.ok(vendor.includes('notice'), 'VendorCard 缺少 notice 错误提示透传');
  console.log('  证据：success 可点击取消、loading 防连点；VendorCard 透传 notice');
});

test('取消链路：SettingsModelsView 含 toggleModel + unregister + clearActiveProfile + toggleError 双向流转', () => {
  const view = read(path.join(CHAT_ETS, 'components', 'SettingsModelsView.ets'));
  assert.ok(view.includes('toggleModel('), '缺少 toggleModel 双向入口');
  assert.ok(view.includes('unregister('), '取消未调用 catalog.unregister');
  assert.ok(view.includes('clearActiveProfile'), '无剩余模型时未调用 clearActiveProfile');
  assert.ok(view.includes('toggleError'), '缺少 toggleError 失败提示');
  assert.ok(view.includes("'loading'") && view.includes("'idle'") && view.includes("'success'"),
    '取消状态流转（loading→idle/success）不完整');
  console.log('  证据：toggleModel + unregister + clearActiveProfile + toggleError（loading→idle/success）齐全');
});

// ---------------------------------------------------------------------------
// 4) 契约：unregister / clearActiveProfile / 颜色不变
// ---------------------------------------------------------------------------
test('契约：ModelCatalogApi/ModelCatalog 有 unregister，AppServices 有 clearActiveProfile，颜色仍 64 键（v3.6 日夜两套精确值）', () => {
  const proto = read(path.join(PKG, 'core_protocol', 'src', 'main', 'ets', 'interfaces', 'ProtocolLayer.ets'));
  assert.ok(/unregister\(\s*providerId:\s*string,\s*modelId:\s*string\s*\)/.test(proto),
    'ModelCatalogApi 缺少 unregister(providerId, modelId)');
  const catalog = read(path.join(PKG, 'core_protocol', 'src', 'main', 'ets', 'ModelCatalog.ets'));
  assert.ok(catalog.includes('async unregister('), 'ModelCatalog 缺少 unregister 实现');
  const app = read(path.join(CHAT_ETS, 'app', 'AppServices.ets'));
  assert.ok(app.includes('async clearActiveProfile('), 'AppServices 缺少 clearActiveProfile');

  const load = (mode) => JSON.parse(read(path.join(RES, mode, 'element', 'color.json')));
  const bk = load('base').color.map((c) => c.name);
  const dk = load('dark').color.map((c) => c.name);
  verifyCodeMathColors(assert, load('base'), load('dark'));
  assert.equal(bk.length, 64, `颜色键 ${bk.length} ≠ 64（v3.6：48 + 6 effort_*）`);
  assert.deepEqual([...bk].sort(), [...dk].sort(), '深浅色键集合不一致');
  const bv = Object.fromEntries(load('base').color.map((c) => [c.name, String(c.value).toUpperCase()]));
  const dv = Object.fromEntries(load('dark').color.map((c) => [c.name, String(c.value).toUpperCase()]));
  const baseEffort = {
    effort_deck_top: '#F6F7FB', effort_deck_bottom: '#FFFFFF', effort_track: '#E6E9F2',
    effort_bar_off: '#DFE3EC', effort_text_dim: '#6B7280', effort_text_bright: '#111827'
  };
  const darkEffort = {
    effort_deck_top: '#11131B', effort_deck_bottom: '#181C28', effort_track: '#232836',
    effort_bar_off: '#2A2F3D', effort_text_dim: '#9CA3AF', effort_text_bright: '#FFFFFF'
  };
  for (const key of Object.keys(baseEffort)) {
    assert.ok(bk.includes(key), `缺少 v3.6 暗舱色键 ${key}`);
    assert.equal(bv[key], baseEffort[key], `base ${key}（日间浅面）`);
    assert.equal(dv[key], darkEffort[key], `dark ${key}（夜间暗舱）`);
  }
  console.log('  证据：unregister 契约+实现、clearActiveProfile 存在；颜色 64 键（6 effort_* 日夜两套精确值）一致');
});

test('纪律：v3.4 面板与胶囊无新增硬编码色值/教学文案（含全仓扫描）', () => {
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
  console.log(`  证据：${files.length} 个 UI 文件 0 硬编码色值（仅 LanEditorServer 内嵌 HTML 豁免）、0 教学文案`);
});

summarize();
