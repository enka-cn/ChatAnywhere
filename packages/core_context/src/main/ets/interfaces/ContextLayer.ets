/**
 * 上下文层装配契约（压缩引擎 + 提示词工坊）。
 */
import { ConversationNode } from '@app/core_model';
import {
  CompactionDecision, CompactionOutcome, CompactionPolicy, CompactorInput, TextSummarizer
} from './CompactionTypes';
import {
  PersonaPreset, PromptAssemblyInput, PromptAssemblyResult, PromptSkillSnippet
} from './PromptTypes';

/** 缓存感知压缩器。 */
export interface CompactorApi {
  /**
   * 决策：是否压缩、为什么、经济性如何。
   * @param input 模型经济性参数
   * @param nodes 活动路径节点（根→叶）
   * @param lastActiveAt 上次活跃时间 ms
   * @param isModelChanged 本次请求是否切换了异构模型
   * @param policy 用户策略
   */
  evaluate(input: CompactorInput, nodes: ConversationNode[], lastActiveAt: number,
    isModelChanged: boolean, policy?: CompactionPolicy): CompactionDecision;

  /**
   * 生成不可变的 checkpoint_summary 节点并返回归档清单。
   * 原始历史节点由调用方标记 archived，永远保留在 RDB + FTS5。
   */
  compactToCheckpoint(sessionId: string, nodes: ConversationNode[], summarizer: TextSummarizer):
    Promise<CompactionOutcome>;

  /** 裁剪尾部大载荷（不破坏历史前缀），返回需要标记 payloadPruned 的节点 id。 */
  pickPrunableNodeIds(nodes: ConversationNode[], keepRecentCount?: number): string[];
}

/** 提示词装配器。 */
export interface PromptAssemblerApi {
  assemble(input: PromptAssemblyInput): PromptAssemblyResult;

  /** 可变变量替换：{{date}} {{time}} {{clipboard}} {{model}} {{user}} {{weekday}}。 */
  renderTemplate(template: string, input: PromptAssemblyInput): string;

  /** 内置角色列表（含「通用助手」）。 */
  personas(): PersonaPreset[];

  /** 按 id 取角色。 */
  persona(id: string): PersonaPreset | null;
}

/** 上下文层门面。 */
export interface ContextLayer {
  compactor: CompactorApi;
  prompts: PromptAssemblerApi;
}

export type CreateContextLayer = () => ContextLayer;

/** 技能片段排序（按 skillId 字典序，保障前缀稳定）。 */
export type SkillSnippetSorter = (snippets: PromptSkillSnippet[]) => PromptSkillSnippet[];
