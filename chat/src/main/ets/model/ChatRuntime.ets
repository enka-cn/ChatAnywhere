/**
 * 对话运行时（轻量门面）。
 *
 * 重构说明：原 2381 行「上帝类」按职责拆到 `model/runtime/`：
 * - SessionController：会话 CRUD / 节点缓存 / 分支 / 标题回写 / 记忆摘要；
 * - StreamTurnExecutor：单轮流式执行（上下文投影、流式事件消费、assistant 落盘、用量）；
 * - ToolLoopRunner：工具循环（≤4 轮）与 tool_result 落盘；
 * - SettingsController：模型 / 6 档思考 / 联网 / 会话角色 / 技能三级继承 / 压缩策略 / 密钥；
 * - TurnCoordinator：发送 / 重试 / 编辑重发 / 手动整理的编排与忙碌互斥；
 * - ContextCompactor、PromptComposer、ProtocolTextSummarizer、StandaloneCleaner、
 *   SearchTraceStore、NodeFactory、SnapshotNotifier、RoundTypes、RuntimeUtils：共享件。
 *
 * 门面自身只保留：快照（RuntimeSnapshot）与订阅 / 通知（32ms 节流、结束清空流式字段）、
 * 生命周期，以及把 ChatRuntimeApi 的调用委派给子模块。对外契约与行为保持稳定。
 */
import {
  ConversationNode, SearchHit, SessionMeta, contextUsageRatio, estimateNodeTokens
} from '@app/core_model';
import { ModelProfile, ThinkingLevel, WebMode } from '@app/core_protocol';
import { AppServices } from '../app/AppServices';
import { AttachmentRef, BranchOption, ChatRuntimeApi, RuntimeSnapshot } from './ChatRuntimeApi';
import { RuntimeHost, RuntimeMetrics, emptySnapshot } from './runtime/RuntimeTypes';
import { SessionController } from './runtime/SessionController';
import { SettingsController } from './runtime/SettingsController';
import { StreamTurnExecutor } from './runtime/StreamTurnExecutor';
import { TurnCoordinator } from './runtime/TurnCoordinator';
import { RoundResult } from './runtime/RoundTypes';
import { SnapshotNotifier } from './runtime/SnapshotNotifier';
import { percentText } from './runtime/RuntimeUtils';

export class ChatRuntime implements ChatRuntimeApi, RuntimeHost {
  private services: AppServices;

  private snapshotValue: RuntimeSnapshot = emptySnapshot();
  private metricsValue: RuntimeMetrics = new RuntimeMetrics();
  private notifier: SnapshotNotifier;

  private inited: boolean = false;
  private initPromise: Promise<void> | null = null;

  private sessions: SessionController;
  private settings: SettingsController;
  private turn: StreamTurnExecutor;
  private turns: TurnCoordinator;

  constructor(services: AppServices) {
    this.services = services;
    this.settings = new SettingsController(this);
    this.sessions = new SessionController(this);
    this.turn = new StreamTurnExecutor(this);
    this.turns = new TurnCoordinator(this, this.sessions, this.settings, this.turn);
    this.notifier = new SnapshotNotifier(() => this.snapshotValue, () => this.turn.copyTrace());
  }

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  async init(): Promise<void> {
    if (this.inited) {
      return;
    }
    if (this.initPromise !== null) {
      await this.initPromise;
      return;
    }
    this.initPromise = this.doInit();
    await this.initPromise;
  }

  private async doInit(): Promise<void> {
    const services = this.services;
    let ok: boolean = false;
    try {
      ok = await services.waitReady();
    } catch (e) {
      ok = false;
    }
    if (!ok) {
      const reason: string = services.initError.length > 0 ? services.initError
        : '应用还没有准备就绪，请稍后重试';
      this.snapshotValue.errorMessage = reason;
      this.notifyNow();
      this.initPromise = null;
      return;
    }
    try {
      await this.settings.reloadSettings();
      await this.sessions.openLastOrNewSession();
      await this.sessions.refreshNodes(true);
      await this.settings.refreshPersonaState();
      this.notifyNow();
    } catch (e) {
      this.snapshotValue.errorMessage = `打开对话失败：${(e as Error).message}`;
      this.notifyNow();
    }
    this.inited = true;
  }

  /** 是否正忙（正在生成或正在整理记忆）。页面用它避免把用户刚输入的文本吞掉。 */
  isBusy(): boolean {
    return this.turns.isBusy();
  }

