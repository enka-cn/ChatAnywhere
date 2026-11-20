/**
 * 窗口断点工具（v3 设计：展开态 ≥600vp 双栏 Master-Detail；折叠态 <600vp 单栏栈页）。
 *
 * 用法（每个页面）：
 *   aboutToAppear() { this.watcher = Breakpoint.watch(this.getUIContext(), (unfolded: boolean) => {
 *     this.unfolded = unfolded;
 *   }); this.unfolded = Breakpoint.isUnfolded(this.getUIContext()); }
 *   aboutToDisappear() { if (this.watcher !== null) { this.watcher.dispose(); this.watcher = null; } }
 */
import { UIContext } from '@kit.ArkUI';
import mediaquery from '@ohos.mediaquery';

export class Breakpoint {
  /** 展开态最小窗口宽度（vp）。 */
  static readonly UNFOLDED_MIN_VP: number = 600;

  /** 当前是否展开态（双栏）。 */
  static isUnfolded(ui: UIContext): boolean {
    return Number(ui.getWindowWidthBreakpoint()) >= Number(WidthBreakpoint.WIDTH_MD);
  }

  /** 监听断点变化（返回句柄，页面销毁时 dispose）。 */
  static watch(ui: UIContext, onChange: (unfolded: boolean) => void): BreakpointWatcher {
    const condition: string = `(width >= ${Breakpoint.UNFOLDED_MIN_VP}vp)`;
    const listener: mediaquery.MediaQueryListener = ui.getMediaQuery().matchMediaSync(condition);
    return new BreakpointWatcher(listener, onChange);
  }
}

export class BreakpointWatcher {
  private listener: mediaquery.MediaQueryListener | null = null;
  private callback: (result: mediaquery.MediaQueryResult) => void;

  constructor(listener: mediaquery.MediaQueryListener, onChange: (unfolded: boolean) => void) {
    this.listener = listener;
    this.callback = (result: mediaquery.MediaQueryResult) => {
      onChange(result.matches);
    };
    listener.on('change', this.callback);
  }

  dispose(): void {
    if (this.listener !== null) {
      this.listener.off('change', this.callback);
      this.listener = null;
    }
  }
}
