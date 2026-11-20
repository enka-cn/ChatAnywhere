/**
 * 居中图标按钮（修复 ArkUI 直接给 SymbolGlyph 设宽高导致图标偏左上角的问题）。
 *
 * 内置轻柔按压反馈（透明度 + 微缩），供顶栏、抽屉、消息操作栏与输入栏统一复用。
 */
import { Layout, Theme } from '../app/Theme';

@Component
export struct IconBtn {
  @Prop icon: Resource = $r('sys.symbol.plus');
  @Prop iconSize: number = Layout.iconM;
  @Prop iconColor: ResourceColor = Theme.iconSecondary;
  @Prop btnSize: number = 34;
  @Prop bgColor: ResourceColor = Color.Transparent;
  @Prop radius: number = Layout.radiusM;
  @Prop btnDisabled: boolean = false;
  onTap: () => void = () => {
  };

  @Styles
  pressedStyles() {
    .opacity(Layout.pressOpacity)
    .scale({ x: 0.94, y: 0.94 })
  }

  @Styles
  normalStyles() {
    .opacity(this.btnDisabled ? Layout.disabledOpacity : 1)
    .scale({ x: 1, y: 1 })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(this.icon)
        .fontSize(this.iconSize)
        .fontColor([this.iconColor])
    }
    .width(this.btnSize)
    .height(this.btnSize)
    .borderRadius(this.radius)
    .backgroundColor(this.bgColor)
    .animation({ duration: 120, curve: Curve.EaseOut })
    .stateStyles({
      pressed: this.pressedStyles,
      normal: this.normalStyles
    })
    .enabled(!this.btnDisabled)
    .onClick(() => {
      if (!this.btnDisabled) {
        this.onTap();
      }
    })
  }
}
