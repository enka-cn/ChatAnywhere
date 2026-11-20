/**
 * 角色头像选择面板（v3.2）：10 个系统符号图标 + 8 个低饱和底色。
 *
 * 只负责选择与高亮，最终落盘由 SettingsPersonaView 的「保存角色」完成。
 */
import { AvatarIconOption, AvatarToneOption, PersonaAvatars } from '../app/PersonaAvatars';
import { Icons, Layout, Theme } from '../app/Theme';

@Component
export struct PersonaAvatarPicker {
  @Prop currentIcon: string = PersonaAvatars.DEFAULT_ICON;
  @Prop currentTone: string = PersonaAvatars.DEFAULT_TONE;
  onPickIcon: (key: string) => void = (key: string) => {
  };
  onPickTone: (key: string) => void = (key: string) => {
  };
  onClose: () => void = () => {
  };

  build() {
    Column({ space: Layout.s2 }) {
      Row({ space: Layout.s2 }) {
        Text('头像')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .layoutWeight(1)
        Text('完成')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.brand)
          .padding({ left: Layout.s3, right: Layout.s3, top: 4, bottom: 4 })
          .borderRadius(Layout.radiusS)
          .backgroundColor(Theme.brandSubtle)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(PersonaAvatars.ICONS, (one: AvatarIconOption) => {
          Row() {
            SymbolGlyph(one.icon)
              .fontSize(Layout.iconM)
              .fontColor([PersonaAvatars.foreground()])
          }
          .width(36)
          .height(36)
          .borderRadius(18)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(PersonaAvatars.toneOf(this.currentTone))
          .border({
            width: this.currentIcon === one.key ? 2 : 1,
            color: this.currentIcon === one.key ? Theme.brand : Theme.border
          })
          .margin({ right: Layout.s2, bottom: Layout.s2 })
          .onClick(() => {
            this.onPickIcon(one.key);
          })
        }, (one: AvatarIconOption) => one.key)
      }
      .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(PersonaAvatars.TONES, (one: AvatarToneOption) => {
          Row() {
            if (this.currentTone === one.key) {
              SymbolGlyph(Icons.check)
                .fontSize(Layout.iconS)
                .fontColor([Theme.brand])
            }
          }
          .width(28)
          .height(28)
          .borderRadius(14)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(one.bg)
          .border({
            width: this.currentTone === one.key ? 2 : 0,
            color: Theme.brand
          })
          .margin({ right: Layout.s2, bottom: Layout.s2 })
          .onClick(() => {
            this.onPickTone(one.key);
          })
        }, (one: AvatarToneOption) => one.key)
      }
      .width('100%')
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface2)
    .borderRadius(Layout.radiusL)
    .alignItems(HorizontalAlign.Start)
  }
}
