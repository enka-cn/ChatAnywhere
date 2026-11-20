/**
 * 技能列表行（v3 Master 左栏）：名称 + 分级 + 全局开关。
 *
 * 分级只展示「声明式 / 远程 MCP」；L3 类型不展示、不进列表。
 */
import { SkillConfigField, SkillSummary } from '@app/core_plugin';
import { Layout, Theme } from '../app/Theme';

/** 分级中文标签；L3/未知返回空串，UI 不展示。 */
export function tierLabel(tier: string): string {
  if (tier === 'L1_DECLARATIVE') {
    return '声明式';
  }
  if (tier === 'L2_REMOTE_MCP') {
    return '远程 MCP';
  }
  return '';
}

/** 卡片可观察状态。 */
@Observed
export class SkillCardState {
  id: string = '';
  name: string = '';
  description: string = '';
  version: string = '';
  tier: string = '';
  badge: string = '';
  enabled: boolean = false;
  mounted: boolean = false;
  allowedDomains: string[] = [];
  fields: SkillConfigField[] = [];
  savedConfigJson: string = '';
  /** 最近一次操作结果（保留给调用方展示）。 */
  lastResult: string = '';
}

/** 由内核摘要构造列表状态。 */
export function toSkillCardState(summary: SkillSummary): SkillCardState {
  const state: SkillCardState = new SkillCardState();
  state.id = summary.id;
  state.name = summary.name.length > 0 ? summary.name : summary.id;
  state.description = summary.description;
  state.version = summary.version.length > 0 ? summary.version : '1.0';
  state.tier = summary.tier;
  state.badge = tierLabel(summary.tier);
  state.enabled = summary.enabled;
  state.mounted = summary.mounted;
  state.allowedDomains = summary.allowedDomains !== undefined ? summary.allowedDomains : [];
  state.fields = summary.configSchema !== undefined ? summary.configSchema : [];
  state.savedConfigJson = summary.savedConfigJson !== undefined ? summary.savedConfigJson : '';
  return state;
}

/** 列表行。 */
@Component
export struct SkillCard {
  @ObjectLink card: SkillCardState;
  /** 是否为当前选中项（展开态右栏对应技能）。 */
  @Prop selected: boolean = false;
  onOpen: (skillId: string) => void = (skillId: string) => {
  };
  onToggleEnabled: (skillId: string, enabled: boolean) => void = (skillId: string, enabled: boolean) => {
  };

  build() {
    Row({ space: Layout.s2 }) {
      Column({ space: 2 }) {
        Text(this.card.name)
          .fontSize(Layout.fontUi)
          .fontColor(this.selected ? Theme.textPrimary : Theme.textSecondary)
          .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.card.badge.length > 0 ? this.card.badge : '技能')
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
          .maxLines(1)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.card.enabled })
        .selectedColor(Theme.brand)
        .onChange((isOn: boolean) => {
          this.onToggleEnabled(this.card.id, isOn);
        })
    }
    .width('100%')
    .padding({ left: Layout.s3, right: Layout.s3, top: Layout.s2, bottom: Layout.s2 })
    .borderRadius(Layout.radiusM)
    .backgroundColor(this.selected ? Theme.bgSurface2 : Color.Transparent)
    .onClick(() => {
      this.onOpen(this.card.id);
    })
  }
}
