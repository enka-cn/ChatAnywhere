/**
 * 缓存感知压缩器（Blueprint §3.4，纯逻辑实现）。
 *
 * 核心原则：**不为省小钱而破坏 30x–50x 的前缀缓存命中**。
 * 只有当「缓存已经失效（空闲过期 / 切换了模型）」或「上下文真的快撑爆（质量红线）」时，
 * 才值得去改写历史摘要；其余时候宁可让缓存继续命中。
 *
 * 本文件不允许 import 任何 @kit.*，必须能被 Node 逻辑测试直接运行。
 * 对象 id 生成、token 估算都来自 @app/core_model 的纯函数工具。
 */
import { CanonicalItem, ConversationNode, NodeRole } from '@app/core_model';
import { contextUsageRatio, estimateNodesTokens, estimateText, newId } from '@app/core_model';
import {
  CompactionDecision, CompactionOutcome, CompactionPolicy, CompactionTrigger, CompactorInput, TextSummarizer
} from './interfaces/CompactionTypes';
import { CompactorApi } from './interfaces/ContextLayer';

/** 质量红线：上下文用量超过该比例后回答质量明显下降，必须整理。 */
const ATTENTION_RATIO: number = 0.7;

/** 激进策略（用户选「尽量省」）下，质量红线提前触发的比例。 */
const AGGRESSIVE_ATTENTION_RATIO: number = 0.5;

/** 低缓存倍率模型的省钱阈值：用量超过 60% 才值得为省 token 去动历史。 */
const LOW_RATIO_USAGE: number = 0.6;

/** 激进策略下的省钱阈值。 */
const AGGRESSIVE_LOW_RATIO_USAGE: number = 0.45;

/** 只有缓存价差倍率 R 不高于该值的模型，才值得为了省 token 主动整理（R 越大越不该动）。 */
const LOW_RATIO_MAX_CACHE_RATIO: number = 10;

/** 预计压缩比 alpha：整理之后大约只剩原来 25% 的体积（0.75 表示压掉 75%）。 */
const EXPECTED_COMPACTION_ALPHA: number = 0.75;

/** 压缩时保留最近 4 轮（user/assistant 各算一个节点，约 8 个节点）不归档。 */
const KEEP_RECENT_NODES: number = 8;

/** 裁剪大载荷时默认保留最近 4 个节点不碰（只动更早的）。 */
const DEFAULT_KEEP_RECENT_FOR_PRUNE: number = 4;

/** 用量还没到 90% 时，优先只裁剪大载荷（破坏面更小），超过了再真正改写摘要。 */
const PRUNE_ONLY_CEILING: number = 0.9;

/** 角色中文名。 */
function roleName(role: NodeRole): string {
  switch (role) {
    case 'user':
      return '用户';
    case 'assistant':
      return '助手';
    case 'tool':
      return '工具';
    case 'system':
      return '系统';
    default:
      return '对话';
  }
}

/**
 * 缓存感知压缩器。
 * 无状态、无平台依赖，可在 UI 线程安全调用。
 */
