/**
 * Codex 风格「思考强度」面板（v3.4 · 能量槽版）。
 *
 * 用户真机反馈修复：
 * - 自然内容高度（不再撑满半模态），底部 28vp 预留，6 个刻度完整可见；
 * - 克制背景：卡片 bgSurface + 细边，只在顶部 56vp 铺一层柔和渐变光（off 几乎不可见），
 *   高档位边框过渡到 violet / pink，不再大面积平涂；
 * - 右上角 6 格阶梯能量柱（亮格数 = 档位）；
 * - 弃用原生 Slider，改手写「能量槽 + 白边发光圆钮」，支持拖动/点按吸附；
 * - 保留徽章呼吸光环（off 静止）、档位大字弹跳、跨档线性马达（try/catch 去抖）。
 *
 * 颜色全部来自 Theme（禁止 hex），尺寸来自 Layout。
 */
import { vibrator } from '@kit.SensorServiceKit';
import { ThinkingLevel } from '@app/core_protocol';
import { EffortLevels, EffortOption } from '../app/EffortLevels';
import { Icons, Layout, Theme } from '../app/Theme';

/** 能量槽左右内边距（避免 18vp 圆钮溢出卡片）。 */
const TRACK_PAD: number = 9;
/** 圆钮直径。 */
const KNOB_SIZE: number = 18;

@Component
export struct ReasoningEffortPanel {
  @Prop @Watch('onLevelChanged') thinkingLevel: ThinkingLevel = 'med';
  onSelect: (level: ThinkingLevel) => void = (level: ThinkingLevel) => {
  };

  /** 光环呼吸缩放（off 静止）。 */
  @State private pulseScale: number = 1;
  /** 光环透明度。 */
  @State private pulseOpacity: number = 0.24;
  /** xHigh 能量柱微光透明度（其余档位为 1）。 */
  @State private barOpacity: number = 1;
  /** 档位大字弹跳缩放。 */
  @State private levelScale: number = 1;
  /** 拖动中的临时档位（-1 表示未拖动，用 thinkingLevel）。 */
  @State private previewIndex: number = -1;
  /** 能量槽实测宽度（vp）。 */
  @State private trackWidth: number = 0;

  private bounceTimer: number = -1;
  private lastVibrated: number = -1;
  private lastCommitted: number = -1;

