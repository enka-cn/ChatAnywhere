/**
 * 设置 · 记忆与缓存（v3）。
 *
 * 缓存过期自动整理（写 COMPACTION_POLICY：auto / off）；
 * 切换模型时自动整理由运行时固定行为承担，这里以只读状态展示。
 */
import { SettingsKeys } from '@app/core_model';
import { AppServices } from '../app/AppServices';
import { Icons, Layout, Theme } from '../app/Theme';

@Component
export struct SettingsMemoryView {
  @State private autoCompact: boolean = true;
  @State private statusText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const repo = AppServices.get().requireModel().repo;
      const policy: string = await repo.getString(SettingsKeys.COMPACTION_POLICY, 'auto');
      this.autoCompact = policy !== 'off';
    } catch (e) {
      this.statusText = `${(e as Error).message}`;
    }
  }

  private async toggleAutoCompact(isOn: boolean): Promise<void> {
    try {
      const repo = AppServices.get().requireModel().repo;
      await repo.putString(SettingsKeys.COMPACTION_POLICY, isOn ? 'auto' : 'off');
      this.autoCompact = isOn;
      this.statusText = isOn ? '已开启' : '已关闭';
    } catch (e) {
      this.statusText = `${(e as Error).message}`;
    }
  }

  build() {
    Scroll() {
      Column({ space: Layout.s3 }) {
        Row({ space: Layout.s3 }) {
          SymbolGlyph(Icons.memory)
            .fontSize(Layout.iconM)
            .fontColor([Theme.iconSecondary])
          Text('缓存过期自动整理')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoCompact })
            .selectedColor(Theme.brand)
            .onChange((isOn: boolean) => {
              this.toggleAutoCompact(isOn);
            })
        }
        .width('100%')
        .padding(Layout.s3)
        .backgroundColor(Theme.bgSurface)
        .borderRadius(Layout.radiusL)
        .border({ width: 1, color: Theme.border })

        Row({ space: Layout.s3 }) {
          SymbolGlyph(Icons.retry)
            .fontSize(Layout.iconM)
            .fontColor([Theme.iconSecondary])
          Text('切换模型时自动整理')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
          Text('已开启')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.brand)
        }
        .width('100%')
        .padding(Layout.s3)
        .backgroundColor(Theme.bgSurface)
        .borderRadius(Layout.radiusL)
        .border({ width: 1, color: Theme.border })

        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .width('100%')
        }
      }
      .width('100%')
      .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s3, bottom: Layout.s8 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }
}
