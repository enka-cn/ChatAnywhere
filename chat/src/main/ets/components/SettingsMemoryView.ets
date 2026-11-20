/**
 * 设置 · 记忆与缓存（v3.2 透明化）。
 *
 * 订阅运行时快照：当前对话记忆（标题/消息数/Token 与窗口占比/缓存命中/立即整理）
 * + 最近整理结果（时间、整理前后 Token、可展开摘要）；下方保留两个自动整理开关。
 */
import { SettingsKeys } from '@app/core_model';
import { AppServices } from '../app/AppServices';
import { Icons, Layout, Theme } from '../app/Theme';
import { RuntimeSnapshot } from '../model/ChatRuntimeApi';
import { getChatRuntime } from '../model/RuntimeHolder';

@Component
export struct SettingsMemoryView {
  @State private hasModel: boolean = false;
  @State private title: string = '';
  @State private nodeCount: number = 0;
  @State private contextTokens: number = 0;
  @State private contextWindow: number = 0;
  @State private cacheHitRatio: number = 0;
  @State private compacting: boolean = false;
  @State private lastCompactionAt: number = 0;
  @State private lastBeforeTokens: number = 0;
  @State private lastAfterTokens: number = 0;
  @State private lastSummary: string = '';
  @State private summaryOpen: boolean = false;

  @State private autoCompact: boolean = true;
  @State private statusText: string = '';

  private listenerId: number = -1;

  aboutToAppear(): void {
    this.loadPolicy();
    try {
      const runtime = getChatRuntime();
      this.applySnapshot(runtime.snapshot());
      this.listenerId = runtime.subscribe((snapshot: RuntimeSnapshot) => {
        this.applySnapshot(snapshot);
      });
    } catch (e) {
      this.statusText = `${(e as Error).message}`;
    }
  }

  aboutToDisappear(): void {
    if (this.listenerId >= 0) {
      try {
        getChatRuntime().unsubscribe(this.listenerId);
      } catch (e) {
        // 运行时已释放时忽略
      }
      this.listenerId = -1;
    }
  }

  private applySnapshot(snapshot: RuntimeSnapshot): void {
    this.hasModel = snapshot.hasModel;
    this.title = snapshot.title;
    this.nodeCount = snapshot.nodeCount;
    this.contextTokens = snapshot.contextTokens;
    this.contextWindow = snapshot.contextWindow;
    this.cacheHitRatio = snapshot.cacheHitRatio;
    this.compacting = snapshot.compacting;
    this.lastCompactionAt = snapshot.lastCompactionAt;
    this.lastBeforeTokens = snapshot.lastCompactionBeforeTokens;
    this.lastAfterTokens = snapshot.lastCompactionAfterTokens;
    this.lastSummary = snapshot.lastCompactionSummary;
  }

