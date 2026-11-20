/**
 * 角色（Persona）与技能三级继承的本地存储（v3 设计，chat 应用层，不改 packages/ 契约）。
 *
 * 三级技能继承：全局总开关（SkillRepository.enabled） ⊂ 角色默认绑定（本文件的 defaultSkills）
 *              ⊂ 当前对话临时开关（session overrides）。
 *
 * 持久化：全部走 core_model 的 SettingsApi（Preferences 后端，非敏感数据；密钥仍只进 Asset Store）。
 */
import { SettingsApi, SkillRepositoryApi } from '@app/core_model';
import { ThinkingLevel } from '@app/core_protocol';
import { SkillSummary } from '@app/core_plugin';

/** 角色配置（Cherry Studio 级）。 */
export interface PersonaProfile {
  id: string;
  name: string;
  /** 系统提示词（支持 {{date}} / {{clipboard}} 变量）。 */
  prompt: string;
  providerId: string;
  modelId: string;
  effortLevel: ThinkingLevel;
  temperature: number;
  topP: number;
  /** 上下文携带轮数上限。 */
  maxTurns: number;
  /** 角色默认绑定技能 id（三级继承中间层）。 */
  defaultSkills: string[];
  builtin: boolean;
  updatedAt: number;
}

/** 「本对话技能」芯片状态。 */
export interface SkillChipState {
  skillId: string;
  name: string;
  tier: string;
  /** 全局总开关。 */
  globalEnabled: boolean;
  /** 角色默认绑定。 */
  bound: boolean;
  /** 当前对话是否生效（三级继承结果）。 */
  active: boolean;
}

/** 设置键。 */
class PersonaKeys {
  static readonly LIST: string = 'persona.list.v3';
  static readonly DEFAULT_ID: string = 'persona.defaultId';
  static readonly SESSION_PREFIX: string = 'persona.session.';
  static readonly SKILL_OVERRIDE_PREFIX: string = 'skill.override.';
}

/** 角色存储。 */
export class PersonaStore {
  private repo: SettingsApi;
  private skills: SkillRepositoryApi;
  private personas: PersonaProfile[] = [];
  private defaultPersonaId: string = '';
  private inited: boolean = false;

  constructor(repo: SettingsApi, skills: SkillRepositoryApi) {
    this.repo = repo;
    this.skills = skills;
  }

  /** 加载或首次播种内置角色。 */
  async init(): Promise<void> {
    if (this.inited) {
      return;
    }
    const raw: string = await this.repo.getString(PersonaKeys.LIST, '');
    let list: PersonaProfile[] = [];
    if (raw.length > 0) {
      try {
        const parsed = JSON.parse(raw) as PersonaProfile[];
        if (Array.isArray(parsed)) {
          for (const one of parsed) {
            const safe = PersonaStore.sanitize(one);
            if (safe !== null) {
              list.push(safe);
            }
          }
        }
      } catch (e) {
        list = [];
      }
    }
    if (list.length === 0) {
      list = PersonaStore.seedPersonas();
      await this.persist(list, list[0].id);
    } else {
      this.personas = list;
      const storedDefault: string = await this.repo.getString(PersonaKeys.DEFAULT_ID, '');
      if (this.find(storedDefault) === null) {
        this.defaultPersonaId = this.personas[0].id;
        await this.repo.putString(PersonaKeys.DEFAULT_ID, this.defaultPersonaId);
      } else {
        this.defaultPersonaId = storedDefault;
      }
    }
    this.inited = true;
  }

  /** 全部角色（副本）。 */
  list(): PersonaProfile[] {
    const out: PersonaProfile[] = [];
    for (const one of this.personas) {
      out.push(PersonaStore.clone(one));
    }
    return out;
  }

  get(id: string): PersonaProfile | null {
    const found = this.find(id);
    return found === null ? null : PersonaStore.clone(found);
  }

  defaultId(): string {
    return this.defaultPersonaId;
  }

  defaultPersona(): PersonaProfile | null {
    return this.get(this.defaultPersonaId);
  }

  /** 设为新对话默认角色。 */
  async setDefault(id: string): Promise<void> {
    if (this.find(id) === null) {
      return;
    }
    this.defaultPersonaId = id;
    await this.repo.putString(PersonaKeys.DEFAULT_ID, id);
  }

  /** 新建空白草稿（未落盘）。 */
  newDraft(): PersonaProfile {
    const now: number = Date.now();
    return {
      id: `p_${now.toString(36)}_${Math.floor(Math.random() * 1000).toString(36)}`,
      name: '新角色',
      prompt: '',
      providerId: 'deepseek',
      modelId: 'deepseek-flash',
      effortLevel: 'med',
      temperature: 0.7,
      topP: 0.95,
      maxTurns: 20,
      defaultSkills: [],
      builtin: false,
      updatedAt: now
    };
  }

