/**
 * 块级增量 Markdown 解析（纯逻辑，零平台依赖，零 import）。
 *
 * 为什么要单独一个文件：`tools/logic-tests/prepare.ps1` 会把名字含 Markdown 的纯逻辑 `.ets`
 * 复制成 `.ts` 用 Node 直接跑；带 ArkUI 装饰器的文件会被跳过。所以解析函数放这里，
 * `MarkdownBlock.ets` 只负责把解析结果渲染成 ArkUI 组件，并原样再导出这两个函数。
 *
 * 设计取舍（对齐 Blueprint §1「块级增量 Markdown」）：
 * - 分块结果带稳定 `id` 与内容 `signature`，UI 用 `id + signature` 做 ForEach key，
 *   历史已闭合块 key 不变 → 不重建；只有末尾正在增长的块会刷新。
 * - 只处理对话里真实会出现的语法：标题、段落、有序/无序列表、引用、代码围栏、表格、分割线，
 *   行内支持 粗体 / 斜体 / 行内代码 / 链接。未闭合的代码围栏按「还在流式输出」处理。
 */

/** 块类型。 */
export type MdBlockKind = 'heading' | 'paragraph' | 'ulist' | 'olist' | 'quote' | 'code' | 'table' | 'divider';

/** 一个块级元素（所有字段都有默认值，避免调用方判空）。 */
export interface MdBlock {
  /** 稳定 id：类型 + 出现序号（同类型顺序不变时历史块 key 不变）。 */
  id: string;
  kind: MdBlockKind;
  /** 标题级别 1..6；引用固定 1；其余 0。 */
  level: number;
  /** 标题 / 段落 / 引用的原始行内 Markdown 文本。 */
  text: string;
  /** 列表项原始行内 Markdown 文本。 */
  lines: string[];
  /** 代码围栏语言标签（可能为空串）。 */
  language: string;
  /** 代码正文。 */
  code: string;
  /** 表格行（每行是单元格原始文本数组）。 */
  rows: string[][];
  /** 内容签名：内容变则变，用于 UI 冻结历史块。 */
  signature: string;
}

/** 行内片段类型。 */
export type InlineKind = 'text' | 'bold' | 'italic' | 'code' | 'link';

/** 行内片段。 */
export interface InlineSpan {
  kind: InlineKind;
  text: string;
  /** kind === 'link' 时的地址。 */
  url?: string;
}

// ---------------------------------------------------------------------------
// 行内解析
// ---------------------------------------------------------------------------

/** 追加一段普通文本（连续文本合并，减少 Span 数量）。 */
function pushPlain(spans: InlineSpan[], text: string): void {
  if (text.length === 0) {
    return;
  }
  const last: InlineSpan | null = spans.length > 0 ? spans[spans.length - 1] : null;
  if (last !== null && last.kind === 'text') {
    last.text += text;
    return;
  }
  const span: InlineSpan = { kind: 'text', text: text };
  spans.push(span);
}

