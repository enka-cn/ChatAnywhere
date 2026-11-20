/**
 * 顶栏模型胶囊（v3.2：只展示真实启用模型；无模型时引导去设置拉取）。
 *
 * 有模型：模型名 · 6 档思考短标签 · chevron，半模态 = 模型列表 + 思考强度滑条。
 * 无模型：胶囊显示「未选择模型」，半模态只保留一行「去设置拉取模型」。
 */
import { ModelProfile, ThinkingLevel } from '@app/core_protocol';
import { EffortLevels, EffortOption } from '../app/EffortLevels';
import { Icons, Layout, Theme } from '../app/Theme';

/** 厂商短名（半模态列表右侧的灰色说明）。 */
function vendorLabel(providerId: string): string {
  if (providerId === 'deepseek') {
    return 'DeepSeek';
  }
  if (providerId === 'anthropic') {
    return 'Anthropic';
  }
  if (providerId === 'openai_compat' || providerId === 'openai') {
    return 'OpenAI';
  }
  return '自定义';
}

@Component
export struct ModelCapsule {
  @Prop modelLabel: string = '';
  @Prop modelId: string = '';
  @Prop providerId: string = '';
  @Prop thinkingLevel: ThinkingLevel = 'med';
  /** 真实启用模型（空 = 还没从设置里拉取过）。 */
  @Prop profiles: ModelProfile[] = [];
  onSelectModel: (providerId: string, modelId: string) => void = (providerId: string, modelId: string) => {
  };
  onSelectThinking: (level: ThinkingLevel) => void = (level: ThinkingLevel) => {
  };
  /** 无模型时：关闭半模态并跳转设置「模型与密钥」。 */
  onGoSettings: () => void = () => {
  };

  @State private showSheet: boolean = false;

  @Styles
  pillPressed() {
    .opacity(Layout.pressOpacity)
    .scale({ x: 0.97, y: 0.97 })
  }

  @Styles
  pillNormal() {
    .opacity(1)
    .scale({ x: 1, y: 1 })
  }

  private effortIndex(): number {
    return EffortLevels.indexOf(this.thinkingLevel);
  }

