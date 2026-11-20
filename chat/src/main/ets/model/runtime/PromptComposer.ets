/**
 * 四层提示词装配（角色 / 技能 / 记忆 / 检索）、采样参数与工具声明收集。
 *
 * v3 要点：
 * - 角色提示词优先（PersonaStore 的 persona.prompt），为空回退 context 的通用基座；
 * - 技能只注入「当前会话生效」的（全局开关 ⊂ 角色绑定 ⊂ 会话临时覆盖），全局停用不得注入；
 * - RequestOptions 带角色的 temperature / topP（6 档思考由 thinkingLevel 负责）；
 * - 历史轮数裁剪（maxTurns）由 StreamTurnExecutor 调用 personaMaxTurns 完成。
 */
import { PromptAssemblyInput, PromptAssemblyResult, PromptSkillSnippet } from '@app/core_context';
import { ModelProfile, RequestOptions, ToolSpec, WebToolOption } from '@app/core_protocol';
import { SkillPromptSnippet, ToolDefinition } from '@app/core_plugin';
import { RuntimeHost } from './RuntimeTypes';

export class PromptComposer {
  private host: RuntimeHost;
  /** 本会话生效的技能 id（null = 不过滤：角色/技能模块降级时保持旧行为）。 */
  private activeSkillIds: string[] | null = null;

  constructor(host: RuntimeHost) {
    this.host = host;
  }

  /** 每轮开始前刷新一次「本会话生效技能」，供同步装配路径过滤（避免把 async 扩散到热路径）。 */
  async refreshActiveSkills(): Promise<void> {
    this.activeSkillIds = null;
    const services = this.host.appServices();
    const sessionId: string = this.host.sessionId();
    if (!services.hasPersonas() || !services.hasPlugin() || sessionId.length === 0) {
      return;
    }
    try {
      const chips = await services.requirePersonas().effectiveSkills(sessionId,
        services.requirePlugin().kernel.list());
      const ids: string[] = [];
      for (const chip of chips) {
        if (chip.active) {
          ids.push(chip.skillId);
        }
      }
      this.activeSkillIds = ids;
    } catch (e) {
      this.activeSkillIds = null;
    }
  }

  /** 该技能是否在当前会话生效（降级模式下不过滤）。 */
  private isSkillActive(skillId: string): boolean {
    if (this.activeSkillIds === null) {
      return true;
    }
    return this.activeSkillIds.indexOf(skillId) >= 0;
  }

  /** 组装本轮请求选项（思考档位 / 联网 / 采样参数 / 工具声明）。 */
  buildRequestOptions(systemPrompt: string): RequestOptions {
    const options: RequestOptions = {
      thinkingLevel: this.host.thinkingLevel(),
      webMode: this.host.webMode(),
      systemPrompt: systemPrompt,
      temperature: this.host.personaTemperature(),
      topP: this.host.personaTopP()
    };
    const specs: ToolSpec[] = this.collectToolSpecs();
    if (specs.length > 0) {
      options.toolSpecs = specs;
    }
    const webTool: WebToolOption = { mode: this.host.webMode() };
    options.webTool = webTool;
    return options;
  }

  /** 本轮可用工具声明（插件不可用或该技能本会话未生效时不注入）。 */
  collectToolSpecs(): ToolSpec[] {
    const out: ToolSpec[] = [];
    const services = this.host.appServices();
    if (!services.hasPlugin()) {
      return out;
    }
    try {
      const defs: ToolDefinition[] = services.requirePlugin().kernel.toolDefinitions();
      for (const one of defs) {
        if (!this.isSkillActive(one.skillId)) {
          continue;
        }
        const spec: ToolSpec = {
          name: one.name,
          description: one.description,
          parametersJson: one.parametersJson,
          skillId: one.skillId
        };
        out.push(spec);
      }
    } catch (e) {
      // 工具定义读失败时按「没有工具」处理
    }
    return out;
  }

  /** 组装本轮 system prompt（memoryBlocks 为独立联网清洗产出的检索层）。 */
  assembleSystemPrompt(profile: ModelProfile, memoryBlocks: string[]): PromptAssemblyResult {
    const ctx = this.host.appServices().requireContextLayer();
    const input: PromptAssemblyInput = {
      personaPrompt: this.host.personaPrompt(),
      skillSnippets: this.collectSkillSnippets(),
      memorySummary: this.host.memorySummary(),
      retrievedMemories: memoryBlocks,
      modelLabel: profile.label,
      webEnabled: this.host.webMode() !== 'off',
      deepThinking: this.host.thinkingLevel() !== 'off'
    };
    return ctx.prompts.assemble(input);
  }

  /** 本会话生效技能给提示词层的片段（插件不可用时为空）。 */
  private collectSkillSnippets(): PromptSkillSnippet[] {
    const out: PromptSkillSnippet[] = [];
    const services = this.host.appServices();
    if (!services.hasPlugin()) {
      return out;
    }
    try {
      const snippets: SkillPromptSnippet[] = services.requirePlugin().kernel.promptSnippets();
      for (const one of snippets) {
        if (!this.isSkillActive(one.skillId)) {
          continue;
        }
        const snippet: PromptSkillSnippet = {
          skillId: one.skillId,
          name: one.name,
          snippet: one.snippet
        };
        out.push(snippet);
      }
    } catch (e) {
      // 技能片段读失败时按「没有技能」处理
    }
    return out;
  }
}
