/**
 * Codex 风格「思考强度」面板（v3.3）。
 *
 * 6 档（off/min/low/med/high/xhigh）随档位变化：
 * - 背景：中性雾灰 → 清透蓝 → 品牌蓝 → 蓝紫 → 蓝紫粉流光（3 层品牌色叠加 + opacity 过渡，深浅色自动适配）；
 * - 能量徽章：sparkles/thinking 图标 + 同心光环呼吸（off 静止）；
 * - 滑条：selectedColor/描边跟随档位主色；
 * - 档位大字：跨档微缩弹跳；
 * - 触感：跨档线性马达轻点（try/catch + 不 await，无硬件/权限时静默）。
 *
 * 颜色全部来自 Theme（禁止 hex）；尺寸来自 Layout。
 */
import { vibrator } from '@kit.SensorServiceKit';
import { ThinkingLevel } from '@app/core_protocol';
import { EffortLevels, EffortOption } from '../app/EffortLevels';
import { Icons, Layout, Theme } from '../app/Theme';

@Component
export struct ReasoningEffortPanel {
  @Prop @Watch('onLevelChanged') thinkingLevel: ThinkingLevel = 'med';
  onSelect: (level: ThinkingLevel) => void = (level: ThinkingLevel) => {
  };

  /** 光环呼吸缩放（off 静止）。 */
  @State private pulseScale: number = 1;
  /** 光环透明度。 */
  @State private pulseOpacity: number = 0.24;
  /** 档位大字弹跳缩放。 */
  @State private levelScale: number = 1;

  private bounceTimer: number = -1;
  private lastVibrated: number = -1;

  aboutToAppear(): void {
    this.lastVibrated = this.index();
  }

  aboutToDisappear(): void {
    if (this.bounceTimer >= 0) {
      clearTimeout(this.bounceTimer);
      this.bounceTimer = -1;
    }
  }

  // -------------------------------------------------------------------------
  // 档位派生值
  // -------------------------------------------------------------------------

  private index(): number {
    return EffortLevels.indexOf(this.thinkingLevel);
  }

  /** 档位主色（滑条选中色 / 大字 / 徽章）。 */
  private accent(): ResourceColor {
    const idx: number = this.index();
    if (idx <= 0) {
      return Theme.textTertiary;
    }
    if (idx >= 5) {
      return Theme.pink;
    }
    if (idx === 4) {
      return Theme.violet;
    }
    return Theme.brand;
  }

  /** 品牌蓝叠层透明度：档位越高越浓。 */
  private brandOpacity(): number {
    const idx: number = this.index();
    if (idx <= 0) {
      return 0;
    }
    if (idx <= 2) {
      return idx === 1 ? 0.08 : 0.12;
    }
    if (idx === 3) {
      return 0.22;
    }
    if (idx === 4) {
      return 0.26;
    }
    return 0.28;
  }

  /** 紫色叠层透明度：high / xhigh 才出现。 */
  private violetOpacity(): number {
    const idx: number = this.index();
    if (idx < 4) {
      return 0;
    }
    return idx === 4 ? 0.20 : 0.26;
  }

  /** 粉色叠层透明度：仅 xhigh 流光。 */
  private pinkOpacity(): number {
    return this.index() >= 5 ? 0.22 : 0;
  }

  // -------------------------------------------------------------------------
  // 动效 / 触感
  // -------------------------------------------------------------------------

  /** 档位变化：重启呼吸光环（off 回到静态）。 */
  onLevelChanged(): void {
    this.startPulse();
  }

