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
test('抽屉退场动画：setDrawerOpen 统一收口（animateTo 220ms + dragX 归零），if 两子节点各挂 OPACITY / move(START)', () => {
  const chatPage = read(path.join(CHAT_ETS, 'pages', 'ChatPage.ets'));
  // 统一入口
  assert.ok(chatPage.includes('private setDrawerOpen('), '缺少 setDrawerOpen(open) 统一入口');
  const fnStart = chatPage.indexOf('private setDrawerOpen(');
  const fnBody = chatPage.slice(fnStart, fnStart + 600);
  assert.ok(/getUIContext\(\)\.animateTo\(\{\s*duration:\s*220/.test(fnBody),
    'setDrawerOpen 未用 animateTo({ duration: 220 }) 包裹 drawerOpen 赋值（退场动画不会播放）');
  assert.ok(/this\.drawerDragX = 0/.test(fnBody), 'setDrawerOpen 未把 drawerDragX 归零');
  assert.ok(/this\.drawerOpen = open/.test(fnBody), 'setDrawerOpen 未真正设置 drawerOpen');
  // 9 处赋值全部收口：drawerOpen 直接赋值只允许 1 处（setDrawerOpen 内）
  assert.equal(count(chatPage, /this\.drawerOpen = /g), 1, 'drawerOpen 直接赋值未收口（应仅 setDrawerOpen 内 1 处）');
  assert.ok(count(chatPage, /this\.setDrawerOpen\(/g) >= 9, 'setDrawerOpen 调用点少于 9 处');

  // if 块两个直接子节点分别挂退场 transition
  const start = chatPage.indexOf('// 折叠态会话抽屉');
  assert.ok(start >= 0, '缺少折叠态抽屉区块');
  const end = chatPage.indexOf('.bindSheet(', start);
  const block = chatPage.slice(start, end);
  assert.ok(block.includes('TransitionEffect.OPACITY'), '遮罩缺少 OPACITY 退场过渡');
  assert.ok(/TransitionEffect\.move\(TransitionEdge\.START\)/.test(block), '抽屉层缺少 move(START) 退场过渡');
  assert.ok(block.includes('220'), '抽屉过渡未使用 220ms');
  assert.ok(block.includes('this.setDrawerOpen(false)'), '抽屉关闭未走 setDrawerOpen(false)');
  assert.ok(/\.layoutWeight\(1\)/.test(block), '右空白点击关闭容器丢失 layoutWeight(1)');
  assert.ok(!/Blank\(\)/.test(block), '抽屉区块内出现装饰 Blank()');
  console.log('  证据：setDrawerOpen + animateTo(220ms) + dragX 归零；scrim OPACITY / 抽屉层 move(START)；drawerOpen 赋值仅 1 处');
});

// ---------------------------------------------------------------------------
// 2) 能量槽面板（删除 Slider）
// ---------------------------------------------------------------------------
test('能量槽面板：无 Slider，含 onAreaChange + onTouch 吸附 + 渐变填充 + 发光圆钮 + 6 格能量柱 + 自然高度', () => {
  const panelPath = path.join(CHAT_ETS, 'components', 'ReasoningEffortPanel.ets');
  assert.ok(existsSync(panelPath), '缺少 components/ReasoningEffortPanel.ets');
  const panel = read(panelPath);
  assert.ok(!panel.includes('Slider('), 'ReasoningEffortPanel 仍含 Slider（应改为手写能量槽）');
  assert.ok(panel.includes('onTouch('), '能量槽缺少 onTouch 拖动手感');
  assert.ok(panel.includes('onAreaChange('), '能量槽缺少 onAreaChange 记录宽度');
  assert.ok(panel.includes('Circle('), '能量槽缺少圆钮（Circle）');
  assert.ok(panel.includes('linearGradient'), '能量槽缺少渐变填充');
  assert.ok(panel.includes('bgSurface'), '面板缺少 bgSurface 克制卡片底');
  // 6 格阶梯能量柱：复用 EffortLevels.ALL（6 档），以 Column 柱体渲染
  const barStart = panel.indexOf('energyBars()');
  const barBlock = panel.slice(barStart, barStart + 900);
  assert.ok(barStart >= 0, '缺少 energyBars 能量柱');
  assert.ok(barBlock.includes('ForEach(EffortLevels.ALL'), '能量柱未按 6 档渲染');
  assert.ok(barBlock.includes('Column()'), '能量柱缺少柱体');
  assert.ok(barBlock.includes('backgroundColor'), '能量柱缺少点亮状态色');
  // 自然高度：不允许撑满 100% 高
  assert.ok(!panel.includes("height('100%')"), '面板仍使用 height(\'100%\')（应为自然高度 + 底部安全区）');
  assert.equal(count(panel, /#[0-9A-Fa-f]{6,8}\b/g), 0, '面板含硬编码色值');
  // 保留：徽章呼吸/档位弹跳/振动 try 兜底
  assert.ok(panel.includes('vibrator.startVibration'), '面板丢失振动反馈');
  assert.ok(/try\s*\{/.test(panel) && /catch\s*\(/.test(panel), '振动缺少 try/catch 兜底');
  console.log(`  证据：无 Slider；onAreaChange+onTouch+linearGradient+Circle 圆钮+bgSurface+6 格 ForEach 能量柱；无 height('100%')、0 硬编码色；振动保留（${panel.split('\n').length} 行）`);
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
test('契约：ModelCatalogApi/ModelCatalog 有 unregister，AppServices 有 clearActiveProfile，颜色仍 48 键', () => {
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
  assert.equal(bk.length, 48, `颜色键 ${bk.length} ≠ 48（v3.4 未新增色键）`);
  assert.deepEqual([...bk].sort(), [...dk].sort(), '深浅色键集合不一致');
  console.log('  证据：unregister 契约+实现、clearActiveProfile 存在；颜色仍 48 键一致');
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
