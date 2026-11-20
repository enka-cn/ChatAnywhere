/**
 * 设置控制器：当前模型 / 思考档位 / 联网模式 / 会话角色 / 压缩策略 / 密钥状态。
 *
 * v3 路由：
 * - 角色来源是 `AppServices.requirePersonas().personaForSession(sessionId)`（PersonaStore）；
 *   角色 prompt 优先，为空回退 core_context 的通用基座；
 * - 采样参数（temperature / topP / maxTurns）与模型 / 思考档位都由角色提供，
 *   新会话创建时继承「全局默认角色」的模型与思考档位（写入设置 + 快照）；
 * - PersonaStore 不可用时降级回旧的「SettingsKeys 角色 id + core_context 内置角色」路径。
 */
import { SecretAliases, SettingsKeys } from '@app/core_model';
import { DEFAULT_PERSONA_ID } from '@app/core_context';
import { ModelProfile, ThinkingLevel, WebMode } from '@app/core_protocol';
import { PersonaProfile, SkillChipState } from '../../app/PersonaStore';
import { RuntimeHost } from './RuntimeTypes';

/** 无角色时的采样默认值（与 PersonaStore 内置角色一致）。 */
const DEFAULT_TEMPERATURE: number = 0.7;
const DEFAULT_TOP_P: number = 0.95;
const DEFAULT_MAX_TURNS: number = 20;

/** 无可用模型时的统一直白中文引导（v3.2 模型目录去占位后首次使用可能没有任何模型）。 */
const NO_MODEL_HINT: string = '还没有可用的真实模型，请到「设置 → 模型与密钥」填写密钥并拉取模型';

export class SettingsController {
  private host: RuntimeHost;
  private profileValue: ModelProfile | null = null;
  private thinkingLevelValue: ThinkingLevel = 'med';
  private webModeValue: WebMode = 'off';
  private compactionPolicyValue: string = 'auto';
  /** 旧路径（PersonaStore 降级）的 settings 角色 id / prompt。 */
  private legacyPersonaId: string = '';
  private personaPromptValue: string = '';
  /** 当前会话角色（PersonaStore；null 表示降级或未加载）。 */
  private personaValue: PersonaProfile | null = null;

  constructor(host: RuntimeHost) {
    this.host = host;
  }

  profile(): ModelProfile | null {
    return this.profileValue;
  }

  thinkingLevel(): ThinkingLevel {
    return this.thinkingLevelValue;
  }

  webMode(): WebMode {
    return this.webModeValue;
  }

  /** 本轮角色提示词（角色 prompt 优先，空则回退通用基座）。 */
  personaPrompt(): string {
    return this.personaPromptValue;
  }

  personaModel(): string {
    return this.personaValue === null ? '' : this.personaValue.modelId;
  }

  personaEffort(): ThinkingLevel {
    return this.personaValue === null ? this.thinkingLevelValue : this.personaValue.effortLevel;
  }

  personaTemperature(): number {
    return this.personaValue === null ? DEFAULT_TEMPERATURE : this.personaValue.temperature;
  }

  personaTopP(): number {
    return this.personaValue === null ? DEFAULT_TOP_P : this.personaValue.topP;
  }

  personaMaxTurns(): number {
    return this.personaValue === null ? DEFAULT_MAX_TURNS : this.personaValue.maxTurns;
  }

  compactionPolicy(): string {
    return this.compactionPolicyValue;
  }

  // -------------------------------------------------------------------------
  // 角色状态（PersonaStore）
  // -------------------------------------------------------------------------

  /**
   * 刷新当前会话的角色名、角色 prompt 与技能芯片（三级继承结果）。
   * 调用时机：初始化 / 新建或切换会话 / 设置页返回 / 切换角色或技能。
   */
  async refreshPersonaState(): Promise<void> {
    const services = this.host.appServices();
    const snapshot = this.host.snapshot();
    const sessionId: string = this.host.sessionId();
    if (!services.hasPersonas()) {
      this.personaValue = null;
      snapshot.personaName = '';
      snapshot.skillChips = [];
      return;
    }
    try {
      const persona: PersonaProfile | null = await services.requirePersonas().personaForSession(sessionId);
      this.personaValue = persona;
      this.personaPromptValue = this.promptForPersona(persona);
      snapshot.personaName = persona === null ? '' : persona.name;
      if (services.hasPlugin() && sessionId.length > 0) {
        snapshot.skillChips = await services.requirePersonas().effectiveSkills(sessionId,
          services.requirePlugin().kernel.list());
      } else {
        snapshot.skillChips = [];
      }
    } catch (e) {
      snapshot.personaName = '';
      snapshot.skillChips = [];
    }
  }

