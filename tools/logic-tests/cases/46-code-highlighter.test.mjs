/**
 * 原生代码高亮（chat/components/CodeHighlighter.ets，v3.7）
 *
 * 核心不变量：`tokens.map(t => t.text).join('') === code`（空白/缩进/符号零丢失）。
 * 覆盖 7 语言族（cpp/ts/python/json/bash/sql/yaml）保真、8 类 token 命中、未知语言整段 plain、
 * 未闭合字符串/注释容错。为静态渲染（CodeBlockView）提供可上色的 CodeToken。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'chat/src/main/ets/components/CodeHighlighter.ts';
const m = await tryImport(P);

if (!m || !m.highlightCode) {
  skip('代码高亮（全部用例）', missingReason(P));
  summarize();
} else {
  const { highlightCode } = m;
  const join = (tokens) => tokens.map((t) => t.text).join('');
  const kindsOf = (tokens) => new Set(tokens.map((t) => t.kind));

  const SAMPLES = {
    cpp: '#include <vector>\n// 计算\nint main() {\n  const char* msg = "hi";\n  std::vector<int> v = {1, 2};\n  return 0;\n}\n',
    ts: 'const count: number = 42;\nfunction add(a: number): number {\n  return a + 1;\n}\n',
    python: 'def greet(name):\n    # 注释\n    return "hi " + name\n\nprint(greet("x"))\n',
    json: '{\n  "name": "demo",\n  "enabled": true,\n  "count": 5\n}\n',
    bash: '#!/bin/bash\n# 注释\necho "hello"\nls -la | grep x\n',
    sql: 'SELECT id, name FROM users WHERE id = 5;\n-- 注释\nINSERT INTO t VALUES (1, \'a\');\n',
    yaml: 'name: demo\nenabled: true\n# 注释\nitems:\n  - one\n'
  };

  test('保真：7 语言族 token 拼接后与源码完全一致（空白/缩进/符号零丢失）', () => {
    for (const [lang, code] of Object.entries(SAMPLES)) {
      const tokens = highlightCode(code, lang);
      assert.ok(tokens.length > 0, `${lang} 无 token`);
      assert.equal(join(tokens), code, `${lang} 拼接不保真`);
    }
    // 语言别名与大小写
    for (const alias of ['c++', 'C', '.hpp', 'PYTHON', 'py', 'TypeScript', 'arkts', 'sh', 'zsh', 'yml', 'MySQL', 'sqlite']) {
      const code = SAMPLES.cpp;
      assert.equal(join(highlightCode(code, alias)), code, `别名 ${alias} 不保真`);
    }
  });

  test('8 类 token 命中：keyword/type/string/number/comment/macro/function/plain', () => {
    const cppKinds = kindsOf(highlightCode(SAMPLES.cpp, 'cpp'));
    for (const kind of ['keyword', 'type', 'string', 'number', 'comment', 'macro', 'function', 'plain']) {
      assert.ok(cppKinds.has(kind), `C++ 样本缺少 token 类 ${kind}（实际 ${[...cppKinds].join(',')}）`);
    }
    const pyKinds = kindsOf(highlightCode(SAMPLES.python, 'python'));
    for (const kind of ['keyword', 'string', 'comment', 'function']) {
      assert.ok(pyKinds.has(kind), `Python 样本缺少 token 类 ${kind}`);
    }
    const sqlKinds = kindsOf(highlightCode(SAMPLES.sql, 'sql'));
    assert.ok(sqlKinds.has('keyword'), 'SQL 样本缺少 keyword');
    assert.ok(sqlKinds.has('comment'), 'SQL 样本缺少 comment');
  });

  test('未知语言：整段 plain 单 token，不误判、不抛错', () => {
    const code = 'some <unknown> { code } // 原样\n第二行';
    const tokens = highlightCode(code, 'brainfuck');
    assert.equal(tokens.length, 1);
    assert.equal(tokens[0].kind, 'plain');
    assert.equal(tokens[0].text, code);
    // 空语言 / null / 空串
    assert.equal(highlightCode('abc', '').length, 1);
    assert.deepEqual(highlightCode('', 'cpp'), []);
    assert.deepEqual(highlightCode(null, 'cpp'), []);
    assert.deepEqual(highlightCode(undefined, 'cpp'), []);
  });

  test('容错：未闭合字符串/注释按已知内容收尾，保真且不抛错', () => {
    for (const code of ['int x = "未闭合\n第二行', '// 没有结尾的注释', '/* 块注释没有闭合', 'def f(:\n    pass']) {
      const tokens = highlightCode(code, 'cpp');
      assert.equal(join(tokens), code, '容错路径拼接不保真');
    }
    const py = highlightCode('s = "未闭合', 'python');
    assert.equal(join(py), 's = "未闭合');
  });

  test('token 结构稳定：kind 合法、text 非空、相邻同类已合并', () => {
    const allowed = new Set(['keyword', 'type', 'string', 'number', 'comment', 'macro', 'function', 'plain']);
    for (const [lang, code] of Object.entries(SAMPLES)) {
      const tokens = highlightCode(code, lang);
      for (const one of tokens) {
        assert.ok(allowed.has(one.kind), `${lang} 非法 kind ${one.kind}`);
        assert.ok(one.text.length > 0, `${lang} 出现空 text token`);
      }
      for (let i = 1; i < tokens.length; i++) {
        assert.notEqual(tokens[i].kind, tokens[i - 1].kind, `${lang} 相邻同类未合并`);
      }
    }
  });

  summarize();
}
