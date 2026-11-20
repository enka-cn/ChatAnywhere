/**
 * 我的技能（v3 Master-Detail）。
 *
 * 展开态：左栏 232vp 技能列表（名称 + 分级 + 全局开关）+ 右栏详情；
 * 折叠态：列表 → 详情二级栈（详情顶栏出现返回箭头）。
 * L3 类型技能不在 UI 出现。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SkillSummary, UpgradeResult } from '@app/core_plugin';
import { RouteUrls, SkillCreatorParams } from '../app/Routes';
import { AppServices } from '../app/AppServices';
import { Breakpoint, BreakpointWatcher } from '../app/Breakpoint';
import { Icons, Layout, Theme } from '../app/Theme';
import { SkillCard, SkillCardState, toSkillCardState } from '../components/SkillCard';
import { SkillDetailView } from '../components/SkillDetailView';

const DOMAIN: number = 0x1A2B;
const TAG: string = 'ChatAnyWhere/SkillManager';
const TIER_L3: string = 'L3_QUICKJS_SANDBOX';

@Entry
@Component
struct SkillManagerPage {
  @State private loading: boolean = true;
  @State private ready: boolean = false;
  @State private pluginMissing: boolean = false;
  @State private pluginError: string = '';
  @State private cards: SkillCardState[] = [];
  @State private detailId: string = '';
  @State private detailName: string = '';
  @State private unfolded: boolean = false;
  @State private foldedDetail: boolean = false;
  @State private message: string = '';
  @State private messageError: boolean = false;
  @State private busying: boolean = false;

  @State private sheetOpen: boolean = false;
  @State private importJson: string = '';

  private watcher: BreakpointWatcher | null = null;
  private openSkillId: string = '';

  aboutToAppear(): void {
    this.unfolded = Breakpoint.isUnfolded(this.getUIContext());
    this.watcher = Breakpoint.watch(this.getUIContext(), (unfolded: boolean) => {
      this.unfolded = unfolded;
      if (unfolded) {
        this.foldedDetail = false;
      }
    });
    this.readParams();
    this.bootstrap();
  }

  aboutToDisappear(): void {
    if (this.watcher !== null) {
      this.watcher.dispose();
      this.watcher = null;
    }
  }

  /** 折叠态：系统返回先退回技能列表。 */
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
      const open: Object = record['openSkillId'];
      if (typeof open === 'string') {
        this.openSkillId = open as string;
      }
    } catch (e) {
      this.openSkillId = '';
    }
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    try {
      const services = AppServices.get();
      this.ready = await services.waitReady();
      this.pluginMissing = !services.hasPlugin();
      this.pluginError = services.pluginError;
      if (this.ready) {
        this.refresh();
      }
    } catch (e) {
      this.pluginError = `${(e as Error).message}`;
      this.pluginMissing = true;
    }
    this.loading = false;
  }

  private refresh(): void {
    const services = AppServices.get();
    if (!services.hasPlugin()) {
      this.pluginMissing = true;
      this.cards = [];
      return;
    }
    this.pluginMissing = false;
    try {
      const list: SkillSummary[] = services.requirePlugin().kernel.list();
      const next: SkillCardState[] = [];
      for (const one of list) {
        if (one.tier === TIER_L3) {
          continue;
        }
        next.push(toSkillCardState(one));
      }
      this.cards = next;
      if (this.detailId.length === 0 || !this.hasCard(this.detailId)) {
        let target: string = '';
        if (this.openSkillId.length > 0 && this.hasCard(this.openSkillId)) {
          target = this.openSkillId;
        } else if (this.cards.length > 0) {
          target = this.cards[0].id;
        }
        this.detailId = target;
        this.detailName = this.nameOf(target);
      } else {
        this.detailName = this.nameOf(this.detailId);
      }
    } catch (e) {
      this.setMessage(`读取失败：${(e as Error).message}`, true);
    }
  }

  private hasCard(skillId: string): boolean {
    for (const one of this.cards) {
      if (one.id === skillId) {
        return true;
      }
    }
    return false;
  }

  private nameOf(skillId: string): string {
    for (const one of this.cards) {
      if (one.id === skillId) {
        return one.name;
      }
    }
    return '';
  }

  private setMessage(text: string, isError: boolean): void {
    this.message = text;
    this.messageError = isError;
  }

  private openDetail(skillId: string): void {
    this.detailId = skillId;
    this.detailName = this.nameOf(skillId);
    this.foldedDetail = true;
  }

  private async toggleEnabled(skillId: string, enabled: boolean): Promise<void> {
    try {
      await AppServices.get().requirePlugin().kernel.setEnabled(skillId, enabled);
      this.setMessage(enabled ? '已启用' : '已停用', false);
    } catch (e) {
      this.setMessage(`切换失败：${(e as Error).message}`, true);
    }
    this.refresh();
  }

  private async exportSkill(skillId: string): Promise<void> {
    try {
      const json: string = AppServices.get().requirePlugin().kernel.exportManifest(skillId);
      if (json.length === 0) {
        this.setMessage('导出失败', true);
        return;
      }
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, json);
      await pasteboard.getSystemPasteboard().setData(data);
      this.setMessage('清单已复制', false);
    } catch (e) {
      this.setMessage(`导出失败：${(e as Error).message}`, true);
    }
  }

  private async importJsonManifest(): Promise<void> {
    const text: string = this.importJson.trim();
    if (text.length === 0) {
      this.setMessage('内容为空', true);
      return;
    }
    this.busying = true;
    try {
      const result: UpgradeResult = await AppServices.get().requirePlugin().kernel.importManifest(text);
      if (result.ok) {
        this.importJson = '';
        this.sheetOpen = false;
        this.setMessage('已导入', false);
      } else {
        const reason: string = result.error !== undefined && result.error.length > 0 ? result.error : '校验未通过';
        this.setMessage(`导入失败：${reason}`, true);
      }
    } catch (e) {
      this.setMessage(`导入失败：${(e as Error).message}`, true);
    }
    this.busying = false;
    this.refresh();
  }

  private goCreator(targetSkillId: string): void {
    const params: SkillCreatorParams = { targetSkillId: targetSkillId, nodeId: '' };
    this.getUIContext().getRouter().pushUrl({ url: RouteUrls.SKILL_CREATOR, params: params }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'open creator failed: %{public}s', err.message);
    });
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

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
      Text('技能')
        .fontSize(Layout.fontTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
      Text('导入')
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textPrimary)
        .padding({ left: Layout.s2, right: Layout.s2, top: 4, bottom: 4 })
        .borderRadius(Layout.radiusS)
        .backgroundColor(Theme.bgSurface)
        .onClick(() => {
          this.sheetOpen = true;
        })
    }
    .width('100%')
    .height(Layout.topBarHeight)
    .padding({ left: Layout.s3, right: Layout.s3 })
    .border({ width: { bottom: 1 }, color: Theme.divider })
  }

  @Builder
  masterPane() {
    Column() {
      this.masterHeader()

      if (this.pluginMissing) {
        Column({ space: Layout.s2 }) {
          Text('技能模块不可用')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.warning)
          Text(this.pluginError.length > 0 ? this.pluginError : '请重启应用后再试')
            .fontSize(Layout.fontCaption)
            .fontColor(Theme.textTertiary)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding(Layout.s3)
        .alignItems(HorizontalAlign.Start)
      } else if (this.cards.length === 0) {
        Column({ space: Layout.s2 }) {
          Text('暂无技能')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.textSecondary)
          Text('新建')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.brand)
            .onClick(() => {
              this.goCreator('');
            })
        }
        .width('100%')
        .padding(Layout.s3)
        .alignItems(HorizontalAlign.Start)
      } else {
        Scroll() {
          Column({ space: Layout.s1 }) {
            ForEach(this.cards, (card: SkillCardState) => {
              SkillCard({
                card: card,
                selected: this.detailId === card.id,
                onOpen: (skillId: string) => {
                  this.openDetail(skillId);
                },
                onToggleEnabled: (skillId: string, enabled: boolean) => {
                  this.toggleEnabled(skillId, enabled);
                }
              })
            }, (card: SkillCardState) => card.id)
          }
          .width('100%')
          .padding(Layout.s2)
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }

      if (!this.pluginMissing) {
        Row({ space: Layout.s2 }) {
          SymbolGlyph(Icons.plus)
            .fontSize(Layout.iconM)
            .fontColor([Theme.brand])
          Text('新建技能')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.brand)
          Blank()
        }
        .width('100%')
        .padding(Layout.s3)
        .onClick(() => {
          this.goCreator('');
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgPage)
  }

  @Builder
  detailHeader() {
    Row({ space: Layout.s2 }) {
      if (!this.unfolded) {
        SymbolGlyph(Icons.backArrow)
          .fontSize(Layout.iconM)
          .fontColor([Theme.iconSecondary])
          .padding(Layout.s1)
          .borderRadius(Layout.radiusS)
          .backgroundColor(Theme.bgSurface)
          .onClick(() => {
            this.foldedDetail = false;
          })
      }
      Text(this.detailName.length > 0 ? this.detailName : '技能详情')
        .fontSize(Layout.fontTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.detailId.length > 0) {
        Text('编辑 SKILL.md')
          .fontSize(Layout.fontSmall)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.brand)
          .padding({ left: Layout.s3, right: Layout.s3, top: 5, bottom: 5 })
          .borderRadius(Layout.radiusS)
          .backgroundColor(Theme.brandSubtle)
          .onClick(() => {
            this.goCreator(this.detailId);
          })
      }
    }
    .width('100%')
    .height(Layout.topBarHeight)
    .padding({ left: Layout.s3, right: Layout.s3 })
    .border({ width: { bottom: 1 }, color: Theme.divider })
  }

  @Builder
  detailPane() {
    Column() {
      this.detailHeader()
      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(Layout.fontSmall)
          .fontColor(this.messageError ? Theme.danger : Theme.success)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s2 })
      }
      Column() {
        if (this.detailId.length > 0) {
          SkillDetailView({
            skillId: this.detailId,
            skillName: this.detailName,
            onChanged: () => {
              this.refresh();
            },
            onExport: (skillId: string) => {
              this.exportSkill(skillId);
            },
            onClosed: () => {
              this.detailId = '';
              this.refresh();
            }
          })
        } else {
          Text('选择左侧技能查看详情')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.textTertiary)
            .padding(Layout.pagePadding)
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  sheetContent() {
    Column({ space: Layout.s3 }) {
      Text('粘贴技能清单')
        .fontSize(Layout.fontBodyLarge)
        .fontColor(Theme.textPrimary)
        .width('100%')
      TextArea({ text: this.importJson, placeholder: '技能 JSON' })
        .fontSize(Layout.fontSmall)
        .height(200)
        .width('100%')
        .backgroundColor(Theme.bgInput)
        .borderRadius(Layout.radiusM)
        .onChange((value: string) => {
          this.importJson = value;
        })
      Row({ space: Layout.s3 }) {
        Text(this.busying ? '处理中' : '导入')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textOnBrand)
          .padding({ left: Layout.s5, right: Layout.s5, top: 8, bottom: 8 })
          .borderRadius(Layout.radiusM)
          .backgroundColor(Theme.brand)
          .onClick(() => {
            this.importJsonManifest();
          })
        Text('取消')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textSecondary)
          .padding({ left: Layout.s5, right: Layout.s5, top: 8, bottom: 8 })
          .borderRadius(Layout.radiusM)
          .backgroundColor(Theme.bgSurface2)
          .onClick(() => {
            this.sheetOpen = false;
          })
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .padding(Layout.pagePadding)
    .alignItems(HorizontalAlign.Start)
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
        Row() {
          Column() {
            this.masterPane()
          }
          .width(Layout.sidebarSkills)
          .height('100%')

          Divider()
            .vertical(true)
            .color(Theme.divider)
            .height('100%')

          Column() {
            this.detailPane()
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
      } else if (!this.foldedDetail) {
        Column() {
          this.masterPane()
        }
        .width('100%')
        .height('100%')
      } else {
        Column() {
          this.detailPane()
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgPage)
    .bindSheet(this.sheetOpen, this.sheetContent(), {
      height: SheetSize.FIT_CONTENT,
      preferType: SheetType.BOTTOM,
      showClose: true,
      onWillDismiss: (action: DismissSheetAction) => {
        this.sheetOpen = false;
        action.dismiss();
      }
    })
  }
}
