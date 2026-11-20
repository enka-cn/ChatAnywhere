/**
 * 设置 · 跨端与数据（v3 卡片）。
 *
 * 电脑局域网编辑（开关 + 地址复制 + 离开视图释放端口）、对话历史导出/导入、
 * 重建索引、通知权限、分享内容整理。操作结果只占一行。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ExportResult, ImportResult, SessionMeta } from '@app/core_model';
import { AppServices } from '../app/AppServices';
import { Icons, Layout, Theme } from '../app/Theme';
import { LanEditorServer, LanServerInfo } from '../bridge/LanEditorServer';
import { LiveViewBridge } from '../bridge/LiveViewBridge';
import { SettingsShareView } from './SettingsShareView';

const DOMAIN: number = 0x1A2B;
const TAG: string = 'ChatAnyWhere/SettingsData';

@Component
export struct SettingsDataView {
  @State private statusText: string = '';
  @State private statusError: boolean = false;

  @State private lanOn: boolean = false;
  @State private lanBusy: boolean = false;
  @State private lanUrl: string = '';
  @State private lanHint: string = '';

  @State private notifyOn: boolean = false;

  @State private exportBusy: boolean = false;
  @State private exportText: string = '';
  @State private exportPath: string = '';

  @State private importOpen: boolean = false;
  @State private importPath: string = '';
  @State private importBusy: boolean = false;

  @State private indexBusy: boolean = false;
  @State private indexText: string = '';
  @State private hasShared: boolean = false;

  private lanStartedHere: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.releaseLan();
  }

  private load(): void {
    this.notifyOn = LiveViewBridge.get().isSupported();
    const lan: LanEditorServer = LanEditorServer.get();
    this.lanOn = lan.isRunning();
    const info: LanServerInfo | null = lan.currentInfo();
    if (info !== null) {
      this.lanUrl = info.url;
      this.lanHint = info.ip === '127.0.0.1' ? '未获取到局域网地址' : info.note;
    }
    this.hasShared = true;
  }

  private setStatus(text: string, isError: boolean): void {
    this.statusText = text;
    this.statusError = isError;
  }

  private releaseLan(): void {
    if (!this.lanStartedHere) {
      return;
    }
    this.lanStartedHere = false;
    this.lanOn = false;
    this.lanUrl = '';
    this.lanHint = '';
    if (LanEditorServer.get().isRunning()) {
      LanEditorServer.get().stop().catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'release lan port failed: %{public}s', err.message);
      });
    }
  }

  private async toggleLan(enabled: boolean): Promise<void> {
    if (this.lanBusy) {
      return;
    }
    this.lanBusy = true;
    this.lanOn = enabled;
    try {
      if (enabled) {
        const info: LanServerInfo = await LanEditorServer.get().start(8123);
        this.lanStartedHere = true;
        this.lanUrl = info.url;
        this.lanHint = info.ip === '127.0.0.1' ? '未获取到局域网地址' : info.note;
        this.lanOn = true;
      } else {
        await LanEditorServer.get().stop();
        this.lanStartedHere = false;
        this.lanUrl = '';
        this.lanHint = '';
        this.lanOn = false;
      }
      this.setStatus('', false);
    } catch (e) {
      this.lanOn = false;
      this.lanUrl = '';
      this.lanHint = '';
      this.setStatus(`${(e as Error).message}`, true);
    }
    this.lanBusy = false;
  }

  private async askNotify(): Promise<void> {
    await LiveViewBridge.get().requestNotificationPermission();
    this.notifyOn = LiveViewBridge.get().isSupported();
    this.setStatus(this.notifyOn ? '通知已开启' : '未获得通知权限', !this.notifyOn);
  }

  private async exportAll(): Promise<void> {
    if (this.exportBusy) {
      return;
    }
    this.exportBusy = true;
    try {
      const result: ExportResult = await AppServices.get().requireModel().exporter.exportAll();
      this.exportPath = result.filePath;
      this.exportText = `${result.sessionCount} 段 · ${this.formatBytes(result.bytes)}`;
      this.setStatus('导出完成', false);
    } catch (e) {
      this.exportText = '';
      this.setStatus(`导出失败：${(e as Error).message}`, true);
    }
    this.exportBusy = false;
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  private async copyText(text: string, tip: string): Promise<void> {
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.setStatus(tip, false);
    } catch (e) {
      this.setStatus(`复制失败：${(e as Error).message}`, true);
    }
  }

  private async importZip(): Promise<void> {
    const path: string = this.importPath.trim();
    if (path.length === 0) {
      this.setStatus('请填写压缩包路径', true);
      return;
    }
    this.importBusy = true;
    try {
      const result: ImportResult = await AppServices.get().requireModel().exporter.importZip(path);
      this.setStatus(`导入 ${result.sessions.length} 段，跳过 ${result.skipped} 段`, false);
      this.importPath = '';
      this.importOpen = false;
    } catch (e) {
      this.setStatus(`导入失败：${(e as Error).message}`, true);
    }
    this.importBusy = false;
  }

  private async rebuildIndex(): Promise<void> {
    if (this.indexBusy) {
      return;
    }
    this.indexBusy = true;
    this.indexText = '进行中';
    try {
      const repo = AppServices.get().requireModel().repo;
      const sessions: SessionMeta[] = await repo.listSessions(500);
      for (const one of sessions) {
        await repo.reindexSession(one.sessionId);
      }
      this.indexText = `${sessions.length} 段`;
      this.setStatus('索引已重建', false);
    } catch (e) {
      this.indexText = '';
      this.setStatus(`重建失败：${(e as Error).message}`, true);
    }
    this.indexBusy = false;
  }

  @Builder
  statusLine() {
    if (this.statusText.length > 0) {
      Text(this.statusText)
        .fontSize(Layout.fontSmall)
        .fontColor(this.statusError ? Theme.danger : Theme.success)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  @Builder
  lanCard() {
    Column({ space: Layout.s2 }) {
      Row({ space: Layout.s3 }) {
        SymbolGlyph(Icons.laptop)
          .fontSize(Layout.iconM)
          .fontColor([Theme.iconSecondary])
        Column({ space: 2 }) {
          Text('电脑局域网编辑')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.textPrimary)
          if (this.lanOn && this.lanUrl.length > 0) {
            Text(this.lanUrl)
              .fontSize(Layout.fontCaption)
              .fontColor(Theme.brand)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          } else if (this.lanHint.length > 0) {
            Text(this.lanHint)
              .fontSize(Layout.fontCaption)
              .fontColor(Theme.textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.lanOn && this.lanUrl.length > 0) {
          SymbolGlyph(Icons.copy)
            .fontSize(Layout.iconM)
            .fontColor([Theme.iconSecondary])
            .padding({ right: Layout.s2 })
            .onClick(() => {
              this.copyText(this.lanUrl, '地址已复制');
            })
        }
        Toggle({ type: ToggleType.Switch, isOn: this.lanOn })
          .selectedColor(Theme.brand)
          .enabled(!this.lanBusy)
          .onChange((isOn: boolean) => {
            this.toggleLan(isOn);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
  }

  @Builder
  notifyCard() {
    Row({ space: Layout.s3 }) {
      SymbolGlyph(Icons.infoCircle)
        .fontSize(Layout.iconM)
        .fontColor([Theme.iconSecondary])
      Text('通知权限')
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
      if (this.notifyOn) {
        Text('已开启')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.brand)
      } else {
        Text('允许')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.brand)
          .onClick(() => {
            this.askNotify();
          })
      }
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
  }

  @Builder
  exportCard() {
    Row({ space: Layout.s3 }) {
      SymbolGlyph(Icons.download)
        .fontSize(Layout.iconM)
        .fontColor([Theme.iconSecondary])
      Column({ space: 2 }) {
        Text('导出对话历史')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textPrimary)
        Text(this.exportText.length > 0 ? this.exportText : '全部对话打包 ZIP')
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.exportPath.length > 0) {
        SymbolGlyph(Icons.copy)
          .fontSize(Layout.iconM)
          .fontColor([Theme.iconSecondary])
          .onClick(() => {
            this.copyText(this.exportPath, '路径已复制');
          })
      }
      if (this.exportBusy) {
        Text('打包中')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textTertiary)
      } else {
        Text('导出 ZIP')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textPrimary)
          .padding({ left: Layout.s3, right: Layout.s3, top: 6, bottom: 6 })
          .borderRadius(Layout.radiusM)
          .backgroundColor(Theme.bgPage)
          .onClick(() => {
            this.exportAll();
          })
      }
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
  }

  @Builder
  importCard() {
    Column({ space: Layout.s2 }) {
      Row({ space: Layout.s3 }) {
        SymbolGlyph(Icons.upload)
          .fontSize(Layout.iconM)
          .fontColor([Theme.iconSecondary])
        Text('导入对话历史')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
        SymbolGlyph(this.importOpen ? Icons.chevronUp : Icons.chevronDown)
          .fontSize(Layout.iconM)
          .fontColor([Theme.iconSecondary])
      }
      .width('100%')
      .onClick(() => {
        this.importOpen = !this.importOpen;
      })

      if (this.importOpen) {
        Row({ space: Layout.s2 }) {
          TextInput({ text: this.importPath, placeholder: '压缩包路径' })
            .fontSize(Layout.fontUi)
            .height(36)
            .layoutWeight(1)
            .backgroundColor(Theme.bgPage)
            .borderRadius(Layout.radiusM)
            .padding({ left: Layout.s3, right: Layout.s3 })
            .onChange((value: string) => {
              this.importPath = value;
            })
          Text(this.importBusy ? '导入中' : '导入')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textOnBrand)
            .padding({ left: Layout.s3, right: Layout.s3, top: 6, bottom: 6 })
            .borderRadius(Layout.radiusM)
            .backgroundColor(Theme.brand)
            .onClick(() => {
              this.importZip();
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
  }

  @Builder
  indexCard() {
    Row({ space: Layout.s3 }) {
      SymbolGlyph(Icons.database)
        .fontSize(Layout.iconM)
        .fontColor([Theme.iconSecondary])
      Text('重建检索索引')
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
      Text(this.indexBusy ? '进行中' : (this.indexText.length > 0 ? this.indexText : '重建'))
        .fontSize(Layout.fontSmall)
        .fontColor(Theme.textSecondary)
        .padding({ left: Layout.s3, right: Layout.s3, top: 6, bottom: 6 })
        .borderRadius(Layout.radiusM)
        .backgroundColor(Theme.bgPage)
        .onClick(() => {
          this.rebuildIndex();
        })
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
  }

  build() {
    Scroll() {
      Column({ space: Layout.s3 }) {
        this.statusLine()
        this.lanCard()
        this.notifyCard()
        this.exportCard()
        this.importCard()
        this.indexCard()
        if (this.hasShared) {
          SettingsShareView({
            onCleared: () => {
              this.hasShared = false;
            }
          })
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
