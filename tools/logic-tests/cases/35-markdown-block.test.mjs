/**
 * 块级增量 Markdown 解析（chat/components/MarkdownParser.ets，经 MarkdownBlock.ets 再导出）
 *
 * QA 清单要求：Markdown 块级分块。重点验证「流式追加时历史块 id+signature 不变」
 * （历史已闭合块冻结复用、只刷新末尾活跃块，是 Blueprint §1 硬性红线的实现基础）。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'chat/src/main/ets/components/MarkdownParser.ts';
const m = await tryImport(P);

if (!m) {
  skip('Markdown 分块（全部用例）', missingReason(P));
  summarize();
} else {
  const kinds = (blocks) => blocks.map((b) => b.kind);

  // ---------------- parseInline ----------------
  test('parseInline：纯文本返回单个 text 片段', () => {
    assert.deepEqual(m.parseInline('普通文字'), [{ kind: 'text', text: '普通文字' }]);
  });

  test('parseInline：粗体 **xxx**', () => {
    const spans = m.parseInline('这是**加粗**文字');
    assert.deepEqual(spans.map((s) => s.kind), ['text', 'bold', 'text']);
    assert.equal(spans[1].text, '加粗');
  });

  test('parseInline：斜体 *xxx* 与 _xxx_', () => {
    assert.equal(m.parseInline('*斜体*')[0].kind, 'italic');
    assert.equal(m.parseInline('*斜体*')[0].text, '斜体');
    assert.equal(m.parseInline('_斜体_')[0].kind, 'italic');
  });

  test('parseInline：行内代码 `xxx`（代码里的 * 不当作粗体）', () => {
    const spans = m.parseInline('用 `a * b` 表示');
    const code = spans.find((s) => s.kind === 'code');
    assert.ok(code);
    assert.equal(code.text, 'a * b');
  });

  test('parseInline：链接 [标题](url) 带 label 与 url', () => {
    const spans = m.parseInline('看[文档](https://example.com/a)吧');
    assert.deepEqual(spans.map((s) => s.kind), ['text', 'link', 'text']);
    assert.equal(spans[1].text, '文档');
    assert.equal(spans[1].url, 'https://example.com/a');
  });

  test('parseInline：混合行内语法顺序正确', () => {
    const spans = m.parseInline('A**B**C`D`E[F](u)G');
    assert.deepEqual(spans.map((s) => s.kind), ['text', 'bold', 'text', 'code', 'text', 'link', 'text']);
  });

  test('parseInline：未闭合标记原样保留为文本', () => {
    const spans = m.parseInline('**未闭合');
    assert.equal(spans.length, 1);
    assert.equal(spans[0].kind, 'text');
    assert.equal(spans[0].text, '**未闭合');
  });

  test('parseInline：空串 / null 返回空片段数组', () => {
    assert.deepEqual(m.parseInline(''), []);
    assert.deepEqual(m.parseInline(null), []);
  });

  // ---------------- splitBlocks ----------------
  test('splitBlocks：空文本返回空块数组', () => {
    assert.deepEqual(m.splitBlocks(''), []);
    assert.deepEqual(m.splitBlocks(null), []);
  });

  test('splitBlocks：普通段落', () => {
    const blocks = m.splitBlocks('你好，世界');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'paragraph');
    assert.equal(blocks[0].text, '你好，世界');
    assert.equal(blocks[0].id, 'paragraph_0');
  });

  test('splitBlocks：多级标题（1-6 级；7 个 # 不算标题）', () => {
    assert.equal(m.splitBlocks('# 一级')[0].level, 1);
    assert.equal(m.splitBlocks('### 三级')[0].level, 3);
    const tooDeep = m.splitBlocks('####### 七级');
    assert.equal(tooDeep[0].kind, 'paragraph');
  });

  test('splitBlocks：带语言的代码围栏', () => {
    const blocks = m.splitBlocks('```ts\nconst a = 1;\nconst b = 2;\n```');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'code');
    assert.equal(blocks[0].language, 'ts');
    assert.equal(blocks[0].code, 'const a = 1;\nconst b = 2;');
  });

  test('splitBlocks：流式尾部未闭合代码围栏按当前已知内容成块', () => {
    const blocks = m.splitBlocks('```python\nprint(1)');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'code');
    assert.equal(blocks[0].language, 'python');
    assert.equal(blocks[0].code, 'print(1)');
  });

  test('splitBlocks：无序列表合并为单个 ulist 块', () => {
    const blocks = m.splitBlocks('- 第一项\n- 第二项\n- 第三项');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'ulist');
    assert.deepEqual(blocks[0].lines, ['第一项', '第二项', '第三项']);
  });

  test('splitBlocks：有序列表（支持 1. 与 1) 两种写法）', () => {
    const blocks = m.splitBlocks('1. 甲\n2) 乙');
    assert.equal(blocks[0].kind, 'olist');
    assert.deepEqual(blocks[0].lines, ['甲', '乙']);
  });

  test('splitBlocks：引用块连续行合并', () => {
    const blocks = m.splitBlocks('> 第一行引用\n> 第二行引用');
    assert.equal(blocks[0].kind, 'quote');
    assert.equal(blocks[0].text, '第一行引用\n第二行引用');
  });

  test('splitBlocks：水平分割线', () => {
    assert.equal(m.splitBlocks('---')[0].kind, 'divider');
    assert.equal(m.splitBlocks('***')[0].kind, 'divider');
  });

  test('splitBlocks：表格（分隔行不入表）', () => {
    const blocks = m.splitBlocks('| 名称 | 数量 |\n|---|---|\n| 苹果 | 3 |');
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].kind, 'table');
    assert.equal(blocks[0].rows.length, 2);
    assert.deepEqual(blocks[0].rows[0], ['名称', '数量']);
    assert.deepEqual(blocks[0].rows[1], ['苹果', '3']);
  });

  test('splitBlocks：混合文档的块顺序', () => {
    const md = '# 标题\n\n第一段\n\n- 列表 A\n- 列表 B\n\n```js\ncode()\n```\n\n> 引用\n\n---';
    const blocks = m.splitBlocks(md);
    assert.deepEqual(kinds(blocks), ['heading', 'paragraph', 'ulist', 'code', 'quote', 'divider']);
  });

  test('splitBlocks：CRLF / CR 统一归一化', () => {
    const blocks = m.splitBlocks('第一段\r\n\r\n第二段\r第三段');
    // 归一化后为「第一段\n\n第二段\n第三段」：中间没有空行，第二三段属于同一段落
    assert.deepEqual(blocks.map((b) => b.kind), ['paragraph', 'paragraph']);
    assert.equal(blocks[0].text, '第一段');
    assert.equal(blocks[1].text, '第二段\n第三段');
  });

  test('splitBlocks：段落遇到下一块起始标记即停止', () => {
    const blocks = m.splitBlocks('正文\n# 紧接的标题');
    assert.deepEqual(kinds(blocks), ['paragraph', 'heading']);
    assert.equal(blocks[0].text, '正文');
  });

  // ---------------- 流式冻结的关键：签名稳定 ----------------
  test('splitBlocks：内容相同的两次解析 id 与 signature 完全一致', () => {
    const a = m.splitBlocks('# 标题\n\n正文内容');
    const b = m.splitBlocks('# 标题\n\n正文内容');
    assert.deepEqual(a.map((x) => `${x.id}|${x.signature}`), b.map((x) => `${x.id}|${x.signature}`));
  });

  test('splitBlocks：流式追加新内容时，历史块 id/signature 不变（历史块冻结复用）', () => {
    const before = m.splitBlocks('# 标题\n\n第一段已完成');
    const after = m.splitBlocks('# 标题\n\n第一段已完成\n\n第二段正在流式输出中');
    assert.equal(after.length, before.length + 1);
    for (let i = 0; i < before.length; i += 1) {
      assert.equal(after[i].id, before[i].id);
      assert.equal(after[i].signature, before[i].signature);
    }
  });

  test('splitBlocks：块内容变化时 signature 变化（UI 据此重绘活跃块）', () => {
    assert.notEqual(m.splitBlocks('内容 A')[0].signature, m.splitBlocks('内容 B')[0].signature);
  });

  test('blockSpacing：标题 8 / 列表 6 / 代码与表格 10 / 段落 6', () => {
    assert.equal(m.blockSpacing('heading'), 8);
    assert.equal(m.blockSpacing('ulist'), 6);
    assert.equal(m.blockSpacing('olist'), 6);
    assert.equal(m.blockSpacing('code'), 10);
    assert.equal(m.blockSpacing('table'), 10);
    assert.equal(m.blockSpacing('paragraph'), 6);
  });

  summarize();
}
