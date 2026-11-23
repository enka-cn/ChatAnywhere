/**
 * CodeHighlighter：零 WebView 的纯 ArkTS 多语言词法高亮器（v3.7）。
 *
 * - 保真：`tokens.map(t => t.text).join('') === code`（空白/缩进/符号一个不丢）；
 * - 零依赖：不 import 任何 @kit/@ohos，纯函数，可被 Node 直接跑；
 * - 容错：未知语言整段 plain 不抛错；未闭合字符串/注释按到行尾或文末处理。
 * 消费方：components/CodeBlockView 按 CodeToken.kind 上色即可。
 */

/** Token 种类（8 类，UI 按此映射主题色）。 */
export type CodeTokenKind = 'keyword' | 'type' | 'string' | 'number' | 'comment' | 'macro' | 'function' | 'plain';

/** 一个词法 Token。 */
export interface CodeToken {
  kind: CodeTokenKind;
  text: string;
}

/** 内部语言族（同族共享词法规则）。 */
type LangFamily = 'cpp' | 'ts' | 'python' | 'json' | 'bash' | 'sql' | 'yaml' | 'unknown';

const CPP_KEYWORDS: string[] = ('if else for while do switch case default break continue return goto sizeof typedef struct union enum class namespace using template typename public private protected virtual override final const constexpr static extern inline volatile mutable explicit friend operator new delete try catch throw this nullptr true false auto register noexcept static_assert alignof decltype thread_local co_await co_return co_yield concept requires and or not').split(' ');
const CPP_TYPES: string[] = ('void bool char short int long float double signed unsigned wchar_t size_t ssize_t ptrdiff_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t uintptr_t intptr_t string vector map unordered_map set unordered_set pair tuple shared_ptr unique_ptr weak_ptr optional variant string_view span array deque list queue stack function atomic mutex thread chrono ostream istream fstream stringstream allocator iterator const_iterator').split(' ');
const TS_KEYWORDS: string[] = ('if else for while do switch case default break continue return throw try catch finally new delete typeof instanceof in of class interface enum namespace module declare export import from as extends implements public private protected readonly static abstract async await yield function let const var this super true false null undefined type keyof infer is asserts satisfies override get set constructor void').split(' ');
const TS_TYPES: string[] = ('string number boolean bigint symbol object never unknown any Array ReadonlyArray Promise Record Partial Required Readonly Pick Omit Exclude Extract ReturnType Parameters Function Date RegExp Error JSON Math Object String Number Boolean Map Set WeakMap WeakSet Symbol BigInt Iterable Iterator Generator').split(' ');
const PY_KEYWORDS: string[] = ('False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls').split(' ');
const PY_TYPES: string[] = ('int float str bool list dict set tuple bytes bytearray complex frozenset object type Any Optional List Dict Set Tuple Union Callable Iterable Iterator Sequence Mapping Self').split(' ');
const JSON_KEYWORDS: string[] = ('true false null').split(' ');
const BASH_KEYWORDS: string[] = ('if then else elif fi for while until do done case esac in function return break continue local export readonly declare unset echo cd source exit set trap shift eval exec wait printf read pwd test true false').split(' ');
const SQL_KEYWORDS: string[] = ('SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER FULL CROSS ON GROUP BY ORDER HAVING LIMIT OFFSET INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE INDEX VIEW DROP ALTER ADD COLUMN PRIMARY KEY FOREIGN REFERENCES UNIQUE NOT NULL AND OR IN IS LIKE BETWEEN EXISTS CASE WHEN THEN ELSE END AS DISTINCT UNION ALL WITH ASC DESC COUNT SUM AVG MIN MAX COALESCE CAST').split(' ');
const SQL_TYPES: string[] = ('INT INTEGER BIGINT SMALLINT TEXT VARCHAR CHAR BOOLEAN BOOL DATE TIMESTAMP TIME NUMERIC DECIMAL FLOAT DOUBLE REAL BLOB JSON UUID SERIAL').split(' ');
const YAML_KEYWORDS: string[] = ('true false null yes no on off').split(' ');

/** 累加 Token（相邻同类合并，减少 span 数量）。 */
class TokenSink {
  readonly tokens: CodeToken[] = [];
  push(kind: CodeTokenKind, text: string): void {
    if (text.length === 0) { return; }
    if (this.tokens.length > 0) {
      const last: CodeToken = this.tokens[this.tokens.length - 1];
      if (last.kind === kind) { last.text = last.text + text; return; }
    }
    const token: CodeToken = { kind: kind, text: text };
    this.tokens.push(token);
  }
}