  /**
   * 新会话继承全局默认角色的模型与思考档位（写入设置 + 快照）。
   * 无角色存储 / 角色模型不可用时保持当前值，绝不阻断新建会话。
   */
  async applyPersonaDefaultsForNewSession(): Promise<void> {
    const services = this.host.appServices();
    if (!services.hasPersonas()) {
      return;
    }
    let persona: PersonaProfile | null = null;
    try {
      persona = await services.requirePersonas().personaForSession(this.host.sessionId());
    } catch (e) {
      persona = null;
    }
    if (persona === null) {
      return;
    }
    this.personaValue = persona;
    this.personaPromptValue = this.promptForPersona(persona);
    this.host.snapshot().personaName = persona.name;
    await this.applyPersonaModel(persona);
    await this.applyPersonaEffort(persona);
  }

  private async applyPersonaModel(persona: PersonaProfile): Promise<void> {
    try {
      const services = this.host.appServices();
      const catalog = services.requireProtocol().catalog;
      const snapshot = this.host.snapshot();
      // v3.2 角色模型兼容：
      // - modelId 非空且命中 → 套用角色指定模型；
      // - modelId 为空（=跟随当前模型）→ 当前模型仍有效则保持，否则回退目录默认模型；
      // - modelId 非空但已不在目录里（旧配置/模型被移除）→ 回退目录默认模型；
      // - 目录里一个真实模型都没有 → 保持当前并 hasModel=false，交给 UI 引导去设置。
      let profile: ModelProfile | null = null;
      if (persona.modelId.length > 0) {
        profile = catalog.findByModelId(persona.modelId);
        if (profile === null) {
          profile = catalog.defaultProfile();
        }
      } else {
        const current: ModelProfile | null = this.profileValue;
        if (current !== null) {
          profile = catalog.findByModelId(current.modelId);
        }
        if (profile === null) {
          profile = catalog.defaultProfile();
        }
      }
      if (profile === null) {
        snapshot.hasModel = false;
        return;
      }
      await services.setActiveProfile(profile.providerId, profile.modelId);
      this.profileValue = profile;
      snapshot.modelId = profile.modelId;
      snapshot.providerId = profile.providerId;
      snapshot.modelLabel = profile.label;
      snapshot.contextWindow = profile.contextWindow;
      snapshot.hasApiKey = await this.checkHasApiKey(profile);
      snapshot.hasModel = true;
    } catch (e) {
      // 模型目录不可用时保持当前模型（不阻断新建会话）
      this.host.snapshot().hasModel = this.host.appServices().hasModels();
    }
  }

  private async applyPersonaEffort(persona: PersonaProfile): Promise<void> {
    try {
      await this.host.appServices().requireModel().repo.putString(SettingsKeys.THINKING_LEVEL, persona.effortLevel);
      this.thinkingLevelValue = persona.effortLevel;
      this.host.snapshot().thinkingLevel = persona.effortLevel;
    } catch (e) {
      // 写入失败时保持当前档位
    }
  }

  /** 角色 prompt 优先；空则回退 core_context 的通用基座。 */
  private promptForPersona(persona: PersonaProfile | null): string {
    if (persona !== null && persona.prompt.trim().length > 0) {
      return persona.prompt;
    }
    try {
      const preset = this.host.appServices().requireContextLayer().prompts.persona(DEFAULT_PERSONA_ID);
      if (preset !== null && preset.prompt.trim().length > 0) {
        return preset.prompt;
      }
    } catch (e) {
      // 提示词模块异常时按「无角色提示词」处理
    }
    return '';
  }

  // -------------------------------------------------------------------------
  // 全局设置
  // -------------------------------------------------------------------------

