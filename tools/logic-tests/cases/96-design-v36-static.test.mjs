/**
 * v3.6 交互修复静态门禁（抽屉单一位移 / 面板日夜双主题 / 弹窗自定义关闭按钮）
 *
 * 三项真机反馈：
 * 1) 抽屉拖动松手会先跳回原位再动画 → 删除双状态（drawerOpen/drawerDragX），只保留
 *    `drawerTranslateX` 单一位移 + `scrimOpacity` 同步；onActionEnd 从当前位移继续动画
 *    （位移 < -W*0.25 或 velocityX < -800 收起），禁止先归零；
 * 2) 6 档面板只有暗舱、日间对比度差 → effort 令牌 base 日间浅面 / dark 暗舱自动切换；
 *    mediaquery 监听 dark-mode 维护 isDark；光晕日间 0.08–0.14、夜间 0.12–0.28；删除轨道上方浮点刻度；
 * 3) bindSheet 系统关闭按钮位置不统一 → ModelCapsule / ChatPage sheetContent `showClose: false`，
 *    标题行右侧统一 `IconBtn(Icons.close, btnSize: 28)`。
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
const baseEffort = {
  effort_deck_top: '#F6F7FB', effort_deck_bottom: '#FFFFFF', effort_track: '#E6E9F2',
  effort_bar_off: '#DFE3EC', effort_text_dim: '#6B7280', effort_text_bright: '#111827'
};
const darkEffort = {
  effort_deck_top: '#11131B', effort_deck_bottom: '#181C28', effort_track: '#232836',
  effort_bar_off: '#2A2F3D', effort_text_dim: '#9CA3AF', effort_text_bright: '#FFFFFF'
};

// ---------------------------------------------------------------------------
// 1) 抽屉单一位移
// ---------------------------------------------------------------------------
test('抽屉单一位移：drawerTranslateX/scrimOpacity + clamp 跟手 + onActionEnd 从当前位移动画（无 drawerDragX/drawerOpen 双状态）', () => {
  const chatPage = read(path.join(CHAT_ETS, 'pages', 'ChatPage.ets'));
  assert.match(chatPage, /@State private drawerTranslateX:\s*number/);
  assert.match(chatPage, /@State private scrimOpacity:\s*number/);
  assert.match(chatPage, /@State private drawerVisible:\s*boolean/);
  assert.equal(count(chatPage, /drawerDragX/g), 0, 'v3.6 不应再有 drawerDragX');
  assert.equal(count(chatPage, /drawerOpen/g), 0, 'v3.6 不应再有 drawerOpen 位移状态');
  assert.ok(count(chatPage, /drawerTranslateX/g) >= 4, 'drawerTranslateX <4');
  assert.ok(count(chatPage, /scrimOpacity/g) >= 2, 'scrimOpacity <2');

  const start = chatPage.indexOf('// 折叠态会话抽屉');
  assert.ok(start >= 0, '缺少折叠态抽屉区块');
  const end = chatPage.indexOf('.bindSheet(', start);
  const block = chatPage.slice(start, end);
  assert.ok(/\.opacity\(this\.scrimOpacity\)/.test(block), '遮罩缺少 opacity(scrimOpacity)');
  assert.ok(/\.translate\(\{\s*x:\s*this\.drawerTranslateX\s*\}\)/.test(block), '抽屉层缺少 translate(drawerTranslateX)');
  assert.ok(block.includes('Visibility.None') && block.includes('Visibility.Visible'), '缺少 Visibility');
  // 跟手：clamp + scrim 同步
  assert.ok(/this\.drawerTranslateX = Math\.max\(-width,\s*Math\.min\(0,\s*e\.offsetX\)\)/.test(block),
    'onActionUpdate 未 clamp 位移');
  assert.ok(/this\.scrimOpacity = 1 \+ this\.drawerTranslateX \/ width/.test(block), '拖动未同步 scrimOpacity');
  // 抬手：从当前位移继续动画（阈值 1/4 或快速左滑），禁止先归零
  const endIdx = block.indexOf('onActionEnd');
  assert.ok(endIdx >= 0, '缺少 onActionEnd');
  const endBody = block.slice(endIdx, block.indexOf('}))', endIdx) + 3);
  assert.ok(/this\.drawerTranslateX < -width \* 0\.25/.test(endBody), 'onActionEnd 未使用 1/4 位移阈值');
  assert.ok(/velocityX < -800/.test(endBody), 'onActionEnd 未使用 300ms 快速左滑阈值');
  assert.ok(!/this\.drawerTranslateX = 0;/.test(endBody.slice(0, endBody.indexOf('animateTo'))),
    'onActionEnd 在动画前先把位移归零（会跳回）');
  assert.ok(endBody.includes('animateTo'), 'onActionEnd 未从当前位移做动画');
  assert.ok(endBody.includes('onFinish'), 'onActionEnd 动画缺少 onFinish');
  assert.ok(!block.includes('TransitionEffect'), '抽屉区块不应有 TransitionEffect');
  assert.ok(!/Blank\(\)/.test(block), '抽屉区块内出现装饰 Blank()');
  assert.ok(/\.layoutWeight\(1\)/.test(block), '右空白点击关闭容器丢失 layoutWeight(1)');
  assert.ok(block.includes('this.setDrawerOpen(false)'), '抽屉关闭未走 setDrawerOpen(false)');
  assert.ok(count(chatPage, /this\.setDrawerOpen\(/g) >= 8, 'setDrawerOpen 调用点 <8');
  console.log('  证据：drawerTranslateX 单一位移 + scrimOpacity 同步 + clamp（Math.max/Math.min）+ onActionEnd 从当前位移收起（< -W*0.25 或 velocityX<-800）；无 drawerDragX/drawerOpen');
});

// ---------------------------------------------------------------------------
// 2) 面板日夜双主题 + 无浮点刻度
// ---------------------------------------------------------------------------
test('面板日夜双主题：isDark + mediaquery.matchMediaSync(dark-mode) + 光晕日间 0.08–0.14 / 夜间 0.12–0.28', () => {
  const panelPath = path.join(CHAT_ETS, 'components', 'ReasoningEffortPanel.ets');
  assert.ok(exists(panelPath), '缺少 ReasoningEffortPanel.ets');
  const panel = read(panelPath);
  assert.ok(panel.includes('@ohos.mediaquery') || panel.includes('mediaquery'), '缺少 mediaquery 监听');
  assert.ok(panel.includes('matchMediaSync('), '缺少 matchMediaSync');
  assert.ok(panel.includes('(dark-mode: true)'), '未监听 dark-mode');
  assert.ok(panel.includes('@State private isDark'), '缺少 isDark 主题状态');
  assert.ok(/0\.08/.test(panel) && /0\.14/.test(panel), '缺少日间光晕 0.08–0.14');
  assert.ok(/0\.12/.test(panel) && /0\.28/.test(panel), '缺少夜间光晕 0.12–0.28');
  for (const token of ['Theme.effortDeckTop', 'Theme.effortDeckBottom', 'Theme.effortTrack',
    'Theme.effortBarOff', 'Theme.effortTextDim', 'Theme.effortTextBright']) {
    assert.ok(panel.includes(token), `缺少 effort 令牌 ${token}`);
  }
  assert.ok(panel.includes('radialGradient('), '缺少 radialGradient 氛围光');
  // 夜/日分支：isDark 决定光晕与圆钮描边
  assert.ok(/this\.isDark \? 0\.26 : 0\.18/.test(panel), '圆钮光晕未按 isDark 分档');
  assert.ok(/this\.isDark \? Theme\.effortTextBright : Theme\.bgSurface/.test(panel), '白钮未按 isDark 切换');
  assert.ok(/this\.isDark \? Theme\.bgSurface : Theme\.border/.test(panel), '圆钮描边未按 isDark 切换');
  console.log('  证据：isDark + matchMediaSync(dark-mode) + 光晕 0.08–0.14/0.12–0.28 + 6 effort 令牌 + radialGradient + 日夜圆钮/描边分支');
});

test('面板无浮点刻度：tickDots / 轨道上方独立小圆点为 0（删除 5 个浮点），仍无 Slider/height(100%)/硬编码色/SensorServiceKit', () => {
  const panel = read(path.join(CHAT_ETS, 'components', 'ReasoningEffortPanel.ets'));
  assert.equal(count(panel, /tickDots|tickDot/g), 0, '仍存在 tickDots 浮点刻度');
  assert.equal(count(panel, /Circle\(\{\s*width:\s*(?:2|3|4)(?:\.\d+)?,\s*height:\s*(?:2|3|4)(?:\.\d+)?\s*\}\)/g), 0,
    '仍存在轨道上方小圆点（width/height ≤4）');
  assert.ok(!panel.includes('Slider('), '面板仍含 Slider');
  assert.ok(!panel.includes("height('100%')"), '面板仍使用 height(100%)');
  assert.equal(count(panel, /#[0-9A-Fa-f]{6,8}\b/g), 0, '面板含硬编码色值');
  assert.ok(panel.includes('HapticUtil.vibrate'), '面板触感未走 HapticUtil.vibrate');
  assert.ok(!panel.includes('@kit.SensorServiceKit'), '面板仍直接 import SensorServiceKit');
  console.log('  证据：tickDots/小圆点 0 处；无 Slider/height(100%)/硬编码色/SensorServiceKit；HapticUtil.vibrate 保留');
});

// ---------------------------------------------------------------------------
// 3) 弹窗自定义关闭按钮
// ---------------------------------------------------------------------------
test('弹窗关闭按钮：ModelCapsule + ChatPage sheetContent 均 showClose:false，各含 IconBtn + Icons.close + btnSize:28', () => {
  const capsule = read(path.join(CHAT_ETS, 'components', 'ModelCapsule.ets'));
  assert.equal(count(capsule, /showClose: true/g), 0, 'ModelCapsule 仍启用系统关闭按钮');
  assert.ok(/showClose:\s*false/.test(capsule), 'ModelCapsule bindSheet 未设 showClose:false');
  assert.ok(capsule.includes('IconBtn('), 'ModelCapsule 缺少自定义关闭按钮 IconBtn');
  assert.ok(capsule.includes('Icons.close'), 'ModelCapsule 关闭按钮缺少 Icons.close');
  assert.ok(/btnSize:\s*28/.test(capsule), 'ModelCapsule 关闭按钮 btnSize 不是 28');

  const chatPage = read(path.join(CHAT_ETS, 'pages', 'ChatPage.ets'));
  // ChatPage 中 showClose:true 仅允许 SourcePane 组件属性（1 处）
  assert.equal(count(chatPage, /showClose: true/g), 1, 'ChatPage showClose:true 数量异常（应仅 SourcePane 1 处）');
  const trueIdx = chatPage.indexOf('showClose: true');
  const srcIdx = chatPage.lastIndexOf('SourcePane(', trueIdx);
  assert.ok(srcIdx >= 0 && trueIdx - srcIdx < 200, 'ChatPage showClose:true 不在 SourcePane 组件属性内');
  assert.ok(count(chatPage, /showClose: false/g) >= 1, 'ChatPage sheetContent 未设 showClose:false');
  assert.ok(chatPage.includes('Icons.close'), 'ChatPage sheetContent 缺少 Icons.close');
  assert.ok(/btnSize:\s*28/.test(chatPage), 'ChatPage 关闭按钮 btnSize 不是 28');
  assert.ok(/IconBtn\(\{[\s\S]{0,400}?Icons\.close/.test(chatPage), 'ChatPage 缺少 IconBtn(Icons.close) 自定义关闭按钮');
  console.log('  证据：ModelCapsule/ChatPage sheetContent showClose:false + IconBtn(Icons.close, btnSize:28)；ChatPage showClose:true 仅 SourcePane');
});

// ---------------------------------------------------------------------------
// 4) 颜色日夜两套 + 纪律
// ---------------------------------------------------------------------------
test('颜色：base/dark 各 64 键（含 12 code/math）且集合一致，effort_* 为日间浅面/夜间暗舱两套精确值，violet/pink 保留', () => {
  const load = (mode) => JSON.parse(read(path.join(RES, mode, 'element', 'color.json')));
  const base = load('base');
  const dark = load('dark');
  const bk = base.color.map((c) => c.name);
  const dk = dark.color.map((c) => c.name);
  verifyCodeMathColors(assert, base, dark);
  assert.equal(bk.length, 64, `base 颜色键 ${bk.length} ≠ 64`);
  assert.deepEqual([...bk].sort(), [...dk].sort(), '深浅色键集合不一致');
  const bv = Object.fromEntries(base.color.map((c) => [c.name, String(c.value).toUpperCase()]));
  const dv = Object.fromEntries(dark.color.map((c) => [c.name, String(c.value).toUpperCase()]));
  for (const key of Object.keys(baseEffort)) {
    assert.equal(bv[key], baseEffort[key], `base ${key}（日间浅面）`);
    assert.equal(dv[key], darkEffort[key], `dark ${key}（夜间暗舱）`);
  }
  assert.ok(bk.includes('violet') && bk.includes('pink'), '缺少既有 violet/pink');
  console.log('  证据：64 键，effort_* base 浅面 / dark 暗舱两套精确值；violet/pink 保留');
});

test('纪律：v3.6 改动文件无硬编码色值/教学文案；@Builder 按值传状态仍为 0', () => {
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
  for (const file of files) {
    assert.ok(!/@Builder\s+vendorCard\s*\(/.test(read(file)), `${path.relative(CHAT_ETS, file)} 出现按值传参 @Builder vendorCard`);
  }
  console.log(`  证据：${files.length} 个 UI 文件 0 硬编码色值（LanEditorServer 模板豁免）/0 教学文案/@Builder 按值传参 0`);
});

summarize();
