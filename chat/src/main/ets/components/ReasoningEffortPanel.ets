/**
 * Codex 风格「思考强度」面板（v3.5 · 深空暗舱版）。
 *
 * 真机反馈修复：
 * - 统一深空暗面（effortDeckTop → effortDeckBottom 竖向渐变，圆角 20，随档位微亮细边）；
 * - 删除顶部硬切色块，改为右上角 radialGradient 柔和氛围光（0.12–0.28 随档位，off 近 0）；
 * - 右上 6 格阶梯能量柱：暗底未亮 effortBarOff / 亮格 accent，xHigh 全亮微光；
 * - 手写能量槽：8vp 轨道 effortTrack + 渐变光轨 + 6 枚对齐刻度微点；
 *   22vp 纯白圆钮 + 中心 8vp 档位色圆点 + 柔和外发光（off 无光晕）；
 * - 触感统一走 HapticUtil（设置总开关关闭即静音）。
 *
 * 颜色全部来自 Theme（禁止 hex），尺寸来自 Layout。
 */
import { ThinkingLevel } from '@app/core_protocol';
import { EffortLevels, EffortOption } from '../app/EffortLevels';
import { HapticUtil } from '../app/HapticUtil';
import { Icons, Layout, Theme } from '../app/Theme';

/** 滑条左右内边距（22vp 圆钮不贴边溢出）。 */
const TRACK_PAD: number = 14;
/** 轨道高度。 */
const TRACK_HEIGHT: number = 8;
/** 滑条组件总高度（容纳圆钮与外发光）。 */
const TRACK_BOX_HEIGHT: number = 30;
/** 圆钮直径。 */
const KNOB_SIZE: number = 22;

@Component
export struct ReasoningEffortPanel {
  @Prop @Watch('onLevelChanged') thinkingLevel: ThinkingLevel = 'med';
  onSelect: (level: ThinkingLevel) => void = (level: ThinkingLevel) => {
  };

  /** xHigh 能量柱微光透明度（其余档位 1）。 */
  @State private barOpacity: number = 1;
  /** 档位大字弹跳缩放。 */
  @State private levelScale: number = 1;
  /** 拖动中的临时档位（-1 = 未拖动）。 */
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

  /** 档位主色：off 用暗字色，min..med 品牌蓝，high 紫，xHigh 粉。 */
  private accent(): ResourceColor {
    const idx: number = this.activeIndex();
    if (idx <= 0) {
      return Theme.effortTextDim;
    }
    if (idx >= 5) {
      return Theme.pink;
    }
    if (idx === 4) {
      return Theme.violet;
    }
    return Theme.brand;
  }

  /** 1vp 细边：off 常规边框，high 紫，xHigh 粉。 */
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

  /** 深空暗面竖向渐变。 */
  private deckColors(): Array<[ResourceColor, number]> {
    const colors: Array<[ResourceColor, number]> = [
      [Theme.effortDeckTop, 0],
      [Theme.effortDeckBottom, 1]
    ];
    return colors;
  }

  /** 右上角氛围光渐变（accent → 透明）。 */
  private auraColors(): Array<[ResourceColor, number]> {
    const accent: ResourceColor = this.activeIndex() <= 0 ? Theme.brand : this.accent();
    const colors: Array<[ResourceColor, number]> = [[accent, 1], [accent, 0]];
    return colors;
  }

  /** 氛围光中心（右上角）。 */
  private auraCenter(): [Length, Length] {
    const center: [Length, Length] = ['85%', '0%'];
    return center;
  }

  /** 氛围光透明度：off 近 0，档位越高越亮（0.12–0.28）。 */
  private auraAlpha(): number {
    const idx: number = this.activeIndex();
    if (idx <= 0) {
      return 0.02;
    }
    if (idx === 1) {
      return 0.12;
    }
    if (idx === 2) {
      return 0.16;
    }
    if (idx === 3) {
      return 0.20;
    }
    if (idx === 4) {
      return 0.24;
    }
    return 0.28;
  }

  /** 能量柱亮格数：off=0、min..high=index、xHigh 全亮 6 格。 */
  private litCount(): number {
    const idx: number = this.activeIndex();
    return idx >= 5 ? 6 : idx;
  }

