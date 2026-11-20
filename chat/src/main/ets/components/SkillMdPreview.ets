/**
 * SKILL.md 轻量预览（只读，自实现，不依赖主对话的 MarkdownBlock）。
 *
 * 对齐 v3 设计（`chatanywhere_v3_pura_x_max.html` 1174–1181）：
 * - frontmatter 渲染成一张说明头卡片（键值逐行）；
 * - 正文支持标题 / 列表 / 段落 / 代码块 / 分割线；
 * - 字号与间距全部走设计令牌。
 */
import { Layout, Theme } from '../app/Theme';

/** 预览块。 */
export interface PreviewBlock {
  /** frontmatter | heading | ulist | olist | paragraph | code | divider */
  kind: string;
  text: string;
  /** heading 为标题层级；olist 为序号。 */
  level: number;
}

/** frontmatter 的一行键值。 */
export interface PreviewRow {
  key: string;
  value: string;
}

/** 解析 frontmatter 文本为键值行。 */
export function parseFrontmatterRows(text: string): PreviewRow[] {
  const rows: PreviewRow[] = [];
  const lines: string[] = text.split('\n');
  for (const raw of lines) {
    const line: string = raw.trim();
    if (line.length === 0 || line.startsWith('#')) {
      // 模板里的注释行不展示
      continue;
    }
    const colon: number = line.indexOf(':');
    if (colon <= 0) {
      rows.push({ key: '', value: line });
      continue;
    }
    rows.push({ key: line.substring(0, colon).trim(), value: line.substring(colon + 1).trim() });
  }
  return rows;
}

/** 判断是否标题行（返回层级，0 表示不是）。 */
function headingLevel(line: string): number {
  let count: number = 0;
  while (count < line.length && line.substring(count, count + 1) === '#') {
    count += 1;
  }
  if (count >= 1 && count <= 6 && line.length > count && line.substring(count, count + 1) === ' ') {
    return count;
  }
  return 0;
}

