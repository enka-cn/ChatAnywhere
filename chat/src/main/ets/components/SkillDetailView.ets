/**
 * 技能详情（v3 右栏）。
 *
 * 全局启用卡（分级 + Switch）、能力参数卡（按 configSchema 自动渲染）、域名 chips、
 * 回滚上一版 / 试跑 / 导出 / 删除；导出与删除结果交给父级提示。
 */
import { DryRunReport, SkillConfigField, SkillSummary, UpgradeResult } from '@app/core_plugin';
import { AppServices } from '../app/AppServices';
import { Icons, Layout, Theme } from '../app/Theme';
import { ConfigForm } from './ConfigForm';
import { tierLabel } from './SkillCard';

const TIER_L3: string = 'L3_QUICKJS_SANDBOX';

@Component
export struct SkillDetailView {
  @Prop @Watch('onSkillChanged') skillId: string = '';
  @Prop skillName: string = '';
  /** 启用/配置/回滚后通知父级刷新列表。 */
  onChanged: () => void = () => {
  };
  /** 删除完成后通知父级退出详情。 */
  onClosed: () => void = () => {
  };
  /** 导出清单（父级负责剪贴板与提示）。 */
  onExport: (skillId: string) => void = (skillId: string) => {
  };

  @State private badge: string = '';
  @State private version: string = '';
  @State private skillEnabled: boolean = false;
  @State private domains: string[] = [];
  @State private fields: SkillConfigField[] = [];
  @State private savedConfig: string = '';
  @State private result: string = '';
  @State private message: string = '';
  @State private messageError: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  /** 右栏切换到另一个技能时重新载入。 */
  private onSkillChanged(): void {
    this.message = '';
    this.result = '';
    this.load();
  }

  private load(): void {
    try {
      const list: SkillSummary[] = AppServices.get().requirePlugin().kernel.list();
      for (const one of list) {
        if (one.id === this.skillId) {
          this.apply(one);
          return;
        }
      }
    } catch (e) {
      this.setMessage(`${(e as Error).message}`, true);
    }
  }

  private apply(summary: SkillSummary): void {
    const label: string = summary.tier === TIER_L3 ? '' : tierLabel(summary.tier);
    this.badge = label;
    this.version = summary.version;
    this.skillEnabled = summary.enabled;
    this.domains = summary.allowedDomains !== undefined ? summary.allowedDomains : [];
    this.fields = summary.configSchema !== undefined ? summary.configSchema : [];
    this.savedConfig = summary.savedConfigJson !== undefined ? summary.savedConfigJson : '';
  }

  private setMessage(text: string, isError: boolean): void {
    this.message = text;
    this.messageError = isError;
  }

  private async toggleEnabled(isOn: boolean): Promise<void> {
    try {
      await AppServices.get().requirePlugin().kernel.setEnabled(this.skillId, isOn);
      this.skillEnabled = isOn;
      this.setMessage(isOn ? '已启用' : '已停用', false);
    } catch (e) {
      this.setMessage(`切换失败：${(e as Error).message}`, true);
    }
    this.onChanged();
  }

  private async saveConfig(configJson: string): Promise<void> {
    try {
      const result: UpgradeResult =
        await AppServices.get().requirePlugin().kernel.updateConfig(this.skillId, configJson);
      if (result.ok) {
        this.savedConfig = configJson;
        this.setMessage('参数已保存', false);
      } else {
        const reason: string = result.error !== undefined && result.error.length > 0 ? result.error : '校验未通过';
        this.setMessage(`保存失败：${reason}`, true);
      }
    } catch (e) {
      this.setMessage(`保存失败：${(e as Error).message}`, true);
    }
    this.onChanged();
  }

  private async dryRun(): Promise<void> {
    this.result = '试跑中';
    try {
      const kernel = AppServices.get().requirePlugin().kernel;
      const report: DryRunReport = await kernel.dryRun(kernel.exportManifest(this.skillId), '鸿蒙 开发');
      const head: string = report.passed ? '试跑通过' : '试跑未通过';
      const reason: string = report.error !== undefined && report.error.length > 0 ? `：${report.error}` : '';
      const sample: string = report.sampleOutput.length > 160
        ? `${report.sampleOutput.substring(0, 160)}…` : report.sampleOutput;
      this.result = `${head} · ${report.latencyMs} 毫秒${reason}\n${sample}`;
    } catch (e) {
      this.result = `试跑失败：${(e as Error).message}`;
    }
  }

