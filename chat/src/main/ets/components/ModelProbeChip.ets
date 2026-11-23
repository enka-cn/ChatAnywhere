/**
 * 模型添加胶囊（v3.3 四态）：idle / loading / success / error。
 *
 * - idle：细边框 +「+ 模型名」，可点击添加；
 * - loading：转圈 +「添加中…」，不响应点击（防连点）；
 * - success：绿色底 + 勾选，点击不再重复添加；
 * - error：红色底 +「重新添加 · 模型名」+ 下方失败原因，可点击重试。
 */
import { Icons, Layout, Theme } from '../app/Theme';

/** 单个模型胶囊的添加状态（父级整体替换数组触发刷新）。 */
export interface ModelAddStatus {
  /** `${providerId}:${modelId}` */
  key: string;
  /** idle / loading / success / error */
  status: string;
  /** 失败原因（中文，≤60 字）。 */
  error: string;
}

@Component
export struct ModelProbeChip {
  @Prop modelId: string = '';
  @Prop displayName: string = '';
  /** idle / loading / success / error（父级保证取值）。 */
  @Prop status: string = 'idle';
  @Prop errorText: string = '';
  onTap: (modelId: string) => void = (modelId: string) => {
  };

  private label(): string {
    return this.displayName.length > 0 ? this.displayName : this.modelId;
  }

  @Builder
  idleChip() {
    Row({ space: 4 }) {
      SymbolGlyph(Icons.plus)
        .fontSize(Layout.iconS)
        .fontColor([Theme.textSecondary])
      Text(this.label())
        .fontSize(Layout.fontCaption)
        .fontColor(Theme.textSecondary)
        .maxLines(1)
        .constraintSize({ maxWidth: 180 })
    }
    .padding({ left: Layout.s2, right: Layout.s2, top: 5, bottom: 5 })
    .borderRadius(Layout.radiusPill)
    .backgroundColor(Theme.bgInput)
    .border({ width: 1, color: Theme.border })
    .onClick(() => {
      this.onTap(this.modelId);
    })
  }

  @Builder
  loadingChip() {
    Row({ space: 4 }) {
      LoadingProgress()
        .width(14)
        .height(14)
        .color(Theme.brand)
      Text('添加中…')
        .fontSize(Layout.fontCaption)
        .fontColor(Theme.brand)
        .maxLines(1)
    }
    .padding({ left: Layout.s2, right: Layout.s2, top: 5, bottom: 5 })
    .borderRadius(Layout.radiusPill)
    .backgroundColor(Theme.brandSubtle)
  }

  @Builder
  successChip() {
    Row({ space: 4 }) {
      SymbolGlyph(Icons.check)
        .fontSize(Layout.iconS)
        .fontColor([Theme.success])
      Text(this.label())
        .fontSize(Layout.fontCaption)
        .fontColor(Theme.success)
        .maxLines(1)
        .constraintSize({ maxWidth: 180 })
    }
    .padding({ left: Layout.s2, right: Layout.s2, top: 5, bottom: 5 })
    .borderRadius(Layout.radiusPill)
    .backgroundColor(Theme.successSubtle)
    .border({ width: 1, color: Theme.success })
  }

  @Builder
  errorChip() {
    Column({ space: 2 }) {
      Row({ space: 4 }) {
        SymbolGlyph(Icons.retry)
          .fontSize(Layout.iconS)
          .fontColor([Theme.danger])
        Text(`重新添加 · ${this.label()}`)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.danger)
          .maxLines(1)
          .constraintSize({ maxWidth: 200 })
      }
      .padding({ left: Layout.s2, right: Layout.s2, top: 5, bottom: 5 })
      .borderRadius(Layout.radiusPill)
      .backgroundColor(Theme.dangerSubtle)
      .border({ width: 1, color: Theme.danger })

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.danger)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 200 })
          .padding({ left: 4 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onTap(this.modelId);
    })
  }

  build() {
    Column() {
      if (this.status === 'loading') {
        this.loadingChip()
      } else if (this.status === 'success') {
        this.successChip()
      } else if (this.status === 'error') {
        this.errorChip()
      } else {
        this.idleChip()
      }
    }
    .margin({ right: Layout.s2, bottom: Layout.s2 })
  }
}