/** 把一行里的 **粗体** / *斜体* / `行内代码` / [链接](url) 切成片段。 */
export function parseInline(text: string): InlineSpan[] {
  const spans: InlineSpan[] = [];
  if (text === undefined || text === null || text.length === 0) {
    return spans;
  }
  let plain: string = '';
  let i: number = 0;
  while (i < text.length) {
    const ch: string = text.charAt(i);

    // 行内代码：`xxx`
    if (ch === '`') {
      const end: number = text.indexOf('`', i + 1);
      if (end > i + 1) {
        pushPlain(spans, plain);
        plain = '';
        const code: InlineSpan = { kind: 'code', text: text.substring(i + 1, end) };
        spans.push(code);
        i = end + 1;
        continue;
      }
    }

    // 粗体：**xxx**
    if (ch === '*' && text.charAt(i + 1) === '*') {
      const end: number = text.indexOf('**', i + 2);
      if (end > i + 2) {
        pushPlain(spans, plain);
        plain = '';
        const bold: InlineSpan = { kind: 'bold', text: text.substring(i + 2, end) };
        spans.push(bold);
        i = end + 2;
        continue;
      }
    }

    // 斜体：*xxx* 或 _xxx_
    if (ch === '*' || ch === '_') {
      const end: number = text.indexOf(ch, i + 1);
      if (end > i + 1 && end - i <= 200) {
        pushPlain(spans, plain);
        plain = '';
        const italic: InlineSpan = { kind: 'italic', text: text.substring(i + 1, end) };
        spans.push(italic);
        i = end + 1;
        continue;
      }
    }

    // 链接：[标题](https://...)
    if (ch === '[') {
      const labelEnd: number = text.indexOf('](', i + 1);
      if (labelEnd > i + 1) {
        const urlEnd: number = text.indexOf(')', labelEnd + 2);
        if (urlEnd > labelEnd + 2) {
          pushPlain(spans, plain);
          plain = '';
          const link: InlineSpan = {
            kind: 'link',
            text: text.substring(i + 1, labelEnd),
            url: text.substring(labelEnd + 2, urlEnd)
          };
          spans.push(link);
          i = urlEnd + 1;
          continue;
        }
      }
    }

    plain += ch;
    i += 1;
  }
  pushPlain(spans, plain);
  return spans;
}

// ---------------------------------------------------------------------------
// 块级解析
// ---------------------------------------------------------------------------

/** 是否水平分割线。 */
function isDivider(line: string): boolean {
  const trimmed: string = line.trim();
  if (trimmed.length < 3) {
    return false;
  }
  const ch: string = trimmed.charAt(0);
  if (ch !== '-' && ch !== '*' && ch !== '_') {
    return false;
  }
  for (let i = 0; i < trimmed.length; i++) {
    if (trimmed.charAt(i) !== ch) {
      return false;
    }
  }
  return true;
}

/** 标题：返回 [级别, 文本]；不是标题返回 null。 */
function readHeading(line: string): string[] | null {
  const trimmed: string = line.replace(/^\s{0,3}/, '');
  let level: number = 0;
  while (level < 6 && level < trimmed.length && trimmed.charAt(level) === '#') {
    level += 1;
  }
  if (level === 0) {
    return null;
  }
  const rest: string = trimmed.substring(level);
  if (rest.length === 0 || (rest.charAt(0) !== ' ' && rest.charAt(0) !== '\t')) {
    return null;
  }
  return [`${level}`, rest.trim()];
}

/** 引用：返回去掉 `>` 之后的内容；不是引用返回 null。 */
function readQuote(line: string): string | null {
  const trimmed: string = line.replace(/^\s{0,3}/, '');
  if (trimmed.length === 0 || trimmed.charAt(0) !== '>') {
    return null;
  }
  let rest: string = trimmed.substring(1);
  if (rest.length > 0 && rest.charAt(0) === ' ') {
    rest = rest.substring(1);
  }
  return rest;
}

/** 无序列表项；不是返回 null。 */
function readUnordered(line: string): string | null {
  const trimmed: string = line.replace(/^\s{0,3}/, '');
  if (trimmed.length < 2) {
    return null;
  }
  const ch: string = trimmed.charAt(0);
  if (ch !== '-' && ch !== '*' && ch !== '+') {
    return null;
  }
  if (trimmed.charAt(1) !== ' ' && trimmed.charAt(1) !== '\t') {
    return null;
  }
  const rest: string = trimmed.substring(2).trim();
  return rest.length === 0 ? '' : rest;
}

/** 有序列表项（只接受 1. / 1) 两种写法）；不是返回 null。 */
function readOrdered(line: string): string | null {
  const trimmed: string = line.replace(/^\s{0,3}/, '');
  const match: RegExpMatchArray | null = trimmed.match(/^(\d{1,9})[.)]\s+(.*)$/);
  if (match === null) {
    return null;
  }
  return match[2].trim();
}