  /** 重新读取设置（从设置页 / 技能页返回时刷新模型、思考、联网、角色、密钥状态）。 */
  async refreshSettings(): Promise<void> {
    if (!this.inited) {
      return;
    }
    try {
      await this.settings.reloadSettings();
      this.recomputeMetrics();
      await this.settings.refreshPersonaState();
      this.notifyNow();
    } catch (e) {
      // 设置读取失败时保持上一份配置，不打断对话
    }
  }

  // -------------------------------------------------------------------------
  // 会话管理
  // -------------------------------------------------------------------------

  listSessions(): Promise<SessionMeta[]> {
    return this.sessions.listSessions();
  }

  currentSessionId(): string {
    return this.sessions.currentSessionId();
  }

  async newSession(): Promise<string> {
    await this.init();
    const id: string = await this.sessions.newSession();
    await this.settings.refreshPersonaState();
    this.recomputeMetrics();
    this.notifyNow();
    return id;
  }

  async openSession(sessionId: string): Promise<void> {
    await this.init();
    await this.sessions.openSession(sessionId);
    await this.settings.refreshPersonaState();
    this.notifyNow();
  }

  async deleteSession(sessionId: string): Promise<void> {
    await this.sessions.deleteSession(sessionId);
    await this.settings.refreshPersonaState();
    this.notifyNow();
  }

  async renameSession(sessionId: string, title: string): Promise<void> {
    await this.sessions.renameSession(sessionId, title);
  }

  // -------------------------------------------------------------------------
  // 对话（编排委派给 TurnCoordinator）
  // -------------------------------------------------------------------------

  async send(text: string, attachments?: AttachmentRef[]): Promise<void> {
    if (this.turns.isBusy()) {
      return;
    }
    await this.init();
    await this.turns.send(text, attachments);
  }

  stop(): void {
    this.turn.stop();
  }

  async retryLast(): Promise<void> {
    if (this.turns.isBusy()) {
      return;
    }
    await this.init();
    await this.turns.retryLast();
  }

  /** 重新生成指定某条回答（长按老消息用；旧分支完整保留）。 */
  async regenerateNode(nodeId: string): Promise<void> {
    if (this.turns.isBusy()) {
      return;
    }
    await this.init();
    await this.turns.regenerateNode(nodeId);
  }

  async editUserNode(nodeId: string, newText: string): Promise<void> {
    if (this.turns.isBusy()) {
      return;
    }
    if (newText.trim().length === 0) {
      return;
    }
    await this.init();
    await this.turns.editUserNode(nodeId, newText);
  }

  branches(nodeId: string): Promise<BranchOption[]> {
    return this.sessions.branches(nodeId);
  }

  switchBranch(parentId: string, childId: string): Promise<void> {
    return this.sessions.switchBranch(parentId, childId);
  }

  // -------------------------------------------------------------------------
  // 记忆整理
  // -------------------------------------------------------------------------

  async compactNow(): Promise<void> {
    if (this.turns.isBusy()) {
      return;
    }
    await this.init();
    await this.turns.compactNow();
  }

  searchHistory(query: string): Promise<SearchHit[]> {
    return this.services.requireModel().repo.search(query, 20);
  }

  // -------------------------------------------------------------------------
  // 设置
  // -------------------------------------------------------------------------

  setModel(providerId: string, modelId: string): Promise<void> {
    return this.settings.setModel(providerId, modelId);
  }

  setThinkingLevel(level: ThinkingLevel): Promise<void> {
    return this.settings.setThinkingLevel(level);
  }

  setWebMode(mode: WebMode): Promise<void> {
    return this.settings.setWebMode(mode);
  }

  /** 切换当前会话角色（写 PersonaStore + 刷新 personaName / skillChips，下一轮生效）。 */
  setPersona(personaId: string): Promise<void> {
    return this.settings.setPersona(personaId);
  }

  /** 切换当前会话的技能临时开关（三级继承最内层）。 */
  toggleSessionSkill(skillId: string): Promise<void> {
    return this.settings.toggleSessionSkill(skillId);
  }

  setSkillEnabled(skillId: string, enabled: boolean): Promise<void> {
    return this.settings.setSkillEnabled(skillId, enabled);
  }

  // -------------------------------------------------------------------------
  // 观察
  // -------------------------------------------------------------------------

