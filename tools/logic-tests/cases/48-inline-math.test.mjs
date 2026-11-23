/**
 * 行内公式 LaTeX→文本映射（chat/components/InlineMath.ets，v3.8 修复回归）
 *
 * v3.8 修复四个真机问题：
 * 1) 命令剥壳不彻底（`\xi`→`ξ`、`\sin`→`sin`、`\frac`→分数）；
 * 2) 上下标顺序错乱（下标 `_{...}` 先转、`^` 后转，避免 `x^4` 被二次处理）；
 * 3) frac 分子/分母为表达式时缺括号（`\frac{a+b}{c}`→`(a+b)/c`）；
 * 4) 独占成行、未加 `$` 的纯 LaTeX 复杂公式未提升为 math 块。
 *
 * 额外不变量：标准函数/格式命令输出**不含反斜杠**；`$x$`/金额 `$5`/转义 `\$`/围栏/表格/align* 回归不破。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const INLINE = 'chat/src/main/ets/components/InlineMath.ts';
const PARSER = 'chat/src/main/ets/components/MarkdownParser.ts';
const im = await tryImport(INLINE);
const mp = await tryImport(PARSER);

if (!im || !im.latexToText || !mp || !mp.splitBlocks) {
  skip('行内公式映射（全部用例）', missingReason(INLINE));
  summarize();
} else {
  const { latexToText } = im;
  const { splitBlocks, parseInline, normalizeMathBody } = mp;
  const noBackslash = (text, label) => {
    assert.ok(text.indexOf('\\') < 0, `${label} 输出仍含反斜杠：${JSON.stringify(text)}`);
  };

  test('v3.8 修复回归：Lead 验证的 5 组输出逐字一致', () => {
    assert.equal(latexToText('e^\\xi>0'), 'e^ξ>0');
    assert.equal(latexToText('\\sin x'), 'sin x');
    assert.equal(latexToText('\\cos x'), 'cos x');
    assert.equal(latexToText('\\tan x'), 'tan x');
    assert.equal(latexToText('\\frac{1}{24}'), '1/24');
    assert.equal(latexToText('\\frac{x^2}{2}'), 'x²/2');
    assert.equal(latexToText('\\frac{a+b}{c}'), '(a+b)/c');
    assert.equal(latexToText('\\left(\\frac{1}{24}-\\frac{1}{8}\\right)'), '(1/24-1/8)');
    assert.equal(latexToText('\\text{速度 }v'), '速度 v');
    console.log('  证据：9 组期望值逐字一致（含 ξ、sin/cos/tan、三种 frac、\\left\\right、\\text 中文）');
  });

  test('复杂公式：lim/frac/上下标全链路 0 反斜杠且顺序正确', () => {
    const input = '\\lim_{x\\to 0}\\frac{\\cos x - e^{-x^2/2}}{x^4}';
    const out = latexToText(input);
    noBackslash(out, '复杂公式');
    assert.equal(out, 'lim_(x→ 0)(cos x - e^(-x²/2))/x⁴');
    assert.ok(out.includes('cos') && out.includes('lim'), '复杂公式缺少函数名');
    assert.ok(!out.includes('^4^'), '上标被二次处理（顺序错误）');
  });

  test('标准函数/格式命令输出不含反斜杠（sin/cos/tan/lim/ln/log/exp/arcsin + 格式命令）', () => {
    const samples = [
      '\\sin x', '\\cos x', '\\tan x', '\\lim_{x\\to 0} x', '\\ln x', '\\log_{2} n',
      '\\exp(x)', '\\arcsin x', '\\text{速度 }v', '\\mathrm{d}x', '\\mathbf{v}',
      '\\left( x \\right)', '\\,', '\\quad'
    ];
    for (const one of samples) {
      const out = latexToText(one);
      noBackslash(out, one);
    }
    assert.equal(latexToText('\\ln x'), 'ln x');
    assert.equal(latexToText('\\log_{2} n'), 'log₂ n');
    assert.equal(latexToText('\\exp(x)'), 'exp(x)');
    assert.equal(latexToText('\\arcsin x'), 'arcsin x');
    assert.equal(latexToText('\\mathrm{d}x'), 'dx');
    assert.equal(latexToText('\\mathbf{v}'), 'v');
    assert.equal(latexToText('\\,'), ' ');
    assert.equal(latexToText('\\quad'), '  ');
    console.log('  证据：14 个函数/格式样本输出均为 0 反斜杠；ln/log₂/exp/arcsin/dx/v/空格映射精确');
  });

  test('splitBlocks：复杂公式提升为单个 math 块；未加 $ 的独占成行纯 LaTeX 也提升', () => {
    for (const big of [
      '\\lim_{x\\to 0}\\frac{\\cos x - e^{-x^2/2}}{x^4}',
      '\\frac{a+b}{c}',
      '\\sum_{i=1}^n i'
    ]) {
      const blocks = splitBlocks(big);
      assert.equal(blocks.length, 1, `${big} 块数 ${blocks.length}`);
      assert.equal(blocks[0].kind, 'math');
      assert.equal(blocks[0].code, big);
      assert.equal(blocks[0].id, 'math_0');
    }
    // 无 $ 的纯 LaTeX 独占成行：文字段落 + math 块
    const mixed = splitBlocks('先算\n$\\frac{a+b}{c}$\n再说');
    assert.equal(mixed.map((b) => b.kind).join(','), 'paragraph,math,paragraph', JSON.stringify(mixed.map((b) => b.kind)));
    // 同一行夹在文字中的 LaTeX 不提升（v3.8 只提升独占成行）
    const inlineMention = splitBlocks('先算\\frac{a+b}{c}再说');
    assert.equal(inlineMention.length, 1);
    assert.equal(inlineMention[0].kind, 'paragraph');
  });

  test('回归：$x$ 行内 math、金额 $5 不误伤、\\$ 转义保持文本', () => {
    const inline = parseInline('质能方程 $E = mc^2$');
    assert.equal(inline.length, 2, JSON.stringify(inline));
    assert.equal(inline[1].kind, 'math');
    assert.equal(inline[1].text, 'E = mc^2');

    const money = parseInline('价格 $5 元');
    assert.ok(money.every((s) => s.kind === 'text'), JSON.stringify(money));
    assert.equal(money.map((s) => s.text).join(''), '价格 $5 元');

    const escaped = parseInline('价格 \\$5 元');
    assert.ok(escaped.every((s) => s.kind === 'text'), JSON.stringify(escaped));
    assert.equal(escaped.map((s) => s.text).join(''), '价格 $5 元');

    const paren = parseInline('公式 \\(a+b\\) 结束');
    assert.equal(paren[1].kind, 'math');
    assert.equal(paren[1].text, 'a+b');
    console.log('  证据：$x$ math span / $5 纯文本 / \\$ 转义 / \\(...\\) 行内全部保持');
  });

  test('回归：代码围栏/表格内公式不解析；align* → aligned 规范化不变', () => {
    const fence = splitBlocks('```text\n$$x$$\n\\frac{a}{b}\n```');
    assert.equal(fence.length, 1);
    assert.equal(fence[0].kind, 'code');
    assert.ok(fence[0].code.includes('$$x$$'), '围栏内公式被误解析');

    const table = splitBlocks('| 公式 | 值 |\n| --- | --- |\n| $x$ | 1 |');
    assert.equal(table[0].kind, 'table');
    assert.deepEqual(table[0].rows[1], ['$x$', '1']);

    assert.equal(normalizeMathBody('\\begin{align*} a &= b \\end{align*}'),
      '\\begin{aligned} a &= b \\end{aligned}');
    const aligned = splitBlocks('$$\\begin{align} a &= b \\\\ c &= d \\end{align}$$');
    assert.equal(aligned[0].kind, 'math');
    assert.ok(aligned[0].code.includes('\\begin{aligned}'), 'align 未归一化为 aligned');
    console.log('  证据：围栏/表格不解析公式；align*→aligned 规范化回归通过');
  });

  test('稳定与边界：空串、纯文本、重复调用结果一致', () => {
    assert.equal(latexToText(''), '');
    assert.equal(latexToText('普通文字'), '普通文字');
    for (const one of ['e^\\xi>0', '\\frac{1}{24}', '\\lim_{x\\to 0} x']) {
      assert.equal(latexToText(one), latexToText(one), `${one} 重复调用不一致`);
    }
    const a = splitBlocks('\\frac{a+b}{c}');
    const b = splitBlocks('\\frac{a+b}{c}');
    assert.deepEqual(a.map((x) => [x.id, x.signature]), b.map((x) => [x.id, x.signature]));
    console.log('  证据：空串/纯文本/重复调用一致，math 块 id+signature 稳定');
  });

  summarize();
}
