/**
 * 「技能创造室」元 Agent（创造模式）。
 *
 * 闭环（Blueprint §1 第 5 条、§3.6）：
 * 自然语言/语音需求 → 元 Agent 产出草稿清单 → 沙箱试跑 → 中文 Diff → 用户确认 → RDB 落盘 + 旧版快照。
 *
 * 驱动方式：协议层（Responses API）多轮 tool_call 驱动 5 个元工具；
 * 未配置模型 Key / 模型不可用时自动降级到本地规则（`util/CreatorHeuristic.ets`），保证离线可演示。
 *
 * ArkTS 约束：不能用 `AsyncIterable`，全部改为回调式（CreatorCallbacks）。
 */
import {
  CanonicalItem, ConversationNode, SecretAliases, SecretApi, SettingsApi, SkillRepositoryApi,
  estimateText, newNodeId
} from '@app/core_model';
import { ModelProfile, ProtocolLayer, RequestOptions, StreamCallbacks, StreamEvent, StreamPayload,
  ToolSpec } from '@app/core_protocol';
import {
  CreatorCallbacks, CreatorDraft, CreatorSessionState, SkillCreatorApi
} from './interfaces/SkillCreator';
import { DryRunReport, SkillManifest, UpgradeResult } from './interfaces/SkillManifest';
import { PluginKernelImpl } from './PluginKernelImpl';
import { diffManifestJson, summarizeDiff } from './SkillDiff';
import { collectSecurityWarnings, normalizeManifestJson, tierLabel } from './SkillSchema';
import { distillDraftRaw, heuristicDraftRaw, HeuristicDraftResult } from './util/CreatorHeuristic';
import {
  emptyRecord, getObject, getString, hasValue, parseRecord, parseStringArray, toJsonText, truncateText
} from './util/JsonLite';

/** 创造模式依赖。 */
export interface SkillCreatorDeps {
  kernel: PluginKernelImpl;
  skills: SkillRepositoryApi;
  secrets: SecretApi;
  settings: SettingsApi;
  protocol: ProtocolLayer | null;
}

/** 模型返回的一个工具调用（累加后的完整参数）。 */
interface ModelToolCall {
  callId: string;
  name: string;
  argumentsJson: string;
}

/** 一轮模型往返的汇总结果。 */
interface ModelRoundResult {
  ok: boolean;
  text: string;
  toolCalls: ModelToolCall[];
}

/** 创造室元 Agent 实现。 */
export class SkillCreatorAgentImpl implements SkillCreatorApi {
  private readonly deps: SkillCreatorDeps;
  private lastDraftValue: CreatorDraft | null = null;

  constructor(deps: SkillCreatorDeps) {
    this.deps = deps;
  }

  // ---------------------------------------------------------------------------
  // 会话
  // ---------------------------------------------------------------------------

  /** 开始/继续会话；targetSkillId 非空时把旧版清单放进状态用于 Diff 与回滚。 */
  start(targetSkillId?: string): CreatorSessionState {
    if (targetSkillId !== undefined && targetSkillId.trim().length > 0) {
      const id: string = targetSkillId.trim();
      const manifestJson: string = this.deps.kernel.exportManifest(id);
      if (manifestJson.length > 0) {
        return {
          targetSkillId: id,
          draftManifestJson: manifestJson,
          previousManifestJson: manifestJson,
          turnedCount: 0
        };
      }
      return { targetSkillId: id, turnedCount: 0 };
    }
    return { turnedCount: 0 };
  }

  /** 最近一次生成的草稿（供 UI 卡片直接渲染，避免再从状态里拼）。 */
  lastDraft(): CreatorDraft | null {
    return this.lastDraftValue;
  }

