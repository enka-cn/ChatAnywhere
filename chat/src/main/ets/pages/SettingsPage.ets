/**
 * 设置中心（v3 Master-Detail）。
 *
 * 展开态（≥600vp）：左栏 216vp 分类列表 + 右栏配置页；
 * 折叠态（<600vp）：分类列表 → 推入配置二级栈页（详情顶栏出现返回箭头）。
 * 分类：角色与提示词 / 模型与密钥 / 记忆与缓存 / 跨端与数据。
 */
import { bundleManager } from '@kit.AbilityKit';
import { AppServices } from '../app/AppServices';
import { Breakpoint, BreakpointWatcher } from '../app/Breakpoint';
import { Icons, Layout, Theme } from '../app/Theme';
import { IconBtn } from '../components/IconBtn';
import { SettingsDataView } from '../components/SettingsDataView';
import { SettingsMemoryView } from '../components/SettingsMemoryView';
import { SettingsModelsView } from '../components/SettingsModelsView';
import { SettingsPersonaView } from '../components/SettingsPersonaView';

class SettingsCategory {
  id: string = '';
  label: string = '';
  icon: Resource = Icons.settings;
}

const CATEGORIES: SettingsCategory[] = [
  { id: 'personas', label: '角色与提示词', icon: Icons.persona },
  { id: 'models', label: '模型与密钥', icon: Icons.model },
  { id: 'memory', label: '记忆与缓存', icon: Icons.memory },
  { id: 'sync', label: '跨端与数据', icon: Icons.laptop }
];

@Entry
@Component
struct SettingsPage {
  @State private loading: boolean = true;
  @State private ready: boolean = false;
  @State private initError: string = '';
  @State private retrying: boolean = false;
  @State private versionText: string = '';

  @State private category: string = 'personas';
  @State private unfolded: boolean = false;
  @State private foldedDetail: boolean = false;

  private watcher: BreakpointWatcher | null = null;

  aboutToAppear(): void {
    this.unfolded = Breakpoint.isUnfolded(this.getUIContext());
    this.watcher = Breakpoint.watch(this.getUIContext(), (unfolded: boolean) => {
      this.unfolded = unfolded;
      if (unfolded) {
        this.foldedDetail = false;
      }
    });
    this.readParams();
    this.versionText = this.readVersion();
    this.bootstrap();
  }

  aboutToDisappear(): void {
    if (this.watcher !== null) {
      this.watcher.dispose();
      this.watcher = null;
    }
  }

