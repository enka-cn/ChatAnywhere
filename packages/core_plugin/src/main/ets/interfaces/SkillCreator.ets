/**
 * 技能创造室（创造模式）契约（Blueprint §3.6）。
 *
 * 必须闭环：自然语言 → 草稿 Manifest → 沙箱试跑 → 中文 Diff → 用户确认 → RDB 落盘 + 旧版快照。
 * 严禁只停在内存。
 *
 * 对 Blueprint 的适配：`sendInstruction(...): AsyncIterable<StreamEvent>` 改为回调式，
 * 因为 ArkTS 不支持生成器 / AsyncIterable（实测）。
 */
import { ConversationNode, SourceRef } from '@app/core_model';
import { StreamEvent } from '@app/core_protocol';
import { DryRunReport, SkillManifest, UpgradeResult } from './SkillManifest';

/** 创造模式会话状态。 */
export interface CreatorSessionState {
  /** 为空表示新建，非空表示改造现有技能。 */
  targetSkillId?: string;
  /** 待审批草稿 JSON。 */
  draftManifestJson?: string;
  /** 旧版清单 JSON，用于渲染 Diff 与回滚。 */
  previousManifestJson?: string;
  /** 最近一次试跑报告。 */
  dryRunReport?: DryRunReport;
  /** 对话记录（仅展示，不落库）。 */
  turnedCount: number;
}

/** 草稿产物。 */
export interface CreatorDraft {
  draftManifestJson: string;
  /** 中文变更对比（逐字段）。 */
  diffText: string;
  /** 一句话中文说明「改了什么」。 */
  summary: string;
  /** 安全告警。 */
  securityWarnings: string[];
}

/** 创造模式回调。 */
export interface CreatorCallbacks {
  /** 思考/工具过程的流式事件（用于对话气泡）。 */
  onEvent?: (event: StreamEvent) => void;
  /** 状态变化（草稿/试跑结果）。 */
  onState?: (state: CreatorSessionState) => void;
  /** 元 Agent 直接回复的文本增量。 */
  onTextDelta?: (delta: string) => void;
  /** 出错（直白中文）。 */
  onError?: (message: string) => void;
}

/** 创造模式 Agent 接口。 */
export interface SkillCreatorApi {
  /** 开始/继续一个会话（targetSkillId 为空即新建）。 */
  start(targetSkillId?: string): CreatorSessionState;

  /** 发送一条自然语言需求，驱动元 Agent 产出草稿/试跑。 */
  sendInstruction(userText: string, state: CreatorSessionState, callbacks: CreatorCallbacks): Promise<void>;

  /** 在受控沙箱中用模拟输入试跑草稿。 */
  dryRun(manifestJson: string, sampleInput: string): Promise<DryRunReport>;

  /** 仅在用户点击「确认应用」后调用：落盘 + 热挂载 + 旧版快照。 */
  confirmAndCommit(manifestJson: string): Promise<UpgradeResult>;

  /** 从一段真实对话反向提炼可复用技能草稿（长按消息「沉淀为技能」）。 */
  distillFromChat(nodes: ConversationNode[]): Promise<CreatorDraft>;

  /** 本地规则兜底：当未配置模型 Key 时，用关键词规则生成草稿，保证可离线演示。 */
  heuristicDraft(requirementText: string, baseManifestJson?: string): CreatorDraft;
}

/** 创造的元工具名（模型 tool call 约定）。 */
export const CREATOR_TOOL_NAMES: string[] = [
  'list_installed_skills',
  'draft_skill_manifest',
  'dry_run_skill',
  'commit_skill_to_rdb',
  'distill_from_chat'
];

/** 网页清洗技能的可参考来源。 */
export interface CreatorSampleInput {
  query: string;
  url?: string;
  sources?: SourceRef[];
}
