/**
 * 单轮流式执行器：把「上下文投影 → 压缩判定 → 四层提示词 → 协议流式 → 落盘」串成一条链路。
 *
 * 关键设计（与重构前完全一致）：
 * - 上下文只发「未归档」的节点：压缩后旧节点留在 RDB 与 FTS5，但不再进入活跃上下文；
 * - 工具调用最多 4 轮：每轮把 assistant 的 tool_call 与 tool 的 tool_result 落盘后再发下一轮；
 * - 流式高频事件按 32ms 帧窗口节流（由门面统一调度），结束/停止时清空活跃气泡；
 * - stop 时把已生成内容落盘（半成品不丢），错误保留中文提示 + 可重试后缀。
 */
import { ConversationNode, cacheHitRatio as toCacheHitRatio, estimateText } from '@app/core_model';
import {
  ModelProfile, RequestOptions, StreamCallbacks, StreamEvent, StreamHandle, StreamPayload, UsageInfo
} from '@app/core_protocol';
import { PromptAssemblyResult } from '@app/core_context';
import { SearchTraceStep } from '../ChatRuntimeApi';
import { RuntimeHost } from './RuntimeTypes';
import { RoundAccumulator, RoundResult, ToolCallAcc } from './RoundTypes';
import { SearchTraceStore } from './SearchTraceStore';
import { ToolLoopRunner } from './ToolLoopRunner';
import { PromptComposer } from './PromptComposer';
import { ContextCompactor } from './ContextCompactor';
import { StandaloneCleaner } from './StandaloneCleaner';
import { buildAssistantNode } from './NodeFactory';
import { toolKey } from './RuntimeUtils';

/** 一轮提问里最多连续执行的工具轮数。 */
const MAX_TOOL_ROUNDS: number = 4;

export class StreamTurnExecutor {
  private host: RuntimeHost;
  /** 本轮时间轴与来源（生命周期与单轮一致）。 */
  private trace: SearchTraceStore;
  private tools: ToolLoopRunner;
  private prompts: PromptComposer;
  private compactor: ContextCompactor;
  private cleaner: StandaloneCleaner;

  /** 当前进行中的流句柄（stop 用）。 */
  private currentHandle: StreamHandle | null = null;
  private activeAcc: RoundAccumulator | null = null;
  private activeSettle: ((result: RoundResult) => void) | null = null;
  private stopRequested: boolean = false;
  /** 重新生成时 forkFrom 建好的空助手节点 id（下一轮结果 UPSERT 到它上面）。 */
  private pendingReuseNodeId: string = '';

  constructor(host: RuntimeHost) {
    this.host = host;
    this.trace = new SearchTraceStore();
    this.tools = new ToolLoopRunner(host, this.trace);
    this.prompts = new PromptComposer(host);
    this.compactor = new ContextCompactor(host);
    this.cleaner = new StandaloneCleaner(host, this.trace);
  }

  /** 本轮时间轴的深拷贝（快照外发用）。 */
  copyTrace(): SearchTraceStep[] {
    return this.trace.copy();
  }

  /** 开始新一轮：清停止标志 + 清空本轮时间轴与来源。 */
  resetTurn(): void {
    this.stopRequested = false;
    this.trace.reset();
  }

  /** 只清空本轮时间轴与来源（切换/新建会话时用，不影响停止标志）。 */
  resetTrace(): void {
    this.trace.reset();
  }

  /** 手动整理记忆（门面 compactNow 委派）。 */
  compactMemory(profile: ModelProfile, path: ConversationNode[], auto: boolean): Promise<void> {
    return this.compactor.compactMemory(profile, path, auto);
  }

  /** 停止本轮生成：settle 半成品、取消网络请求、清空活跃气泡（内容由调用方落盘）。 */
  stop(): void {
    this.stopRequested = true;
    const acc: RoundAccumulator | null = this.activeAcc;
    const settle: ((result: RoundResult) => void) | null = this.activeSettle;
    const handle: StreamHandle | null = this.currentHandle;
    if (acc !== null && !acc.settled) {
      acc.stopped = true;
      if (settle !== null) {
        settle(acc.toResult());
      }
    }
    this.activeAcc = null;
    this.activeSettle = null;
    this.currentHandle = null;
    if (handle !== null) {
      try {
        handle.cancel();
      } catch (e) {
        // 取消失败不影响"已停止"的语义
      }
    }
    this.host.snapshot().streaming = false;
    this.host.notifyNow();
  }

