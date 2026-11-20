/**
 * 快照订阅与通知总线：持有订阅者、32ms 节流派发定时器与快照深拷贝。
 *
 * 门面只负责维护 RuntimeSnapshot 的字段，通知节奏（流式帧节流、立即通知、结束清空）
 * 全部由这里统一保证，避免各模块各自 setTimeout 造成渲染抖动。
 */
import { RuntimeSnapshot, SearchTraceStep } from '../ChatRuntimeApi';
import { SkillChipState } from '../../app/PersonaStore';
import { copySources } from './RuntimeUtils';

/** 流式帧节流窗口（ms）。 */
const NOTIFY_INTERVAL_MS: number = 32;

export class SnapshotNotifier {
  private listeners: Map<number, (snapshot: RuntimeSnapshot) => void> =
    new Map<number, (snapshot: RuntimeSnapshot) => void>();
  private listenerSeq: number = 0;
  /** 节流通知定时器（-1 表示没有待触发的帧）。 */
  private timer: number = -1;
  private snapshotProvider: () => RuntimeSnapshot;
  private traceProvider: () => SearchTraceStep[];

  constructor(snapshotProvider: () => RuntimeSnapshot, traceProvider: () => SearchTraceStep[]) {
    this.snapshotProvider = snapshotProvider;
    this.traceProvider = traceProvider;
  }

  /** 订阅状态变化，返回订阅 id。 */
  subscribe(listener: (snapshot: RuntimeSnapshot) => void): number {
    this.listenerSeq += 1;
    const id: number = this.listenerSeq;
    this.listeners.set(id, listener);
    return id;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  /** 立即通知（列表/状态类变更）：清掉待触发的节流帧后同步 flush。 */
  notifyNow(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.flush();
  }

  /** 节流通知（流式帧）：32ms 窗口内最多发一次。 */
  notifyThrottled(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.flush();
    }, NOTIFY_INTERVAL_MS);
  }

  /** 立即 flush 但保留节流定时器（refreshNodes(false) 的语义）。 */
  notifyImmediate(): void {
    this.flush();
  }

  /** 推一份快照副本给订阅者（副本避免外部改到运行时内部状态）。 */
  private flush(): void {
    if (this.listeners.size === 0) {
      return;
    }
    const copy: RuntimeSnapshot = this.cloneSnapshot();
    this.listeners.forEach((listener: (snapshot: RuntimeSnapshot) => void) => {
      try {
        listener(copy);
      } catch (e) {
        // 单个订阅者异常不能影响其它订阅者
      }
    });
  }

  private cloneSnapshot(): RuntimeSnapshot {
    const source: RuntimeSnapshot = this.snapshotProvider();
    const copy: RuntimeSnapshot = {
      sessionId: source.sessionId,
      title: source.title,
      streaming: source.streaming,
      streamingText: source.streamingText,
      streamingReasoning: source.streamingReasoning,
      errorMessage: source.errorMessage,
      noticeMessage: source.noticeMessage,
      contextTokens: source.contextTokens,
      contextWindow: source.contextWindow,
      cacheHitRatio: source.cacheHitRatio,
      memoryRatio: source.memoryRatio,
      compacting: source.compacting,
      compactTip: source.compactTip,
      modelLabel: source.modelLabel,
      modelId: source.modelId,
      providerId: source.providerId,
      thinkingLevel: source.thinkingLevel,
      webMode: source.webMode,
      personaName: source.personaName,
      skillChips: copySkillChips(source.skillChips),
      searchTrace: this.traceProvider(),
      sources: copySources(source.sources),
      nodeCount: source.nodeCount,
      hasApiKey: source.hasApiKey,
      hasModel: source.hasModel,
      lastCompactionAt: source.lastCompactionAt,
      lastCompactionBeforeTokens: source.lastCompactionBeforeTokens,
      lastCompactionAfterTokens: source.lastCompactionAfterTokens,
      lastCompactionSummary: source.lastCompactionSummary
    };
    return copy;
  }
}

/** 深拷贝技能芯片列表（避免 UI 改动快照内的对象）。 */
function copySkillChips(source: SkillChipState[]): SkillChipState[] {
  const out: SkillChipState[] = [];
  for (const one of source) {
    out.push({
      skillId: one.skillId,
      name: one.name,
      tier: one.tier,
      globalEnabled: one.globalEnabled,
      bound: one.bound,
      active: one.active
    });
  }
  return out;
}