  /** 发送一条自然语言需求：优先模型驱动，失败自动降级到本地规则。 */
  async sendInstruction(userText: string, state: CreatorSessionState,
    callbacks: CreatorCallbacks): Promise<void> {
    const text: string = userText === null || userText === undefined ? '' : userText.trim();
    if (text.length === 0) {
      this.reportError(callbacks, '请先用一句话说说你想让技能做什么。');
      return;
    }
    state.turnedCount = state.turnedCount + 1;
    if (state.targetSkillId !== undefined && (state.previousManifestJson === undefined ||
      state.previousManifestJson.length === 0)) {
      const existing: string = this.deps.kernel.exportManifest(state.targetSkillId);
      if (existing.length > 0) {
        state.previousManifestJson = existing;
      }
    }
    if (callbacks.onState !== undefined) {
      callbacks.onState(state);
    }
    let modelDriven: boolean = false;
    try {
      modelDriven = await this.runModelLoop(text, state, callbacks);
    } catch (e) {
      const err = e as Error;
      modelDriven = false;
      this.reportError(callbacks, `模型驱动失败，已改用本地规则：${err.message}`);
    }
    if (!modelDriven) {
      this.applyHeuristic(text, state, callbacks);
    }
  }

  /** 在受控环境试跑草稿（不落盘）。 */
  async dryRun(manifestJson: string, sampleInput: string): Promise<DryRunReport> {
    return this.deps.kernel.dryRun(manifestJson, sampleInput);
  }

  /** 用户点击「应用生效」后才会走到这里：落盘 + 热挂载 + 旧版快照。 */
  async confirmAndCommit(manifestJson: string): Promise<UpgradeResult> {
    const normalized = normalizeManifestJson(manifestJson);
    if (!normalized.ok) {
      return { ok: false, error: normalized.error, diffText: '', securityWarnings: normalized.warnings };
    }
    const manifest = JSON.parse(normalized.manifestJson) as SkillManifest;
    return this.deps.kernel.atomicUpgrade(manifest);
  }

  /** 从一段真实对话反向提炼技能草稿（长按消息「沉淀为技能」）。 */
  async distillFromChat(nodes: ConversationNode[]): Promise<CreatorDraft> {
    const parts: string[] = [];
    if (nodes !== null && nodes !== undefined) {
      for (const node of nodes) {
        for (const item of node.items) {
          if (item.kind === 'text' && item.text !== undefined && item.text.trim().length > 0) {
            parts.push(item.text.trim());
          }
        }
      }
    }
    const chatText: string = parts.join('\n');
    const raw: HeuristicDraftResult = distillDraftRaw(chatText, '');
    const draft: CreatorDraft = {
      draftManifestJson: raw.draftManifestJson,
      diffText: raw.diffText,
      summary: raw.summary.length > 0 ? raw.summary : (raw.ok ? '已沉淀为技能草稿' : raw.error),
      securityWarnings: parseStringArray(raw.securityWarningsJson)
    };
    this.lastDraftValue = draft;
    return draft;
  }

  /** 本地规则兜底：无模型 Key 也能演示。 */
  heuristicDraft(requirementText: string, baseManifestJson?: string): CreatorDraft {
    const base: string = baseManifestJson === undefined ? '' : baseManifestJson;
    const raw: HeuristicDraftResult = heuristicDraftRaw(requirementText, base);
    const draft: CreatorDraft = {
      draftManifestJson: raw.draftManifestJson,
      diffText: raw.diffText,
      summary: raw.summary.length > 0 ? raw.summary : raw.error,
      securityWarnings: parseStringArray(raw.securityWarningsJson)
    };
    if (raw.ok) {
      this.lastDraftValue = draft;
    }
    return draft;
  }

  // ---------------------------------------------------------------------------
  // 模型驱动（多轮元工具）
  // ---------------------------------------------------------------------------