  /** 重新读取当前模型 / 思考 / 联网 / 角色(降级路径) / 压缩策略 / 密钥状态。 */
  async reloadSettings(): Promise<void> {
    const services = this.host.appServices();
    const repo = services.requireModel().repo;
    // v3.2：模型目录去占位后可能一个真实模型都没有；这里绝不抛错，交给 hasModel/引导处理。
    let profile: ModelProfile | null = null;
    try {
      profile = await services.resolveActiveProfile();
    } catch (e) {
      profile = null;
    }
    this.profileValue = profile;
    this.thinkingLevelValue = await services.currentThinkingLevel();
    this.webModeValue = await services.currentWebMode();
    if (!services.hasPersonas()) {
      // 降级路径：仍读旧的 settings 角色（PersonaStore 就绪时由 refreshPersonaState 接管）。
      this.legacyPersonaId = await services.currentPersonaId();
      this.personaPromptValue = await services.currentPersonaPrompt();
      // 其它页面可能只写了角色 id：这里补一次「按 id 取内置角色提示词」，避免角色选了却不生效。
      if (this.personaPromptValue.trim().length === 0 && this.legacyPersonaId.length > 0) {
        try {
          const preset = services.requireContextLayer().prompts.persona(this.legacyPersonaId);
          if (preset !== null) {
            this.personaPromptValue = preset.prompt;
          }
        } catch (e) {
          this.personaPromptValue = '';
        }
      }
    }
    this.compactionPolicyValue = await repo.getString(SettingsKeys.COMPACTION_POLICY, 'auto');
    const snapshot = this.host.snapshot();
    snapshot.hasModel = services.hasModels();
    if (profile !== null) {
      snapshot.modelId = profile.modelId;
      snapshot.providerId = profile.providerId;
      snapshot.modelLabel = profile.label;
      snapshot.contextWindow = profile.contextWindow;
      snapshot.hasApiKey = await this.checkHasApiKey(profile);
    } else {
      // 无模型：清空模型展示（顶栏显示「模型」占位），保留可用 Key 状态供引导判断。
      snapshot.modelId = '';
      snapshot.providerId = '';
      snapshot.modelLabel = '';
      snapshot.hasApiKey = await this.hasAnyApiKey();
    }
    snapshot.thinkingLevel = this.thinkingLevelValue;
    snapshot.webMode = this.webModeValue;
  }

  /** 当前模型配置（未加载时补加载；无真实模型时返回 null 并给出中文引导，绝不抛错）。 */
  async ensureProfile(): Promise<ModelProfile | null> {
    const services = this.host.appServices();
    if (!services.hasModels()) {
      this.profileValue = null;
      const snapshot = this.host.snapshot();
      snapshot.hasModel = false;
      snapshot.errorMessage = NO_MODEL_HINT;
      this.host.notifyNow();
      return null;
    }
    if (this.profileValue !== null) {
      return this.profileValue;
    }
    try {
      const profile: ModelProfile = await services.resolveActiveProfile();
      this.profileValue = profile;
      const snapshot = this.host.snapshot();
      snapshot.modelId = profile.modelId;
      snapshot.providerId = profile.providerId;
      snapshot.modelLabel = profile.label;
      snapshot.contextWindow = profile.contextWindow;
      snapshot.hasModel = true;
      return profile;
    } catch (e) {
      this.profileValue = null;
      const snapshot = this.host.snapshot();
      snapshot.hasModel = false;
      snapshot.errorMessage = NO_MODEL_HINT;
      this.host.notifyNow();
      return null;
    }
  }

  /** 是否有任意可用密钥（无模型时也用于「无 Key 优先提示」判断）。 */
  async hasAnyApiKey(): Promise<boolean> {
    try {
      const secrets = this.host.appServices().requireModel().secrets;
      if (await secrets.has(SecretAliases.DEEPSEEK)) {
        return true;
      }
      if (await secrets.has(SecretAliases.OPENAI_COMPAT)) {
        return true;
      }
      if (await secrets.has(SecretAliases.ANTHROPIC)) {
        return true;
      }
      return false;
    } catch (e) {
      return true;
    }
  }

  /** 是否有可用密钥（Asset Store Kit 读失败时按「有」处理，避免误报）。 */
  async checkHasApiKey(profile: ModelProfile): Promise<boolean> {
    try {
      const secrets = this.host.appServices().requireModel().secrets;
      if (await secrets.has(profile.assetKeyAlias)) {
        return true;
      }
    } catch (e) {
      return true;
    }
    return this.hasAnyApiKey();
  }

  // -------------------------------------------------------------------------
  // 用户设置（落盘 + 刷新快照）
  // -------------------------------------------------------------------------

  async setModel(providerId: string, modelId: string): Promise<void> {
    try {
      const services = this.host.appServices();
      const catalog = services.requireProtocol().catalog;
      // v3.2：先校验模型真实存在，找不到时不写设置（避免把 ACTIVE_MODEL 写坏）。
      let profile: ModelProfile | null = catalog.get(providerId, modelId);
      if (profile === null) {
        profile = catalog.findByModelId(modelId);
      }
      if (profile === null) {
        this.host.snapshot().noticeMessage = '这个模型暂时不可用，请刷新「设置 → 模型与密钥」的模型列表后重试';
        this.host.notifyNow();
        return;
      }
      await services.setActiveProfile(profile.providerId, profile.modelId);
      this.profileValue = profile;
      const snapshot = this.host.snapshot();
      snapshot.modelId = profile.modelId;
      snapshot.providerId = profile.providerId;
      snapshot.modelLabel = profile.label;
      snapshot.contextWindow = profile.contextWindow;
      snapshot.hasApiKey = await this.checkHasApiKey(profile);
      snapshot.hasModel = true;
      snapshot.noticeMessage = `已切换到「${profile.label}」`;
      this.host.recomputeMetrics();
      this.host.notifyNow();
    } catch (e) {
      this.host.snapshot().errorMessage = `切换模型失败：${(e as Error).message}`;
      this.host.notifyNow();
    }
  }