  private async rollback(): Promise<void> {
    try {
      const ok: boolean = await AppServices.get().requirePlugin().kernel.rollback(this.skillId);
      this.setMessage(ok ? '已回滚上一版' : '无可回滚版本', !ok);
    } catch (e) {
      this.setMessage(`回滚失败：${(e as Error).message}`, true);
    }
    this.load();
    this.onChanged();
  }

  private confirmDelete(): void {
    const name: string = this.skillName.length > 0 ? this.skillName : this.skillId;
    this.getUIContext().showAlertDialog({
      title: '删除技能',
      message: `${name} 及其版本快照将一并删除。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: () => {
          this.deleteSkill();
        }
      }
    });
  }

  private async deleteSkill(): Promise<void> {
    try {
      await AppServices.get().requirePlugin().kernel.remove(this.skillId);
      this.onClosed();
      return;
    } catch (e) {
      this.setMessage(`删除失败：${(e as Error).message}`, true);
    }
    this.onChanged();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @Builder
  actionItem(icon: Resource, label: string, danger: boolean, onTap: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(Layout.iconM)
        .fontColor([danger ? Theme.danger : Theme.iconPrimary])
      Text(label)
        .fontSize(Layout.fontCaption)
        .fontColor(danger ? Theme.danger : Theme.textSecondary)
    }
    .padding({ left: Layout.s3, right: Layout.s3, top: Layout.s2, bottom: Layout.s2 })
    .borderRadius(Layout.radiusM)
    .backgroundColor(Theme.bgSurface)
    .onClick(onTap)
  }

  build() {
    Scroll() {
      Column({ space: Layout.s3 }) {
        // 全局启用
        Row({ space: Layout.s3 }) {
          Column({ space: 2 }) {
            Text('全局启用')
              .fontSize(Layout.fontUi)
              .fontColor(Theme.textPrimary)
            Row({ space: Layout.s2 }) {
              if (this.badge.length > 0) {
                Text(this.badge)
                  .fontSize(Layout.fontCaption)
                  .fontColor(Theme.chipText)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(Layout.radiusS)
                  .backgroundColor(Theme.chipBg)
              }
              Text(`v${this.version}`)
                .fontSize(Layout.fontCaption)
                .fontColor(Theme.textTertiary)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.skillEnabled })
            .selectedColor(Theme.brand)
            .onChange((isOn: boolean) => {
              this.toggleEnabled(isOn);
            })
        }
        .width('100%')
        .padding(Layout.s3)
        .backgroundColor(Theme.bgSurface)
        .borderRadius(Layout.radiusL)
        .border({ width: 1, color: Theme.border })

        // 域名
        if (this.domains.length > 0) {
          Column({ space: Layout.s2 }) {
            Text('可访问域名')
              .fontSize(Layout.fontSmall)
              .fontColor(Theme.textSecondary)
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.domains, (domain: string) => {
                Text(domain)
                  .fontSize(Layout.fontCaption)
                  .fontColor(Theme.chipText)
                  .padding({ left: Layout.s2, right: Layout.s2, top: 3, bottom: 3 })
                  .borderRadius(Layout.radiusPill)
                  .backgroundColor(Theme.chipBg)
                  .margin({ right: Layout.s2, bottom: Layout.s2 })
              }, (domain: string) => domain)
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

        // 能力参数
        Column({ space: Layout.s2 }) {
          Text('能力参数')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .width('100%')
          ConfigForm({
            skillId: this.skillId,
            fields: this.fields,
            savedConfigJson: this.savedConfig,
            onSave: (configJson: string) => {
              this.saveConfig(configJson);
            }
          })
        }
        .width('100%')
        .padding(Layout.s3)
        .backgroundColor(Theme.bgSurface)
        .borderRadius(Layout.radiusL)
        .border({ width: 1, color: Theme.border })
        .alignItems(HorizontalAlign.Start)

        // 操作
        Row({ space: Layout.s2 }) {
          this.actionItem(Icons.retry, '回滚上一版', false, () => {
            this.rollback();
          })
          this.actionItem(Icons.sparkles, '试跑', false, () => {
            this.dryRun();
          })
          this.actionItem(Icons.download, '导出', false, () => {
            this.onExport(this.skillId);
          })
          Blank()
          this.actionItem(Icons.trash, '删除', true, () => {
            this.confirmDelete();
          })
        }
        .width('100%')

        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(Layout.fontSmall)
            .fontColor(this.messageError ? Theme.danger : Theme.success)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        if (this.result.length > 0) {
          Text(this.result)
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .width('100%')
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(Layout.lineTight)
            .padding(Layout.s3)
            .borderRadius(Layout.radiusM)
            .backgroundColor(Theme.codeBg)
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
