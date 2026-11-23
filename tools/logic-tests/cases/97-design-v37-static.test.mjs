/**
 * v3.7 富文本渲染升级静态门禁（Markdown 排版 / 原生代码高亮 / 离线 LaTeX 公式）
 *
 * 交付面：
 * 1) `MarkdownBlock.ets`：列表 5×5 圆点 + 行高居中、有序行高、间距 6、链接 http 校验、长按划选
 *    `copyOption(LocalDevice)`、标题 margin 10/2、接入 CodeBlockView/MathBlock；无 BREAK_ALL 单 Text 拼代码；
 * 2) `CodeHighlighter.ets` + `CodeBlockView.ets`：零依赖 8 类 token、7 语言族保真、横向 Scroll + 复制反馈 1.5s；
 * 3) `MarkdownParser.ets` + `InlineMath.ets` + `MathBlock.ets` + `PromptPresets.ets` + rawfile/katex：
 *    math 块/行内、align→aligned、离线 KaTeX Web 高度自适应 + 3s 降级、提示词 LaTeX 约定。
 * 颜色：v3.7 base/dark 各 **64 键**（新增 12 个 code/math 令牌，两套精确值）。
 */
import { test, assert, summarize } from './_harness.mjs';
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyCodeMathColors } from './_theme.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..', '..');
const CHAT_ETS = path.join(REPO, 'chat', 'src', 'main', 'ets');
const RES = path.join(REPO, 'chat', 'src', 'main', 'resources');
const RAWFILE = path.join(RES, 'rawfile', 'katex');
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

