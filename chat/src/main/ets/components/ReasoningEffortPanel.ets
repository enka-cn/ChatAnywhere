/**
 * Codex 风格「思考强度」面板（v3.6 · 日夜双主题）。
 *
 * 日间：清透浅面（effortDeckTop→DeckBottom 浅色渐变）+ 轻光晕 + 深色文字，与白底半模态浑然一体；
 * 夜间：深空暗舱（同一套 Theme 令牌自动切到暗色值）+ 霓虹氛围光 + 档位边。
 * - 顶部：图标 + dim 小字 + 亮色大号档位字（弹跳）+ 右上 6 格阶梯能量柱；
 * - 手写能量槽：8vp 轨道 + 渐变光轨 + 22vp 白钮（日间带描边可见）+ 8vp 档位色内点 + 外发光；
 * - 移除轨道上方独立小圆点，仅保留底槽/光轨/白钮/底部刻度；
 * - 触感统一走 HapticUtil（设置总开关关闭即静音）。
 *
 * 颜色全部来自 Theme（禁止 hex），尺寸来自 Layout。
 */
import mediaquery from '@ohos.mediaquery';
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
  /** 当前系统是否深色模式（决定光晕强度与描边策略）。 */
  @State private isDark: boolean = false;

  private bounceTimer: number = -1;
  private lastVibrated: number = -1;
  private lastCommitted: number = -1;
  private darkListener: mediaquery.MediaQueryListener | null = null;
  private darkCallback: ((result: mediaquery.MediaQueryResult) => void) | null = null;

  aboutToAppear(): void {
    this.lastVibrated = this.index();
    this.lastCommitted = this.index();
    this.watchColorMode();
  }

  aboutToDisappear(): void {
    if (this.bounceTimer >= 0) {
      clearTimeout(this.bounceTimer);
      this.bounceTimer = -1;
    }
    if (this.darkListener !== null && this.darkCallback !== null) {
      this.darkListener.off('change', this.darkCallback);
      this.darkListener = null;
      this.darkCallback = null;
    }
  }

  /** 监听系统深浅色（等价 mediaquery.matchMediaSync('(dark-mode: true)')）。 */
  private watchColorMode(): void {
    try {
      const listener: mediaquery.MediaQueryListener =
        this.getUIContext().getMediaQuery().matchMediaSync('(dark-mode: true)');
      this.darkListener = listener;
      this.isDark = listener.matches;
      const callback = (result: mediaquery.MediaQueryResult): void => {
        this.isDark = result.matches;
      };
      this.darkCallback = callback;
      listener.on('change', callback);
    } catch (e) {
      this.isDark = false;
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

  /** 1vp 细边：日间统一 Theme.border；夜间 off border / high 紫 / xHigh 粉。 */
  private edgeColor(): ResourceColor {
    if (!this.isDark) {
      return Theme.border;
    }
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

  /** 氛围光透明度：日间 0.08–0.14、夜间 0.12–0.28（随档递增，off 最低）。 */
  private auraAlpha(): number {
    const idx: number = this.activeIndex();
    if (idx <= 0) {
      return 0.02;
    }
    if (this.isDark) {
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
    if (idx === 1) {
      return 0.08;
    }
    if (idx === 2) {
      return 0.09;
    }
    if (idx === 3) {
      return 0.10;
    }
    if (idx === 4) {
      return 0.12;
    }
    return 0.14;
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

  /** 手写能量槽：底槽 + 渐变光轨 + 白钮/档位色圆点/外发光（不再有独立刻度圆点）。 */
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
      // 外发光（off 无光晕；日间更淡）
      Circle({ width: KNOB_SIZE + 12, height: KNOB_SIZE + 12 })
        .fill(this.accent())
        .opacity(this.activeIndex() <= 0 ? 0 : (this.isDark ? 0.26 : 0.18))
        .position({
          x: this.knobCenterX() - (KNOB_SIZE + 12) / 2,
          y: (TRACK_BOX_HEIGHT - KNOB_SIZE - 12) / 2
        })
      // 22vp 白钮：夜间纯白，日间白底 + 细描边保证可见
      Circle({ width: KNOB_SIZE, height: KNOB_SIZE })
        .fill(this.isDark ? Theme.effortTextBright : Theme.bgSurface)
        .stroke(this.isDark ? Theme.bgSurface : Theme.border)
        .strokeWidth(1)
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