export class CacheAwareCompactor implements CompactorApi {
  /**
   * 判断这一轮要不要整理对话记忆，并说明「为什么」与「整理一次大概几轮才回本」。
   *
   * @param input 模型窗口与缓存经济性参数
   * @param nodes 当前活动路径节点（根→叶，按时间正序）
   * @param lastActiveAt 上次活跃时间（ms）
   * @param isModelChanged 本次请求是否切换了异构模型（原厂缓存必然作废）
   * @param policy 用户策略，缺省 auto
   */
  evaluate(input: CompactorInput, nodes: ConversationNode[], lastActiveAt: number, isModelChanged: boolean,
    policy?: CompactionPolicy): CompactionDecision {
    const effectivePolicy: CompactionPolicy = policy === undefined ? 'auto' : policy;
    const now: number = Date.now();
    const tokens: number = estimateNodesTokens(nodes);
    const usageRatio: number = contextUsageRatio(tokens, input.contextWindowTokens);
    const breakEvenTurns: number = CacheAwareCompactor.breakEvenTurns(input.cacheMissToHitRatio);

    // 还没有任何内容，整理没有意义。
    if (tokens <= 0) {
      return CacheAwareCompactor.decide(false, 'none', breakEvenTurns, false,
        '当前还没有可以整理的对话内容，先继续聊', usageRatio);
    }

    // 用户关掉了自动整理：除了「质量红线」这一种情况，一律不动历史。
    if (effectivePolicy === 'off') {
      if (usageRatio > ATTENTION_RATIO) {
        return CacheAwareCompactor.decide(true, 'attention_threshold', breakEvenTurns,
          usageRatio < PRUNE_ONLY_CEILING, CacheAwareCompactor.attentionReason(usageRatio), usageRatio);
      }
      return CacheAwareCompactor.decide(false, 'none', breakEvenTurns, false,
        '你已经关掉了自动整理，对话记录会原样保留', usageRatio);
    }

    const aggressive: boolean = effectivePolicy === 'aggressive';
    const attentionRatio: number = aggressive ? AGGRESSIVE_ATTENTION_RATIO : ATTENTION_RATIO;
    const lowRatioUsage: number = aggressive ? AGGRESSIVE_LOW_RATIO_USAGE : LOW_RATIO_USAGE;
    const idleMs: number = now - lastActiveAt;
    const ttlMs: number = input.cacheIdleTtlSec * 1000;

    // 1) 空闲过期：服务端缓存本来就已经作废，此时整理是零沉没成本。
    if (ttlMs > 0 && idleMs > ttlMs) {
      return CacheAwareCompactor.decide(true, 'idle_cache_expired', breakEvenTurns, false,
        CacheAwareCompactor.idleReason(idleMs), usageRatio);
    }

    // 2) 切换模型：换了厂商/模型，原来的前缀缓存必然用不上，免费窗口。
    if (isModelChanged) {
      return CacheAwareCompactor.decide(true, 'model_switched', breakEvenTurns, false,
        '刚换了模型，原来的缓存用不上了，趁现在整理旧内容正好不浪费', usageRatio);
    }

    // 3) 质量红线：再不管，后面回答会开始变糊涂。
    if (usageRatio > attentionRatio) {
      return CacheAwareCompactor.decide(true, 'attention_threshold', breakEvenTurns,
        usageRatio < PRUNE_ONLY_CEILING, CacheAwareCompactor.attentionReason(usageRatio), usageRatio);
    }

    // 4) 低缓存倍率模型的经济性压缩：R 小的模型本来缓存就不值钱，省 token 更划算。
    if (input.cacheMissToHitRatio <= LOW_RATIO_MAX_CACHE_RATIO && usageRatio > lowRatioUsage) {
      return CacheAwareCompactor.decide(true, 'low_ratio_economic', breakEvenTurns, false,
        CacheAwareCompactor.lowRatioReason(usageRatio), usageRatio);
    }

    const noneReason: string = aggressive
      ? '对话还很短，暂时不用整理，缓存还能接着用'
      : '对话还不算长，先不整理，缓存还能接着用';
    return CacheAwareCompactor.decide(false, 'none', breakEvenTurns, false, noneReason, usageRatio);
  }