  /** 保存（新增或更新）并落盘。 */
  async save(persona: PersonaProfile): Promise<void> {
    const safe = PersonaStore.sanitize(persona);
    if (safe === null) {
      throw new Error('角色配置不完整，保存失败');
    }
    safe.updatedAt = Date.now();
    const idx = this.indexOf(safe.id);
    if (idx >= 0) {
      this.personas[idx] = safe;
    } else {
      this.personas.push(safe);
    }
    await this.repo.putString(PersonaKeys.LIST, JSON.stringify(this.personas));
  }

  /** 复制角色。 */
  async duplicate(id: string): Promise<PersonaProfile | null> {
    const src = this.find(id);
    if (src === null) {
      return null;
    }
    const copy = PersonaStore.clone(src);
    copy.id = `p_${Date.now().toString(36)}_${Math.floor(Math.random() * 1000).toString(36)}`;
    copy.name = `${src.name} 副本`;
    copy.builtin = false;
    copy.updatedAt = Date.now();
    this.personas.push(copy);
    await this.repo.putString(PersonaKeys.LIST, JSON.stringify(this.personas));
    return PersonaStore.clone(copy);
  }

  /** 删除角色（至少保留一个；删除默认角色时自动改选第一个）。 */
  async remove(id: string): Promise<boolean> {
    if (this.personas.length <= 1) {
      return false;
    }
    const idx = this.indexOf(id);
    if (idx < 0) {
      return false;
    }
    this.personas.splice(idx, 1);
    if (this.defaultPersonaId === id) {
      this.defaultPersonaId = this.personas[0].id;
      await this.repo.putString(PersonaKeys.DEFAULT_ID, this.defaultPersonaId);
    }
    await this.repo.putString(PersonaKeys.LIST, JSON.stringify(this.personas));
    return true;
  }

  // ---- 会话级绑定 ---------------------------------------------------------

  /** 会话当前角色 id（缺省用全局默认角色）。 */
  async sessionPersonaId(sessionId: string): Promise<string> {
    const raw: string = await this.repo.getString(`${PersonaKeys.SESSION_PREFIX}${sessionId}`, '');
    if (raw.length > 0 && this.find(raw) !== null) {
      return raw;
    }
    return this.defaultPersonaId;
  }

  /** 会话当前角色配置。 */
  async personaForSession(sessionId: string): Promise<PersonaProfile | null> {
    const id: string = await this.sessionPersonaId(sessionId);
    return this.get(id);
  }

  /** 切换会话角色（会清空该会话的技能临时覆盖，回到角色默认绑定）。 */
  async setSessionPersona(sessionId: string, personaId: string): Promise<void> {
    if (this.find(personaId) === null) {
      return;
    }
    await this.repo.putString(`${PersonaKeys.SESSION_PREFIX}${sessionId}`, personaId);
    await this.repo.putString(`${PersonaKeys.SKILL_OVERRIDE_PREFIX}${sessionId}`, '{}');
  }

  // ---- 技能三级继承 -------------------------------------------------------

  private async overrides(sessionId: string): Promise<Record<string, boolean>> {
    const raw: string = await this.repo.getString(`${PersonaKeys.SKILL_OVERRIDE_PREFIX}${sessionId}`, '{}');
    try {
      const rec = JSON.parse(raw) as Record<string, boolean>;
      return rec === null ? JSON.parse('{}') as Record<string, boolean> : rec;
    } catch (e) {
      return JSON.parse('{}') as Record<string, boolean>;
    }
  }

  /** 计算当前会话的技能芯片状态（全局开关 ⊂ 角色绑定 ⊂ 会话临时覆盖）。 */
  async effectiveSkills(sessionId: string, summaries: SkillSummary[]): Promise<SkillChipState[]> {
    const persona = await this.personaForSession(sessionId);
    const bound: string[] = persona === null ? [] : persona.defaultSkills;
    const override = await this.overrides(sessionId);
    const out: SkillChipState[] = [];
    for (const sk of summaries) {
      const isBound: boolean = bound.indexOf(sk.id) >= 0;
      const raw = override[sk.id];
      const overridden: boolean = raw !== undefined;
      const active: boolean = sk.enabled && (overridden ? raw === true : isBound);
      out.push({
        skillId: sk.id,
        name: sk.name,
        tier: sk.tier,
        globalEnabled: sk.enabled,
        bound: isBound,
        active: active
      });
    }
    return out;
  }

