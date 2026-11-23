/**
 * 全局设计令牌 v3.1（HarmonyOS NEXT 旗舰排版与 Pura X Max 阔折叠视觉优化）。
 *
 * 规则：
 * - UI 禁止硬编码色值，一律 `Theme.*`；颜色来自 `resources/{base,dark}/element/color.json`，自动深浅色。
 * - 间距/圆角/字号只用 `Layout.*`（采用更舒适的原生可读字号阶梯，告别偏小偏挤的网页感）。
 * - 图标统一 `SymbolGlyph(Icons.xxx)`，按钮一律走 `IconBtn` 居中容器。
 * - 全站选中/开关/高亮只用单一品牌蓝 `Theme.brand`。
 */

export class Theme {
  static readonly bgPage: ResourceColor = $r('app.color.bg_page');
  static readonly bgSurface: ResourceColor = $r('app.color.bg_surface');
  static readonly bgSurface2: ResourceColor = $r('app.color.bg_surface_2');
  static readonly bgSurface3: ResourceColor = $r('app.color.bg_surface_3');
  static readonly bgInput: ResourceColor = $r('app.color.bg_input');

  static readonly textPrimary: ResourceColor = $r('app.color.text_primary');
  static readonly textSecondary: ResourceColor = $r('app.color.text_secondary');
  static readonly textTertiary: ResourceColor = $r('app.color.text_tertiary');
  static readonly textOnBrand: ResourceColor = $r('app.color.text_on_brand');

  static readonly brand: ResourceColor = $r('app.color.brand');
  static readonly brandPressed: ResourceColor = $r('app.color.brand_pressed');
  static readonly brandSubtle: ResourceColor = $r('app.color.brand_subtle');

  static readonly border: ResourceColor = $r('app.color.border');
  static readonly divider: ResourceColor = $r('app.color.divider');

  static readonly bubbleUser: ResourceColor = $r('app.color.bubble_user');
  static readonly bubbleUserText: ResourceColor = $r('app.color.bubble_user_text');

  static readonly codeBg: ResourceColor = $r('app.color.code_bg');
  static readonly codeText: ResourceColor = $r('app.color.code_text');
  static readonly quoteBar: ResourceColor = $r('app.color.quote_bar');

  static readonly danger: ResourceColor = $r('app.color.danger');
  static readonly dangerSubtle: ResourceColor = $r('app.color.danger_subtle');
  static readonly violet: ResourceColor = $r('app.color.violet');
  // 思考强度暗舱（v3.5）
  static readonly effortDeckTop: ResourceColor = $r('app.color.effort_deck_top');
  static readonly effortDeckBottom: ResourceColor = $r('app.color.effort_deck_bottom');
  static readonly effortTrack: ResourceColor = $r('app.color.effort_track');
  static readonly effortBarOff: ResourceColor = $r('app.color.effort_bar_off');
  static readonly effortTextDim: ResourceColor = $r('app.color.effort_text_dim');
  static readonly effortTextBright: ResourceColor = $r('app.color.effort_text_bright');
  static readonly pink: ResourceColor = $r('app.color.pink');
  static readonly warning: ResourceColor = $r('app.color.warning');
  static readonly warningSubtle: ResourceColor = $r('app.color.warning_subtle');
  static readonly success: ResourceColor = $r('app.color.success');
  static readonly successSubtle: ResourceColor = $r('app.color.success_subtle');

  static readonly memoryOk: ResourceColor = $r('app.color.memory_ok');
  static readonly memoryWarn: ResourceColor = $r('app.color.memory_warn');
  static readonly memoryHigh: ResourceColor = $r('app.color.memory_high');

  static readonly scrim: ResourceColor = $r('app.color.scrim');
  static readonly drawerBg: ResourceColor = $r('app.color.drawer_bg');
  static readonly sheetBg: ResourceColor = $r('app.color.sheet_bg');
  static readonly chipBg: ResourceColor = $r('app.color.chip_bg');
  static readonly chipText: ResourceColor = $r('app.color.chip_text');
  static readonly sheetHandle: ResourceColor = $r('app.color.sheet_handle');
  static readonly toggleOff: ResourceColor = $r('app.color.toggle_off');

  static readonly iconPrimary: ResourceColor = $r('app.color.icon_primary');
  static readonly iconSecondary: ResourceColor = $r('app.color.icon_secondary');

  static memoryColor(ratio: number): ResourceColor {
    if (ratio >= 0.85) {
      return Theme.memoryHigh;
    }
    if (ratio >= 0.6) {
      return Theme.memoryWarn;
    }
    return Theme.memoryOk;
  }
}

export class Layout {
  static readonly s1: number = 4;
  static readonly s2: number = 8;
  static readonly s3: number = 12;
  static readonly s4: number = 16;
  static readonly s5: number = 20;
  static readonly s6: number = 24;
  static readonly s8: number = 32;

  static readonly pagePadding: number = 16;

  static readonly radiusS: number = 8;
  static readonly radiusM: number = 12;
  static readonly radiusL: number = 16;
  static readonly radiusXL: number = 20;
  static readonly radiusPill: number = 999;

  static readonly inputRadius: number = 24;
  static readonly bubbleRadius: number = 20;
  static readonly bubbleTail: number = 6;
  static readonly cardRadius: number = 16;
  static readonly sheetTopRadius: number = 24;

