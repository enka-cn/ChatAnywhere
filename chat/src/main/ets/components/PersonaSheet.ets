/**
 * 「切换对话角色」半模态内容（v3.2：角色头像 + 绑定模型摘要）。
 *
 * 角色列表来自 PersonaStore；头像用 `PersonaAvatars.iconOf/toneOf` 解析
 * `PersonaProfile.avatarIcon/avatarTone`；底部「定制角色与提示词」跳设置中心角色分类。
 */
import { PersonaAvatars } from '../app/PersonaAvatars';
import { PersonaProfile } from '../app/PersonaStore';
import { Icons, Layout, Theme } from '../app/Theme';

/**
 * 角色切换面板。
 *
 * @param personas 全部角色
 * @param activeId 当前会话角色 id
 */
@Component
export struct PersonaSheet {
  @Prop personas: PersonaProfile[] = [];
  @Prop activeId: string = '';
  onPick: (personaId: string) => void = (personaId: string) => {
  };
  onOpenSettings: () => void = () => {
  };

  /** 绑定模型摘要：空 modelId 表示跟随当前模型。 */
  private modelSummary(persona: PersonaProfile): string {
    if (persona.modelId.length === 0) {
      return '跟随当前模型';
    }
    return persona.modelId;
  }

  @Builder
  avatar(persona: PersonaProfile) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(PersonaAvatars.iconOf(persona.avatarIcon))
        .fontSize(Layout.iconM)
        .fontColor([PersonaAvatars.foreground()])
    }
    .width(40)
    .height(40)
    .borderRadius(Layout.radiusPill)
    .backgroundColor(PersonaAvatars.toneOf(persona.avatarTone))
  }

  build() {
    Column({ space: Layout.s3 }) {
      Row({ space: Layout.s2 }) {
        SymbolGlyph(Icons.persona).fontSize(Layout.iconM).fontColor([Theme.brand])
        Text('切换对话角色')
          .fontSize(Layout.fontHeadline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')

      if (this.personas.length === 0) {
        Text('暂无角色')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textTertiary)
          .width('100%')
          .padding({ top: Layout.s2, bottom: Layout.s2 })
      } else {
        Column({ space: Layout.s1 }) {
          ForEach(this.personas, (persona: PersonaProfile) => {
            Row({ space: Layout.s3 }) {
              this.avatar(persona)
              Column({ space: 2 }) {
                Text(persona.name)
                  .fontSize(Layout.fontBody)
                  .fontColor(persona.id === this.activeId ? Theme.textPrimary : Theme.textSecondary)
                  .fontWeight(persona.id === this.activeId ? FontWeight.Medium : FontWeight.Normal)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Row({ space: 4 }) {
                  SymbolGlyph(Icons.model)
                    .fontSize(Layout.fontCaption)
                    .fontColor([Theme.textTertiary])
                  Text(this.modelSummary(persona))
                    .fontSize(Layout.fontSmall)
                    .fontColor(Theme.textTertiary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              if (persona.id === this.activeId) {
                SymbolGlyph(Icons.check).fontSize(Layout.iconM).fontColor([Theme.brand])
              }
            }
            .width('100%')
            .padding({ left: Layout.s3, right: Layout.s3, top: 8, bottom: 8 })
            .borderRadius(Layout.radiusL)
            .backgroundColor(persona.id === this.activeId ? Theme.brandSubtle : Theme.bgSurface)
            .border({ width: 1, color: persona.id === this.activeId ? Color.Transparent : Theme.border })
            .onClick(() => {
              this.onPick(persona.id);
            })
          }, (persona: PersonaProfile) => `${persona.id}_${persona.avatarIcon}_${persona.avatarTone}`)
        }
        .width('100%')
      }

      Text('定制角色与提示词')
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textSecondary)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 10, bottom: 10 })
        .borderRadius(Layout.radiusM)
        .backgroundColor(Theme.bgSurface2)
        .onClick(() => {
          this.onOpenSettings();
        })
    }
    .width('100%')
    .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s5, bottom: Layout.s6 })
  }
}