  /** 当前会话切换技能临时开关，返回切换后的生效状态。 */
  async toggleSessionSkill(sessionId: string, skillId: string, currentlyActive: boolean): Promise<boolean> {
    const rec = await this.overrides(sessionId);
    const next: boolean = !currentlyActive;
    rec[skillId] = next;
    await this.repo.putString(`${PersonaKeys.SKILL_OVERRIDE_PREFIX}${sessionId}`, JSON.stringify(rec));
    return next;
  }

  // ---- 私有 ---------------------------------------------------------------

  private find(id: string): PersonaProfile | null {
    for (const one of this.personas) {
      if (one.id === id) {
        return one;
      }
    }
    return null;
  }

  private indexOf(id: string): number {
    for (let i = 0; i < this.personas.length; i++) {
      if (this.personas[i].id === id) {
        return i;
      }
    }
    return -1;
  }

  private async persist(list: PersonaProfile[], defaultId: string): Promise<void> {
    this.personas = list;
    this.defaultPersonaId = defaultId;
    await this.repo.putString(PersonaKeys.LIST, JSON.stringify(list));
    await this.repo.putString(PersonaKeys.DEFAULT_ID, defaultId);
  }

  private static clone(src: PersonaProfile): PersonaProfile {
    const out: PersonaProfile = {
      id: src.id,
      name: src.name,
      prompt: src.prompt,
      providerId: src.providerId,
      modelId: src.modelId,
      effortLevel: src.effortLevel,
      temperature: src.temperature,
      topP: src.topP,
      maxTurns: src.maxTurns,
      defaultSkills: [],
      builtin: src.builtin,
      updatedAt: src.updatedAt
    };
    for (const sid of src.defaultSkills) {
      out.defaultSkills.push(sid);
    }
    return out;
  }

  private static sanitize(src: PersonaProfile): PersonaProfile | null {
    if (src === undefined || src === null || src.id === undefined || src.id.length === 0) {
      return null;
    }
    const out: PersonaProfile = {
      id: src.id,
      name: src.name === undefined || src.name.length === 0 ? '未命名角色' : src.name,
      prompt: src.prompt === undefined ? '' : src.prompt,
      providerId: src.providerId === undefined || src.providerId.length === 0 ? 'deepseek' : src.providerId,
      modelId: src.modelId === undefined || src.modelId.length === 0 ? 'deepseek-flash' : src.modelId,
      effortLevel: src.effortLevel === undefined ? 'med' : src.effortLevel,
      temperature: src.temperature === undefined ? 0.7 : Math.min(2, Math.max(0, src.temperature)),
      topP: src.topP === undefined ? 0.95 : Math.min(1, Math.max(0.1, src.topP)),
      maxTurns: src.maxTurns === undefined ? 20 : Math.min(50, Math.max(4, src.maxTurns)),
      defaultSkills: [],
      builtin: src.builtin === true,
      updatedAt: src.updatedAt === undefined ? Date.now() : src.updatedAt
    };
    if (Array.isArray(src.defaultSkills)) {
      for (const sid of src.defaultSkills) {
        if (typeof sid === 'string') {
          out.defaultSkills.push(sid);
        }
      }
    }
    return out;
  }

  /** 内置三角色（对齐 v3 设计稿）。 */
  private static seedPersonas(): PersonaProfile[] {
    const now: number = Date.now();
    const p1: PersonaProfile = {
      id: 'p_default',
      name: '默认助手',
      prompt: '简洁、直接、中文回答，避免冗余客套。',
      providerId: 'deepseek',
      modelId: 'deepseek-flash',
      effortLevel: 'med',
      temperature: 0.7,
      topP: 0.95,
      maxTurns: 20,
      defaultSkills: ['tech_doc_search'],
      builtin: true,
      updatedAt: now
    };
    const p2: PersonaProfile = {
      id: 'p_arch',
      name: '系统架构师',
      prompt: '以资深终端系统工程师视角分析架构取舍、性能瓶颈与落地方案。当前日期：{{date}}。',
      providerId: 'deepseek',
      modelId: 'deepseek-v4-pro',
      effortLevel: 'high',
      temperature: 0.3,
      topP: 0.9,
      maxTurns: 30,
      defaultSkills: ['tech_doc_search', 'web_article_extract'],
      builtin: true,
      updatedAt: now
    };
    const p3: PersonaProfile = {
      id: 'p_paper',
      name: '技术精读',
      prompt: '提炼论文与文档的核心贡献、量化指标与局限性，并保留原始出处。',
      providerId: 'anthropic',
      modelId: 'claude-sonnet-4-5',
      effortLevel: 'high',
      temperature: 0.2,
      topP: 0.9,
      maxTurns: 16,
      defaultSkills: ['tech_doc_search'],
      builtin: true,
      updatedAt: now
    };
    return [p1, p2, p3];
  }
}