  // HarmonyOS 原生舒适字号阶梯
  static readonly fontCaption: number = 11.5;
  static readonly fontSmall: number = 12.5;
  static readonly fontUi: number = 13.5;
  static readonly fontBody: number = 15;
  static readonly fontChat: number = 15.5;
  static readonly fontBodyLarge: number = 16;
  static readonly fontTitle: number = 16;
  static readonly fontHeadline: number = 17;
  static readonly fontHero: number = 26;

  static readonly lineChat: number = 26;
  static readonly lineBody: number = 23;
  static readonly lineTight: number = 20;

  static readonly topBarHeight: number = 48;
  static readonly topBarFoldedHeight: number = 44;
  static readonly statusBarHeight: number = 24;
  static readonly chatMaxWidth: number = 680;
  static readonly sidebarChat: number = 232;
  static readonly sidebarSkills: number = 236;
  static readonly sidebarSettings: number = 220;
  static readonly sourcePaneWidth: number = 288;
  static readonly drawerRatio: number = 0.78;
  static readonly drawerMaxWidth: number = 284;
  static readonly sheetMaxRatio: number = 0.82;

  static readonly iconS: number = 15;
  static readonly iconM: number = 18;
  static readonly iconL: number = 20;

  static readonly pressOpacity: number = 0.62;
  static readonly disabledOpacity: number = 0.35;
  static readonly animDuration: number = 200;
}

export class Icons {
  static readonly panelOpen: Resource = $r('sys.symbol.open_sidebar');
  static readonly panelClose: Resource = $r('sys.symbol.close_sidebar');
  static readonly back: Resource = $r('sys.symbol.chevron_left');
  static readonly backArrow: Resource = $r('sys.symbol.arrow_left');
  static readonly chevronRight: Resource = $r('sys.symbol.chevron_right');
  static readonly chevronDown: Resource = $r('sys.symbol.chevron_down');
  static readonly chevronUp: Resource = $r('sys.symbol.chevron_up');
  static readonly close: Resource = $r('sys.symbol.xmark');
  static readonly more: Resource = $r('sys.symbol.ellipsis_circle');

  static readonly plus: Resource = $r('sys.symbol.plus');
  static readonly minus: Resource = $r('sys.symbol.minus');
  static readonly check: Resource = $r('sys.symbol.checkmark');
  static readonly send: Resource = $r('sys.symbol.arrow_up');
  static readonly stop: Resource = $r('sys.symbol.square_fill');
  static readonly search: Resource = $r('sys.symbol.magnifyingglass');
  static readonly newChat: Resource = $r('sys.symbol.square_and_pencil');
  static readonly edit: Resource = $r('sys.symbol.square_and_pencil');
  static readonly copy: Resource = $r('sys.symbol.doc_text_on_doc_text');
  static readonly retry: Resource = $r('sys.symbol.arrow_clockwise');
  static readonly trash: Resource = $r('sys.symbol.trash');
  static readonly link: Resource = $r('sys.symbol.link');

  static readonly creator: Resource = $r('sys.symbol.doc_plaintext_and_pencil');
  static readonly skills: Resource = $r('sys.symbol.square_stack_3d');
  static readonly settings: Resource = $r('sys.symbol.slider_horizontal_2');
  static readonly model: Resource = $r('sys.symbol.memory_module');
  static readonly memory: Resource = $r('sys.symbol.AI_memory');
  static readonly thinking: Resource = $r('sys.symbol.lightbulb');
  static readonly web: Resource = $r('sys.symbol.globe_badge_message');
  static readonly persona: Resource = $r('sys.symbol.person_crop_circle_fill');
  static readonly clock: Resource = $r('sys.symbol.clock');

  static readonly attach: Resource = $r('sys.symbol.plus');
  static readonly image: Resource = $r('sys.symbol.ohos_photo');
  static readonly file: Resource = $r('sys.symbol.doc_text');
  static readonly camera: Resource = $r('sys.symbol.camera');
  static readonly cpu: Resource = $r('sys.symbol.memory_module');
  static readonly database: Resource = $r('sys.symbol.AI_memory');
  static readonly laptop: Resource = $r('sys.symbol.computer');
  static readonly gauge: Resource = $r('sys.symbol.gauge_with_dots_needle_33percent');
  static readonly sparkles: Resource = $r('sys.symbol.wand_and_stars');
  static readonly checkmarkCircle: Resource = $r('sys.symbol.checkmark_circle');
  static readonly infoCircle: Resource = $r('sys.symbol.info_circle');
  static readonly warnCircle: Resource = $r('sys.symbol.exclamationmark_circle');
  static readonly share: Resource = $r('sys.symbol.share');
  static readonly download: Resource = $r('sys.symbol.download');
  static readonly upload: Resource = $r('sys.symbol.upload');
  static readonly wifi: Resource = $r('sys.symbol.wifi');
  static readonly key: Resource = $r('sys.symbol.key');

  // 角色头像预设（v3.2）
  static readonly plan: Resource = $r('sys.symbol.list_bullet');
  static readonly code: Resource = $r('sys.symbol.code_square');
  static readonly fileText: Resource = $r('sys.symbol.doc_text');
  static readonly translate: Resource = $r('sys.symbol.translate');
  static readonly shield: Resource = $r('sys.symbol.lock_shield');

  static readonly drawer: Resource = $r('sys.symbol.open_sidebar');
  static readonly drawerClose: Resource = $r('sys.symbol.close_sidebar');
  static readonly skillCreator: Resource = $r('sys.symbol.doc_plaintext_and_pencil');
  static readonly branch: Resource = $r('sys.symbol.split');
  static readonly warn: Resource = $r('sys.symbol.exclamationmark_circle');
  static readonly info: Resource = $r('sys.symbol.info_circle');
}
