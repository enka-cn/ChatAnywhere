/**
 * 块级 Markdown 渲染（ArkUI）。
 *
 * 解析逻辑全部在 `MarkdownParser.ets`（纯函数，零平台依赖，可被 Node 逻辑测试直接跑），
 * 行内公式的 LaTeX→文本映射在 `InlineMath.ets`（同样纯逻辑）。
 * 本文件只负责渲染：历史已闭合块用 `block.id + block.signature` 作 ForEach key，
 * 内容没变就不重建，只有末尾正在增长的那一块刷新。
 *
 * 视觉：颜色/字号/行高全部来自设计令牌（Theme / Layout），支持深浅色自动切换。
 */
import { common, Want } from '@kit.AbilityKit';
import { Layout, Theme } from '../app/Theme';
import { CodeBlockView } from './CodeBlockView';
import { latexToText } from './InlineMath';
import { MathBlock } from './MathBlock';
import { InlineSpan, MdBlock, parseInline, splitBlocks } from './MarkdownParser';

export { parseInline, splitBlocks } from './MarkdownParser';

/** 列表项间距（vp）。 */
const LIST_GAP: number = 6;

/** 标题字号（1..6）。 */
function headingSize(level: number): number {
  if (level <= 1) {
    return Layout.fontHeadline + 2;
  }
  if (level === 2) {
    return Layout.fontHeadline;
  }
  if (level === 3) {
    return Layout.fontBodyLarge + 1;
  }
  if (level === 4) {
    return Layout.fontBodyLarge;
  }
  return Layout.fontBody;
}

/** 块与块之间的上间距。 */
function gapFor(kind: string): number {
  if (kind === 'heading') {
    return Layout.s4;
  }
  if (kind === 'code' || kind === 'table' || kind === 'math') {
    return Layout.s3;
  }
  if (kind === 'ulist' || kind === 'olist') {
    return Layout.s2;
  }
  return Layout.s3;
}

/**
 * Markdown 渲染组件（无外框，直接排版）。
 *
 * 用法：`MarkdownBlock({ markdown: text })`
 */
@Component
export struct MarkdownBlock {
  /** 完整 Markdown 文本（流式时为“当前已经收到的全部文本”）。 */
  @Prop @Watch('onMarkdownChanged') markdown: string = '';
  /** 正文字号（默认取设计令牌）。 */
  @Prop baseFontSize: number = Layout.fontChat;

  @State private blocks: MdBlock[] = [];

  aboutToAppear(): void {
    this.blocks = splitBlocks(this.markdown);
  }

  /** 文本变化：整体重新分块（历史块靠 signature 复用到同一批节点）。 */
  onMarkdownChanged(): void {
    this.blocks = splitBlocks(this.markdown);
  }

  // -------------------------------------------------------------------------
  // 链接打开（http/https 校验；优先 openLink，失败退回 viewData）
  // -------------------------------------------------------------------------