/** 表格分隔行（|---|---|）。 */
function isTableSeparator(line: string): boolean {
  const trimmed: string = line.trim();
  if (trimmed.length === 0) {
    return false;
  }
  if (trimmed.indexOf('-') < 0) {
    return false;
  }
  for (let i = 0; i < trimmed.length; i++) {
    const ch: string = trimmed.charAt(i);
    if (ch !== '-' && ch !== '|' && ch !== ':' && ch !== ' ' && ch !== '\t') {
      return false;
    }
  }
  return true;
}

/** 是否表格行。 */
function isTableRow(line: string): boolean {
  const trimmed: string = line.trim();
  if (trimmed.indexOf('|') < 0) {
    return false;
  }
  return trimmed.charAt(0) === '|';
}

/** 拆分表格单元格。 */
function splitCells(line: string): string[] {
  let body: string = line.trim();
  if (body.startsWith('|')) {
    body = body.substring(1);
  }
  if (body.endsWith('|')) {
    body = body.substring(0, body.length - 1);
  }
  const cells: string[] = body.split('|');
  const out: string[] = [];
  for (const cell of cells) {
    out.push(cell.trim());
  }
  return out;
}

/** 轻量字符串哈希（只用于内容签名，不做安全用途）。 */
function hashText(input: string): number {
  let hash: number = 5381;
  for (let i = 0; i < input.length; i++) {
    hash = ((hash << 5) + hash + input.charCodeAt(i)) & 0x7fffffff;
  }
  return hash;
}

/** 计算内容签名（供 UI 冻结历史块：内容没变 → 签名不变 → ForEach key 不变）。 */
function signBlock(block: MdBlock): string {
  let linesJoined: string = '';
  for (const one of block.lines) {
    linesJoined += `${one}\n`;
  }
  let rowsJoined: string = '';
  for (const row of block.rows) {
    for (const cell of row) {
      rowsJoined += `${cell}|`;
    }
    rowsJoined += '\n';
  }
  return `${block.kind}|${block.level}|${block.language}|${hashText(block.text)}|${hashText(block.code)}`
    + `|${hashText(linesJoined)}|${hashText(rowsJoined)}`;
}

/** 创建块（字段全给的工厂，避免各处漏字段）。 */
function makeBlock(kind: MdBlockKind, index: number): MdBlock {
  const block: MdBlock = {
    id: `${kind}_${index}`,
    kind: kind,
    level: 0,
    text: '',
    lines: [],
    language: '',
    code: '',
    rows: [],
    signature: ''
  };
  return block;
}

/**
 * 把 Markdown 文本切成块。
 *
 * 流式场景的重要行为：未闭合的代码围栏 / 未结束的表格会按「当前已知内容」成块，
 * 因此每次追加文本都会重新解析，但历史块的 `id + signature` 不变。
 */