function contains(list: string[], value: string): boolean {
  for (const one of list) { if (one === value) { return true; } }
  return false;
}

/** 语言名规范化（去 `.`、大小写不敏感、常见别名）。 */
function normalizeLanguage(language: string): LangFamily {
  if (language === null || language === undefined) { return 'unknown'; }
  let key: string = language.trim().toLowerCase();
  if (key.startsWith('.')) { key = key.substring(1); }
  switch (key) {
    case 'cpp': case 'c++': case 'c': case 'h': case 'hpp': case 'cc': case 'cxx': return 'cpp';
    case 'ts': case 'typescript': case 'arkts': case 'ets': case 'js': case 'javascript': case 'jsx': case 'tsx': case 'node': return 'ts';
    case 'python': case 'py': case 'python3': return 'python';
    case 'json': case 'jsonc': return 'json';
    case 'bash': case 'sh': case 'shell': case 'shellscript': case 'zsh': case 'console': return 'bash';
    case 'sql': case 'mysql': case 'postgresql': case 'sqlite': return 'sql';
    case 'yaml': case 'yml': return 'yaml';
    default: return 'unknown';
  }
}

function isKeyword(lang: LangFamily, word: string): boolean {
  switch (lang) {
    case 'cpp': return contains(CPP_KEYWORDS, word);
    case 'ts': return contains(TS_KEYWORDS, word);
    case 'python': return contains(PY_KEYWORDS, word);
    case 'json': return contains(JSON_KEYWORDS, word);
    case 'bash': return contains(BASH_KEYWORDS, word);
    case 'sql': return contains(SQL_KEYWORDS, word.toUpperCase());
    case 'yaml': return contains(YAML_KEYWORDS, word.toLowerCase());
    default: return false;
  }
}

function isTypeName(lang: LangFamily, word: string): boolean {
  switch (lang) {
    case 'cpp': return contains(CPP_TYPES, word);
    case 'ts': return contains(TS_TYPES, word);
    case 'python': return contains(PY_TYPES, word);
    case 'sql': return contains(SQL_TYPES, word.toUpperCase());
    default: return false;
  }
}

/** 常见大写开头标识符（TS/Python 的类名、类型参数等）归为 type。 */
function looksLikeTypeName(lang: LangFamily, word: string): boolean {
  if (lang !== 'ts' && lang !== 'python') { return false; }
  if (word.length === 0) { return false; }
  const first: string = word.charAt(0);
  return first !== first.toLowerCase() && first === first.toUpperCase();
}

/** 是否 Python 字符串前缀（r/b/u/f 组合）。 */
function isPyStringPrefix(word: string): boolean {
  return contains(('r u f b br rb fr rf bf fb ur ru').split(' '), word.toLowerCase());
}

function isIdentStart(ch: string): boolean {
  if (ch.length === 0) { return false; }
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch === '_' || ch === '$';
}

function isIdentPart(ch: string): boolean {
  return isIdentStart(ch) || isDigit(ch);
}

function isDigit(ch: string): boolean {
  return ch.length > 0 && ch >= '0' && ch <= '9';
}

function isHexDigit(ch: string): boolean {
  return isDigit(ch) || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
}

function isNumberSuffix(ch: string): boolean {
  return ch === 'f' || ch === 'F' || ch === 'l' || ch === 'L' || ch === 'u' || ch === 'U';
}

function hasSlashLineComment(lang: LangFamily): boolean {
  return lang === 'cpp' || lang === 'ts' || lang === 'sql';
}

function hasBlockComment(lang: LangFamily): boolean {
  return lang === 'cpp' || lang === 'ts' || lang === 'sql';
}

/** 该引号在目标语言里是否字符串起始。 */
function isQuoteStart(lang: LangFamily, ch: string): boolean {
  if (ch === '"') { return true; }
  if (ch === '\'') { return lang !== 'json'; }
  if (ch === '`') { return lang === 'ts' || lang === 'bash'; }
  return false;
}

function isSpaceChar(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\r';
}

/** 从 start 到行尾（不含换行）的结束下标。 */
function scanLineEnd(code: string, start: number): number {
  const n: number = code.length;
  let i: number = start;
  while (i < n && code.charAt(i) !== '\n' && code.charAt(i) !== '\r') { i = i + 1; }
  return i;
}

