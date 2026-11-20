/**
 * 缓存感知压缩契约（Blueprint §3.4）。
 *
 * 核心原则：**不为省小钱而破坏 30x–50x 的前缀缓存命中**。
 * 本模块为纯逻辑（不 import 任何平台 Kit），可被 Node 逻辑测试覆盖。
 */
import { ConversationNode } from '@app/core_model';

/** 压缩触发原因。 */
export type CompactionTrigger = 'none' | 'idle_cache_expired' | 'model_switched' | 'attention_threshold' |
  'low_ratio_economic';

/** 用户策略。 */
export type CompactionPolicy = 'auto' | 'aggressive' | 'off';

/** 压缩决策所需的模型经济性参数（由 ModelProfile 显式映射，避免纯逻辑依赖协议层）。 */
export interface CompactorInput {
  contextWindowTokens: number;
  /** 缓存未命中/命中价差倍率 R。 */
  cacheMissToHitRatio: number;
  /** 服务端缓存自然过期秒数。 */
  cacheIdleTtlSec: number;
  supportsServerWebTools: boolean;
}

/** 压缩决策。 */
export interface CompactionDecision {
  shouldCompact: boolean;
  trigger: CompactionTrigger;
  /** 公式: (alpha / (1 - alpha)) * R，alpha=预计压缩比。 */
  estimatedBreakEvenTurns: number;
  /** true 时仅在入库前裁剪尾部大载荷，不破坏历史前缀。 */
  pruneToolPayloadsOnly: boolean;
  /** 直白中文原因，供「对话记忆条」悬浮提示。 */
  reasonText: string;
  /** 当前上下文占用比例 0..1。 */
  usageRatio: number;
}

/** 压缩结果。 */
export interface CompactionOutcome {
  /** 生成的 checkpoint_summary 节点（由调用方落库）。 */
  checkpoint: ConversationNode;
  /** 被归档的原始节点 id（永不物理删除）。 */
  archivedNodeIds: string[];
  /** 压缩前后估算 token。 */
  beforeTokens: number;
  afterTokens: number;
}

/** 摘要器：由 ChatRuntime 用协议层实现（core_context 保持纯净）。 */
export interface TextSummarizer {
  summarize(nodes: ConversationNode[]): Promise<string>;
}