  /**
   * 生成不可变的 checkpoint_summary 节点，并返回被归档的原始节点 id。
   *
   * 规则：
   * - 保留最近 4 轮（约 8 个节点）不归档；对话太短时至少保留最后 1 个节点，
   *   保证永远不会把当前这一轮也整理掉；
   * - 被归档的原始节点由调用方标记 archived，原文永远留在 RDB 与 FTS5；
   * - 摘要失败（网络/模型异常）时用本地降级摘要兜底，不让压缩把聊天打断。
   *
   * @param sessionId 所属会话 id
   * @param nodes 当前活动路径节点（根→叶，按时间正序）
   * @param summarizer 由调用方注入的摘要器（协议层实现）
   */
  async compactToCheckpoint(sessionId: string, nodes: ConversationNode[],
    summarizer: TextSummarizer): Promise<CompactionOutcome> {
    if (nodes.length === 0) {
      throw new Error('没有可以整理的对话内容');
    }

    const keepCount: number = Math.min(KEEP_RECENT_NODES, Math.max(1, nodes.length - 1));
    const archiveCount: number = nodes.length - keepCount;
    const older: ConversationNode[] = nodes.slice(0, archiveCount);
    const kept: ConversationNode[] = nodes.slice(archiveCount);
    if (older.length === 0) {
      throw new Error('对话还不够长，先不用整理');
    }

    let summaryText: string = '';
    try {
      summaryText = await summarizer.summarize(older);
    } catch (error) {
      // 摘要失败不阻断压缩流程：用本地降级摘要兜底。
      summaryText = '';
    }
    if (summaryText.trim().length === 0) {
      summaryText = CacheAwareCompactor.buildFallbackSummary(older);
    }

    const now: number = Date.now();
    const summaryItem: CanonicalItem = {
      id: newId('it'),
      kind: 'checkpoint_summary',
      text: summaryText,
      createdAt: now
    };

    // checkpoint 挂到被压缩区间的父节点上：即路径首节点的 parentId（根节点通常为 null）。
    const checkpoint: ConversationNode = {
      nodeId: newId('nd'),
      parentId: nodes[0].parentId,
      sessionId: sessionId,
      role: 'assistant',
      items: [summaryItem],
      tokenEstimate: 0,
      createdAt: now
    };
    // 6 = 节点结构开销，4 = 单个 item 结构开销，其余是摘要正文。
    checkpoint.tokenEstimate = 6 + 4 + estimateText(summaryText);

    const archivedNodeIds: string[] = [];
    for (const node of older) {
      archivedNodeIds.push(node.nodeId);
    }

    const outcome: CompactionOutcome = {
      checkpoint: checkpoint,
      archivedNodeIds: archivedNodeIds,
      beforeTokens: estimateNodesTokens(nodes),
      afterTokens: estimateNodesTokens(kept) + checkpoint.tokenEstimate
    };
    return outcome;
  }

  /**
   * 挑出可以安全裁剪大载荷的节点（tool_call / tool_result / web_search_call）。
   *
   * 为避免破坏最前面已经被缓存的前缀，只处理「保留最近 keepRecentCount 个节点」之外的更早节点；
   * 已经被裁剪过（payloadPruned=true）的不重复返回。
   *
   * @param nodes 当前活动路径节点（根→叶，按时间正序）
   * @param keepRecentCount 尾部保留不动的节点数，默认 4
   */
  pickPrunableNodeIds(nodes: ConversationNode[], keepRecentCount?: number): string[] {
    const keep: number = keepRecentCount === undefined
      ? DEFAULT_KEEP_RECENT_FOR_PRUNE
      : Math.max(0, Math.floor(keepRecentCount));
    const limit: number = nodes.length - keep;
    const prunable: string[] = [];
    for (let i = 0; i < limit; i++) {
      const node: ConversationNode = nodes[i];
      if (CacheAwareCompactor.hasPrunablePayload(node)) {
        prunable.push(node.nodeId);
      }
    }
    return prunable;
  }

  /**
   * 缓存未命中 vs 命中价差 R 下，整理一次需要多少轮才回本：
   * `round((alpha / (1 - alpha)) * R)`，alpha 为预计压缩比（0.75 → 3R）。
   */
  static breakEvenTurns(cacheMissToHitRatio: number): number {
    const alpha: number = EXPECTED_COMPACTION_ALPHA;
    const raw: number = (alpha / (1 - alpha)) * cacheMissToHitRatio;
    if (raw <= 0) {
      return 0;
    }
    return Math.round(raw);
  }

