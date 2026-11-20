/**
 * 对话运行时契约（Lead/运行时/UI 三方共用，冻结；变更须 Lead 仲裁）。
 *
 * 设计取舍：UI 只做「快照 → 渲染」，状态变更全部由 ChatRuntime 管理；
 * 流式文本按帧节流后通过 subscribe 推送。ArkTS 不支持 AsyncIterable，用回调。
 */
import { ConversationNode, SearchHit, SessionMeta, SourceRef } from '@app/core_model';
import { ThinkingLevel, WebMode } from '@app/core_protocol';
import { SkillChipState } from '../app/PersonaStore';

/** 用户发送时附带的一个附件（v3：输入框「+」仅用于附件）。 */
export interface AttachmentRef {
  id: string;
  /** 展示名（文件名 / 链接标题）。 */
  name: string;
  /** image / file / link */
  kind: string;
  /** 本地 uri 或网页链接。 */
  uri: string;
  mimeType?: string;
}

/** 分支选项（长按消息切换分支）。 */
export interface BranchOption {
  childId: string;
  /** 分支首条内容的预览（≤40 字）。 */
  preview: string;
  active: boolean;
  createdAt: number;
}

/** 「检索与清洗过程」时间轴的一步。 */
export interface SearchTraceStep {
  id: string;
  /** search / read / clean / fetch */
  kind: string;
  /** 直白中文，如「正在搜索：华为鸿蒙 26 新特性」。 */
  title: string;
  detail: string;
  /** running / done / failed */
  status: string;
  at: number;
}

/** 运行时可观察快照（每次通知整体替换，UI 直接 setState）。 */
export interface RuntimeSnapshot {
  sessionId: string;
  title: string;
  /** 是否正在接收模型输出。 */
  streaming: boolean;
  /** 本轮已生成的正文（未落盘时用于渲染末尾活跃气泡）。 */
  streamingText: string;
  /** 本轮思考过程（深度思考时展示，可折叠）。 */
  streamingReasoning: string;
  /** 致命错误的中文提示（空串无错误）。 */
  errorMessage: string;
  /** 非致命提示（如「已自动整理对话记忆」）。 */
  noticeMessage: string;
  /** 本轮上下文估算 token。 */
  contextTokens: number;
  /** 模型上下文窗口。 */
  contextWindow: number;
  /** 本轮缓存命中率 0..1。 */
  cacheHitRatio: number;
  /** 记忆条占用 0..1。 */
  memoryRatio: number;
  /** 是否正在整理记忆。 */
  compacting: boolean;
  /** 记忆条悬浮说明（直白中文）。 */
  compactTip: string;
  /** 当前模型中文名。 */
  modelLabel: string;
  modelId: string;
  providerId: string;
  thinkingLevel: ThinkingLevel;
  webMode: WebMode;
  /** 当前会话角色名（顶栏 persona 胶囊）。 */
  personaName: string;
  /** 本对话技能芯片（三级继承结果，展开态输入框上方）。 */
  skillChips: SkillChipState[];
  /** 本轮联网时间轴。 */
  searchTrace: SearchTraceStep[];
  /** 本轮引用来源。 */
  sources: SourceRef[];
  /** 已落盘节点数。 */
  nodeCount: number;
  /** 是否有可用 Key（未配置时输入栏提示去设置）。 */
  hasApiKey: boolean;
  /** 是否已拉取到可用模型（false 时顶栏/输入栏引导去设置）。 */
  hasModel: boolean;
  /** 最近一次记忆整理时间（0 表示从未整理）。 */
  lastCompactionAt: number;
  /** 最近一次整理前估算 token。 */
  lastCompactionBeforeTokens: number;
  /** 最近一次整理后估算 token。 */
  lastCompactionAfterTokens: number;
  /** 最近一次整理摘要全文（空串表示没有）。 */
  lastCompactionSummary: string;
}

/** 运行时接口。 */
export interface ChatRuntimeApi {
  /** 幂等初始化（加载上次会话或新建）。 */
  init(): Promise<void>;

  // ---- 会话管理 ----
  listSessions(): Promise<SessionMeta[]>;
  currentSessionId(): string;
  newSession(): Promise<string>;
  openSession(sessionId: string): Promise<void>;
  deleteSession(sessionId: string): Promise<void>;
  renameSession(sessionId: string, title: string): Promise<void>;

  // ---- 对话 ----
  send(text: string, attachments?: AttachmentRef[]): Promise<void>;
  /** 停止本轮生成（保留已生成内容并落盘）。 */
  stop(): void;
  /** 重新生成最后一条助手回复（生成新分支）。 */
  retryLast(): Promise<void>;
  /** 编辑历史提问并生成新分支。 */
  editUserNode(nodeId: string, newText: string): Promise<void>;

  // ---- 分支 ----
  branches(nodeId: string): Promise<BranchOption[]>;
  switchBranch(parentId: string, childId: string): Promise<void>;

  // ---- 记忆 ----
  compactNow(): Promise<void>;
  searchHistory(query: string): Promise<SearchHit[]>;

  // ---- 设置 ----
  setModel(providerId: string, modelId: string): Promise<void>;
  setThinkingLevel(level: ThinkingLevel): Promise<void>;
  setWebMode(mode: WebMode): Promise<void>;
  /** 切换当前会话角色（personaId 来自 PersonaStore.list()）。 */
  setPersona(personaId: string): Promise<void>;
  setSkillEnabled(skillId: string, enabled: boolean): Promise<void>;
  /** 切换当前会话的技能临时开关（三级继承最内层）。 */
  toggleSessionSkill(skillId: string): Promise<void>;

  // ---- 观察 ----
  snapshot(): RuntimeSnapshot;
  /** 已落盘节点（用于消息列表渲染）。 */
  nodes(): ConversationNode[];
  /** 订阅状态变化，返回订阅 id。 */
  subscribe(listener: (snapshot: RuntimeSnapshot) => void): number;
  unsubscribe(id: number): void;
}
