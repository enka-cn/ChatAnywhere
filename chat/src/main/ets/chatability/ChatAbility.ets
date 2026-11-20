import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppServices } from '../app/AppServices';

const DOMAIN = 0x1A2B;
const TAG = 'ChatAnyWhere';

export default class ChatAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    // 接收系统分享的链接/文本（Share Kit 直连清洗入口，由 bridge 消费）
    const shared: string = this.extractSharedText(want);
    if (shared.length > 0) {
      AppStorage.setOrCreate<string>('pendingSharedContent', shared);
    }
    // fire-and-forget：应用层服务在后台初始化，页面用 waitReady() 等待
    AppServices.get().init(this.context).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'services init failed: %{public}s', err.message);
    });
  }

  private extractSharedText(want: Want): string {
    if (want === undefined || want === null) {
      return '';
    }
    const uri: string = want.uri ?? '';
    if (uri.length > 0) {
      return uri;
    }
    return '';
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');

    // 启动即主对话页（无中转首页）；会话抽屉在 ChatPage 内
    windowStage.loadContent('pages/ChatPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      try {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'setColorMode failed: %{public}s', (e as Error).message);
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }
}