  /** 跑元 Agent 多轮工具循环；返回 true 表示已产出可用草稿。 */
  private async runModelLoop(userText: string, state: CreatorSessionState,
    callbacks: CreatorCallbacks): Promise<boolean> {
    const protocol: ProtocolLayer | null = this.deps.protocol;
    if (protocol === null) {
      return false;
    }
    let apiKey: string = '';
    try {
      const fetched: string | null = await this.deps.secrets.get(SecretAliases.DEEPSEEK);
      apiKey = fetched === null ? '' : fetched;
    } catch (e) {
      apiKey = '';
    }
    if (apiKey.length === 0) {
      return false;
    }
    let profile: ModelProfile;
    try {
      // v3.2：模型目录只含真实模型，未拉取模型时返回 null → 创造室降级到本地规则
      const resolved: ModelProfile | null = protocol.catalog.defaultProfile();
      if (resolved === null) {
        return false;
      }
      profile = resolved;
    } catch (e) {
      return false;
    }
    const systemPrompt: string = this.buildSystemPrompt(state);
    const nodes: ConversationNode[] = [];
    const userItem: CanonicalItem = { id: newNodeId(), kind: 'text', text: userText };
    nodes.push({
      nodeId: newNodeId(),
      parentId: null,
      sessionId: 'creator',
      role: 'user',
      items: [userItem],
      tokenEstimate: estimateText(userText),
      createdAt: Date.now()
    });
    for (let round = 0; round < 3; round++) {
      const roundResult: ModelRoundResult = await this.sendRound(protocol, profile, nodes, systemPrompt,
        (delta: string) => {
          if (callbacks.onTextDelta !== undefined) {
            callbacks.onTextDelta(delta);
          }
        });
      if (!roundResult.ok) {
        return false;
      }
      if (roundResult.toolCalls.length === 0) {
        break;
      }
      const assistantItems: CanonicalItem[] = [];
      if (roundResult.text.length > 0) {
        assistantItems.push({ id: newNodeId(), kind: 'text', text: roundResult.text });
      }
      for (const call of roundResult.toolCalls) {
        assistantItems.push({
          id: newNodeId(),
          kind: 'tool_call',
          callId: call.callId,
          toolName: call.name,
          argumentsJson: call.argumentsJson
        });
      }
      const parentId: string = nodes[nodes.length - 1].nodeId;
      nodes.push({
        nodeId: newNodeId(),
        parentId,
        sessionId: 'creator',
        role: 'assistant',
        items: assistantItems,
        tokenEstimate: 0,
        createdAt: Date.now()
      });
      const resultItems: CanonicalItem[] = [];
      for (const call of roundResult.toolCalls) {
        const output: string = await this.executeMetaTool(call.name, call.argumentsJson, state, callbacks);
        resultItems.push({
          id: newNodeId(),
          kind: 'tool_result',
          callId: call.callId,
          toolName: call.name,
          text: output
        });
      }
      const toolParentId: string = nodes[nodes.length - 1].nodeId;
      nodes.push({
        nodeId: newNodeId(),
        parentId: toolParentId,
        sessionId: 'creator',
        role: 'tool',
        items: resultItems,
        tokenEstimate: 0,
        createdAt: Date.now()
      });
    }
    if (state.draftManifestJson !== undefined && state.draftManifestJson.length > 0) {
      this.finalizeDraft(state, callbacks);
      return true;
    }
    return false;
  }

  /** 发起一轮流式请求并把事件收敛为文本 + 工具调用。 */
  private sendRound(protocol: ProtocolLayer, profile: ModelProfile, nodes: ConversationNode[],
    systemPrompt: string, onTextDelta: (delta: string) => void): Promise<ModelRoundResult> {
    return new Promise<ModelRoundResult>((resolve: (value: ModelRoundResult) => void) => {
      const textParts: string[] = [];
      const calls: Map<string, ModelToolCall> = new Map<string, ModelToolCall>();
      let settled: boolean = false;
      const finish = (ok: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        const toolCalls: ModelToolCall[] = [];
        calls.forEach((value: ModelToolCall) => {
          toolCalls.push(value);
        });
        resolve({ ok, text: textParts.join(''), toolCalls });
      };
      const options: RequestOptions = {
        thinkingLevel: 'off',
        webMode: 'off',
        systemPrompt,
        toolSpecs: this.metaToolSpecs()
      };
      const callbacks: StreamCallbacks = {
        onEvent: (event: StreamEvent): void => {
          const payload: StreamPayload = event.payload;
          if (event.type === 'text_delta') {
            const delta: string = payload.delta === undefined ? '' : payload.delta;
            if (delta.length > 0) {
              textParts.push(delta);
              onTextDelta(delta);
            }
          } else if (event.type === 'tool_call_delta') {
            this.accumulateCall(calls, payload.callId === undefined ? '' : payload.callId,
              payload.toolName, payload.argumentsDelta, payload.phase);
          }
        },
        onError: (message: string, errorCode: string, retriable: boolean): void => {
          finish(false);
        },
        onDone: (): void => {
          finish(true);
        }
      };
      try {
        protocol.send(profile, nodes, options, callbacks);
      } catch (e) {
        finish(false);
      }
    });
  }