  aboutToAppear(): void {
    this.lastVibrated = this.index();
    this.lastCommitted = this.index();
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

  /** 当前生效档位（拖动时优先预览值）。 */
  private activeIndex(): number {
    const idx: number = this.previewIndex >= 0 ? this.previewIndex : this.index();
    if (idx < 0) {
      return 0;
    }
    return idx > EffortLevels.ALL.length - 1 ? EffortLevels.ALL.length - 1 : idx;
  }

  /** 档位主色（大字 / 徽章 / 亮格 / 填充起点）。 */
  private accent(): ResourceColor {
    const idx: number = this.activeIndex();
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

  /** 能量柱亮格数：off=0、min..high=index、xHigh 全亮 6 格。 */
  private litCount(): number {
    const idx: number = this.activeIndex();
    return idx >= 5 ? 6 : idx;
  }

  /** 边框颜色：high 紫、xHigh 粉，其余常规细边。 */
  private edgeColor(): ResourceColor {
    const idx: number = this.activeIndex();
    if (idx >= 5) {
      return Theme.pink;
    }
    if (idx === 4) {
      return Theme.violet;
    }
    return Theme.border;
  }

  /** 顶部柔光透明度：off 几乎不可见。 */
  private glowOpacity(): number {
    const idx: number = this.activeIndex();
    if (idx <= 0) {
      return 0.04;
    }
    if (idx === 1) {
      return 0.22;
    }
    if (idx === 2) {
      return 0.38;
    }
    if (idx === 3) {
      return 0.52;
    }
    return idx === 4 ? 0.66 : 0.80;
  }

  /** 顶部柔光渐变色（accent → 透明）。 */
  private glowColors(): Array<[ResourceColor, number]> {
    const base: ResourceColor = this.activeIndex() <= 0 ? Theme.bgSurface3 : this.accent();
    const colors: Array<[ResourceColor, number]> = [[base, 0.85], [base, 0.0]];
    return colors;
  }

  /** 能量槽填充渐变色。 */
  private fillColors(): Array<[ResourceColor, number]> {
    const idx: number = this.activeIndex();
    if (idx <= 0) {
      const off: Array<[ResourceColor, number]> = [[Theme.textTertiary, 1], [Theme.textTertiary, 1]];
      return off;
    }
    if (idx === 4) {
      const high: Array<[ResourceColor, number]> = [[Theme.brand, 0], [Theme.violet, 1]];
      return high;
    }
    if (idx >= 5) {
      const max: Array<[ResourceColor, number]> = [[Theme.brand, 0], [Theme.violet, 0.55], [Theme.pink, 1]];
      return max;
    }
    const basic: Array<[ResourceColor, number]> = [[Theme.brandSubtle, 0], [Theme.brand, 1]];
    return basic;
  }

  /** 圆钮左侧偏移（px）：让圆心落在 9 .. width-9 之间。 */
  private knobOffset(): number {
    const usable: number = this.trackWidth - TRACK_PAD * 2;
    if (usable <= 0) {
      return 0;
    }
    const ratio: number = this.activeIndex() / (EffortLevels.ALL.length - 1);
    return usable * ratio;
  }

  /** 填充宽度（px）：从槽左端到圆钮圆心。 */
  private fillWidth(): number {
    const usable: number = this.trackWidth - TRACK_PAD * 2;
    if (usable <= 0) {
      return 0;
    }
    return TRACK_PAD + usable * (this.activeIndex() / (EffortLevels.ALL.length - 1));
  }

  // -------------------------------------------------------------------------
  // 动效 / 触感
  // -------------------------------------------------------------------------

  /** 档位变化：重启呼吸光环（off 静止）与 xHigh 微光。 */
  onLevelChanged(): void {
    this.previewIndex = -1;
    this.lastCommitted = this.index();
    this.startPulse();
  }

  private startPulse(): void {
    const idx: number = this.index();
    if (idx <= 0) {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.pulseScale = 1;
        this.pulseOpacity = 0.24;
        this.barOpacity = 1;
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
    if (idx >= 5) {
      this.getUIContext().animateTo({
        duration: 1200,
        iterations: -1,
        curve: Curve.EaseInOut,
        playMode: PlayMode.Alternate
      }, () => {
        this.barOpacity = 0.72;
      });
    } else {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.barOpacity = 1;
      });
    }
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

  /** 提交一个档位（index 真正变化才回调 onSelect）。 */
  private commitIndex(index: number): void {
    if (index < 0 || index > EffortLevels.ALL.length - 1) {
      return;
    }
    if (index === this.lastCommitted) {
      return;
    }
    this.lastCommitted = index;
    this.bounce();
    this.vibrate(index);
    this.onSelect(EffortLevels.byIndex(index).level);
  }

  /** 触点 x → 0..5 档（考虑左右各 9vp 内边距）。 */
  private indexFromX(x: number): number {
    const usable: number = this.trackWidth - TRACK_PAD * 2;
    if (usable <= 0) {
      return this.index();
    }
    const ratio: number = Math.max(0, Math.min(1, (x - TRACK_PAD) / usable));
    return Math.round(ratio * (EffortLevels.ALL.length - 1));
  }

  private handleTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    const x: number = event.touches[0].x;
    const idx: number = this.indexFromX(x);
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      this.previewIndex = idx;
      this.commitIndex(idx);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.commitIndex(idx);
      this.previewIndex = -1;
    }
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
        .opacity(this.activeIndex() <= 0 ? 0.10 : this.pulseOpacity)
        .scale({ x: this.pulseScale, y: this.pulseScale })
      Circle({ width: 32, height: 32 })
        .fill(this.accent())
        .opacity(this.activeIndex() <= 0 ? 0.16 : 0.22)
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.activeIndex() <= 0 ? Icons.thinking : Icons.sparkles)
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