  private readVersion(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(0);
      return info.versionName.length > 0 ? info.versionName : '0.1.0';
    } catch (e) {
      return '0.1.0';
    }
  }

  onPageShow(): void {
    if (!this.loading) {
      this.initError = AppServices.get().initError;
      this.ready = AppServices.get().isReady();
    }
  }

  /** 折叠态：系统返回先退回分类列表。 */
  onBackPress(): boolean {
    if (!this.unfolded && this.foldedDetail) {
      this.foldedDetail = false;
      return true;
    }
    return false;
  }

  private readParams(): void {
    try {
      const raw: Object = this.getUIContext().getRouter().getParams();
      if (raw === undefined || raw === null) {
        return;
      }
      const record: Record<string, Object> = raw as Record<string, Object>;
      const category: Object = record['category'];
      if (typeof category === 'string') {
        const value: string = category as string;
        if (value === 'personas' || value === 'models' || value === 'memory' || value === 'sync') {
          this.category = value;
          this.foldedDetail = true;
        }
      }
    } catch (e) {
      this.category = 'personas';
    }
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    this.ready = await AppServices.get().waitReady();
    this.initError = AppServices.get().initError;
    this.loading = false;
  }

  private async retry(): Promise<void> {
    if (this.retrying) {
      return;
    }
    this.retrying = true;
    try {
      await AppServices.get().retryInit();
    } catch (e) {
      this.initError = `${(e as Error).message}`;
    }
    this.retrying = false;
    this.ready = AppServices.get().isReady();
    this.initError = AppServices.get().initError;
  }

  private categoryLabel(): string {
    for (const one of CATEGORIES) {
      if (one.id === this.category) {
        return one.label;
      }
    }
    return '设置';
  }

  private selectCategory(id: string): void {
    this.category = id;
    this.foldedDetail = true;
  }

  @Builder
  masterHeader() {
    Row({ space: Layout.s2 }) {
      SymbolGlyph(Icons.backArrow)
        .fontSize(Layout.iconM)
        .fontColor([Theme.iconSecondary])
        .padding(Layout.s1)
        .borderRadius(Layout.radiusS)
        .backgroundColor(Theme.bgSurface)
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })
      Text('设置')
        .fontSize(Layout.fontTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
      Blank()
    }
    .width('100%')
    .height(Layout.topBarHeight)
    .padding({ left: Layout.s3, right: Layout.s3 })
    .border({ width: { bottom: 1 }, color: Theme.divider })
  }

  @Builder
  categoryRow(one: SettingsCategory) {
    Row({ space: Layout.s2 }) {
      SymbolGlyph(one.icon)
        .fontSize(Layout.iconM)
        .fontColor([this.category === one.id ? Theme.brand : Theme.iconSecondary])
      Text(one.label)
        .fontSize(Layout.fontUi)
        .fontColor(this.category === one.id ? Theme.brand : Theme.textSecondary)
        .fontWeight(this.category === one.id ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(38)
    .padding({ left: Layout.s3, right: Layout.s3 })
    .borderRadius(Layout.radiusM)
    .backgroundColor(this.category === one.id ? Theme.brandSubtle : Color.Transparent)
    .onClick(() => {
      this.selectCategory(one.id);
    })
  }

  @Builder
  masterFooter() {
    Column({ space: Layout.s1 }) {
      if (this.initError.length > 0) {
        Row({ space: Layout.s1 }) {
          SymbolGlyph(Icons.warnCircle)
            .fontSize(Layout.iconS)
            .fontColor([Theme.danger])
          Text(this.retrying ? '重试中' : '初始化异常')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.danger)
          Blank()
          Text(this.retrying ? '' : '重试')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.brand)
        }
        .width('100%')
        .padding({ left: Layout.s3, right: Layout.s3, top: Layout.s2, bottom: Layout.s2 })
        .onClick(() => {
          this.retry();
        })
      }
      Text(`v${this.versionText}`)
        .fontSize(Layout.fontCaption)
        .fontColor(Theme.textTertiary)
        .width('100%')
        .padding({ left: Layout.s3, bottom: Layout.s3 })
    }
    .width('100%')
  }

  @Builder
  masterPane() {
    Column() {
      this.masterHeader()
      Column({ space: Layout.s1 }) {
        ForEach(CATEGORIES, (one: SettingsCategory) => {
          this.categoryRow(one)
        }, (one: SettingsCategory) => one.id)
      }
      .width('100%')
      .padding(Layout.s2)
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      this.masterFooter()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgPage)
  }

  @Builder
  detailHeader() {
    Row({ space: Layout.s2 }) {
      if (!this.unfolded) {
        IconBtn({
          icon: Icons.backArrow,
          iconSize: Layout.iconM,
          iconColor: Theme.iconSecondary,
          btnSize: 34,
          bgColor: Theme.bgSurface,
          radius: Layout.radiusM,
          onTap: () => {
            this.foldedDetail = false;
          }
        })
      }
      Text(this.categoryLabel())
        .fontSize(Layout.fontTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(Layout.topBarHeight)
    .padding({ left: Layout.s3, right: Layout.s4 })
    .border({ width: { bottom: 1 }, color: Theme.divider })
  }

  @Builder
  errorView() {
    Column({ space: Layout.s3 }) {
      Text('初始化失败')
        .fontSize(Layout.fontBodyLarge)
        .fontColor(Theme.textPrimary)
      Text(this.initError)
        .fontSize(Layout.fontSmall)
        .fontColor(Theme.textSecondary)
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.retrying ? '重试中' : '重试')
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textOnBrand)
        .padding({ left: Layout.s5, right: Layout.s5, top: Layout.s2, bottom: Layout.s2 })
        .borderRadius(Layout.radiusS)
        .backgroundColor(Theme.brand)
        .onClick(() => {
          this.retry();
        })
    }
    .width('100%')
    .padding(Layout.pagePadding)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  detailBody() {
    if (!this.ready) {
      this.errorView()
    } else if (this.category === 'personas') {
      SettingsPersonaView()
    } else if (this.category === 'models') {
      SettingsModelsView()
    } else if (this.category === 'memory') {
      SettingsMemoryView()
    } else {
      SettingsDataView()
    }
  }

  @Builder
  unfoldedLayout() {
    Row() {
      Column() {
        this.masterPane()
      }
      .width(Layout.sidebarSettings)
      .height('100%')

      Divider()
        .vertical(true)
        .color(Theme.divider)
        .height('100%')

      Column() {
        this.detailHeader()
        Column() {
          this.detailBody()
        }
        .layoutWeight(1)
        .width('100%')
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  foldedLayout() {
    if (!this.foldedDetail) {
      Column() {
        this.masterPane()
      }
      .width('100%')
      .height('100%')
    } else {
      Column() {
        this.detailHeader()
        Column() {
          this.detailBody()
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
    }
  }

  build() {
    Column() {
      if (this.loading) {
        Column() {
          LoadingProgress().width(Layout.s6).height(Layout.s6).color(Theme.brand)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.unfolded) {
        this.unfoldedLayout()
      } else {
        this.foldedLayout()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgPage)
  }
}