  /** 累加 tool_call 分片（同一 callId 的参数可能分多帧到达）。 */
  private accumulateCall(calls: Map<string, ModelToolCall>, callId: string,
    toolName: string | undefined, argumentsDelta: string | undefined, phase: string | undefined): void {
    if (callId.length === 0) {
      return;
    }
    let call: ModelToolCall | undefined = calls.get(callId);
    if (call === undefined) {
      call = { callId, name: '', argumentsJson: '' };
      calls.set(callId, call);
    }
    if (toolName !== undefined && toolName.length > 0) {
      call.name = toolName;
    }
    if (argumentsDelta !== undefined && argumentsDelta.length > 0) {
      call.argumentsJson = call.argumentsJson + argumentsDelta;
    }
  }

  /** 执行一个元工具（返回给模型看的文本结果）。 */
  private async executeMetaTool(name: string, argsJson: string, state: CreatorSessionState,
    callbacks: CreatorCallbacks): Promise<string> {
    let args: Record<string, Object> = emptyRecord();
    const parsed = parseRecord(argsJson);
    if (parsed !== null) {
      args = parsed;
    }
    if (name === 'list_installed_skills') {
      return this.describeInstalledSkills();
    }
    if (name === 'draft_skill_manifest') {
      const manifestJson: string = this.extractManifestJson(args);
      if (manifestJson.length === 0) {
        return '草稿参数里没有找到清单，请把完整技能清单放在 manifestJson（字符串）或 manifest（对象）字段里。';
      }
      const normalized = normalizeManifestJson(manifestJson);
      if (!normalized.ok) {
        return `草稿不合法：${normalized.error}。请修正后重新调用 draft_skill_manifest。`;
      }
      state.draftManifestJson = normalized.manifestJson;
      const previous: string = state.previousManifestJson === undefined ? '' : state.previousManifestJson;
      const summaryText: string = summarizeDiff(diffManifestJson(previous, normalized.manifestJson));
      // 注意：Diff 卡片在工具循环结束时统一推送一次，避免重复刷屏
      return `草稿已生成（${summaryText}）。必须由用户点击「应用生效」后才会保存，请不要自行落盘。`;
    }
    if (name === 'dry_run_skill') {
      let manifestJson: string = getString(args, 'manifestJson', '').trim();
      if (manifestJson.length === 0) {
        manifestJson = state.draftManifestJson === undefined ? '' : state.draftManifestJson;
      }
      if (manifestJson.length === 0) {
        return '还没有可试跑的草稿，请先调用 draft_skill_manifest。';
      }
      const sampleInput: string = getString(args, 'sampleInput', '');
      const report: DryRunReport = await this.deps.kernel.dryRun(manifestJson, sampleInput);
      state.dryRunReport = report;
      if (callbacks.onState !== undefined) {
        callbacks.onState(state);
      }
      if (report.passed) {
        return `试跑通过（耗时 ${report.latencyMs} 毫秒）：${truncateText(report.sampleOutput, 400)}`;
      }
      const errorText: string = report.error === undefined ? '未知原因' : report.error;
      return `试跑未通过：${errorText}`;
    }
    if (name === 'commit_skill_to_rdb') {
      return '保存动作只能由用户点击「应用生效」触发，元 Agent 不会自动落盘。请提示用户确认后再提交。';
    }
    if (name === 'distill_from_chat') {
      const chatText: string = getString(args, 'chatText', '');
      const base: string = state.previousManifestJson === undefined ? '' : state.previousManifestJson;
      const raw: HeuristicDraftResult = distillDraftRaw(chatText, base);
      if (!raw.ok) {
        return `沉淀失败：${raw.error}`;
      }
      state.draftManifestJson = raw.draftManifestJson;
      return `已从对话沉淀草稿：${raw.summary}`;
    }
    return `不认识的元工具：${name}。可用：${this.metaToolSpecs().map((one: ToolSpec) => one.name).join('、')}`;
  }

