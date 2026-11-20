/**
 * 运行时内部协作契约：轻量门面 → 子模块的唯一入口。
 *
 * 依赖方向固定为 `ChatRuntime → {SessionController, StreamTurnExecutor, SettingsController} → 本文件`；
 * 子模块**不 import ChatRuntime**，门面实现本接口后把 `this` 注入子模块，避免循环依赖。
 * 本文件同时声明运行时内部共享的可变指标（RuntimeMetrics）与初始快照。
 */
import { ConversationNode } from '@app/core_model';
import { ModelProfile, ThinkingLevel, WebMode } from '@app/core_protocol';
import { AppServices } from '../../app/AppServices';
import { RuntimeSnapshot } from '../ChatRuntimeApi';
import { RoundResult } from './RoundTypes';

/** 运行时内部共享的用量 / 记忆指标（唯一可变实例由门面持有）。 */
export class RuntimeMetrics {
  /** 最近一轮 system prompt 的估算 token。 */
  systemPromptTokens: number = 0;
  /** 最近一轮缓存命中率 0..1。 */
  cacheHitRatio: number = 0;
  /** 最近一轮 usage.inputTokens。 */
  usageInputTokens: number = 0;
  /** 压缩决策给出的说明（直白中文）。 */
  compactionTip: string = '';
}

/** 门面提供给子模块的宿主能力（全部只读状态 + 少量受控写入）。 */
export interface RuntimeHost {
  /** 应用级服务装配（四层 + 设置读取）。 */
  appServices(): AppServices;
  /** 运行时唯一快照（子模块按需就地更新字段）。 */
  snapshot(): RuntimeSnapshot;
  /** 运行时内部指标（唯一可变实例）。 */
  metrics(): RuntimeMetrics;

  /** 立即通知（清掉节流定时器后同步 flush）。 */
  notifyNow(): void;
  /** 流式帧节流通知（32ms 窗口）。 */
  notifyThrottled(): void;
  /** 立即 flush 但保留节流定时器（refreshNodes(false) 的语义）。 */
  notifyImmediate(): void;
  /** 按当前节点列表与指标重算记忆条 / 缓存展示。 */
  recomputeMetrics(): void;

  // ---- 会话与节点（SessionController） ----
  /** 当前会话 id（空串表示尚未建立会话）。 */
  sessionId(): string;
  /** 落盘节点 + 设为父节点的激活子分支。 */
  appendNode(node: ConversationNode): Promise<void>;
  /** 刷新 nodes 缓存与记忆条指标。 */
  refreshNodes(notifyNow: boolean): Promise<void>;
  /** 真正发给模型的上下文（只含未归档节点）。 */
  requestPathTo(leafId: string | null): Promise<ConversationNode[]>;
  /** 标题回写（服务端标题 / 本地首句兜底）。 */
  applyTitle(profile: ModelProfile, result: RoundResult, node: ConversationNode,
    path: ConversationNode[]): Promise<void>;
  /** 刷新会话 updated_at（仅用于会话列表排序）。 */
  touchSession(): Promise<void>;
  /** 只清空本轮时间轴与来源（不改变 stopRequested）。 */
  resetTurnTrace(): void;
  /** 停止本轮生成（会话切换时用）。 */
  stopGeneration(): void;
  /** 新会话继承默认角色的模型与思考档位（无角色存储时降级为空操作）。 */
  applyPersonaDefaults(): Promise<void>;

  // ---- 配置（SettingsController） ----
  /** 当前模型配置（未加载时补加载）。 */
  ensureProfile(): Promise<ModelProfile | null>;
  thinkingLevel(): ThinkingLevel;
  webMode(): WebMode;
  /** 角色提示词（空串表示默认）。 */
  personaPrompt(): string;
  /** 当前会话角色的采样温度（无角色时给 0.7 默认值）。 */
  personaTemperature(): number;
  /** 当前会话角色的 Top-P（无角色时给 0.95 默认值）。 */
  personaTopP(): number;
  /** 当前会话角色允许携带的历史轮数（无角色时给 20）。 */
  personaMaxTurns(): number;
  /** 当前会话记忆摘要（由 checkpoint 恢复）。 */
  memorySummary(): string;
  setMemorySummary(text: string): void;
  /** 压缩策略：auto / aggressive / off。 */
  compactionPolicy(): string;
}

/** 创建初始快照（每次新建对象，避免各处共享同一份可变对象）。 */
export function emptySnapshot(): RuntimeSnapshot {
  const snapshot: RuntimeSnapshot = {
    sessionId: '',
    title: '',
    streaming: false,
    streamingText: '',
    streamingReasoning: '',
    errorMessage: '',
    noticeMessage: '',
    contextTokens: 0,
    contextWindow: 1000000,
    cacheHitRatio: 0,
    memoryRatio: 0,
    compacting: false,
    compactTip: '',
    modelLabel: '深度求索·极速',
    modelId: 'deepseek-flash',
    providerId: 'deepseek',
    thinkingLevel: 'med',
    webMode: 'off',
    personaName: '',
    skillChips: [],
    searchTrace: [],
    sources: [],
    nodeCount: 0,
    hasApiKey: false
  };
  return snapshot;
}