  @Builder
  goSettingsRow() {
    Row({ space: Layout.s2 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(Icons.settings).fontSize(Layout.iconM).fontColor([Theme.brand])
      }
      .width(34)
      .height(34)
      .borderRadius(Layout.radiusM)
      .backgroundColor(Theme.brandSubtle)
      Text('去设置拉取模型')
        .fontSize(Layout.fontBody)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.brand)
        .layoutWeight(1)
      SymbolGlyph(Icons.chevronRight).fontSize(Layout.iconS).fontColor([Theme.textTertiary])
    }
    .width('100%')
    .padding({ left: Layout.s2, right: Layout.s3, top: Layout.s2, bottom: Layout.s2 })
    .borderRadius(Layout.radiusL)
    .backgroundColor(Theme.bgSurface)
    .border({ width: 1, color: Theme.border })
    .onClick(() => {
      this.showSheet = false;
      this.onGoSettings();
    })
  }

  @Builder
  sheetContent() {
    Column({ space: Layout.s4 }) {
      Text('模型与思考')
        .fontSize(Layout.fontHeadline)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary)
        .width('100%')

      if (this.profiles.length === 0) {
        this.goSettingsRow()
      } else {
        Column({ space: 8 }) {
          ForEach(this.profiles, (profile: ModelProfile) => {
            Row({ space: Layout.s2 }) {
              Text(profile.label)
                .fontSize(Layout.fontBody)
                .fontWeight(FontWeight.Medium)
                .fontColor(profile.modelId === this.modelId && profile.providerId === this.providerId
                  ? Theme.brand : Theme.textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(vendorLabel(profile.providerId))
                .fontSize(Layout.fontSmall)
                .fontColor(Theme.textTertiary)
                .fontFamily('monospace')
              if (profile.modelId === this.modelId && profile.providerId === this.providerId) {
                SymbolGlyph(Icons.check).fontSize(Layout.iconM).fontColor([Theme.brand])
              }
            }
            .width('100%')
            .padding({ left: Layout.s4, right: Layout.s4, top: 12, bottom: 12 })
            .borderRadius(Layout.radiusL)
            .backgroundColor(profile.modelId === this.modelId && profile.providerId === this.providerId
              ? Theme.brandSubtle : Theme.bgSurface)
            .border({
              width: 1,
              color: profile.modelId === this.modelId && profile.providerId === this.providerId
                ? Color.Transparent : Theme.border
            })
            .stateStyles({ pressed: this.pillPressed, normal: this.pillNormal })
            .onClick(() => {
              this.onSelectModel(profile.providerId, profile.modelId);
              this.showSheet = false;
            })
          }, (profile: ModelProfile) => `${profile.providerId}_${profile.modelId}`)
        }
        .width('100%')

        Column({ space: Layout.s3 }) {
          Row() {
            Text('思考强度')
              .fontSize(Layout.fontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary)
              .layoutWeight(1)
            Text(EffortLevels.short(this.thinkingLevel))
              .fontSize(Layout.fontUi)
              .fontWeight(FontWeight.Bold)
              .fontFamily('monospace')
              .fontColor(Theme.brand)
          }
          .width('100%')

          Slider({
            value: this.effortIndex(),
            min: 0,
            max: EffortLevels.ALL.length - 1,
            step: 1,
            style: SliderStyle.OutSet
          })
            .selectedColor(Theme.brand)
            .blockColor(Theme.brand)
            .trackThickness(4)
            .width('100%')
            .onChange((value: number, mode: SliderChangeMode) => {
              this.onSelectThinking(EffortLevels.byIndex(Math.round(value)).level);
            })

          Row() {
            ForEach(EffortLevels.ALL, (option: EffortOption, index: number) => {
              Text(option.short)
                .fontSize(Layout.fontCaption)
                .fontFamily('monospace')
                .fontWeight(index === this.effortIndex() ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(index === this.effortIndex() ? Theme.brand : Theme.textTertiary)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
            }, (option: EffortOption) => option.level)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: Layout.s4, right: Layout.s4, top: Layout.s4, bottom: Layout.s3 })
        .borderRadius(Layout.radiusL)
        .backgroundColor(Theme.bgSurface)
        .border({ width: 1, color: Theme.border })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s4, bottom: Layout.s6 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Row({ space: 6 }) {
      if (this.profiles.length === 0) {
        SymbolGlyph(Icons.model).fontSize(Layout.iconS).fontColor([Theme.textTertiary])
        Text('未选择模型')
          .fontSize(Layout.fontUi)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary)
          .maxLines(1)
        SymbolGlyph(Icons.chevronDown)
          .fontSize(Layout.iconS)
          .fontColor([Theme.textTertiary])
      } else {
        Text(this.modelLabel.length > 0 ? this.modelLabel : '未选择模型')
          .fontSize(Layout.fontUi)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 160 })
        Text('·')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textTertiary)
        Text(EffortLevels.short(this.thinkingLevel))
          .fontSize(Layout.fontSmall)
          .fontFamily('monospace')
          .fontColor(Theme.textSecondary)
        SymbolGlyph(Icons.chevronDown)
          .fontSize(Layout.iconS)
          .fontColor([Theme.textTertiary])
      }
    }
    .height(34)
    .padding({ left: 12, right: 10 })
    .borderRadius(Layout.radiusPill)
    .backgroundColor(Theme.bgSurface)
    .border({ width: 1, color: Theme.border })
    .stateStyles({ pressed: this.pillPressed, normal: this.pillNormal })
    .onClick(() => {
      this.showSheet = true;
    })
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: SheetSize.MEDIUM,
      preferType: SheetType.BOTTOM,
      showClose: true,
      dragBar: true,
      backgroundColor: Theme.sheetBg,
      radius: { topLeft: Layout.sheetTopRadius, topRight: Layout.sheetTopRadius }
    })
  }
}