  /** 滑条可用宽度（扣除左右内边距）。 */
  private usableWidth(): number {
    const usable: number = this.trackWidth - TRACK_PAD * 2;
    return usable > 0 ? usable : 0;
  }

  private ratio(): number {
    return this.activeIndex() / (EffortLevels.ALL.length - 1);
  }

  /** 圆钮圆心距轨道左端的距离（px）。 */
  private knobCenterX(): number {
    return TRACK_PAD + this.usableWidth() * this.ratio();
  }

  /** 光轨渐变：off 灰、min..med 品牌蓝、high 紫、xHigh 蓝→紫→粉。 */
  private fillColors(): Array<[ResourceColor, number]> {
    const idx: number = this.activeIndex();
    if (idx <= 0) {
      const off: Array<[ResourceColor, number]> = [[Theme.effortBarOff, 0], [Theme.effortBarOff, 1]];
      return off;
    }
    if (idx === 4) {
      const high: Array<[ResourceColor, number]> = [[Theme.violet, 0.55], [Theme.violet, 1]];
      return high;
    }
    if (idx >= 5) {
      const max: Array<[ResourceColor, number]> = [[Theme.brand, 0.5], [Theme.violet, 1], [Theme.pink, 1]];
      return max;
    }
    const basic: Array<[ResourceColor, number]> = [[Theme.brand, 0.45], [Theme.brand, 1]];
    return basic;
  }

  // -------------------------------------------------------------------------
  // 动效 / 触感
  // -------------------------------------------------------------------------

  /** 档位变化：重启 xHigh 微光（其余档位复位）。 */
  onLevelChanged(): void {
    this.previewIndex = -1;
    this.lastCommitted = this.index();
    this.startBarGlow();
  }

