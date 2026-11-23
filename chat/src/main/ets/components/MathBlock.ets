/**
 * 离线数学公式块（v3.7）：仅 math 块使用 Web 渲染本地 KaTeX，零 CDN。
 *
 * - Web 加载 rawfile/katex/render.html，页面加载完成后注入公式；
 * - 通过 javaScriptProxy 回传渲染高度，ArkTS 侧动态设高（40–4000vp 夹取）；
 * - JS 异常 / 3 秒无回调时降级为可复制的源码文本，绝不白屏。
 */
import { webview } from '@kit.ArkWeb';
import mediaquery from '@ohos.mediaquery';
import { Layout, Theme } from '../app/Theme';

const MIN_WEB_HEIGHT: number = 40;
const MAX_WEB_HEIGHT: number = 4000;
const RENDER_TIMEOUT_MS: number = 3000;

/** JS 回调桥：页面 rAF 后回传 document.body.scrollHeight。 */
class MathBridge {
  onRendered: (height: number) => void = (height: number) => {
  };
}

@Component
export struct MathBlock {
  @Prop @Watch('onCodeChanged') code: string = '';

  @State private webHeight: number = 60;
  @State private failed: boolean = false;
  @State private dark: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: MathBridge = new MathBridge();
  private pageReady: boolean = false;
  private rendered: boolean = false;
  private timeoutId: number = -1;
  private darkListener: mediaquery.MediaQueryListener | null = null;

  aboutToAppear(): void {
    this.bridge.onRendered = (height: number) => {
      this.onHeight(height);
    };
    this.watchDarkMode();
    this.armFallback();
  }

  aboutToDisappear(): void {
    this.clearFallback();
    if (this.darkListener !== null) {
      try {
        this.darkListener.off('change', this.onDarkChange);
      } catch (e) {
        // 监听已释放时忽略
      }
      this.darkListener = null;
    }
  }

  /** 暗色监听：跟随系统深浅色，重新渲染公式。 */
  private watchDarkMode(): void {
    try {
      const listener: mediaquery.MediaQueryListener =
        this.getUIContext().getMediaQuery().matchMediaSync('(dark-mode: true)');
      this.dark = listener.matches;
      listener.on('change', this.onDarkChange);
      this.darkListener = listener;
    } catch (e) {
      this.dark = false;
    }
  }

  private onDarkChange = (result: mediaquery.MediaQueryResult): void => {
    this.dark = result.matches;
    this.render();
  };

  private onCodeChanged(): void {
    this.rendered = false;
    this.failed = false;
    this.armFallback();
    this.render();
  }

  private clearFallback(): void {
    if (this.timeoutId >= 0) {
      clearTimeout(this.timeoutId);
      this.timeoutId = -1;
    }
  }

  /** 3 秒兜底：没有任何高度回调则降级为源码文本。 */
  private armFallback(): void {
    this.clearFallback();
    this.timeoutId = setTimeout(() => {
      this.timeoutId = -1;
      if (!this.rendered) {
        this.failed = true;
      }
    }, RENDER_TIMEOUT_MS);
  }

  private onHeight(height: number): void {
    this.rendered = true;
    this.failed = false;
    this.clearFallback();
    let value: number = Math.ceil(height);
    if (!Number.isFinite(value) || value < MIN_WEB_HEIGHT) {
      value = MIN_WEB_HEIGHT;
    }
    if (value > MAX_WEB_HEIGHT) {
      value = MAX_WEB_HEIGHT;
    }
    this.webHeight = value;
  }

  private onPageEnd(): void {
    this.pageReady = true;
    this.rendered = false;
    this.failed = false;
    this.armFallback();
    this.render();
  }

  /** 注入公式：dark 与公式文本都以 JSON 字符串安全传入。 */
  private render(): void {
    if (!this.pageReady) {
      return;
    }
    const tex: string = JSON.stringify(this.code);
    const darkFlag: string = this.dark ? 'true' : 'false';
    const script: string = `renderFormula(${tex}, ${darkFlag});`;
    try {
      this.controller.runJavaScript(script).catch(() => {
        // 页面尚未就绪时忽略，onPageEnd 会重试
      });
    } catch (e) {
      this.failed = true;
    }
  }

  @Builder
  formulaView() {
    Web({ src: $rawfile('katex/render.html'), controller: this.controller })
      .javaScriptAccess(true)
      .javaScriptProxy({
        object: this.bridge,
        name: 'kaTexBridge',
        methodList: ['onRendered'],
        controller: this.controller
      })
      .onPageEnd(() => {
        this.onPageEnd();
      })
      .width('100%')
      .height(this.webHeight)
      .backgroundColor(Color.Transparent)
  }

  @Builder
  fallbackView() {
    Text(this.code)
      .fontSize(13)
      .lineHeight(21)
      .fontColor(Theme.textPrimary)
      .copyOption(CopyOptions.LocalDevice)
      .width('100%')
      .padding({ top: Layout.s1, bottom: Layout.s1 })
  }

  build() {
    Column() {
      if (this.failed) {
        this.fallbackView()
      } else {
        this.formulaView()
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .margin(6)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }
}
