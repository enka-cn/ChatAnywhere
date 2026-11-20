/**
 * 输入框上方的「对话记忆」条（v3）。
 *
 * - 占用 < 60% 且未在整理时完全隐藏（不占高度）；
 * - 显示时 3px 进度条 + 等宽百分比；点开只有一行「对话记忆 N% · 本轮命中 M%」+「立即整理」；
 * - 整理中显示「正在生成检查点摘要…」。
 */
import { Layout, Theme } from '../app/Theme';

@Component
export struct MemoryGaugeBar {
  /** 记忆占用 0..1。 */
  @Prop ratio: number = 0;
  /** 本轮缓存命中 0..1。 */
  @Prop cacheRatio: number = 0;
  /** 是否正在整理记忆。 */
  @Prop compacting: boolean = false;
  onCompact: () => void = () => {
  };

  @State private expanded: boolean = false;

  private percent(): number {
    return Math.round(Math.max(0, Math.min(1, this.ratio)) * 100);
  }

  private cachePercent(): number {
    return Math.round(Math.max(0, Math.min(1, this.cacheRatio)) * 100);
  }

  private visible(): boolean {
    return this.compacting || this.ratio >= 0.6;
  }

  @Builder
  bubble() {
    Row({ space: Layout.s2 }) {
      Text(this.compacting ? '正在生成检查点摘要…'
        : `对话记忆 ${this.percent()}% · 本轮命中 ${this.cachePercent()}%`)
        .fontSize(Layout.fontSmall)
        .fontColor(Theme.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.compacting ? '整理中' : '立即整理')
        .fontSize(Layout.fontSmall)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.compacting ? Theme.textTertiary : Theme.brand)
        .onClick(() => {
          if (this.compacting) {
            return;
          }
          this.expanded = false;
          this.onCompact();
        })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .borderRadius(Layout.radiusM)
    .backgroundColor(Theme.bgSurface)
    .border({ width: 1, color: Theme.border })
    .margin({ bottom: 6 })
  }

  build() {
    Column() {
      if (this.visible()) {
        if (this.expanded) {
          this.bubble()
        }
        Row({ space: Layout.s2 }) {
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(3)
              .borderRadius(2)
              .backgroundColor(Theme.bgSurface2)
            Row()
              .width(`${this.percent()}%`)
              .height(3)
              .borderRadius(2)
              .backgroundColor(this.ratio >= 0.85 ? Theme.danger : Theme.memoryWarn)
          }
          .layoutWeight(1)
          .height(3)
          Text(this.compacting ? '整理中' : `${this.percent()}%`)
            .fontSize(Layout.fontCaption)
            .fontFamily('monospace')
            .fontColor(Theme.textTertiary)
        }
        .width('100%')
        .padding({ top: 2, bottom: 6 })
        .onClick(() => {
          this.expanded = !this.expanded;
        })
      }
    }
    .width('100%')
  }
}
