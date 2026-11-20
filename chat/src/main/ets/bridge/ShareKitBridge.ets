/**
 * 系统分享接收桥（Share Kit 直连清洗入口）。
 *
 * 事实依据：
 * - `ChatAbility.onCreate` 已把分享进来的内容写进 `AppStorage['pendingSharedContent']`；
 * - 清洗能力来自 `plugin.web`（core_plugin 的双轨联网引擎 fetchDoc），失败一律返回中文提示。
 *
 * 注意：本 SDK 里 `wantConstant.Action` 只有 `ACTION_SEND_TO_DATA`，`ACTION_VIEW_DATA` 是 FA 遗留常量，
 * 因此分享入口配置在 module.json5 里用字符串 `'ohos.want.action.viewData'`（Lead 负责，不在本文件）。
 */
import { CleanedWebDoc, CleanedWebPolicyLike } from '@app/core_plugin';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppServices } from '../app/AppServices';

const DOMAIN: number = 0x1A2B;
const TAG: string = 'ChatAnyWhere/Share';

/** 分享内容清洗结果（全中文，失败也不抛错）。 */
export interface SharedSummaryResult {
  ok: boolean;
  /** 网页标题（取不到时用链接本身）。 */
  title: string;
  /** 原始链接或原文。 */
  url: string;
  /** 清洗后的正文摘要（已截断，可直接展示/喂模型）。 */
  summary: string;
  /** 失败原因或补充说明（中文）。 */
  message: string;
}

/**
 * 分享内容桥。
 * 用法：设置页/对话页 `consumePending()` 拿到内容后，链接类内容调 `summarizeSharedLink(url)`。
 */
export class ShareKitBridge {
  private static shared: ShareKitBridge | null = null;

  /** ChatAbility 写入 AppStorage 时使用的键名（不要改名）。 */
  private readonly storageKey: string = 'pendingSharedContent';

  static get(): ShareKitBridge {
    if (ShareKitBridge.shared === null) {
      ShareKitBridge.shared = new ShareKitBridge();
    }
    return ShareKitBridge.shared;
  }

  /** 是否有待处理的分享内容。 */
  hasPending(): boolean {
    return this.pendingText().length > 0;
  }

  /** 只读当前待处理内容（不清空）。 */
  pendingText(): string {
    try {
      const value: string | undefined = AppStorage.get<string>(this.storageKey);
      if (value === undefined || value === null) {
        return '';
      }
      return value as string;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read pending shared content failed');
      return '';
    }
  }

  /** 取出待处理内容并清空（一次性消费）。 */
  consumePending(): string {
    const text: string = this.pendingText();
    if (text.length > 0) {
      this.clearPending();
    }
    return text;
  }

  /** 清空待处理内容。 */
  clearPending(): void {
    try {
      AppStorage.delete(this.storageKey);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'clear pending shared content failed');
    }
  }

  /** 判断一段内容是不是网页链接。 */
  isLink(text: string): boolean {
    const lower: string = text.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  /**
   * 清洗一条分享链接，生成可直接阅读/喂模型的摘要。
   * 失败（未配密钥、网络不通、网页读不到）都返回 `ok=false` 与中文说明，不抛异常。
   */
  async summarizeSharedLink(url: string): Promise<SharedSummaryResult> {
    const target: string = url.trim();
    if (target.length === 0) {
      return {
        ok: false, title: '', url: '', summary: '', message: '没有收到要整理的链接'
      };
    }
    if (!this.isLink(target)) {
      // 分享过来的可能是纯文字：本地做一次简单整理（去多余空白 + 截断），不需要联网
      return {
        ok: true,
        title: '分享的文字',
        url: target,
        summary: this.tidyText(target),
        message: '这不是网页链接，已按分享的文字做了整理'
      };
    }

    const services = AppServices.get();
    if (!services.hasPlugin()) {
      const reason: string = services.pluginError.length > 0 ? services.pluginError : '技能模块暂不可用';
      return {
        ok: false, title: target, url: target, summary: '', message: `暂时无法整理这个链接：${reason}`
      };
    }

    const policy: CleanedWebPolicyLike = {
      mode: 'auto',
      includeDomains: [],
      excludeDomains: [],
      minRerankScore: 1.5,
      minAuthority: 0,
      fetchTopK: 0,
      fetchTimeoutMs: 8000
    };

    try {
      const doc: CleanedWebDoc | null = await services.requirePlugin().web.fetchDoc(target, policy);
      if (doc === null) {
        return {
          ok: false,
          title: target,
          url: target,
          summary: '',
          message: '没能读到这篇网页的内容（可能被网站拦了，或者链接已失效），可以换个链接再试'
        };
      }
      const content: string = doc.contentForModel.length > 0 ? doc.contentForModel : '（网页没有可读正文）';
      return {
        ok: true,
        title: doc.title.length > 0 ? doc.title : target,
        url: doc.url.length > 0 ? doc.url : target,
        summary: this.tidyText(content),
        message: doc.usedFallbackSummary ? '正文太长，已用网页摘要代替' : '已整理网页正文'
      };
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'fetch shared link failed: %{public}s', (e as Error).message);
      return {
        ok: false,
        title: target,
        url: target,
        summary: '',
        message: `整理失败：${(e as Error).message}`
      };
    }
  }

  /** 去多余空白并截断到便于阅读的长度。 */
  private tidyText(raw: string): string {
    const lines: string[] = raw.split('\n');
    const kept: string[] = [];
    let total: number = 0;
    for (const line of lines) {
      const one: string = line.trim();
      if (one.length === 0) {
        continue;
      }
      kept.push(one);
      total += one.length;
      if (total > 1200) {
        break;
      }
    }
    let text: string = kept.join('\n');
    if (text.length > 1200) {
      text = `${text.substring(0, 1200)}…`;
    }
    return text;
  }
}