/** 块注释结束下标（含 `＊/`，未闭合到文末）。 */
function scanBlockCommentEnd(code: string, start: number): number {
  const n: number = code.length;
  let i: number = start + 2;
  while (i + 1 < n) {
    if (code.charAt(i) === '*' && code.charAt(i + 1) === '/') { return i + 2; }
    i = i + 1;
  }
  return n;
}

/** 扫描字符串（Python 三引号 / TS、Bash 反引号跨行 / 转义），返回结束下标。 */
function scanStringEnd(code: string, quoteStart: number, lang: LangFamily): number {
  const n: number = code.length;
  const quote: string = code.charAt(quoteStart);
  if (lang === 'python' && (quote === '"' || quote === '\'')) {
    if (quoteStart + 2 < n && code.charAt(quoteStart + 1) === quote && code.charAt(quoteStart + 2) === quote) {
      let j: number = quoteStart + 3;
      while (j + 2 < n) {
        if (code.charAt(j) === quote && code.charAt(j + 1) === quote && code.charAt(j + 2) === quote) { return j + 3; }
        j = j + 1;
      }
      return n;
    }
  }
  const multiline: boolean = (lang === 'ts' && quote === '`') || (lang === 'bash' && quote === '`');
  let i: number = quoteStart + 1;
  while (i < n) {
    const ch: string = code.charAt(i);
    if (ch === '\\') { i = i + 2; continue; }
    if (ch === quote) { return i + 1; }
    if (ch === '\n' && !multiline) { return i; }
    i = i + 1;
  }
  return n;
}

/** 扫描数字（整数/小数/十六进制/二进制/八进制/科学计数法 + 后缀）。 */
function scanNumberEnd(code: string, start: number, sink: TokenSink): number {
  const n: number = code.length;
  let i: number = start;
  let hexLike: boolean = false;
  if (code.charAt(i) === '0' && i + 1 < n) {
    const second: string = code.charAt(i + 1).toLowerCase();
    if (second === 'x' || second === 'b' || second === 'o') {
      i = i + 2;
      while (i < n && (isHexDigit(code.charAt(i)) || code.charAt(i) === '_')) { i = i + 1; }
      hexLike = true;
    }
  }
  if (!hexLike) {
    while (i < n && (isDigit(code.charAt(i)) || code.charAt(i) === '_')) { i = i + 1; }
    if (i < n && code.charAt(i) === '.' && i + 1 < n && isDigit(code.charAt(i + 1))) {
      i = i + 1;
      while (i < n && isDigit(code.charAt(i))) { i = i + 1; }
    }
    if (i < n) {
      const exp: string = code.charAt(i);
      if (exp === 'e' || exp === 'E') {
        let k: number = i + 1;
        if (k < n && (code.charAt(k) === '+' || code.charAt(k) === '-')) { k = k + 1; }
        if (k < n && isDigit(code.charAt(k))) {
          i = k;
          while (i < n && isDigit(code.charAt(i))) { i = i + 1; }
        }
      }
    }
  }
  while (i < n && isNumberSuffix(code.charAt(i))) { i = i + 1; }
  sink.push('number', code.substring(start, i));
  return i;
}

/** 文本之后是否处在新行行首（仅空白）——块注释/多行字符串后恢复行首状态。 */
function atLineStartAfter(text: string): boolean {
  const index: number = text.lastIndexOf('\n');
  if (index < 0) { return false; }
  return text.substring(index + 1).trim().length === 0;
}

/** 扫描标识符并分类（关键字 / 函数 / 类型 / 普通），返回结束下标。 */
function scanIdentifierEnd(code: string, start: number, lang: LangFamily, sink: TokenSink): number {
  const n: number = code.length;
  let i: number = start;
  while (i < n && isIdentPart(code.charAt(i))) { i = i + 1; }
  const word: string = code.substring(start, i);
  if (lang === 'python' && i < n && isQuoteStart(lang, code.charAt(i)) && isPyStringPrefix(word)) {
    const end: number = scanStringEnd(code, i, lang);
    sink.push('string', code.substring(start, end));
    return end;
  }
  if (isKeyword(lang, word)) { sink.push('keyword', word); return i; }
  let k: number = i;
  while (k < n && (code.charAt(k) === ' ' || code.charAt(k) === '\t')) { k = k + 1; }
  if (k < n && code.charAt(k) === '(') { sink.push('function', word); return i; }
  if (isTypeName(lang, word) || looksLikeTypeName(lang, word)) { sink.push('type', word); return i; }
  sink.push('plain', word);
  return i;
}