  /** 从元工具参数里取清单 JSON（兼容字符串/对象/直接给清单三种写法）。 */
  private extractManifestJson(args: Record<string, Object>): string {
    const direct: string = getString(args, 'manifestJson', '').trim();
    if (direct.length > 0) {
      return direct;
    }
    const nested = getObject(args, 'manifest');
    if (nested !== null) {
      return toJsonText(nested);
    }
    if (hasValue(args, 'id') && hasValue(args, 'runtimePayload')) {
      return toJsonText(args);
    }
    return '';
  }

  /** 生成待审批草稿并推给 UI（不改状态以外的任何东西）。 */
  private finalizeDraft(state: CreatorSessionState, callbacks: CreatorCallbacks): void {
    const draftJson: string = state.draftManifestJson === undefined ? '' : state.draftManifestJson;
    if (draftJson.length === 0) {
      return;
    }
    const previous: string = state.previousManifestJson === undefined ? '' : state.previousManifestJson;
    const diffText: string = diffManifestJson(previous, draftJson);
    const warnings: string[] = collectSecurityWarnings(draftJson);
    const draft: CreatorDraft = {
      draftManifestJson: draftJson,
      diffText,
      summary: summarizeDiff(diffText),
      securityWarnings: warnings
    };
    this.lastDraftValue = draft;
    if (callbacks.onTextDelta !== undefined) {
      callbacks.onTextDelta(`\n\n变更对比：\n${diffText}\n`);
    }
    if (callbacks.onState !== undefined) {
      callbacks.onState(state);
    }
  }

  /** 本地规则兜底生成草稿。 */
  private applyHeuristic(requirement: string, state: CreatorSessionState,
    callbacks: CreatorCallbacks): void {
    const baseJson: string = state.previousManifestJson === undefined ? '' : state.previousManifestJson;
    const raw: HeuristicDraftResult = heuristicDraftRaw(requirement, baseJson);
    if (!raw.ok) {
      this.reportError(callbacks, raw.error);
      return;
    }
    state.draftManifestJson = raw.draftManifestJson;
    const draft: CreatorDraft = {
      draftManifestJson: raw.draftManifestJson,
      diffText: raw.diffText,
      summary: raw.summary,
      securityWarnings: parseStringArray(raw.securityWarningsJson)
    };
    this.lastDraftValue = draft;
    if (callbacks.onTextDelta !== undefined) {
      callbacks.onTextDelta(`已根据你的描述生成草稿：${raw.summary}。\n\n变更对比：\n${raw.diffText}\n`);
    }
    if (callbacks.onState !== undefined) {
      callbacks.onState(state);
    }
  }

  /** 错误上报（优先 onError，其次文本）。 */
  private reportError(callbacks: CreatorCallbacks, message: string): void {
    if (callbacks.onError !== undefined) {
      callbacks.onError(message);
      return;
    }
    if (callbacks.onTextDelta !== undefined) {
      callbacks.onTextDelta(message);
    }
  }

  /** 已装技能清单（喂给元 Agent）。 */
  private describeInstalledSkills(): string {
    const summaries = this.deps.kernel.list();
    const lines: string[] = [];
    lines.push(`当前已装 ${summaries.length} 个技能：`);
    for (const one of summaries) {
      const domains: string = one.allowedDomains.length === 0 ? '不访问网络' : one.allowedDomains.join('、');
      lines.push(`- ${one.id}｜${one.name}｜${tierLabel(one.tier)}｜${one.enabled ? '已启用' : '已停用'}｜${domains}`);
    }
    return lines.join('\n');
  }

