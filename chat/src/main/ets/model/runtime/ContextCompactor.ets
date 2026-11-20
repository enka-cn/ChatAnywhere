/**
 * 缓存感知的记忆压缩：决策 → checkpoint 摘要 → 旧节点归档 → 根分支回钉。
 *
 * 红线：压缩只把旧节点标记 archived（原文仍在 RDB 与 FTS5），永不物理删除；
 * 自动整理失败不打断对话，手动整理只给中文提示。
 */
import { ConversationNode, estimateNodesTokens } from '@app/core_model';
import { CompactionDecision, CompactorInput, TextSummarizer } from '@app/core_context';
import { ModelProfile } from '@app/core_protocol';
import { RuntimeHost } from './RuntimeTypes';
import { ProtocolTextSummarizer } from './ProtocolTextSummarizer';
import { checkpointText } from './RuntimeUtils';

export class ContextCompactor {
  private host: RuntimeHost;

  constructor(host: RuntimeHost) {
    this.host = host;
  }

  /** 自动整理：命中缓存感知压缩决策时执行（永不打断对话）。 */
  async maybeAutoCompact(profile: ModelProfile, path: ConversationNode[]): Promise<void> {
    try {
      const decision: CompactionDecision = this.evaluateCompaction(profile, path);
      this.host.metrics().compactionTip = decision.reasonText;
      this.host.recomputeMetrics();
      if (!decision.shouldCompact) {
        return;
      }
      await this.compactMemory(profile, path, true);
    } catch (e) {
      // 自动整理永不打断对话
    }
  }

  /** 交给 core_context 的压缩器做决策（窗口 / 缓存 TTL / 模型切换 / 用户策略）。 */
  private evaluateCompaction(profile: ModelProfile, path: ConversationNode[]): CompactionDecision {
    const ctx = this.host.appServices().requireContextLayer();
    const input: CompactorInput = {
      contextWindowTokens: profile.contextWindow,
      cacheMissToHitRatio: profile.cacheMissToHitRatio,
      cacheIdleTtlSec: profile.cacheIdleTtlSec,
      supportsServerWebTools: profile.supportsServerWebTools
    };
    let lastActiveAt: number = Date.now();
    if (path.length > 0) {
      lastActiveAt = path[path.length - 1].createdAt;
    }
    let isModelChanged: boolean = false;
    for (let i = path.length - 1; i >= 0; i--) {
      const node: ConversationNode = path[i];
      if (node.role === 'assistant') {
        if (node.modelId !== undefined && node.modelId !== profile.modelId) {
          isModelChanged = true;
        } else if (node.providerId !== undefined && node.providerId !== profile.providerId) {
          isModelChanged = true;
        }
        break;
      }
    }
    const policy = this.host.compactionPolicy() === 'aggressive' ? 'aggressive'
      : (this.host.compactionPolicy() === 'off' ? 'off' : 'auto');
    return ctx.compactor.evaluate(input, path, lastActiveAt, isModelChanged, policy);
  }

  /**
   * 生成 checkpoint 摘要并把旧节点标记归档（原文仍在 RDB 与 FTS5）。
   * @param auto true 表示自动触发（文案不同）
   */
  async compactMemory(profile: ModelProfile, path: ConversationNode[], auto: boolean): Promise<void> {
    if (path.length <= 1) {
      if (!auto) {
        this.host.snapshot().noticeMessage = '对话还太短，暂时不用整理';
      }
      return;
    }
    const snapshot = this.host.snapshot();
    snapshot.compacting = true;
    this.host.notifyNow();
    const ctx = this.host.appServices().requireContextLayer();
    const summarizer: TextSummarizer = new ProtocolTextSummarizer(this.host, profile);
    try {
      const outcome = await ctx.compactor.compactToCheckpoint(this.host.sessionId(), path, summarizer);
      const trajectory = this.host.appServices().requireModel().trajectory;
      await trajectory.append(outcome.checkpoint);
      // checkpoint 是挂在根层的兄弟节点；必须把根分支重新钉回原来的第一条消息，
      // 否则「默认选最新根节点」会把整段对话从活动路径里挤掉（UI 看起来像丢消息）。
      await this.pinRootBranch(path);
      await trajectory.archive(outcome.archivedNodeIds);
      const summary: string = checkpointText(outcome.checkpoint);
      if (summary.length > 0) {
        this.host.setMemorySummary(summary);
      }
      // v3.2：记录「最近一次整理」的前后 Token 与摘要全文（失败路径不写，保留上一次成功值）。
      snapshot.lastCompactionAt = Date.now();
      snapshot.lastCompactionBeforeTokens = estimateNodesTokens(path);
      snapshot.lastCompactionAfterTokens = outcome.afterTokens;
      if (summary.length > 0) {
        snapshot.lastCompactionSummary = summary;
      }
      // 压缩后上一轮的 input_tokens 已经不代表当前上下文了，清掉让记忆条按新内容重算。
      this.host.metrics().usageInputTokens = 0;
      // 顺带把更早的大载荷标记为已归档（DB 侧记录，UI 不受影响）
      try {
        const prunable: string[] = ctx.compactor.pickPrunableNodeIds(path);
        const repo = this.host.appServices().requireModel().repo;
        for (const nodeId of prunable) {
          await repo.markPayloadPruned(nodeId);
        }
      } catch (e) {
        // 裁剪只是锦上添花
      }
      snapshot.noticeMessage = auto ? '已自动整理对话记忆，早期细节仍然可以搜索到'
        : '已整理对话记忆，早期细节仍可搜索到';
    } catch (e) {
      snapshot.noticeMessage = `这次没有整理对话记忆：${(e as Error).message}`;
    } finally {
      snapshot.compacting = false;
      // 整理中 → 完成（或失败回退）都立刻通知 UI，指标/记忆条无需等下一轮。
      this.host.notifyNow();
    }
  }

  /**
   * 把会话根分支钉回真正的根节点（压缩后 checkpoint 会成为新的根层兄弟节点，
   * 不钉回去的话「默认选最新根」会让历史消息脱离活动路径）。
   */
  private async pinRootBranch(path: ConversationNode[]): Promise<void> {
    if (path.length === 0) {
      return;
    }
    try {
      const trajectory = this.host.appServices().requireModel().trajectory;
      let cursor: string | null = path[0].nodeId;
      const visited: Set<string> = new Set<string>();
      while (cursor !== null && cursor.length > 0 && !visited.has(cursor)) {
        visited.add(cursor);
        const node: ConversationNode | null = await trajectory.getNode(cursor);
        if (node === null) {
          return;
        }
        if (node.parentId === null) {
          await trajectory.switchBranch(this.host.sessionId(), null, node.nodeId);
          return;
        }
        cursor = node.parentId;
      }
    } catch (e) {
      // 根分支只是显示顺序偏好，失败时下次刷新仍会退回默认选择
    }
  }
}