/** 扫描装饰器 `@xxx.yyy`，返回结束下标。 */
function scanDecoratorEnd(code: string, start: number): number {
  const n: number = code.length;
  let i: number = start + 1;
  while (i < n && (isIdentPart(code.charAt(i)) || code.charAt(i) === '.')) { i = i + 1; }
  return i;
}

/** 主扫描循环。 */
function lex(code: string, lang: LangFamily, sink: TokenSink): void {
  const n: number = code.length;
  let i: number = 0;
  let lineStart: boolean = true;
  while (i < n) {
    const ch: string = code.charAt(i);
    if (ch === '\n') { sink.push('plain', ch); i = i + 1; lineStart = true; continue; }
    if (isSpaceChar(ch)) { sink.push('plain', ch); i = i + 1; continue; }
    // C/C++ 预处理指令：整行 macro
    if (lineStart && ch === '#' && lang === 'cpp') {
      const end: number = scanLineEnd(code, i);
      sink.push('macro', code.substring(i, end));
      i = end;
      lineStart = false;
      continue;
    }
    // 装饰器：@Component / @app.route / @decorator
    if (ch === '@' && (lang === 'ts' || lang === 'python')) {
      const end: number = scanDecoratorEnd(code, i);
      sink.push('macro', code.substring(i, end));
      i = end;
      lineStart = false;
      continue;
    }
    if (ch === '/' && i + 1 < n && code.charAt(i + 1) === '/' && hasSlashLineComment(lang)) {
      const end: number = scanLineEnd(code, i);
      sink.push('comment', code.substring(i, end));
      i = end;
      lineStart = false;
      continue;
    }
    if (ch === '/' && i + 1 < n && code.charAt(i + 1) === '*' && hasBlockComment(lang)) {
      const end: number = scanBlockCommentEnd(code, i);
      const text: string = code.substring(i, end);
      sink.push('comment', text);
      i = end;
      lineStart = atLineStartAfter(text);
      continue;
    }
    // `#` 注释：python 任意位置；bash/yaml 需在行首或空白后
    if (ch === '#') {
      const hashComment: boolean = lang === 'python' ||
        ((lang === 'bash' || lang === 'yaml') && (lineStart || i === 0 || isSpaceChar(code.charAt(i - 1))));
      if (hashComment) {
        const end: number = scanLineEnd(code, i);
        sink.push('comment', code.substring(i, end));
        i = end;
        lineStart = false;
        continue;
      }
    }
    // SQL `--` 行注释
    if (ch === '-' && i + 1 < n && code.charAt(i + 1) === '-' && lang === 'sql') {
      const end: number = scanLineEnd(code, i);
      sink.push('comment', code.substring(i, end));
      i = end;
      lineStart = false;
      continue;
    }
    if (isQuoteStart(lang, ch)) {
      const end: number = scanStringEnd(code, i, lang);
      const text: string = code.substring(i, end);
      sink.push('string', text);
      i = end;
      lineStart = atLineStartAfter(text);
      continue;
    }
    if (isDigit(ch) || (ch === '.' && i + 1 < n && isDigit(code.charAt(i + 1)))) {
      i = scanNumberEnd(code, i, sink);
      lineStart = false;
      continue;
    }
    if (isIdentStart(ch)) {
      i = scanIdentifierEnd(code, i, lang, sink);
      lineStart = false;
      continue;
    }
    sink.push('plain', ch);
    i = i + 1;
    lineStart = false;
  }
}

/**
 * 把一段代码切分为带类别的 Token；保证 `tokens.map(t => t.text).join('') === code`。
 * @param code 原始代码（含缩进/换行）
 * @param language 代码块语言标签（可为空/未知）
 */
export function highlightCode(code: string, language: string): CodeToken[] {
  const sink: TokenSink = new TokenSink();
  if (code === null || code === undefined || code.length === 0) { return sink.tokens; }
  const lang: LangFamily = normalizeLanguage(language);
  if (lang === 'unknown') {
    sink.push('plain', code);
    return sink.tokens;
  }
  lex(code, lang, sink);
  return sink.tokens;
}