  private async loadPolicy(): Promise<void> {
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

  private async compactNow(): Promise<void> {
    if (this.compacting) {
      return;
    }
    this.statusText = '';
    try {
      await getChatRuntime().compactNow();
      this.statusText = '已整理';
    } catch (e) {
      this.statusText = `整理失败：${(e as Error).message}`;
    }
  }

  private formatTokens(value: number): string {
    if (value >= 1000000) {
      return `${(value / 1000000).toFixed(1)}M`;
    }
    if (value >= 1000) {
      return `${(value / 1000).toFixed(1)}K`;
    }
    return `${Math.round(value)}`;
  }

  private formatWhen(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const hh: string = d.getHours().toString().padStart(2, '0');
    const mm: string = d.getMinutes().toString().padStart(2, '0');
    return `${d.getMonth() + 1}月${d.getDate()}日 ${hh}:${mm}`;
  }

  private ratio(): number {
    if (this.contextWindow <= 0) {
      return 0;
    }
    const value: number = this.contextTokens / this.contextWindow;
    return Math.max(0, Math.min(1, value));
  }

  private ratioPercent(): number {
    return Math.round(this.ratio() * 100);
  }

  private cachePercent(): number {
    const value: number = this.cacheHitRatio * 100;
    return Math.max(0, Math.min(100, Math.round(value)));
  }

  @Builder
  memoryCard() {
    Column({ space: Layout.s2 }) {
      Row({ space: Layout.s2 }) {
        Text('当前对话记忆')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .layoutWeight(1)
        if (!this.hasModel) {
          Text('未配置模型')
            .fontSize(Layout.fontCaption)
            .fontColor(Theme.warning)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(Layout.radiusS)
            .backgroundColor(Theme.warningSubtle)
        }
      }
      .width('100%')

      Text(this.title.length > 0 ? this.title : '当前对话')
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textPrimary)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row() {
        Text(`${this.nodeCount} 条消息`)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
        Blank()
        Text(this.contextWindow > 0
          ? `${this.formatTokens(this.contextTokens)} / ${this.formatTokens(this.contextWindow)}`
          : '窗口未知')
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
      }
      .width('100%')

      Row() {
        Row()
          .width(`${this.ratioPercent()}%`)
          .height(6)
          .borderRadius(3)
          .backgroundColor(Theme.memoryColor(this.ratio()))
      }
      .width('100%')
      .height(6)
      .borderRadius(3)
      .backgroundColor(Theme.bgSurface3)

      Row() {
        Text(`占比 ${this.ratioPercent()}%`)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textSecondary)
        Blank()
        Text(`本轮缓存 ${this.cachePercent()}%`)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textSecondary)
      }
      .width('100%')

      Row({ space: Layout.s2 }) {
        Blank()
        Row({ space: Layout.s1 }) {
          if (this.compacting) {
            LoadingProgress().width(Layout.iconM).height(Layout.iconM).color(Theme.textOnBrand)
          }
          Text(this.compacting ? '整理中' : '立即整理记忆')
            .fontSize(Layout.fontSmall)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textOnBrand)
        }
        .padding({ left: Layout.s4, right: Layout.s4, top: 7, bottom: 7 })
        .borderRadius(Layout.radiusM)
        .backgroundColor(this.compacting ? Theme.brandPressed : Theme.brand)
        .onClick(() => {
          this.compactNow();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  compactionCard() {
    Column({ space: Layout.s2 }) {
      Row() {
        Text('最近整理结果')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .layoutWeight(1)
        if (this.lastCompactionAt > 0) {
          Text(this.formatWhen(this.lastCompactionAt))
            .fontSize(Layout.fontCaption)
            .fontColor(Theme.textTertiary)
        }
      }
      .width('100%')

      if (this.lastCompactionAt <= 0) {
        Text('还没有整理记录')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textTertiary)
          .width('100%')
      } else {
        Text(`${this.formatTokens(this.lastBeforeTokens)} → ${this.formatTokens(this.lastAfterTokens)}`)
          .fontSize(Layout.fontBodyLarge)
          .fontColor(Theme.brand)
          .width('100%')

        if (this.lastSummary.length > 0) {
          Row() {
            Text('摘要')
              .fontSize(Layout.fontSmall)
              .fontColor(Theme.textSecondary)
              .layoutWeight(1)
            SymbolGlyph(this.summaryOpen ? Icons.chevronUp : Icons.chevronDown)
              .fontSize(Layout.iconS)
              .fontColor([Theme.iconSecondary])
          }
          .width('100%')
          .onClick(() => {
            this.summaryOpen = !this.summaryOpen;
          })
          if (this.summaryOpen) {
            Text(this.lastSummary)
              .fontSize(Layout.fontSmall)
              .fontColor(Theme.textSecondary)
              .width('100%')
              .lineHeight(Layout.lineTight)
              .padding(Layout.s2)
              .borderRadius(Layout.radiusM)
              .backgroundColor(Theme.bgPage)
          }
        }
      }
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  switchCard() {
    Column() {
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

      Divider().color(Theme.divider).margin({ left: Layout.s3 })

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
    }
    .width('100%')
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
  }

  build() {
    Scroll() {
      Column({ space: Layout.s3 }) {
        this.memoryCard()
        this.compactionCard()
        this.switchCard()
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
