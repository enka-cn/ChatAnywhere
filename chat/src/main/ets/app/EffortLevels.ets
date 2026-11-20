/**
 * 思考强度 6 档（对齐 v3 设计：关闭 / Min / Low / Med / High / xHigh）。
 *
 * 契约：`ThinkingLevel` 为 6 档字符串；各厂商 Adapter 负责离线静态映射
 * （DeepSeek reasoning.effort / Anthropic thinking budget / OpenAI 兼容端点透传）。
 * 旧版本本地设置里的 `quick` / `deep` 通过 `normalize()` 迁移为 `med` / `high`。
 */
import { ThinkingLevel } from '@app/core_protocol';

/** 一档强度。 */
export interface EffortOption {
  level: ThinkingLevel;
  /** 顶栏胶囊里的短标签（设计稿：关闭 / Min / Low / Med / High / xHigh）。 */
  short: string;
}

export class EffortLevels {
  static readonly ALL: EffortOption[] = [
    { level: 'off', short: '关闭' },
    { level: 'min', short: 'Min' },
    { level: 'low', short: 'Low' },
    { level: 'med', short: 'Med' },
    { level: 'high', short: 'High' },
    { level: 'xhigh', short: 'xHigh' }
  ];

  /** 默认档位（新会话 / 迁移缺省）。 */
  static readonly DEFAULT: ThinkingLevel = 'med';

  /** 索引（0..5），未知回退默认档。 */
  static indexOf(level: ThinkingLevel): number {
    for (let i = 0; i < EffortLevels.ALL.length; i++) {
      if (EffortLevels.ALL[i].level === level) {
        return i;
      }
    }
    return EffortLevels.indexOf(EffortLevels.DEFAULT);
  }

  /** 按索引取档位（越界回退默认）。 */
  static byIndex(index: number): EffortOption {
    if (index < 0 || index >= EffortLevels.ALL.length) {
      return EffortLevels.ALL[EffortLevels.indexOf(EffortLevels.DEFAULT)];
    }
    return EffortLevels.ALL[index];
  }

  static byLevel(level: ThinkingLevel): EffortOption {
    return EffortLevels.ALL[EffortLevels.indexOf(level)];
  }

  /** 顶栏短标签。 */
  static short(level: ThinkingLevel): string {
    return EffortLevels.byLevel(level).short;
  }

  /** 迁移旧值 / 容错任意存储值。 */
  static normalize(raw: string): ThinkingLevel {
    if (raw === 'off' || raw === 'min' || raw === 'low' || raw === 'med' || raw === 'high' || raw === 'xhigh') {
      return raw as ThinkingLevel;
    }
    if (raw === 'quick') {
      return 'med';
    }
    if (raw === 'deep') {
      return 'high';
    }
    return EffortLevels.DEFAULT;
  }
}