export function splitBlocks(markdown: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  if (markdown === undefined || markdown === null || markdown.length === 0) {
    return blocks;
  }
  const normalized: string = markdown.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lines: string[] = normalized.split('\n');
  let i: number = 0;
  while (i < lines.length) {
    const line: string = lines[i];

    // 空行：跳过
    if (line.trim().length === 0) {
      i += 1;
      continue;
    }

    // 代码围栏
    const fenceMatch: RegExpMatchArray | null = line.trim().match(/^```(.*)$/);
    if (fenceMatch !== null) {
      const language: string = fenceMatch[1].trim();
      const codeLines: string[] = [];
      i += 1;
      while (i < lines.length && lines[i].trim() !== '```') {
        codeLines.push(lines[i]);
        i += 1;
      }
      if (i < lines.length) {
        i += 1; // 跳过闭合围栏（未闭合时 i 已到末尾）
      }
      const block: MdBlock = makeBlock('code', blocks.length);
      block.language = language;
      block.code = codeLines.join('\n');
      block.signature = signBlock(block);
      blocks.push(block);
      continue;
    }

    // 水平分割线
    if (isDivider(line)) {
      const block: MdBlock = makeBlock('divider', blocks.length);
      block.signature = signBlock(block);
      blocks.push(block);
      i += 1;
      continue;
    }

    // 标题
    const heading: string[] | null = readHeading(line);
    if (heading !== null) {
      const block: MdBlock = makeBlock('heading', blocks.length);
      block.level = Number.parseInt(heading[0]);
      block.text = heading[1];
      block.signature = signBlock(block);
      blocks.push(block);
      i += 1;
      continue;
    }

    // 表格（首行以 | 开头，且下一行是分隔行或下一行也是表格行）
    if (isTableRow(line)) {
      const tableLines: string[] = [];
      while (i < lines.length && isTableRow(lines[i])) {
        tableLines.push(lines[i]);
        i += 1;
      }
      const rows: string[][] = [];
      for (const rowLine of tableLines) {
        if (isTableSeparator(rowLine) && rows.length > 0) {
          continue; // 分隔行不入表
        }
        rows.push(splitCells(rowLine));
      }
      const block: MdBlock = makeBlock('table', blocks.length);
      block.rows = rows;
      block.signature = signBlock(block);
      blocks.push(block);
      continue;
    }

    // 引用（连续多行合并成一个块）
    const quote: string | null = readQuote(line);
    if (quote !== null) {
      const quoteLines: string[] = [];
      let cursor: number = i;
      while (cursor < lines.length) {
        const one: string | null = readQuote(lines[cursor]);
        if (one === null) {
          break;
        }
        quoteLines.push(one);
        cursor += 1;
      }
      const block: MdBlock = makeBlock('quote', blocks.length);
      block.level = 1;
      block.text = quoteLines.join('\n');
      block.signature = signBlock(block);
      blocks.push(block);
      i = cursor;
      continue;
    }

    // 无序列表
    const firstUnordered: string | null = readUnordered(line);
    if (firstUnordered !== null) {
      const items: string[] = [];
      let cursor: number = i;
      while (cursor < lines.length) {
        const one: string | null = readUnordered(lines[cursor]);
        if (one === null) {
          break;
        }
        items.push(one);
        cursor += 1;
      }
      const block: MdBlock = makeBlock('ulist', blocks.length);
      block.lines = items;
      block.signature = signBlock(block);
      blocks.push(block);
      i = cursor;
      continue;
    }

    // 有序列表
    const firstOrdered: string | null = readOrdered(line);
    if (firstOrdered !== null) {
      const items: string[] = [];
      let cursor: number = i;
      while (cursor < lines.length) {
        const one: string | null = readOrdered(lines[cursor]);
        if (one === null) {
          break;
        }
        items.push(one);
        cursor += 1;
      }
      const block: MdBlock = makeBlock('olist', blocks.length);
      block.lines = items;
      block.signature = signBlock(block);
      blocks.push(block);
      i = cursor;
      continue;
    }

    // 段落：吃到空行或下一个块起始标记为止
    const paragraphLines: string[] = [];
    let cursor: number = i;
    while (cursor < lines.length) {
      const one: string = lines[cursor];
      if (one.trim().length === 0) {
        break;
      }
      if (cursor > i) {
        if (readHeading(one) !== null || readQuote(one) !== null || readUnordered(one) !== null
          || readOrdered(one) !== null || isDivider(one) || isTableRow(one)
          || one.trim().startsWith('```')) {
          break;
        }
      }
      paragraphLines.push(one);
      cursor += 1;
    }
    const block: MdBlock = makeBlock('paragraph', blocks.length);
    block.text = paragraphLines.join('\n');
    block.signature = signBlock(block);
    blocks.push(block);
    i = cursor > i ? cursor : i + 1;
  }
  return blocks;
}

/** 相邻块之间的间距（UI 与纯逻辑共用同一套规则，保证视觉稳定）。 */
export function blockSpacing(kind: MdBlockKind): number {
  if (kind === 'heading') {
    return 8;
  }
  if (kind === 'ulist' || kind === 'olist') {
    return 6;
  }
  if (kind === 'code' || kind === 'table') {
    return 10;
  }
  return 6;
}