  /** 组装一条决策（统一出口，避免各处字段缺漏）。 */
  private static decide(shouldCompact: boolean, trigger: CompactionTrigger, estimatedBreakEvenTurns: number,
    pruneToolPayloadsOnly: boolean, reasonText: string, usageRatio: number): CompactionDecision {
    const decision: CompactionDecision = {
      shouldCompact: shouldCompact,
      trigger: trigger,
      estimatedBreakEvenTurns: estimatedBreakEvenTurns,
      pruneToolPayloadsOnly: pruneToolPayloadsOnly,
      reasonText: reasonText,
      usageRatio: usageRatio
    };
    return decision;
  }

  /** 用量百分比文本，如 `42%`。 */
  private static percentText(usageRatio: number): string {
    return `${Math.round(usageRatio * 100)}%`;
  }

  /** 空闲时长的中文说法。 */
  private static idleSpanText(idleMs: number): string {
    const minutes: number = Math.max(1, Math.round(idleMs / 60000));
    if (minutes >= 120) {
      return `${Math.floor(minutes / 60)} 个多小时`;
    }
    if (minutes >= 60) {
      return '1 个多小时';
    }
    return `${minutes} 分钟`;
  }

  private static attentionReason(usageRatio: number): string {
    return `对话记忆已经用掉 ${CacheAwareCompactor.percentText(usageRatio)} 了，再不整理后面的回答容易变糊涂`;
  }

  private static idleReason(idleMs: number): string {
    return `距上次对话已经过去 ${CacheAwareCompactor.idleSpanText(idleMs)}，缓存早就过期了，这时候顺手整理不会多花一分钱`;
  }

  private static lowRatioReason(usageRatio: number): string {
    return `这个模型的缓存本来就不贵，记忆已经用掉 ${CacheAwareCompactor.percentText(usageRatio)}，整理一下更省钱`;
  }

  /** 节点里是否有值得裁剪的大载荷。 */
  private static hasPrunablePayload(node: ConversationNode): boolean {
    for (const item of node.items) {
      if (item.payloadPruned === true) {
        continue;
      }
      if (item.kind === 'tool_call' || item.kind === 'tool_result' || item.kind === 'web_search_call') {
        return true;
      }
    }
    return false;
  }

  /** 摘要器不可用时的本地降级摘要：把较早对话的要点压成一小段中文。 */
  private static buildFallbackSummary(nodes: ConversationNode[]): string {
    const parts: string[] = [];
    for (const node of nodes) {
      const text: string = CacheAwareCompactor.collectNodeText(node);
      if (text.length > 0) {
        parts.push(`${roleName(node.role)}：${text}`);
      }
    }
    if (parts.length === 0) {
      return '（较早的对话已经整理过，这里只保留了最近的内容。）';
    }
    const joined: string = parts.join('；');
    if (joined.length > 600) {
      return `${joined.substring(0, 600)}……`;
    }
    return joined;
  }

  /** 抽取单个节点的可读文本（用于降级摘要）。 */
  private static collectNodeText(node: ConversationNode): string {
    const chunks: string[] = [];
    for (const item of node.items) {
      if (item.text !== undefined && item.text.trim().length > 0) {
        const text: string = item.text.trim();
        chunks.push(text.length > 120 ? `${text.substring(0, 120)}…` : text);
      } else if (item.kind === 'tool_call') {
        chunks.push(`用了工具 ${item.toolName === undefined ? '（未知）' : item.toolName}`);
      } else if (item.kind === 'web_search_call') {
        chunks.push('查了网上的资料');
      } else if (item.kind === 'image') {
        chunks.push('发过一张图片');
      } else if (item.kind === 'file_ref') {
        chunks.push('传过一个文件');
      }
    }
    return chunks.join(' ');
  }
}
