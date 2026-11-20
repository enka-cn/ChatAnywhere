/**
 * 设置 · 跨端与数据 · 分享内容整理。
 *
 * 只处理 ChatAbility 写入的待处理分享内容：整理 / 复制 / 清空，结果单行提示。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { Icons, Layout, Theme } from '../app/Theme';
import { ShareKitBridge, SharedSummaryResult } from '../bridge/ShareKitBridge';

@Component
export struct SettingsShareView {
  /** 清空后通知父级隐藏本区块。 */
  onCleared: () => void = () => {
  };

  @State private text: string = '';
  @State private busy: boolean = false;
  @State private title: string = '';
  @State private summary: string = '';
  @State private msg: string = '';

  aboutToAppear(): void {
    this.text = ShareKitBridge.get().pendingText();
  }

  private async summarize(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const result: SharedSummaryResult = await ShareKitBridge.get().summarizeSharedLink(this.text);
    this.busy = false;
    if (result.ok) {
      this.title = result.title;
      this.summary = result.summary;
      this.msg = '';
    } else {
      this.title = '';
      this.summary = '';
      this.msg = result.message;
    }
  }

  private async copy(): Promise<void> {
    if (this.summary.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.summary);
      await pasteboard.getSystemPasteboard().setData(data);
      this.msg = '已复制';
    } catch (e) {
      this.msg = `复制失败：${(e as Error).message}`;
    }
  }

  private clear(): void {
    ShareKitBridge.get().clearPending();
    this.text = '';
    this.title = '';
    this.summary = '';
    this.msg = '';
    this.onCleared();
  }

  build() {
    Column() {
      if (this.text.length > 0) {
        Column({ space: Layout.s2 }) {
          Text(this.text)
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.title.length > 0) {
            Text(this.title)
              .fontSize(Layout.fontBody)
              .fontColor(Theme.textPrimary)
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.summary.length > 0) {
            Text(this.summary)
              .fontSize(Layout.fontSmall)
              .fontColor(Theme.textSecondary)
              .width('100%')
              .maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.msg.length > 0) {
            Text(this.msg)
              .fontSize(Layout.fontCaption)
              .fontColor(Theme.warning)
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          Row({ space: Layout.s4 }) {
            SymbolGlyph(Icons.web)
              .fontSize(18)
              .fontColor([Theme.brand])
              .onClick(() => {
                this.summarize();
              })
            SymbolGlyph(Icons.copy)
              .fontSize(18)
              .fontColor([Theme.iconSecondary])
              .onClick(() => {
                this.copy();
              })
            Blank()
            SymbolGlyph(Icons.trash)
              .fontSize(18)
              .fontColor([Theme.iconSecondary])
              .onClick(() => {
                this.clear();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(Layout.s4)
        .backgroundColor(Theme.bgSurface)
        .borderRadius(Layout.radiusM)
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
  }
}