/** 判断有序列表（返回序号，0 表示不是）。 */
function orderedIndex(line: string): number {
  let digits: number = 0;
  while (digits < line.length && line.substring(digits, digits + 1) >= '0'
    && line.substring(digits, digits + 1) <= '9') {
    digits += 1;
  }
  if (digits === 0 || digits >= line.length) {
    return 0;
  }
  const mark: string = line.substring(digits, digits + 1);
  if ((mark === '.' || mark === ')') && line.length > digits + 1 && line.substring(digits + 1, digits + 2) === ' ') {
    const parsed: number = Number.parseInt(line.substring(0, digits), 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

/** 是否为无序列表行。 */
function isUnordered(line: string): boolean {
  if (line.length < 3) {
    return false;
  }
  const mark: string = line.substring(0, 1);
  return (mark === '-' || mark === '*' || mark === '+') && line.substring(1, 2) === ' ';
}

/**
 * 把 SKILL.md 文本拆成可渲染的预览块（纯函数，便于单独验证）。
 */
export function parseSkillMdPreview(markdown: string): PreviewBlock[] {
  const blocks: PreviewBlock[] = [];
  const text: string = markdown.trim();
  if (text.length === 0) {
    return blocks;
  }
  let body: string = text;
  if (text.startsWith('---')) {
    const lines: string[] = text.split('\n');
    let closing: number = -1;
    for (let i = 1; i < lines.length; i++) {
      if (lines[i].trim() === '---') {
        closing = i;
        break;
      }
    }
    if (closing > 0) {
      const frontLines: string[] = lines.slice(1, closing);
      blocks.push({ kind: 'frontmatter', text: frontLines.join('\n'), level: 0 });
      body = lines.slice(closing + 1).join('\n');
    }
  }

  const bodyLines: string[] = body.split('\n');
  let paragraph: string[] = [];
  let codeLines: string[] = [];
  let inCode: boolean = false;

  const flushParagraph = (): void => {
    if (paragraph.length > 0) {
      blocks.push({ kind: 'paragraph', text: paragraph.join(' '), level: 0 });
      paragraph = [];
    }
  };

  for (const raw of bodyLines) {
    const line: string = raw.trim();
    if (inCode) {
      if (line.startsWith('```')) {
        blocks.push({ kind: 'code', text: codeLines.join('\n'), level: 0 });
        codeLines = [];
        inCode = false;
      } else {
        codeLines.push(raw);
      }
      continue;
    }
    if (line.startsWith('```')) {
      flushParagraph();
      inCode = true;
      codeLines = [];
      continue;
    }
    if (line.length === 0) {
      flushParagraph();
      continue;
    }
    if (line === '---') {
      flushParagraph();
      blocks.push({ kind: 'divider', text: '', level: 0 });
      continue;
    }
    const level: number = headingLevel(line);
    if (level > 0) {
      flushParagraph();
      blocks.push({ kind: 'heading', text: line.substring(level + 1).trim(), level: level });
      continue;
    }
    if (isUnordered(line)) {
      flushParagraph();
      blocks.push({ kind: 'ulist', text: line.substring(2).trim(), level: 0 });
      continue;
    }
    const ordered: number = orderedIndex(line);
    if (ordered > 0) {
      flushParagraph();
      let content: string = line.substring(String(ordered).length + 1).trim();
      if (content.length === 0) {
        content = '';
      }
      blocks.push({ kind: 'olist', text: content, level: ordered });
      continue;
    }
    paragraph.push(line);
  }
  if (inCode && codeLines.length > 0) {
    blocks.push({ kind: 'code', text: codeLines.join('\n'), level: 0 });
  }
  flushParagraph();
  return blocks;
}

/** 标题字号（按层级映射到设计令牌）。 */
function headingSize(level: number): number {
  if (level <= 1) {
    return Layout.fontHeadline;
  }
  if (level === 2) {
    return Layout.fontTitle;
  }
  return Layout.fontBody;
}

@Component
export struct SkillMdPreview {
  markdown: string = '';

  @Builder
  frontmatterCard(block: PreviewBlock) {
    Column({ space: 6 }) {
      ForEach(parseFrontmatterRows(block.text), (row: PreviewRow) => {
        Row({ space: Layout.s2 }) {
          if (row.key.length > 0) {
            Text(row.key)
              .fontSize(Layout.fontSmall)
              .fontFamily('monospace')
              .fontColor(Theme.textTertiary)
              .width(96)
          }
          Text(row.value.length > 0 ? row.value : '（空）')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .layoutWeight(1)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (row: PreviewRow, index: number) => `${index}_${row.key}_${row.value}`)
    }
    .width('100%')
    .padding(Layout.s3)
    .borderRadius(Layout.radiusM)
    .backgroundColor(Theme.bgPage)
    .border({ width: 1, color: Theme.border })
  }

  @Builder
  blockView(block: PreviewBlock, index: number) {
    if (block.kind === 'frontmatter') {
      this.frontmatterCard(block)
    } else if (block.kind === 'heading') {
      Text(block.text)
        .fontSize(headingSize(block.level))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary)
        .width('100%')
        .margin({ top: block.level <= 1 ? Layout.s2 : Layout.s1 })
    } else if (block.kind === 'ulist') {
      Row({ space: 6 }) {
        Text('•')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textTertiary)
        Text(block.text)
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textPrimary)
          .lineHeight(Layout.lineTight)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: Layout.s2 })
      .alignItems(VerticalAlign.Top)
    } else if (block.kind === 'olist') {
      Row({ space: 6 }) {
        Text(`${block.level}.`)
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textTertiary)
        Text(block.text)
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textPrimary)
          .lineHeight(Layout.lineTight)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: Layout.s2 })
      .alignItems(VerticalAlign.Top)
    } else if (block.kind === 'code') {
      Text(block.text)
        .fontSize(Layout.fontSmall)
        .fontFamily('monospace')
        .fontColor(Theme.codeText)
        .lineHeight(Layout.lineTight)
        .width('100%')
        .padding(Layout.s2)
        .borderRadius(Layout.radiusS)
        .backgroundColor(Theme.codeBg)
    } else if (block.kind === 'divider') {
      Divider()
        .color(Theme.divider)
        .strokeWidth(1)
    } else {
      Text(block.text)
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textPrimary)
        .lineHeight(Layout.lineBody)
        .width('100%')
    }
  }

  build() {
    Scroll() {
      Column({ space: Layout.s2 }) {
        ForEach(parseSkillMdPreview(this.markdown), (block: PreviewBlock, index: number) => {
          this.blockView(block, index)
        }, (block: PreviewBlock, index: number) => `${index}_${block.kind}_${block.text.length}_${block.text}`)
      }
      .width('100%')
      .padding(Layout.s3)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }
}