  /** 右上角 6 格阶梯能量柱。 */
  @Builder
  energyBars() {
    Row({ space: 3 }) {
      ForEach(EffortLevels.ALL, (option: EffortOption, index: number) => {
        Column()
          .width(6)
          .height(8 + index * 2)
          .borderRadius(2)
          .backgroundColor(index < this.litCount() ? this.accent() : Theme.bgSurface3)
          .opacity(index < this.litCount() ? this.barOpacity : 1)
          .animation({ duration: 220, curve: Curve.EaseInOut })
      }, (option: EffortOption) => `bar_${option.level}`)
    }
    .height(24)
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  headerRow() {
    Row({ space: Layout.s3 }) {
      this.energyBadge()
      Column({ space: 2 }) {
        Text('思考强度')
          .fontSize(Layout.fontUi)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary)
          .width('100%')
        Text(EffortLevels.short(EffortLevels.byIndex(this.activeIndex()).level))
          .fontSize(Layout.fontHero)
          .fontWeight(FontWeight.Bold)
          .fontFamily('monospace')
          .fontColor(this.accent())
          .scale({ x: this.levelScale, y: this.levelScale })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      this.energyBars()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 手写能量槽：凹槽 + 渐变填充 + 白边发光圆钮。 */
  @Builder
  energyTrough() {
    Stack({ alignContent: Alignment.Start }) {
      // 凹槽
      Row()
        .width('100%')
        .height(10)
        .borderRadius(Layout.radiusPill)
        .backgroundColor(Theme.bgInput)
        .position({ x: 0, y: (KNOB_SIZE - 10) / 2 })
      // 渐变填充
      Row()
        .width(this.fillWidth())
        .height(10)
        .borderRadius(Layout.radiusPill)
        .linearGradient({ angle: 90, colors: this.fillColors() })
        .position({ x: 0, y: (KNOB_SIZE - 10) / 2 })
      // 圆钮同色光晕（off 无光晕）
      Circle({ width: KNOB_SIZE + 10, height: KNOB_SIZE + 10 })
        .fill(this.accent())
        .opacity(this.activeIndex() <= 0 ? 0 : 0.28)
        .position({ x: this.knobOffset() - 5, y: -5 })
      // 白边圆钮
      Circle({ width: KNOB_SIZE, height: KNOB_SIZE })
        .fill(this.accent())
        .stroke(Theme.bgSurface)
        .strokeWidth(2)
        .position({ x: this.knobOffset(), y: 0 })
    }
    .width('100%')
    .height(KNOB_SIZE)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const widthValue: Length = newValue.width;
      if (typeof widthValue === 'number') {
        this.trackWidth = widthValue as number;
      }
    })
    .onTouch((event: TouchEvent) => {
      this.handleTouch(event);
    })
  }

  @Builder
  tickRow() {
    Row() {
      ForEach(EffortLevels.ALL, (option: EffortOption, index: number) => {
        Text(option.short)
          .fontSize(Layout.fontCaption)
          .fontFamily('monospace')
          .fontWeight(index === this.activeIndex() ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(index === this.activeIndex() ? this.accent() : Theme.textTertiary)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.previewIndex = -1;
            this.commitIndex(index);
          })
      }, (option: EffortOption) => option.level)
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 顶部柔和渐变光（48–64vp，随档位增强；off 几乎不可见）
      Column()
        .width('100%')
        .height(56)
        .linearGradient({ angle: 180, colors: this.glowColors() })
        .opacity(this.glowOpacity())
        .animation({ duration: 260, curve: Curve.EaseInOut })

      Column({ space: Layout.s4 }) {
        this.headerRow()
        this.energyTrough()
        this.tickRow()
      }
      .width('100%')
      .padding({ top: Layout.s4, left: Layout.s4, right: Layout.s4, bottom: 28 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ maxHeight: '92%' })
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: this.edgeColor() })
    .clip(true)
    .animation({ duration: 260, curve: Curve.EaseInOut })
    .onAppear(() => {
      this.startPulse();
    })
  }
}
