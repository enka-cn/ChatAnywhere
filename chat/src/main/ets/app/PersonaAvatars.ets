/**
 * 角色头像预设（v3.2）：系统符号图标 + 低饱和底色，深浅色自动适配。
 *
 * `PersonaProfile.avatarIcon` / `avatarTone` 存的是这里的 key（字符串），
 * 便于持久化与跨版本兼容；渲染时用 `PersonaAvatars.iconOf/toneOf` 解析。
 */
import { Icons } from './Theme';

/** 可选头像图标（10 个）。 */
export interface AvatarIconOption {
  key: string;
  label: string;
  icon: Resource;
}

/** 可选头像底色（8 个，低饱和度，深浅色各一套）。 */
export interface AvatarToneOption {
  key: string;
  label: string;
  bg: ResourceColor;
}

export class PersonaAvatars {
  static readonly DEFAULT_ICON: string = 'persona';
  static readonly DEFAULT_TONE: string = 'blue';

  static readonly ICONS: AvatarIconOption[] = [
    { key: 'persona', label: '助手', icon: Icons.persona },
    { key: 'plan', label: '规划', icon: Icons.plan },
    { key: 'research', label: '研究', icon: Icons.search },
    { key: 'writing', label: '写作', icon: Icons.fileText },
    { key: 'code', label: '代码', icon: Icons.code },
    { key: 'data', label: '数据', icon: Icons.database },
    { key: 'think', label: '思辨', icon: Icons.thinking },
    { key: 'translate', label: '翻译', icon: Icons.translate },
    { key: 'spark', label: '灵感', icon: Icons.sparkles },
    { key: 'shield', label: '严谨', icon: Icons.shield }
  ];

  static readonly TONES: AvatarToneOption[] = [
    { key: 'blue', label: '蓝', bg: $r('app.color.avatar_bg_blue') },
    { key: 'violet', label: '紫', bg: $r('app.color.avatar_bg_violet') },
    { key: 'teal', label: '青', bg: $r('app.color.avatar_bg_teal') },
    { key: 'amber', label: '琥珀', bg: $r('app.color.avatar_bg_amber') },
    { key: 'rose', label: '玫', bg: $r('app.color.avatar_bg_rose') },
    { key: 'green', label: '绿', bg: $r('app.color.avatar_bg_green') },
    { key: 'slate', label: '石板', bg: $r('app.color.avatar_bg_slate') },
    { key: 'cyan', label: '湖蓝', bg: $r('app.color.avatar_bg_cyan') }
  ];

  /** key → 图标资源（未知回退默认）。 */
  static iconOf(key: string): Resource {
    for (const item of PersonaAvatars.ICONS) {
      if (item.key === key) {
        return item.icon;
      }
    }
    return Icons.persona;
  }

  /** key → 底色（未知回退默认）。 */
  static toneOf(key: string): ResourceColor {
    for (const item of PersonaAvatars.TONES) {
      if (item.key === key) {
        return item.bg;
      }
    }
    return $r('app.color.avatar_bg_blue');
  }

  /** 深色字（头像图标颜色）：统一用品牌色系前景，保证低饱和底上的可读性。 */
  static foreground(): ResourceColor {
    return $r('app.color.brand');
  }
}
