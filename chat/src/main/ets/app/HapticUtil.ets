/**
 * 触感震动统一入口（v3.5）。
 *
 * - 默认开启；用户在设置页关闭后，全应用（思考档位滑条等）立即静音；
 * - 内存缓存开关，避免每次震动都读一次 RDB；
 * - 无振动硬件 / 权限被拒 / 系统异常时静默跳过，不阻塞 UI。
 */
import { SettingsApi, SettingsKeys } from '@app/core_model';
import { vibrator } from '@kit.SensorServiceKit';

export class HapticUtil {
  private static enabled: boolean = true;
  private static repo: SettingsApi | null = null;
  private static ready: boolean = false;

  /** 应用启动时初始化（读取持久化开关；失败保持默认开启）。 */
  static async init(repo: SettingsApi): Promise<void> {
    HapticUtil.repo = repo;
    try {
      const raw: string = await repo.getString(SettingsKeys.HAPTIC_ENABLED, 'true');
      HapticUtil.enabled = raw !== 'false';
    } catch (e) {
      HapticUtil.enabled = true;
    }
    HapticUtil.ready = true;
  }

  /** 是否已初始化（设置页可据此回显）。 */
  static isReady(): boolean {
    return HapticUtil.ready;
  }

  static isEnabled(): boolean {
    return HapticUtil.enabled;
  }

  /** 切换总开关：立即更新内存缓存 + 落盘（失败不影响本次静音/开启）。 */
  static async setEnabled(value: boolean): Promise<void> {
    HapticUtil.enabled = value;
    const repo: SettingsApi | null = HapticUtil.repo;
    if (repo !== null) {
      try {
        await repo.putString(SettingsKeys.HAPTIC_ENABLED, value ? 'true' : 'false');
      } catch (e) {
        // 落盘失败不阻断交互；下次启动回退默认值
      }
    }
  }

  /** 轻触反馈（跨档滑条等）。duration 单位 ms。 */
  static vibrate(duration: number): void {
    if (!HapticUtil.enabled) {
      return;
    }
    try {
      const ms: number = duration > 0 ? duration : 8;
      vibrator.startVibration({ type: 'time', duration: ms }, { id: 0, usage: 'touch' }).catch(() => {
        // 无马达/权限被拒：静默
      });
    } catch (e) {
      // 无振动能力：静默
    }
  }
}