  private startPulse(): void {
    const idx: number = this.index();
    if (idx <= 0) {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.pulseScale = 1;
        this.pulseOpacity = 0.24;
      });
      return;
    }
    const scaleTarget: number = 1.06 + idx * 0.045;
    const opacityTarget: number = Math.max(0.05, 0.2 - idx * 0.024);
    this.getUIContext().animateTo({
      duration: 1400,
      iterations: -1,
      curve: Curve.EaseInOut,
      playMode: PlayMode.Alternate
    }, () => {
      this.pulseScale = scaleTarget;
      this.pulseOpacity = opacityTarget;
    });
  }

  /** 跨档大字弹跳。 */
  private bounce(): void {
    this.getUIContext().animateTo({ duration: 90, curve: Curve.EaseOut }, () => {
      this.levelScale = 1.12;
    });
    if (this.bounceTimer >= 0) {
      clearTimeout(this.bounceTimer);
    }
    this.bounceTimer = setTimeout(() => {
      this.bounceTimer = -1;
      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseInOut }, () => {
        this.levelScale = 1;
      });
    }, 90);
  }

  /** 线性马达：档位越高轻点越久；无硬件/权限时静默。 */
  private vibrate(index: number): void {
    if (index <= 0 || index === this.lastVibrated) {
      return;
    }
    this.lastVibrated = index;
    try {
      const duration: number = 8 + index * 6;
      const effect: vibrator.VibrateTime = { type: 'time', duration: duration };
      const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'touch' };
      vibrator.startVibration(effect, attribute).catch(() => {
        // 振动失败（无硬件/受限）不影响 UI
      });
    } catch (e) {
      // 无振动能力时静默
    }
  }

  private onSliderChange(value: number): void {
    const index: number = Math.round(value);
    const option: EffortOption = EffortLevels.byIndex(index);
    if (option.level === this.thinkingLevel) {
      return;
    }
    this.bounce();
    this.vibrate(index);
    this.onSelect(option.level);
  }

  // -------------------------------------------------------------------------
  // 视图
  // -------------------------------------------------------------------------

  /** 能量徽章 + 2 层同心光环（off 静止）。 */
  @Builder
  energyBadge() {
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: 44, height: 44 })
        .fill(this.accent())
        .opacity(this.index() <= 0 ? 0.10 : this.pulseOpacity)
        .scale({ x: this.pulseScale, y: this.pulseScale })
      Circle({ width: 32, height: 32 })
        .fill(this.accent())
        .opacity(this.index() <= 0 ? 0.16 : 0.22)
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.index() <= 0 ? Icons.thinking : Icons.sparkles)
          .fontSize(Layout.iconM)
          .fontColor([this.accent()])
      }
      .width(30)
      .height(30)
      .borderRadius(Layout.radiusPill)
      .backgroundColor(Theme.bgSurface)
    }
    .width(48)
    .height(48)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  labelRow() {
    Row({ space: Layout.s3 }) {
      this.energyBadge()
      Column({ space: 2 }) {
        Text('思考强度')
          .fontSize(Layout.fontUi)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
          .width('100%')
        Text(EffortLevels.short(this.thinkingLevel))
          .fontSize(Layout.fontHero)
          .fontWeight(FontWeight.Bold)
          .fontFamily('monospace')
          .fontColor(this.accent())
          .scale({ x: this.levelScale, y: this.levelScale })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  build() {
    Stack() {
      // 背景叠层：bgInput + 品牌蓝/紫/粉（opacity 随档位过渡）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.bgInput)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.brand)
        .opacity(this.brandOpacity())
        .animation({ duration: 260, curve: Curve.EaseInOut })
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.violet)
        .opacity(this.violetOpacity())
        .animation({ duration: 260, curve: Curve.EaseInOut })
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.pink)
        .opacity(this.pinkOpacity())
        .animation({ duration: 260, curve: Curve.EaseInOut })

      Column({ space: Layout.s3 }) {
        this.labelRow()

        Slider({
          value: this.index(),
          min: 0,
          max: EffortLevels.ALL.length - 1,
          step: 1,
          style: SliderStyle.OutSet
        })
          .trackColor(Theme.border)
          .selectedColor(this.accent())
          .blockColor(Theme.brand)
          .trackThickness(4)
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            this.onSliderChange(value);
          })

        Row() {
          ForEach(EffortLevels.ALL, (option: EffortOption, index: number) => {
            Text(option.short)
              .fontSize(Layout.fontCaption)
              .fontFamily('monospace')
              .fontWeight(index === this.index() ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(index === this.index() ? this.accent() : Theme.textTertiary)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
          }, (option: EffortOption) => option.level)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: Layout.s4, right: Layout.s4, top: Layout.s3, bottom: Layout.s3 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .borderRadius(Layout.radiusL)
    .border({
      width: this.index() >= 5 ? 2 : 1,
      color: this.index() >= 5 ? Theme.pink : Theme.border
    })
    .clip(true)
    .animation({ duration: 260, curve: Curve.EaseInOut })
    .onAppear(() => {
      this.startPulse();
    })
  }
}