  // -------------------------------------------------------------------------
  // 一轮对话（含工具循环）
  // -------------------------------------------------------------------------

  /**
   * 从 leafId 往后生成助手回复；工具调用最多 MAX_TOOL_ROUNDS 轮。
   * 每生成一个节点都先落盘，再继续下一轮。
   *
   * @param reuseAssistantId 非空时表示「重新生成」已用 forkFrom 建好的空助手节点 id，
   *                         第一轮助手结果用同一个 nodeId UPSERT 填进去（不留空节点）。
   */
  async runAssistantTurn(profile: ModelProfile, leafId: string | null,
    reuseAssistantId: string = ''): Promise<void> {
    this.pendingReuseNodeId = reuseAssistantId;
    const snapshot = this.host.snapshot();
    // v3：本轮只注入「当前会话生效」的角色技能（全局开关 ⊂ 角色绑定 ⊂ 会话覆盖）。
    await this.prompts.refreshActiveSkills();
    let cursor: string | null = leafId;
    let round: number = 0;
    while (true) {
      round += 1;
      let path: ConversationNode[] = await this.host.requestPathTo(cursor);
      if (round === 1) {
        await this.compactor.maybeAutoCompact(profile, path);
        if (this.stopRequested) {
          snapshot.streaming = false;
          this.host.notifyNow();
          return;
        }
        path = await this.host.requestPathTo(cursor);
      }
      if (this.stopRequested) {
        snapshot.streaming = false;
        this.host.notifyNow();
        return;
      }
      // v3：按角色 maxTurns 裁剪历史（保留 checkpoint / system，保证记忆摘要不丢）。
      const promptPath: ConversationNode[] = this.trimByMaxTurns(path);
      const memoryBlocks: string[] = round === 1 ? await this.cleaner.run(path) : [];
      const assembled: PromptAssemblyResult = this.prompts.assembleSystemPrompt(profile, memoryBlocks);
      this.host.metrics().systemPromptTokens = estimateText(assembled.systemPrompt);
      snapshot.streaming = true;
      snapshot.streamingText = '';
      snapshot.streamingReasoning = '';
      snapshot.searchTrace = this.trace.copy();
      this.host.notifyNow();

      const acc: RoundAccumulator = new RoundAccumulator();
      const result: RoundResult = await this.streamOnce(profile, promptPath, assembled.systemPrompt, acc);
      snapshot.streaming = false;

      if (result.stopped) {
        await this.persistStopped(profile, result, cursor);
        snapshot.streamingText = '';
        snapshot.streamingReasoning = '';
        snapshot.noticeMessage = '已经停止生成，上面保留的是已经写出来的部分';
        await this.host.refreshNodes(true);
        return;
      }

      if (result.errorMessage.length > 0) {
        if (result.text.length > 0 || result.reasoning.length > 0) {
          await this.appendAssistantNode(profile, cursor, result, false);
        }
        const suffix: string = result.retriable ? '（可以点“重新生成”再试一次）' : '';
        snapshot.errorMessage = `${result.errorMessage}${suffix}`;
        snapshot.streamingText = '';
        snapshot.streamingReasoning = '';
        snapshot.sources = this.trace.collect(acc.webCalls);
        await this.host.refreshNodes(true);
        return;
      }

      const hasToolCalls: boolean = result.toolCalls.length > 0;
      const canRunTools: boolean = hasToolCalls && round <= MAX_TOOL_ROUNDS;
      if (canRunTools) {
        const assistantNode: ConversationNode = await this.appendAssistantNode(profile, cursor, result, true);
        // 这一轮的正文已经落盘成消息，清空活跃气泡；执行技能期间继续显示"正在思考"。
        snapshot.streamingText = '';
        snapshot.streamingReasoning = '';
        snapshot.streaming = true;
        snapshot.searchTrace = this.trace.copy();
        await this.host.refreshNodes(true);
        const toolNodeId: string | null = await this.tools.execute(result, assistantNode.nodeId);
        cursor = toolNodeId !== null ? toolNodeId : assistantNode.nodeId;
        snapshot.searchTrace = this.trace.copy();
        await this.host.refreshNodes(true);
        continue;
      }

      const finalNode: ConversationNode = buildAssistantNode(this.host.sessionId(), profile, cursor, result, false);
      await this.applyUsage(result, finalNode);
      await this.appendAssistantNode(profile, cursor, result, false, finalNode);
      await this.host.touchSession();
      if (hasToolCalls) {
        snapshot.noticeMessage = '一轮里能自动用的技能次数已经到上限，先把现在的结果给你';
      }
      await this.host.applyTitle(profile, result, finalNode, path);
      snapshot.streamingText = '';
      snapshot.streamingReasoning = '';
      snapshot.sources = this.trace.collect(acc.webCalls);
      snapshot.searchTrace = this.trace.copy();
      await this.host.refreshNodes(true);
      return;
    }
  }

