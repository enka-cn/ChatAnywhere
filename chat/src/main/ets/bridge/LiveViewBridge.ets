/**
 * 后台进度桥接（「实况窗」的可用替代实现）。
 *
 * 事实依据（docs/API_REFERENCE.md §9.2）：本 SDK 不存在 `@ohos.app.ability.LiveView`，
 * 三方应用无法直接创建系统实况窗。因此这里用两条通道实现「切到后台也能看到深度搜索进度」：
 *   1. 应用内状态（AppStorage，供对话页/首页悬浮显示）；
 *   2. 系统通知（@kit.NotificationKit 的 notificationManager.publish，普通文字通知）。
 *
 * 降级策略：通知被关闭、发布失败、取消失败一律只记录日志并继续跑，绝不抛出到 UI 线程。
 */
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppServices } from '../app/AppServices';

const DOMAIN: number = 0x1A2B;
const TAG: string = 'ChatAnyWhere/Progress';

/** 进度快照（应用内展示用）。 */
export interface DeepSearchProgressState {
  /** 是否有正在进行的任务。 */
  active: boolean;
  /** 任务标题，如「正在深度搜索：鸿蒙 26」。 */
  title: string;
  /** 当前一步的中文说明。 */
  text: string;
  /** 0–100。 */
  percent: number;
}

/**
 * 后台深度搜索进度桥。
 *
 * 用法（对话页在开始长耗时搜索时调用）：
 *   LiveViewBridge.get().startDeepSearchProgress('正在深度搜索');
 *   LiveViewBridge.get().updateProgress('已读 3 个网页', 45);
 *   LiveViewBridge.get().finish();
 */
export class LiveViewBridge {
  private static shared: LiveViewBridge | null = null;

  /** 通知 id（固定，保证同一条通知被反复更新而不是刷屏）。 */
  private readonly notificationId: number = 9101;
  /** AppStorage 键：给 UI 层读的文字/百分比/活跃位。 */
  private readonly keyText: string = 'deepSearchProgressText';
  private readonly keyPercent: string = 'deepSearchProgressPercent';
  private readonly keyActive: string = 'deepSearchProgressActive';

  private state: DeepSearchProgressState = { active: false, title: '', text: '', percent: 0 };
  private published: boolean = false;
  private lastPublishAt: number = 0;

  static get(): LiveViewBridge {
    if (LiveViewBridge.shared === null) {
      LiveViewBridge.shared = new LiveViewBridge();
    }
    return LiveViewBridge.shared;
  }

  /**
   * 是否支持「后台进度同步」。
   * 实况窗不可用，这里返回系统通知是否开启；未开启时应用内进度条仍然可用。
   */
  isSupported(): boolean {
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'read notification state failed: %{public}s', err.message);
      return false;
    }
  }

  /** 主动申请通知权限（系统会弹出授权框；失败返回 false，不抛错）。 */
  async requestNotificationPermission(): Promise<boolean> {
    try {
      const context: common.UIAbilityContext = AppServices.get().requireContext();
      await notificationManager.requestEnableNotification(context);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'request notification failed: %{public}s', err.message);
      return false;
    }
  }

  /** 开始一个后台任务：先写应用内状态，再尽力发通知。 */
  async startDeepSearchProgress(title: string): Promise<void> {
    this.state.active = true;
    this.state.title = title.length > 0 ? title : '正在深度搜索';
    this.state.text = '正在整理问题…';
    this.state.percent = 0;
    this.published = false;
    this.lastPublishAt = 0;
    this.publishAppState();
    await this.publishNotification('正在整理问题…', 0);
  }

  /**
   * 更新进度。text 为直白中文说明，percent 为 0–100。
   * 通知最多每 800 毫秒刷新一次，避免刷屏与耗电；应用内状态每次都更新。
   */
  updateProgress(text: string, percent: number): void {
    if (!this.state.active) {
      return;
    }
    this.state.text = text;
    this.state.percent = Math.max(0, Math.min(100, Math.round(percent)));
    this.publishAppState();
    const now: number = Date.now();
    if (now - this.lastPublishAt < 800) {
      return;
    }
    this.lastPublishAt = now;
    this.publishNotification(text, this.state.percent).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'update progress failed: %{public}s', err.message);
    });
  }

  /** 结束任务：清状态并撤掉通知（失败也不抛错）。 */
  async finish(): Promise<void> {
    this.state.active = false;
    this.state.text = '';
    this.state.percent = 0;
    this.publishAppState();
    if (this.published) {
      try {
        await notificationManager.cancel(this.notificationId);
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'cancel progress notification failed: %{public}s', err.message);
      }
    }
    this.published = false;
  }

  /** 当前进度快照（应用内进度条读取）。 */
  progressState(): DeepSearchProgressState {
    return this.state;
  }

  private publishAppState(): void {
    try {
      AppStorage.setOrCreate<boolean>(this.keyActive, this.state.active);
      AppStorage.setOrCreate<string>(this.keyText, this.state.text);
      AppStorage.setOrCreate<number>(this.keyPercent, this.state.percent);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write app storage failed');
    }
  }

  private async publishNotification(text: string, percent: number): Promise<void> {
    try {
      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: this.state.title.length > 0 ? this.state.title : '后台任务进行中',
          text: `${text} · ${percent}%`
        }
      };
      const request: notificationManager.NotificationRequest = {
        id: this.notificationId,
        content: content,
        isOngoing: true
      };
      await notificationManager.publish(request);
      this.published = true;
    } catch (e) {
      const err = e as BusinessError;
      // 通知被系统关闭 / 无权限 / 发布失败 → 降级为仅应用内进度，绝不崩溃
      this.published = false;
      hilog.warn(DOMAIN, TAG, 'publish progress degradation: %{public}s', err.message);
    }
  }
}
