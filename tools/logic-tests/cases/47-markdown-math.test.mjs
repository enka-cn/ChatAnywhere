/**
 * Markdown 公式与分块（chat/components/MarkdownParser.ets，v3.7）
 *
 * 覆盖：块级 `$$...$$` / `\[...\]`（含跨行/未闭合容错）、`\begin{align}`→`aligned` 归一化、
 * 代码围栏内不解析、表格单元格保持文本、复杂行内公式独占成块提升、普通 `$x$` 行内 span、
 * 金额 `$5` 不误伤、块 id/signature 稳定（流式追加历史块冻结）、块间距规则。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'chat/src/main/ets/components/MarkdownParser.ts';
const m = await tryImport(P);

if (!m || !m.splitBlocks) {
  skip('Markdown 公式/分块（全部用例）', missingReason(P));
  summarize();
} else {
  const { splitBlocks, parseInline, normalizeMathBody, blockSpacing } = m;

  test('块级公式：单行 $$...$$ 解析为 math 块（code 去标记）', () => {
    const blocks = splitBlocks('$$\\frac{a}{b}$$');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'math');
    assert.equal(blocks[0].code, '\\frac{a}{b}');
    assert.equal(blocks[0].id, 'math_0');
  });

  test('块级公式：\\[...\\] 同样解析；跨行 $$…$$ 完整收集', () => {
    const bracket = splitBlocks('\\[x^2 + y^2\\]');
    assert.equal(bracket.length, 1);
    assert.equal(bracket[0].kind, 'math');
    assert.equal(bracket[0].code, 'x^2 + y^2');

    const multi = splitBlocks('$$\na + b\nc + d\n$$');
    assert.equal(multi.length, 1);
    assert.equal(multi[0].kind, 'math');
    assert.equal(multi[0].code, 'a + b\nc + d');
  });

  test('未闭合块级公式：按当前已知内容成块，不抛错', () => {
    const blocks = splitBlocks('$$\na + b');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'math');
    assert.equal(blocks[0].code, 'a + b');
  });

  test('align 归一化：\\begin{align} / align* → aligned（normalizeMathBody 与块解析同源）', () => {
    assert.equal(normalizeMathBody('\\begin{align} a &= b \\end{align}'),
      '\\begin{aligned} a &= b \\end{aligned}');
    assert.equal(normalizeMathBody('\\begin{align*} x \\end{align*}'),
      '\\begin{aligned} x \\end{aligned}');
    const blocks = splitBlocks('$$\\begin{align} a &= b \\\\ c &= d \\end{align}$$');
    assert.equal(blocks[0].kind, 'math');
    assert.ok(blocks[0].code.includes('\\begin{aligned}'), '块解析未归一化为 aligned');
    assert.ok(!blocks[0].code.includes('\\begin{align}'), '仍残留 align 环境');
  });

  test('代码围栏内不解析公式：整段保留为 code 块', () => {
    const blocks = splitBlocks('```python\n$$x$$\n\n\\[y\\]\n```');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'code');
    assert.equal(blocks[0].language, 'python');
    assert.ok(blocks[0].code.includes('$$x$$'), '围栏内公式被误解析');
    assert.ok(blocks[0].code.includes('\\[y\\]'), '围栏内 \\[ 被误解析');
  });

  test('表格单元格公式保持文本（不生成 math 块）', () => {
    const blocks = splitBlocks('| 公式 | 值 |\n| --- | --- |\n| $x$ | 1 |');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'table');
    assert.equal(blocks[0].rows.length, 2);
    assert.deepEqual(blocks[0].rows[1], ['$x$', '1']);
  });

  test('复杂行内公式独占成行时提升为 math 块，两侧文字仍是段落', () => {
    for (const body of ['\\frac{1}{2}', '\\sum_{i=1}^n i', '\\int_0^1 x', '\\sqrt{2}']) {
      const blocks = splitBlocks(`前文\n$${body}$\n后文`);
      assert.equal(blocks.length, 3, `${body} 块数 ${blocks.length}`);
      assert.equal(blocks[0].kind, 'paragraph');
      assert.equal(blocks[0].text, '前文');
      assert.equal(blocks[1].kind, 'math');
      assert.equal(blocks[1].code, body);
      assert.equal(blocks[2].kind, 'paragraph');
      assert.equal(blocks[2].text, '后文');
    }
  });

  test('普通行内公式：$x$ 生成 math span；不独占成段的简单公式不提升为块', () => {
    const spans = parseInline('质能方程 $E = mc^2$ 很简洁');
    assert.equal(spans.length, 3, JSON.stringify(spans));
    assert.equal(spans[1].kind, 'math');
    assert.equal(spans[1].text, 'E = mc^2');
    const blocks = splitBlocks('这是 $x$ 公式');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'paragraph');
  });

  test('金额 $5 不误伤：无收尾 $ 保持纯文本', () => {
    const spans = parseInline('价格 $5 元');
    assert.ok(spans.every((s) => s.kind === 'text'), JSON.stringify(spans));
    assert.equal(spans.map((s) => s.text).join(''), '价格 $5 元');
    // 转义 \$ 也保留为普通字符
    const escaped = parseInline('价格 \\$5 元');
    assert.ok(escaped.every((s) => s.kind === 'text'));
    assert.equal(escaped.map((s) => s.text).join(''), '价格 $5 元');
  });

  test('转义与 \(\\) 行内公式', () => {
    const spans = parseInline('公式 \\(a+b\\) 结束');
    assert.equal(spans.length, 3);
    assert.equal(spans[1].kind, 'math');
    assert.equal(spans[1].text, 'a+b');
  });

  test('id/signature 稳定：同输入两次一致；流式追加不改变历史块签名', () => {
    const text = '第一段\n\n## 标题\n\n$$\np+q\n$$';
    const a = splitBlocks(text);
    const b = splitBlocks(text);
    assert.deepEqual(a.map((x) => x.id), b.map((x) => x.id));
    assert.deepEqual(a.map((x) => x.signature), b.map((x) => x.signature));

    const grown = splitBlocks(text + '\n\n新增段落');
    for (let i = 0; i < a.length; i++) {
      assert.equal(grown[i].id, a[i].id, `第 ${i} 块 id 漂移`);
      assert.equal(grown[i].signature, a[i].signature, `第 ${i} 块 signature 漂移`);
    }
    assert.equal(grown.length, a.length + 1);
  });

  test('块间距规则：heading 8 / 列表 6 / code·table·math 10 / 段落 6', () => {
    assert.equal(blockSpacing('heading'), 8);
    assert.equal(blockSpacing('ulist'), 6);
    assert.equal(blockSpacing('olist'), 6);
    assert.equal(blockSpacing('code'), 10);
    assert.equal(blockSpacing('table'), 10);
    assert.equal(blockSpacing('math'), 10);
    assert.equal(blockSpacing('paragraph'), 6);
  });

  test('空输入 / 无公式文本：不产生 math 块', () => {
    assert.deepEqual(splitBlocks(''), []);
    const blocks = splitBlocks('普通文本\n\n- 列表项');
    assert.ok(blocks.every((b) => b.kind !== 'math'));
    assert.equal(blocks[0].kind, 'paragraph');
    assert.equal(blocks[1].kind, 'ulist');
  });

  summarize();
}