  private startBarGlow(): void {
    if (this.index() >= 5) {
      this.getUIContext().animateTo({
        duration: 1200,
        iterations: -1,
        curve: Curve.EaseInOut,
        playMode: PlayMode.Alternate
      }, () => {
        this.barOpacity = 0.72;
      });
      return;
    }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.barOpacity = 1;
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

  /** 触感：统一走 HapticUtil（设置总开关关闭时静音）；同档去抖。 */
  private vibrate(index: number): void {
    if (index <= 0 || index === this.lastVibrated) {
      return;
    }
    this.lastVibrated = index;
    HapticUtil.vibrate(8 + index * 6);
  }

  /** 提交档位：index 真正变化才回调 onSelect。 */
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

  /** 触点 x → 0..5 档（考虑左右 14vp 内边距）。 */
  private indexFromX(x: number): number {
    const usable: number = this.usableWidth();
    if (usable <= 0) {
      return this.index();
    }
    const r: number = Math.max(0, Math.min(1, (x - TRACK_PAD) / usable));
    return Math.round(r * (EffortLevels.ALL.length - 1));
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

  /** 右上角 6 格阶梯能量柱（暗底对比清晰）。 */
  @Builder
  energyBars() {
    Row({ space: 3 }) {
      ForEach(EffortLevels.ALL, (option: EffortOption, index: number) => {
        Column()
          .width(6)
          .height(8 + index * 2)
          .borderRadius(2)
          .backgroundColor(index < this.litCount() ? this.accent() : Theme.effortBarOff)
          .opacity(index < this.litCount() ? this.barOpacity : 1)
          .animation({ duration: 220, curve: Curve.EaseInOut })
      }, (option: EffortOption) => `bar_${option.level}`)
    }
    .height(26)
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  headerRow() {
    Row({ space: Layout.s3 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.activeIndex() <= 0 ? Icons.thinking : Icons.sparkles)
          .fontSize(Layout.iconM)
          .fontColor([this.accent()])
      }
      .width(34)
      .height(34)
      .borderRadius(Layout.radiusM)
      .backgroundColor(Theme.effortTrack)
      .animation({ duration: 260, curve: Curve.EaseInOut })

      Column({ space: 2 }) {
        Text('思考强度')
          .fontSize(Layout.fontUi)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.effortTextDim)
          .width('100%')
        Text(EffortLevels.short(EffortLevels.byIndex(this.activeIndex()).level))
          .fontSize(Layout.fontHero)
          .fontWeight(FontWeight.Bold)
          .fontFamily('monospace')
          .fontColor(Theme.effortTextBright)
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

  /** 6 枚对齐刻度微点（均分在轨道上）。 */
  @Builder
  tickDots() {
    ForEach(EffortLevels.ALL, (option: EffortOption, index: number) => {
      Circle({ width: 3, height: 3 })
        .fill(index <= this.activeIndex() ? Theme.effortTextBright : Theme.effortBarOff)
        .opacity(index <= this.activeIndex() ? 0.75 : 0.6)
        .position({
          x: TRACK_PAD + this.usableWidth() * (index / (EffortLevels.ALL.length - 1)) - 1.5,
          y: (TRACK_HEIGHT - 3) / 2
        })
    }, (option: EffortOption) => `dot_${option.level}`)
  }

  /** 手写能量槽：底槽 + 渐变光轨 + 刻度微点 + 白钮/档位色圆点/外发光。 */
  @Builder
  energyTrough() {
    Stack({ alignContent: Alignment.Start }) {
      // 底槽
      Row()
        .width('100%')
        .height(TRACK_HEIGHT)
        .borderRadius(Layout.radiusPill)
        .backgroundColor(Theme.effortTrack)
        .position({ x: 0, y: (TRACK_BOX_HEIGHT - TRACK_HEIGHT) / 2 })
      // 渐变光轨（到圆钮圆心）
      Row()
        .width(this.knobCenterX())
        .height(TRACK_HEIGHT)
        .borderRadius(Layout.radiusPill)
        .linearGradient({ angle: 90, colors: this.fillColors() })
        .position({ x: 0, y: (TRACK_BOX_HEIGHT - TRACK_HEIGHT) / 2 })
      // 刻度微点
      this.tickDots()
      // 外发光（off 无光晕）
      Circle({ width: KNOB_SIZE + 12, height: KNOB_SIZE + 12 })
        .fill(this.accent())
        .opacity(this.activeIndex() <= 0 ? 0 : 0.26)
        .position({
          x: this.knobCenterX() - (KNOB_SIZE + 12) / 2,
          y: (TRACK_BOX_HEIGHT - KNOB_SIZE - 12) / 2
        })
      // 22vp 纯白圆钮
      Circle({ width: KNOB_SIZE, height: KNOB_SIZE })
        .fill(Theme.effortTextBright)
        .position({ x: this.knobCenterX() - KNOB_SIZE / 2, y: (TRACK_BOX_HEIGHT - KNOB_SIZE) / 2 })
      // 中心 8vp 档位色圆点
      Circle({ width: 8, height: 8 })
        .fill(this.accent())
        .position({ x: this.knobCenterX() - 4, y: (TRACK_BOX_HEIGHT - 8) / 2 })
    }
    .width('100%')
    .height(TRACK_BOX_HEIGHT)
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

  /** 6 档刻度文字（居中等距，当前档高亮）。 */
  @Builder
  tickRow() {
    Row() {
      ForEach(EffortLevels.ALL, (option: EffortOption, index: number) => {
        Text(option.short)
          .fontSize(Layout.fontCaption)
          .fontFamily('monospace')
          .fontWeight(index === this.activeIndex() ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(index === this.activeIndex() ? this.accent() : Theme.effortTextDim)
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
      // 右上角氛围光（柔和、无硬切色块；off 近不可见）
      Column()
        .width('100%')
        .height(200)
        .radialGradient({
          center: this.auraCenter(),
          radius: '85%',
          colors: this.auraColors()
        })
        .opacity(this.auraAlpha())
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
    .linearGradient({ angle: 180, colors: this.deckColors() })
    .borderRadius(Layout.radiusXL)
    .border({ width: 1, color: this.edgeColor() })
    .clip(true)
    .animation({ duration: 260, curve: Curve.EaseInOut })
    .onAppear(() => {
      this.startBarGlow();
    })
  }
}