  async setThinkingLevel(level: ThinkingLevel): Promise<void> {
    try {
      await this.host.appServices().requireModel().repo.putString(SettingsKeys.THINKING_LEVEL, level);
      this.thinkingLevelValue = level;
      this.host.snapshot().thinkingLevel = level;
      this.host.notifyNow();
    } catch (e) {
      this.host.snapshot().errorMessage = `切换思考档位失败：${(e as Error).message}`;
      this.host.notifyNow();
    }
  }

  async setWebMode(mode: WebMode): Promise<void> {
    try {
      await this.host.appServices().requireModel().repo.putString(SettingsKeys.WEB_MODE, mode);
      this.webModeValue = mode;
      this.host.snapshot().webMode = mode;
      this.host.notifyNow();
    } catch (e) {
      this.host.snapshot().errorMessage = `切换联网模式失败：${(e as Error).message}`;
      this.host.notifyNow();
    }
  }

  /** 切换当前会话角色：写 PersonaStore（会清掉该会话技能临时覆盖）并刷新芯片。 */
  async setPersona(personaId: string): Promise<void> {
    const services = this.host.appServices();
    const sessionId: string = this.host.sessionId();
    if (services.hasPersonas() && sessionId.length > 0) {
      try {
        await services.requirePersonas().setSessionPersona(sessionId, personaId);
        await this.refreshPersonaState();
        this.host.snapshot().noticeMessage = '已切换角色，下一轮回答就会按新角色来';
        this.host.notifyNow();
      } catch (e) {
        this.host.snapshot().errorMessage = `切换角色失败：${(e as Error).message}`;
        this.host.notifyNow();
      }
      return;
    }
    await this.setLegacyPersona(personaId);
  }

  /** 降级路径：写 SettingsKeys 角色 id / 内置角色提示词。 */
  private async setLegacyPersona(personaId: string): Promise<void> {
    try {
      const repo = this.host.appServices().requireModel().repo;
      await repo.putString(SettingsKeys.PERSONA_ID, personaId);
      this.legacyPersonaId = personaId;
      let prompt: string = '';
      try {
        const preset = this.host.appServices().requireContextLayer().prompts.persona(personaId);
        if (preset !== null) {
          prompt = preset.prompt;
        }
      } catch (e) {
        prompt = '';
      }
      if (prompt.length > 0) {
        await repo.putString(SettingsKeys.PERSONA_PROMPT, prompt);
      } else {
        await repo.remove(SettingsKeys.PERSONA_PROMPT);
      }
      this.personaPromptValue = prompt;
      this.host.snapshot().noticeMessage = '已切换角色提示词，下一轮回答就会按新角色来';
      this.host.notifyNow();
    } catch (e) {
      this.host.snapshot().errorMessage = `切换角色失败：${(e as Error).message}`;
      this.host.notifyNow();
    }
  }

  /** 切换当前会话的技能临时开关（三级继承最内层），并刷新芯片。 */
  async toggleSessionSkill(skillId: string): Promise<void> {
    const services = this.host.appServices();
    const sessionId: string = this.host.sessionId();
    if (!services.hasPersonas() || sessionId.length === 0) {
      return;
    }
    let current: SkillChipState | null = null;
    for (const chip of this.host.snapshot().skillChips) {
      if (chip.skillId === skillId) {
        current = chip;
        break;
      }
    }
    if (current === null) {
      return;
    }
    try {
      await services.requirePersonas().toggleSessionSkill(sessionId, skillId, current.active);
      await this.refreshPersonaState();
      this.host.notifyNow();
    } catch (e) {
      this.host.snapshot().errorMessage = `切换技能失败：${(e as Error).message}`;
      this.host.notifyNow();
    }
  }

  /** 全局技能总开关（三级继承最外层）；切换后芯片需同步刷新。 */
  async setSkillEnabled(skillId: string, enabled: boolean): Promise<void> {
    const services = this.host.appServices();
    if (!services.hasPlugin()) {
      this.host.snapshot().noticeMessage = '技能模块暂不可用，这次没法切换技能';
      this.host.notifyNow();
      return;
    }
    try {
      await services.requirePlugin().kernel.setEnabled(skillId, enabled);
      this.host.snapshot().noticeMessage = enabled ? '技能已打开，下一轮就会带上它' : '技能已关闭';
      await this.refreshPersonaState();
    } catch (e) {
      this.host.snapshot().errorMessage = `切换技能失败：${(e as Error).message}`;
    }
    this.host.notifyNow();
  }
}