  /** 5 个元工具声明。 */
  private metaToolSpecs(): ToolSpec[] {
    const tools: ToolSpec[] = [];
    tools.push({
      name: 'list_installed_skills',
      description: '读取当前已安装技能清单与配置（id、名称、分级、启用状态、可访问域名）。改造技能前先调用它。',
      parametersJson: '{"type":"object","properties":{},"additionalProperties":false}'
    });
    tools.push({
      name: 'draft_skill_manifest',
      description: '生成或修改完整的技能清单。清单里 runtimePayload 必须显式给出 allowedDomains；密钥只能用 {{secret:别名}} 占位符。',
      parametersJson: '{"type":"object","properties":{"manifestJson":{"type":"string","description":"完整技能清单 JSON 字符串"}},"required":["manifestJson"]}'
    });
    tools.push({
      name: 'dry_run_skill',
      description: '用模拟输入在受控环境试跑草稿，返回耗时与结果。落盘前必须试跑。',
      parametersJson: '{"type":"object","properties":{"manifestJson":{"type":"string","description":"要试跑的清单 JSON，可省略表示当前草稿"},"sampleInput":{"type":"string","description":"模拟输入 JSON，可省略"}},"required":[]}'
    });
    tools.push({
      name: 'commit_skill_to_rdb',
      description: '仅在用户点击「应用生效」后由 UI 调用；元 Agent 调用它只会得到提示，不会真正落盘。',
      parametersJson: '{"type":"object","properties":{"manifestJson":{"type":"string","description":"待保存清单 JSON"}},"required":[]}'
    });
    tools.push({
      name: 'distill_from_chat',
      description: '从一段真实对话记录中反向提炼可复用的技能草稿。',
      parametersJson: '{"type":"object","properties":{"chatText":{"type":"string","description":"对话文本"}},"required":["chatText"]}'
    });
    return tools;
  }

  /** 元 Agent 的系统提示词（含清单 Schema 约束与 5 个元工具说明）。 */
  private buildSystemPrompt(state: CreatorSessionState): string {
    const lines: string[] = [];
    lines.push('你是手机应用「技能创造室」里的技能设计助手，面向不懂技术的普通用户。');
    lines.push('你的任务：把用户的一句话需求，变成一个可运行、可回滚的技能清单（SkillManifest JSON）。');
    lines.push('');
    lines.push('你可以调用 5 个元工具：');
    lines.push('1. list_installed_skills — 查看已装技能与配置；');
    lines.push('2. draft_skill_manifest({manifestJson}) — 产出最终草稿（必须调用且只调用一次作为最后一步）；');
    lines.push('3. dry_run_skill({manifestJson?, sampleInput?}) — 试跑草稿；');
    lines.push('4. commit_skill_to_rdb — 不允许你真正保存，保存只能由用户点击「应用生效」；');
    lines.push('5. distill_from_chat({chatText}) — 从对话沉淀技能。');
    lines.push('');
    lines.push('技能清单必须满足：');
    lines.push('- id：小写字母开头，只含小写字母/数字/下划线，2-48 位；version：形如 1.0.0；');
    lines.push('- tier：L1_DECLARATIVE（HTTP 模板）/ L2_REMOTE_MCP（MCP 地址）/ L3_QUICKJS_SANDBOX（脚本，当前不可运行）；');
    lines.push('- runtimePayload.allowedDomains 必须显式列出要访问的域名（默认拒绝，禁止通配符），请求地址必须 https；');
    lines.push('- configSchema 每项含 key/label/type/defaultValueJson（boolean/number/string/string_list/enum）；');
    lines.push('- toolSchemaJson 是 {name, description, parameters} 的 JSON 字符串；');
    lines.push('- 提示词片段 promptSnippet 要写清楚什么时候使用该技能；');
    lines.push('- 严禁写入明文密钥，只能用 {{secret:别名}} 占位符。');
    lines.push('- 联网检索类需求优先在现有技能「tech_doc_search」基础上改造（屏蔽站点改 blockedSites，输出格式改 outputFormat）。');
    lines.push('');
    lines.push(this.describeInstalledSkills());
    lines.push('');
    if (state.targetSkillId !== undefined && state.targetSkillId.length > 0) {
      lines.push(`当前正在改造技能：${state.targetSkillId}`);
      const previous: string = state.previousManifestJson === undefined ? '' : state.previousManifestJson;
      if (previous.length > 0) {
        lines.push(`旧版清单：${truncateText(previous, 3000)}`);
      }
    } else {
      lines.push('当前是新建技能（没有旧版清单）。');
    }
    lines.push('');
    lines.push('回答用户时用直白中文，先说明你准备改什么，再调用工具；不要输出代码块以外的工程术语。');
    return lines.join('\n');
  }
}