  private openLink(url: string): void {
    if (url.length === 0) {
      return;
    }
    const lower: string = url.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return;
    }
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (context !== undefined && context !== null) {
        context.openLink(url).catch(() => {
          this.startViewData(url);
        });
        return;
      }
    } catch (e) {
      // 退回 startAbility
    }
    this.startViewData(url);
  }

  private startViewData(url: string): void {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (context === undefined || context === null) {
        return;
      }
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      context.startAbility(want).catch(() => {
        // 没有可处理该链接的应用：静默
      });
    } catch (e) {
      // 静默
    }
  }

  // -------------------------------------------------------------------------
  // 行内片段
  // -------------------------------------------------------------------------

  @Builder
  inlineSpans(text: string) {
    ForEach(parseInline(text), (span: InlineSpan) => {
      if (span.kind === 'bold') {
        Span(span.text).fontWeight(FontWeight.Bold)
      } else if (span.kind === 'italic') {
        Span(span.text).fontStyle(FontStyle.Italic)
      } else if (span.kind === 'code') {
        Span(span.text)
          .fontFamily('monospace')
          .fontColor(Theme.codeText)
          .textBackgroundStyle({ color: Theme.codeBg })
      } else if (span.kind === 'math') {
        Span(latexToText(span.text))
          .fontStyle(FontStyle.Italic)
          .fontColor(Theme.mathInline)
      } else if (span.kind === 'link') {
        Span(span.text)
          .fontColor(Theme.brand)
          .decoration({ type: TextDecorationType.Underline, color: Theme.brand })
          .onClick(() => {
            this.openLink(span.url === undefined ? '' : span.url);
          })
      } else {
        Span(span.text)
      }
    }, (span: InlineSpan, index: number) => `${index}_${span.kind}_${span.text.length}_${span.text}`)
  }

  @Builder
  inlineText(text: string, size: number, weight: FontWeight) {
    Text() {
      this.inlineSpans(text)
    }
    .fontSize(size)
    .fontColor(Theme.textPrimary)
    .fontWeight(weight)
    .lineHeight(Layout.lineChat)
    .width('100%')
    .copyOption(CopyOptions.LocalDevice)
  }

  // -------------------------------------------------------------------------
  // 各类型块
  // -------------------------------------------------------------------------

  @Builder
  headingBlock(block: MdBlock) {
    Text() {
      this.inlineSpans(block.text)
    }
    .fontSize(headingSize(block.level))
    .fontWeight(FontWeight.Bold)
    .fontColor(Theme.textPrimary)
    .lineHeight(headingSize(block.level) + Layout.s2)
    .width('100%')
    .margin({ top: 10, bottom: 2 })
  }

  @Builder
  paragraphBlock(block: MdBlock) {
    this.inlineText(block.text, this.baseFontSize, FontWeight.Normal)
  }

  @Builder
  quoteBlock(block: MdBlock) {
    Column() {
      this.inlineText(block.text, this.baseFontSize, FontWeight.Normal)
    }
    .width('100%')
    .padding({ left: Layout.s3, top: Layout.s1, bottom: Layout.s1 })
    .border({ width: { left: 2 }, color: { left: Theme.quoteBar } })
  }

  @Builder
  listBlock(block: MdBlock) {
    Column({ space: LIST_GAP }) {
      ForEach(block.lines, (item: string, index: number) => {
        Row() {
          if (block.kind === 'olist') {
            Text(`${index + 1}.`)
              .fontSize(this.baseFontSize)
              .fontColor(Theme.textTertiary)
              .lineHeight(Layout.lineChat)
              .width(Layout.s5)
              .textAlign(TextAlign.End)
          } else {
            Column() {
              Circle({ width: 5, height: 5 }).fill(Theme.textTertiary)
            }
            .width(Layout.s5)
            .height(Layout.lineChat)
            .alignItems(HorizontalAlign.End)
            .justifyContent(FlexAlign.Center)
          }
          Column() {
            this.inlineText(item, this.baseFontSize, FontWeight.Normal)
          }
          .layoutWeight(1)
          .padding({ left: Layout.s2 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (item: string, index: number) => `${index}_${item.length}_${item}`)
    }
    .width('100%')
  }

  @Builder
  codeBlock(block: MdBlock) {
    CodeBlockView({ language: block.language, code: block.code })
  }

  @Builder
  mathBlock(block: MdBlock) {
    MathBlock({ code: block.code })
  }

  @Builder
  tableBlock(block: MdBlock) {
    Column() {
      ForEach(block.rows, (row: string[], rowIndex: number) => {
        Column() {
          Row() {
            ForEach(row, (cell: string, cellIndex: number) => {
              Text(cell)
                .fontSize(Layout.fontSmall + 1)
                .fontColor(rowIndex === 0 ? Theme.textPrimary : Theme.textSecondary)
                .fontWeight(rowIndex === 0 ? FontWeight.Medium : FontWeight.Normal)
                .layoutWeight(1)
                .padding({ left: Layout.s2, right: Layout.s2, top: 6, bottom: 6 })
                .copyOption(CopyOptions.LocalDevice)
            }, (cell: string, cellIndex: number) => `${cellIndex}_${cell.length}_${cell}`)
          }
          .width('100%')
          .backgroundColor(rowIndex === 0 ? Theme.bgSurface2 : Theme.bgSurface)
          .alignItems(VerticalAlign.Top)
          if (rowIndex < block.rows.length - 1) {
            Divider().color(Theme.divider)
          }
        }
        .width('100%')
      }, (row: string[], rowIndex: number) => `${rowIndex}_${row.length}_${row.join('|')}`)
    }
    .width('100%')
    .border({ width: 1, color: Theme.border })
    .borderRadius(Layout.radiusM)
    .clip(true)
  }

  @Builder
  dividerBlock() {
    Divider().color(Theme.divider).margin({ top: Layout.s2, bottom: Layout.s2 })
  }

  @Builder
  oneBlock(block: MdBlock) {
    if (block.kind === 'heading') {
      this.headingBlock(block)
    } else if (block.kind === 'code') {
      this.codeBlock(block)
    } else if (block.kind === 'math') {
      this.mathBlock(block)
    } else if (block.kind === 'ulist' || block.kind === 'olist') {
      this.listBlock(block)
    } else if (block.kind === 'quote') {
      this.quoteBlock(block)
    } else if (block.kind === 'table') {
      this.tableBlock(block)
    } else if (block.kind === 'divider') {
      this.dividerBlock()
    } else {
      this.paragraphBlock(block)
    }
  }

  build() {
    Column() {
      ForEach(this.blocks, (block: MdBlock) => {
        Column() {
          this.oneBlock(block)
        }
        .width('100%')
        .margin({ top: gapFor(block.kind) })
      }, (block: MdBlock) => `${block.id}_${block.signature}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
