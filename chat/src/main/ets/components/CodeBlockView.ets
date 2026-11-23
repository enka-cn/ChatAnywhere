/**
 * 原生代码块（v3.7）：语言栏 + 复制反馈 + 横向滚动 + 语法高亮。
 *
 * 高亮 token 由同目录 CodeHighlighter 的 highlightCode(code, language) 提供；
 * 代码区使用横向 Scroll 保留原始行宽与缩进（不使用 WordBreak.BREAK_ALL）。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { CodeToken, highlightCode } from './CodeHighlighter';
import { Icons, Layout, Theme } from '../app/Theme';

/** 复制反馈保持时长（ms）。 */
const COPIED_HOLD_MS: number = 1500;

@Component
export struct CodeBlockView {
  @Prop language: string = '';
  @Prop code: string = '';

  @State private copied: boolean = false;
  private copyTimer: number = -1;

  aboutToDisappear(): void {
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.copyTimer >= 0) {
      clearTimeout(this.copyTimer);
      this.copyTimer = -1;
    }
  }

  /** 高亮；高亮器异常时退化为单段 plain，绝不白屏。 */
  private tokens(): CodeToken[] {
    try {
      const list: CodeToken[] = highlightCode(this.code, this.language);
      if (list.length > 0) {
        return list;
      }
    } catch (e) {
      // 落到 plain 兜底
    }
    const plain: CodeToken = { kind: 'plain', text: this.code };
    const out: CodeToken[] = [];
    out.push(plain);
    return out;
  }

  private languageLabel(): string {
    const raw: string = this.language.trim().toLowerCase();
    return raw.length > 0 ? raw : 'text';
  }

  private colorOf(kind: string): ResourceColor {
    if (kind === 'keyword') {
      return Theme.codeKeyword;
    }
    if (kind === 'type') {
      return Theme.codeType;
    }
    if (kind === 'string') {
      return Theme.codeString;
    }
    if (kind === 'number') {
      return Theme.codeNumber;
    }
    if (kind === 'comment') {
      return Theme.codeComment;
    }
    if (kind === 'macro') {
      return Theme.codeMacro;
    }
    if (kind === 'function') {
      return Theme.codeFunction;
    }
    return Theme.codePlain;
  }

  private async copyCode(): Promise<void> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.code);
      await pasteboard.getSystemPasteboard().setData(data);
      this.copied = true;
      this.clearTimer();
      this.copyTimer = setTimeout(() => {
        this.copied = false;
        this.copyTimer = -1;
      }, COPIED_HOLD_MS);
    } catch (e) {
      // 剪贴板不可用时静默，不打断阅读
    }
  }

  @Builder
  headerBar() {
    Row({ space: Layout.s2 }) {
      Text(this.languageLabel())
        .fontSize(Layout.fontSmall)
        .fontColor(Theme.textTertiary)
        .maxLines(1)
        .layoutWeight(1)
      Row({ space: 4 }) {
        SymbolGlyph(this.copied ? Icons.check : Icons.copy)
          .fontSize(Layout.iconS)
          .fontColor([this.copied ? Theme.success : Theme.textSecondary])
        Text(this.copied ? '已复制' : '复制')
          .fontSize(Layout.fontSmall)
          .fontColor(this.copied ? Theme.success : Theme.textSecondary)
      }
      .padding({ left: Layout.s2, right: Layout.s2, top: 3, bottom: 3 })
      .borderRadius(Layout.radiusS)
      .onClick(() => {
        this.copyCode();
      })
    }
    .width('100%')
    .height(36)
    .padding({ left: Layout.s3, right: Layout.s2 })
    .backgroundColor(Theme.codeHeaderBg)
  }

  @Builder
  codeArea() {
    Scroll() {
      Text() {
        ForEach(this.tokens(), (token: CodeToken, index: number) => {
          Span(token.text).fontColor(this.colorOf(token.kind))
        }, (token: CodeToken, index: number) => `${index}:${token.kind}`)
      }
      .fontSize(13.5)
      .lineHeight(21)
      .fontColor(Theme.codePlain)
      .copyOption(CopyOptions.LocalDevice)
      .padding(Layout.s3)
    }
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .backgroundColor(Theme.codeBg)
  }

  build() {
    Column() {
      this.headerBar()
      Divider()
        .strokeWidth(1)
        .color(Theme.divider)
      this.codeArea()
    }
    .width('100%')
    .borderRadius(14)
    .border({ width: 1, color: Theme.border })
    .backgroundColor(Theme.codeBg)
    .clip(true)
  }
}
