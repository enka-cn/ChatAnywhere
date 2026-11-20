/**
 * 流式助手内容区（v3.1：无气泡通栏 + 折叠「思考过程」胶囊 + 极简纯图标操作栏）。
 */
import { SourceRef } from '@app/core_model';
import { Icons, Layout, Theme } from '../app/Theme';
import { SearchTraceStep } from '../model/ChatRuntimeApi';
import { IconBtn } from './IconBtn';
import { MarkdownBlock } from './MarkdownBlock';

const FRAME_MS: number = 32;
const BLINK_MS: number = 500;

@Component
export struct StreamingMessage {
  @Prop @Watch('onTextFrame') text: string = '';
  @Prop @Watch('onReasoningFrame') reasoning: string = '';
  @Prop streaming: boolean = true;
  @Prop sources: SourceRef[] = [];
  @Prop searchTrace: SearchTraceStep[] = [];
  onCopyText: (text: string) => void = (text: string) => {
  };
  onRegenerate: () => void = () => {
  };

  @State private displayText: string = '';
  @State private displayReasoning: string = '';
  @State private showThinking: boolean = false;
  @State private cursorOn: boolean = true;

  private pendingText: string = '';
  private pendingReasoning: string = '';
  private frameTimer: number = -1;
  private blinkTimer: number = -1;

  aboutToAppear(): void {
    this.pendingText = this.text;
    this.pendingReasoning = this.reasoning;
    this.displayText = this.text;
    this.displayReasoning = this.reasoning;
    this.blinkTimer = setInterval(() => {
      this.cursorOn = !this.cursorOn;
    }, BLINK_MS);
  }

  aboutToDisappear(): void {
    if (this.frameTimer >= 0) {
      clearTimeout(this.frameTimer);
      this.frameTimer = -1;
    }
    if (this.blinkTimer >= 0) {
      clearInterval(this.blinkTimer);
      this.blinkTimer = -1;
    }
  }

  onTextFrame(): void {
    this.pendingText = this.text;
    this.scheduleFrame();
  }

  onReasoningFrame(): void {
    this.pendingReasoning = this.reasoning;
    this.scheduleFrame();
  }

  private scheduleFrame(): void {
    if (this.frameTimer >= 0) {
      return;
    }
    this.frameTimer = setTimeout(() => {
      this.frameTimer = -1;
      this.displayText = this.pendingText;
      this.displayReasoning = this.pendingReasoning;
    }, FRAME_MS);
  }

  private hasThinking(): boolean {
    return this.searchTrace.length > 0 || this.displayReasoning.length > 0;
  }

  private stepChipText(step: SearchTraceStep): string {
    if (step.kind === 'search') {
      return step.detail.length > 0 ? `检索 · ${step.detail}` : `检索 · ${step.title}`;
    }
    return step.title;
  }

  @Builder
  thinkingCapsule() {
    Column() {
      Row({ space: 6 }) {
        SymbolGlyph(Icons.thinking)
          .fontSize(Layout.iconS)
          .fontColor([Theme.brand])
        Text(this.streaming ? '思考中…'
          : `思考过程${this.sources.length > 0 ? ` · ${this.sources.length} 篇` : ''}`)
          .fontSize(Layout.fontSmall)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary)
        SymbolGlyph(this.showThinking ? Icons.chevronUp : Icons.chevronDown)
          .fontSize(Layout.iconS)
          .fontColor([Theme.textTertiary])
      }
      .height(30)
      .padding({ left: 12, right: 10 })
      .borderRadius(Layout.radiusPill)
      .backgroundColor(Theme.bgSurface)
      .onClick(() => {
        this.showThinking = !this.showThinking;
      })

      if (this.showThinking) {
        Column({ space: 6 }) {
          ForEach(this.searchTrace, (step: SearchTraceStep) => {
            if (step.kind === 'search') {
              Row({ space: 6 }) {
                SymbolGlyph(Icons.search).fontSize(Layout.iconS).fontColor([Theme.brand])
                Text(this.stepChipText(step))
                  .fontSize(Layout.fontSmall)
                  .fontColor(Theme.brand)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(Layout.radiusS)
              .backgroundColor(Theme.brandSubtle)
            } else {
              Text(step.detail.length > 0 ? `${step.title}：${step.detail}` : step.title)
                .fontSize(Layout.fontSmall)
                .fontColor(Theme.textSecondary)
                .lineHeight(Layout.lineTight)
                .width('100%')
            }
          }, (step: SearchTraceStep) => `${step.id}_${step.status}_${step.title.length}`)

          if (this.displayReasoning.length > 0) {
            Text(this.displayReasoning)
              .fontSize(Layout.fontSmall)
              .fontColor(Theme.textSecondary)
              .lineHeight(Layout.lineTight)
              .width('100%')
          }
        }
        .width('100%')
        .padding({ left: Layout.s3, top: Layout.s2, bottom: Layout.s1 })
        .margin({ top: Layout.s2 })
        .border({ width: { left: 2 }, color: { left: Theme.border } })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: Layout.s2 })
  }

  @Builder
  actionsRow() {
    Row({ space: 4 }) {
      IconBtn({
        icon: Icons.copy,
        iconSize: Layout.iconS,
        iconColor: Theme.textTertiary,
        btnSize: 30,
        radius: Layout.radiusS,
        onTap: () => {
          this.onCopyText(this.displayText);
        }
      })
      IconBtn({
        icon: Icons.retry,
        iconSize: Layout.iconS,
        iconColor: Theme.textTertiary,
        btnSize: 30,
        radius: Layout.radiusS,
        onTap: () => {
          this.onRegenerate();
        }
      })
      Blank()
    }
    .width('100%')
    .margin({ top: Layout.s1 })
  }

  build() {
    Column() {
      if (this.hasThinking()) {
        this.thinkingCapsule()
      }

      if (this.displayText.length > 0) {
        MarkdownBlock({ markdown: this.displayText })
      }

      if (this.streaming) {
        Row() {
          Row()
            .width(6)
            .height(16)
            .borderRadius(3)
            .backgroundColor(Theme.brand)
        }
        .height(18)
        .opacity(this.cursorOn ? 1 : 0.2)
        .margin({ top: 3 })
      }

      if (!this.streaming && this.displayText.length > 0) {
        this.actionsRow()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