  snapshot(): RuntimeSnapshot {
    return this.snapshotValue;
  }

  nodes(): ConversationNode[] {
    return this.sessions.nodes();
  }

  subscribe(listener: (snapshot: RuntimeSnapshot) => void): number {
    return this.notifier.subscribe(listener);
  }

  unsubscribe(id: number): void {
    this.notifier.unsubscribe(id);
  }

  // -------------------------------------------------------------------------
  // RuntimeHost 实现（子模块的唯一入口，只做委派 + 快照/通知）
  // -------------------------------------------------------------------------

  appServices(): AppServices {
    return this.services;
  }

  metrics(): RuntimeMetrics {
    return this.metricsValue;
  }

  notifyNow(): void {
    this.notifier.notifyNow();
  }

  notifyThrottled(): void {
    this.notifier.notifyThrottled();
  }

  notifyImmediate(): void {
    this.notifier.notifyImmediate();
  }

  /** 重算上下文占用与缓存命中展示（全部用估算，保证永远有数）。 */
  recomputeMetrics(): void {
    const profile: ModelProfile | null = this.settings.profile();
    const window: number = profile === null ? this.snapshotValue.contextWindow : profile.contextWindow;
    let tokens: number = 0;
    for (const node of this.sessions.nodes()) {
      if (node.archived === true) {
        continue;
      }
      tokens += node.tokenEstimate > 0 ? node.tokenEstimate : estimateNodeTokens(node);
    }
    if (this.metricsValue.usageInputTokens > tokens) {
      tokens = this.metricsValue.usageInputTokens;
    }
    tokens += this.metricsValue.systemPromptTokens;
    this.snapshotValue.contextWindow = window;
    this.snapshotValue.contextTokens = tokens;
    this.snapshotValue.memoryRatio = contextUsageRatio(tokens, window);
    this.snapshotValue.cacheHitRatio = this.metricsValue.cacheHitRatio;
    const ratioText: string = percentText(this.snapshotValue.memoryRatio);
    const cacheText: string = percentText(this.metricsValue.cacheHitRatio);
    const base: string = `对话记忆 ${ratioText} · 本轮省钱命中 ${cacheText}`;
    this.snapshotValue.compactTip = this.metricsValue.compactionTip.length > 0
      ? `${base}\n${this.metricsValue.compactionTip}` : base;
  }

  sessionId(): string {
    return this.sessions.currentSessionId();
  }

  appendNode(node: ConversationNode): Promise<void> {
    return this.sessions.appendNode(node);
  }

  refreshNodes(notifyNowFlag: boolean): Promise<void> {
    return this.sessions.refreshNodes(notifyNowFlag);
  }

  requestPathTo(leafId: string | null): Promise<ConversationNode[]> {
    return this.sessions.requestPathTo(leafId);
  }

  applyTitle(profile: ModelProfile, result: RoundResult, node: ConversationNode,
    path: ConversationNode[]): Promise<void> {
    return this.sessions.applyTitle(profile, result, node, path);
  }

  touchSession(): Promise<void> {
    return this.sessions.touchSession();
  }

  resetTurnTrace(): void {
    this.turn.resetTrace();
  }

  stopGeneration(): void {
    this.turn.stop();
  }

  applyPersonaDefaults(): Promise<void> {
    return this.settings.applyPersonaDefaultsForNewSession();
  }

  ensureProfile(): Promise<ModelProfile | null> {
    return this.settings.ensureProfile();
  }

  thinkingLevel(): ThinkingLevel {
    return this.settings.thinkingLevel();
  }

  webMode(): WebMode {
    return this.settings.webMode();
  }

  personaPrompt(): string {
    return this.settings.personaPrompt();
  }

  personaTemperature(): number {
    return this.settings.personaTemperature();
  }

  personaTopP(): number {
    return this.settings.personaTopP();
  }

  personaMaxTurns(): number {
    return this.settings.personaMaxTurns();
  }

  memorySummary(): string {
    return this.sessions.memorySummary();
  }

  setMemorySummary(text: string): void {
    this.sessions.setMemorySummary(text);
  }

  compactionPolicy(): string {
    return this.settings.compactionPolicy();
  }
}

// 兼容旧的导入路径：记忆条说明与 token 估算仍在 `model/ChatRuntime` 模块下可用。
export { describeMemoryUsage, estimateActiveTokens } from './runtime/RuntimeUtils';