// ---------------------------------------------------------------------------
// 1) MarkdownBlock 排版修复
// ---------------------------------------------------------------------------
test('MarkdownBlock 排版：列表 5×5 圆点 + 行高居中、有序行高、间距 6、链接校验、长按划选、标题间距、接入代码/公式组件', () => {
  const p = path.join(CHAT_ETS, 'components', 'MarkdownBlock.ets');
  assert.ok(exists(p), '缺少 MarkdownBlock.ets');
  const text = read(p);
  // 无序列表圆点 5×5 + 行高容器居中
  assert.ok(/Circle\(\{\s*width:\s*5,\s*height:\s*5\s*\}\)/.test(text), '列表圆点不是 5×5');
  assert.ok(/\.width\(Layout\.s5\)[\s\S]{0,200}?\.height\(Layout\.lineChat\)[\s\S]{0,200}?\.justifyContent\(FlexAlign\.Center\)/.test(text),
    '列表圆点容器缺少 height(Layout.lineChat) + justifyContent(Center)');
  // 有序列表行高
  assert.ok(count(text, /lineHeight\(Layout\.lineChat\)/g) >= 1, '正文/列表缺少 lineHeight(Layout.lineChat)');
  // 列表项间距 6
  assert.ok(/const LIST_GAP: number = 6/.test(text), '列表项间距不是 6');
  // 链接：onClick + http/https 校验
  assert.ok(text.includes("startsWith('http://')") && text.includes("startsWith('https://')"), '缺少 http/https 校验');
  assert.ok(/\.onClick\(\(\)\s*=>\s*\{[\s\S]{0,120}?openLink\(/.test(text), '链接 span 缺少 onClick');
  // 长按划选复制
  assert.ok(count(text, /copyOption\(CopyOptions\.LocalDevice\)/g) >= 1, '缺少 copyOption(CopyOptions.LocalDevice)');
  // 标题间距 10/2
  assert.ok(/\.margin\(\{\s*top:\s*10,\s*bottom:\s*2\s*\}\)/.test(text), 'headingBlock 缺少 margin 10/2');
  // 接入代码块 / 公式块
  assert.ok(text.includes('CodeBlockView('), '未接入 CodeBlockView');
  assert.ok(text.includes('MathBlock('), '未接入 MathBlock');
  // 旧 bug 不回退：无 BREAK_ALL、无单 Text(block.code)
  assert.ok(!text.includes('WordBreak.BREAK_ALL'), '仍存在 WordBreak.BREAK_ALL');
  assert.ok(!/Text\(block\.code\)/.test(text), '仍用单个 Text(block.code) 渲染代码');
  console.log('  证据：5×5 圆点 + lineChat 居中 + 有序行高 + 间距 6 + 链接 http 校验/onClick + copyOption + 标题 margin 10/2 + CodeBlockView/MathBlock；无 BREAK_ALL/单 Text(block.code)');
});

// ---------------------------------------------------------------------------
// 2) 解析器与高亮器纯逻辑
// ---------------------------------------------------------------------------
test('MarkdownParser：math 块/行内类型、$$/\\[/\\( 处理、align→aligned 归一化、signature 字段', () => {
  const p = path.join(CHAT_ETS, 'components', 'MarkdownParser.ets');
  assert.ok(exists(p), '缺少 MarkdownParser.ets');
  const text = read(p);
  assert.ok(/'math'/.test(text), '缺少 math 类型');
  assert.ok(/MdBlockKind[^;]*'math'/.test(text), 'MdBlockKind 未包含 math');
  assert.ok(/InlineKind[^;]*'math'/.test(text), 'InlineKind 未包含 math');
  assert.ok(text.includes('$$'), '缺少 $$ 处理');
  assert.ok(text.includes("startsWith('\\\\[')"), '缺少 \\[ 处理');
  assert.ok(/charAt\(i \+ 1\) === '\('/.test(text), '缺少 \\( 处理');
  assert.ok(/\\begin\{align\*?\}/.test(text) || text.includes('begin{align}'), '缺少 \\begin{align} 处理');
  assert.ok(text.includes('normalizeMathBody'), '缺少 normalizeMathBody');
  assert.ok(text.includes('aligned'), '缺少 align→aligned 归一化');
  assert.ok(text.includes('signature'), '缺少块 signature');
  assert.ok(text.includes('blockSpacing'), '缺少 blockSpacing 规则');
  console.log('  证据：math 块/行内 + $$/\\[/\\( + align→aligned + normalizeMathBody + signature + blockSpacing');
});

test('CodeHighlighter：导出 highlightCode/CodeToken/8 类 kind，7 语言族 + 零依赖', () => {
  const p = path.join(CHAT_ETS, 'components', 'CodeHighlighter.ets');
  assert.ok(exists(p), '缺少 CodeHighlighter.ets');
  const text = read(p);
  assert.ok(text.includes('export function highlightCode('), '缺少 highlightCode');
  assert.ok(text.includes('export interface CodeToken'), '缺少 CodeToken');
  for (const kind of ['keyword', 'type', 'string', 'number', 'comment', 'macro', 'function', 'plain']) {
    assert.ok(text.includes(`'${kind}'`), `缺少 token 类 ${kind}`);
  }
  for (const lang of ['cpp', 'ts', 'python', 'json', 'bash', 'sql', 'yaml']) {
    assert.ok(text.includes(`'${lang}'`), `缺少语言族 ${lang}`);
  }
  assert.ok(!/import\s+[^;]*from\s+['"]@(?:ohos|kit|hms)/.test(text), 'CodeHighlighter 不应 import 平台 kit（需纯逻辑）');
  console.log('  证据：highlightCode/CodeToken/8 类 kind/7 语言族齐全，零平台依赖');
});

// ---------------------------------------------------------------------------
// 3) 代码块渲染（原生高亮 + 复制 + 横向滚动）
// ---------------------------------------------------------------------------
test('CodeBlockView：横向 Scroll + 8 类 Theme 高亮 + 复制反馈 1.5s + 剪贴板 + codeHeaderBg/codeBg', () => {
  const p = path.join(CHAT_ETS, 'components', 'CodeBlockView.ets');
  assert.ok(exists(p), '缺少 CodeBlockView.ets');
  const text = read(p);
  assert.ok(/Scroll\(\)/.test(text), '缺少 Scroll');
  assert.ok(text.includes('ScrollDirection.Horizontal'), '代码块不是横向滚动');
  assert.ok(text.includes('highlightCode('), '未调用 highlightCode');
  assert.ok(text.includes('Icons.copy') && text.includes('Icons.check'), '复制反馈缺少 copy/check 图标');
  assert.ok(/1500|COPIED_HOLD_MS/.test(text), '复制反馈未体现 1.5s 保持');
  assert.ok(/pasteboard|setData\(/.test(text), '缺少剪贴板写入');
  for (const token of ['Theme.codeHeaderBg', 'Theme.codeBg', 'Theme.codePlain', 'Theme.codeKeyword',
    'Theme.codeType', 'Theme.codeFunction', 'Theme.codeMacro', 'Theme.codeComment', 'Theme.codeNumber',
    'Theme.codeString']) {
    assert.ok(text.includes(token), `代码块缺少主题色 ${token}`);
  }
  assert.ok(text.includes('14'), '代码块圆角 14 缺失');
  console.log('  证据：横向 Scroll + highlightCode + copy/check 1.5s + 剪贴板 + 8 类 Theme 高亮 + 圆角 14');
});

// ---------------------------------------------------------------------------
// 4) 公式渲染（离线 KaTeX + 高度自适应 + 降级）
// ---------------------------------------------------------------------------
test('MathBlock：$rawfile(katex/render.html) + javaScriptProxy + runJavaScript + 高度自适应 + 3s 降级源码', () => {
  const p = path.join(CHAT_ETS, 'components', 'MathBlock.ets');
  assert.ok(exists(p), '缺少 MathBlock.ets');
  const text = read(p);
  assert.ok(text.includes("$rawfile('katex/render.html')"), '未加载 rawfile katex/render.html');
  assert.ok(text.includes('javaScriptProxy'), '缺少 javaScriptProxy');
  assert.ok(text.includes('runJavaScript'), '缺少 runJavaScript 注入公式');
  assert.ok(/onRendered|onHeight\(/.test(text), '缺少渲染高度回传');
  assert.ok(/webHeight|\.height\(/.test(text), '缺少高度自适应');
  assert.ok(/fallback|降级|源码/.test(text), '缺少 3s 降级源码显示');
  assert.ok(text.includes('40') && text.includes('4000'), '高度夹取不是 40–4000');
  console.log('  证据：rawfile render.html + javaScriptProxy + runJavaScript + 高度回传/夹取 + 降级源码');
});

test('katex 资源：本地 js/css + ≥20 woff2；render.html 引用本地 katex.min.* + throwOnError:false + kaTexBridge.onRendered', () => {
  assert.ok(exists(RAWFILE), '缺少 resources/rawfile/katex 目录');
  const files = readdirSync(RAWFILE).filter((n) => statSync(path.join(RAWFILE, n)).isFile());
  const fontDir = path.join(RAWFILE, 'fonts');
  const fonts = existsSync(fontDir) ? readdirSync(fontDir).filter((n) => n.endsWith('.woff2')) : [];
  assert.ok(files.includes('katex.min.js'), '缺少 katex.min.js');
  assert.ok(files.includes('katex.min.css'), '缺少 katex.min.css');
  assert.ok(fonts.length >= 20, `woff2 字体 ${fonts.length} < 20`);
  const jsSize = statSync(path.join(RAWFILE, 'katex.min.js')).size;
  assert.ok(jsSize > 200 * 1024, `katex.min.js 体积异常：${jsSize}`);
  const html = read(path.join(RAWFILE, 'render.html'));
  assert.ok(html.includes('katex.min.js') && html.includes('katex.min.css'), 'render.html 未引用本地 katex.min.*');
  assert.ok(html.includes('throwOnError') && html.includes('false'), 'render.html 缺少 throwOnError:false');
  assert.ok(html.includes('kaTexBridge') && html.includes('onRendered'), 'render.html 缺少 kaTexBridge.onRendered 回调');
  const totalKb = [...files.map((n) => statSync(path.join(RAWFILE, n)).size),
    ...fonts.map((n) => statSync(path.join(fontDir, n)).size)].reduce((a, b) => a + b, 0) / 1024;
  console.log(`  证据：katex.min.js ${(jsSize / 1024).toFixed(1)}KB + css + ${fonts.length} woff2（合计 ${totalKb.toFixed(1)}KB）；render.html 本地引用/throwOnError/onRendered 齐全`);
});

// ---------------------------------------------------------------------------
// 5) 行内公式与提示词约定
// ---------------------------------------------------------------------------
test('InlineMath：latexToText + 希腊字母/常见符号映射（纯逻辑）', () => {
  const p = path.join(CHAT_ETS, 'components', 'InlineMath.ets');
  assert.ok(exists(p), '缺少 InlineMath.ets');
  const text = read(p);
  assert.ok(text.includes('export function latexToText('), '缺少 latexToText');
  const greek = [
    ["map.set('alpha', 'α')", 'α'], ["map.set('beta', 'β')", 'β'],
    ["map.set('gamma', 'γ')", 'γ'], ["map.set('theta', 'θ')", 'θ'],
    ["map.set('lambda', 'λ')", 'λ'], ["map.set('pi', 'π')", 'π'],
    ["map.set('sigma', 'σ')", 'σ'], ["map.set('omega', 'ω')", 'ω']
  ];
  for (const [needle, ch] of greek) {
    assert.ok(text.includes(needle), `缺少希腊映射 ${ch}`);
  }
  assert.ok(!/@ohos|@kit|@hms/.test(text), 'InlineMath 不应 import 平台 kit（需纯逻辑可测）');
  console.log('  证据：latexToText + 8 组希腊映射，零平台依赖');
});

test('PromptPresets：BASE_PROMPT 含 LaTeX 约定（行内 $...$、独立 $$...$$）', () => {
  const p = path.join(PKG, 'core_context', 'src', 'main', 'ets', 'PromptPresets.ets');
  assert.ok(exists(p), '缺少 PromptPresets.ets');
  const text = read(p);
  assert.ok(text.includes('LaTeX'), 'BASE_PROMPT 未包含 LaTeX 约定');
  assert.ok(text.includes('$$'), '缺少独立公式 $$ 约定');
  assert.ok(text.includes('$...$'), '缺少行内公式 $...$ 约定');
  console.log('  证据：BASE_PROMPT 末尾 LaTeX 约定（行内 $...$ / 独立 $$...$$）');
});

// ---------------------------------------------------------------------------
// 6) 颜色 64 键 + 纪律
// ---------------------------------------------------------------------------
test('颜色：base/dark 各 64 键且集合一致，12 个 code/math 键两套精确值', () => {
  const load = (mode) => JSON.parse(read(path.join(RES, mode, 'element', 'color.json')));
  const base = load('base');
  const dark = load('dark');
  const bk = base.color.map((c) => c.name);
  const dk = dark.color.map((c) => c.name);
  assert.equal(bk.length, 64, `base 颜色键 ${bk.length} ≠ 64（v3.7：54 + 12 code/math - 去重 2）`);
  assert.equal(dk.length, 64, `dark 颜色键 ${dk.length} ≠ 64`);
  assert.deepEqual([...bk].sort(), [...dk].sort(), '深浅色键集合不一致');
  verifyCodeMathColors(assert, base, dark);
  assert.ok(bk.includes('violet') && bk.includes('pink'), '缺少既有 violet/pink');
  for (const key of ['effort_deck_top', 'effort_deck_bottom', 'effort_track', 'effort_bar_off',
    'effort_text_dim', 'effort_text_bright']) {
    assert.ok(bk.includes(key) && dk.includes(key), `缺少 effort 键 ${key}`);
  }
  console.log('  证据：64 键集合一致，12 个 code/math 两套精确值，violet/pink 与 6 effort_* 保留');
});

test('纪律：硬编码色值仅 render.html 与 LanEditorServer 模板豁免，其余 UI 0；教学文案 0；@Builder 按值传参 0', () => {
  const keywords = ['小提示', '聊两句就', '会先在心里推理', '要不要联网', '问题想多深', '当前构建未启用', '端侧小脚本'];
  const files = walk(CHAT_ETS, /\.(ets|ts)$/);
  const offenders = [];
  for (const file of files) {
    const text = read(file);
    if (/#[0-9A-Fa-f]{6,8}\b/.test(text)) {
      offenders.push(`${path.relative(CHAT_ETS, file)} 含硬编码色值`);
    }
    const hits = keywords.filter((k) => text.includes(k));
    if (hits.length > 0) offenders.push(`${path.relative(CHAT_ETS, file)} 含教学文案 ${hits.join(',')}`);
  }
  // 仅 LanEditorServer.ets（bridge HTML 模板）豁免；render.html 在 resources/rawfile 不在扫描范围
  const allowed = offenders.filter((line) => line.includes('LanEditorServer'));
  const bad = offenders.filter((line) => !line.includes('LanEditorServer'));
  assert.deepEqual(bad, [], bad.join('\n'));
  assert.ok(allowed.length <= 1, 'LanEditorServer 豁免出现异常');
  for (const file of files) {
    assert.ok(!/@Builder\s+vendorCard\s*\(/.test(read(file)), `${path.relative(CHAT_ETS, file)} 出现按值传参 @Builder vendorCard`);
  }
  console.log(`  证据：${files.length} 个 UI 文件仅 LanEditorServer HTML 模板含硬编码色（豁免），其余 0；教学文案 0；@Builder 按值传参 0`);
});

summarize();