  /** 停止时把已生成内容落盘（保证不丢）。 */
  private async persistStopped(profile: ModelProfile, result: RoundResult,
    parentId: string | null): Promise<void> {
    if (result.text.trim().length === 0 && result.reasoning.trim().length === 0) {
      return;
    }
    await this.appendAssistantNode(profile, parentId, result, false);
  }

  /**
   * 构造助手节点并落盘；若本次是「重新生成」，把 forkFrom 建好的空节点 id 复用（UPSERT），
   * 避免历史上留下一条空回答。
   *
   * @param prepared 已构造好的节点（最终一轮需要先写入用量字段），可为 null
   */
  private async appendAssistantNode(profile: ModelProfile, parentId: string | null, result: RoundResult,
    includeToolCalls: boolean, prepared: ConversationNode | null = null): Promise<ConversationNode> {
    let node: ConversationNode;
    if (prepared !== null) {
      node = prepared;
    } else {
      node = buildAssistantNode(this.host.sessionId(), profile, parentId, result, includeToolCalls);
    }
    if (this.pendingReuseNodeId.length > 0) {
      node.nodeId = this.pendingReuseNodeId;
      this.pendingReuseNodeId = '';
    }
    await this.host.appendNode(node);
    return node;
  }

  // -------------------------------------------------------------------------
  // 协议流式请求与事件消费
  // -------------------------------------------------------------------------

  /** 单轮流式请求，onDone/onError/stop 三者任一到达即 resolve。 */
  private streamOnce(profile: ModelProfile, path: ConversationNode[], systemPrompt: string,
    acc: RoundAccumulator): Promise<RoundResult> {
    return new Promise<RoundResult>((resolve: (value: RoundResult) => void) => {
      this.activeAcc = acc;
      this.activeSettle = (result: RoundResult): void => {
        if (acc.settled) {
          return;
        }
        acc.settled = true;
        this.activeAcc = null;
        this.activeSettle = null;
        this.currentHandle = null;
        resolve(result);
      };
      const options: RequestOptions = this.prompts.buildRequestOptions(systemPrompt);
      const callbacks: StreamCallbacks = {
        onEvent: (event: StreamEvent): void => {
          if (acc.settled) {
            return;
          }
          this.handleStreamEvent(acc, event);
        },
        onError: (message: string, errorCode: string, retriable: boolean): void => {
          acc.errorMessage = message;
          acc.errorCode = errorCode;
          acc.retriable = retriable;
          this.settleActive(acc);
        },
        onDone: (): void => {
          this.settleActive(acc);
        }
      };
      try {
        this.currentHandle = this.host.appServices().requireProtocol().send(profile, path, options, callbacks);
      } catch (e) {
        acc.errorMessage = `请求模型失败：${(e as Error).message}`;
        acc.retriable = true;
        this.settleActive(acc);
      }
    });
  }

  private settleActive(acc: RoundAccumulator): void {
    const settle: ((result: RoundResult) => void) | null = this.activeSettle;
    if (settle !== null) {
      settle(acc.toResult());
    }
  }

  private handleStreamEvent(acc: RoundAccumulator, event: StreamEvent): void {
    const payload: StreamPayload = event.payload;
    if (event.type === 'text_delta') {
      acc.text += payload.delta === undefined ? '' : payload.delta;
    } else if (event.type === 'reasoning_delta') {
      acc.reasoning += payload.delta === undefined ? '' : payload.delta;
    } else if (event.type === 'tool_call_delta') {
      this.handleToolCall(acc, payload);
    } else if (event.type === 'web_search_status') {
      this.trace.applyWebStatus(acc, payload);
    } else if (event.type === 'usage_final') {
      if (payload.usage !== undefined) {
        acc.usage = payload.usage;
      }
    } else if (event.type === 'title_generated') {
      if (payload.title !== undefined) {
        acc.title = payload.title;
      }
    } else if (event.type === 'error') {
      acc.errorMessage = payload.message === undefined ? '模型返回了错误' : payload.message;
      acc.errorCode = payload.errorCode === undefined ? '' : payload.errorCode;
      acc.retriable = payload.retriable === true;
    }
    this.syncFrame(acc);
  }

  /** 更新可观察的流式字段并按 32ms 帧窗口节流通知。 */
  private syncFrame(acc: RoundAccumulator): void {
    const snapshot = this.host.snapshot();
    snapshot.streamingText = acc.text;
    snapshot.streamingReasoning = acc.reasoning;
    snapshot.searchTrace = this.trace.copy();
    snapshot.sources = this.trace.collect(acc.webCalls);
    this.host.notifyThrottled();
  }

  private handleToolCall(acc: RoundAccumulator, payload: StreamPayload): void {
    const phase: string = payload.phase === undefined ? 'delta' : payload.phase;
    const callId: string = payload.callId === undefined ? '' : payload.callId;
    const itemId: string = payload.itemId === undefined ? '' : payload.itemId;
    let call: ToolCallAcc | null = null;
    for (const one of acc.toolCalls) {
      if (callId.length > 0 && one.callId === callId) {
        call = one;
        break;
      }
      if (itemId.length > 0 && one.itemId === itemId) {
        call = one;
        break;
      }
    }
    if (call === null) {
      call = new ToolCallAcc();
      call.callId = callId;
      call.itemId = itemId;
      acc.toolCalls.push(call);
    }
    if (callId.length > 0) {
      call.callId = callId;
    }
    if (itemId.length > 0) {
      call.itemId = itemId;
    }
    if (payload.toolName !== undefined && payload.toolName.length > 0) {
      call.toolName = payload.toolName;
    }
    const argsDelta: string = payload.argumentsDelta === undefined ? '' : payload.argumentsDelta;
    if (phase === 'end') {
      if (argsDelta.length > 0) {
        call.argumentsJson = argsDelta;
      }
      call.ended = true;
      this.trace.upsert(`tool_${toolKey(call)}`, 'tool',
        `准备执行技能「${call.toolName.length > 0 ? call.toolName : '未知技能'}」`, '', 'running');
    } else if (argsDelta.length > 0) {
      call.argumentsJson += argsDelta;
    }
  }

  /**
   * v3：按角色 maxTurns 裁剪历史投影。
   * 保留最近 maxTurns 个「用户提问」及其之后的节点；system 与 checkpoint_summary 永不裁剪。
   */
  private trimByMaxTurns(path: ConversationNode[]): ConversationNode[] {
    const maxTurns: number = this.host.personaMaxTurns();
    if (maxTurns <= 0 || path.length === 0) {
      return path;
    }
    let userCount: number = 0;
    let keepStart: number = -1;
    for (let i = path.length - 1; i >= 0; i--) {
      if (path[i].role !== 'user') {
        continue;
      }
      userCount += 1;
      if (userCount >= maxTurns) {
        keepStart = i;
        break;
      }
    }
    if (keepStart <= 0) {
      return path;
    }
    const out: ConversationNode[] = [];
    for (let i = 0; i < path.length; i++) {
      if (i >= keepStart || path[i].role === 'system' || hasCheckpointItem(path[i])) {
        out.push(path[i]);
      }
    }
    return out;
  }

  private async applyUsage(result: RoundResult, node: ConversationNode): Promise<void> {
    if (result.usage === null) {
      return;
    }
    const usage: UsageInfo = result.usage;
    node.cachedTokens = usage.cachedTokens;
    node.promptTokens = usage.inputTokens;
    node.completionTokens = usage.outputTokens;
    node.cacheHitRatio = toCacheHitRatio(usage.cachedTokens, usage.inputTokens);
    this.host.metrics().usageInputTokens = usage.inputTokens;
    this.host.metrics().cacheHitRatio = node.cacheHitRatio === undefined ? 0 : node.cacheHitRatio;
  }
}

/** 节点是否承载记忆摘要（裁剪历史时必须保留）。 */
function hasCheckpointItem(node: ConversationNode): boolean {
  for (const item of node.items) {
    if (item.kind === 'checkpoint_summary') {
      return true;
    }
  }
  return false;
}
