/**
 * 应用级服务装配点（Lead 独占维护）。
 *
 * 页面通过 `AppServices.get()` 获取单例，禁止在页面内直接 new 服务或直连 RDB。
 * 初始化顺序：数据层 → 协议层 → 上下文层 → 插件层，任一步失败都记录中文原因，
 * 由首页以「提示条」形式告诉用户，绝不让应用白屏崩溃。
 */
import { common } from '@kit.AbilityKit';
import {
  ModelLayer,
  ModelLayerOptions,
  SecretAliases,
  SettingsKeys,
  createModelLayer
} from '@app/core_model';
import {
  ModelCatalogApi,
  ModelProfile,
  ProtocolLayer,
  ThinkingLevel,
  WebMode,
  createProtocolLayer
} from '@app/core_protocol';
import { ContextLayer, PersonaPreset, createContextLayer } from '@app/core_context';
import { PluginLayer, createPluginLayer } from '@app/core_plugin';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PersonaStore } from './PersonaStore';
import { EffortLevels } from './EffortLevels';

const DOMAIN: number = 0x1A2B;
const TAG: string = 'ChatAnyWhere';

/** 应用服务单例。 */
export class AppServices {
  private static shared: AppServices | null = null;

  private abilityContext: common.UIAbilityContext | null = null;
  private initPromise: Promise<void> | null = null;

  /** 数据层（会话 / 轨迹 / 检索 / 技能存储 / 设置 / 密钥 / 导入导出）。 */
  model: ModelLayer | null = null;
  /** 协议层（模型目录 / 流式对话 / 标题生成 / 连接测试）。 */
  protocol: ProtocolLayer | null = null;
  /** 上下文层（缓存感知压缩 / 提示词装配 / 角色）。 */
  context: ContextLayer | null = null;
  /** 插件层（技能内核 / 联网清洗 / 技能创造室）。 */
  plugin: PluginLayer | null = null;

  ready: boolean = false;
  /** 初始化失败的中文原因（空串表示正常）。 */
  initError: string = '';

  static get(): AppServices {
    if (AppServices.shared === null) {
      AppServices.shared = new AppServices();
    }
    return AppServices.shared;
  }

  /** 是否已完成初始化。 */
  isReady(): boolean {
    return this.ready;
  }

  /** 等待初始化完成（页面首帧用）。返回是否就绪。 */
  async waitReady(): Promise<boolean> {
    if (this.ready) {
      return true;
    }
    if (this.initPromise !== null) {
      await this.initPromise;
    }
    return this.ready;
  }

  /** 幂等初始化（页面 aboutToAppear 调用即可）。 */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.ready) {
      return;
    }
    if (this.initPromise !== null) {
      await this.initPromise;
      return;
    }
    this.abilityContext = context;
    this.initPromise = this.doInit(context);
    await this.initPromise;
  }

  private async doInit(context: common.UIAbilityContext): Promise<void> {
    try {
      const options: ModelLayerOptions = { dbName: 'chatanywhere.db' };
      this.model = await createModelLayer(context, options);
      hilog.info(DOMAIN, TAG, 'model layer ready');
    } catch (e) {
      this.initError = `本地数据库打开失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'model layer failed: %{public}s', (e as Error).message);
      this.initPromise = null;
      return;
    }

    try {
      this.protocol = createProtocolLayer({
        secrets: this.model.secrets,
        settings: this.model.repo,
        models: this.model.repo
      });
      await this.protocol.catalog.init();
      hilog.info(DOMAIN, TAG, 'protocol layer ready');
    } catch (e) {
      this.initError = `模型协议层初始化失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'protocol layer failed: %{public}s', (e as Error).message);
      this.initPromise = null;
      return;
    }

    try {
      this.context = createContextLayer();
    } catch (e) {
      this.initError = `提示词与记忆模块初始化失败：${(e as Error).message}`;
      this.initPromise = null;
      return;
    }

    try {
      this.plugin = await createPluginLayer({
        skills: this.model.repo,
        settings: this.model.repo,
        secrets: this.model.secrets,
        protocol: this.protocol
      });
      await this.plugin.init();
      hilog.info(DOMAIN, TAG, 'plugin layer ready');
    } catch (e) {
      // 技能模块属于增强能力：失败时降级（对话仍可用），不阻断整个应用
      this.plugin = null;
      this.pluginError = `技能模块未能启动（不影响普通对话）：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'plugin layer degraded: %{public}s', (e as Error).message);
    }

    // 角色与技能三级继承（v3）：依赖数据层设置与技能仓库，失败降级为内置角色在内存可用
    try {
      this.personaStore = new PersonaStore(this.model.repo, this.model.repo);
      await this.personaStore.init();
      hilog.info(DOMAIN, TAG, 'persona store ready');
    } catch (e) {
      this.personaStore = null;
      this.initError = `角色配置加载失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'persona store failed: %{public}s', (e as Error).message);
    }

    this.ready = true;
  }

  /** 角色存储（v3）。 */
  personaStore: PersonaStore | null = null;

  /** 角色存储是否就绪。 */
  hasPersonas(): boolean {
    return this.personaStore !== null;
  }

  requirePersonas(): PersonaStore {
    if (this.personaStore === null) {
      throw new Error('角色配置尚未就绪');
    }
    return this.personaStore;
  }

  /** 技能模块降级原因（空串表示正常）。 */
  pluginError: string = '';

  /** 技能模块是否可用。 */
  hasPlugin(): boolean {
    return this.plugin !== null;
  }

  /** 重新尝试初始化（设置页「重试」按钮）。 */
  async retryInit(): Promise<void> {
    if (this.ready || this.abilityContext === null) {
      return;
    }
    this.initError = '';
    this.initPromise = null;
    await this.init(this.abilityContext);
  }

  /** UIAbilityContext（创建分享/文件路径等需要）。 */
  requireContext(): common.UIAbilityContext {
    if (this.abilityContext === null) {
      throw new Error('应用尚未初始化');
    }
    return this.abilityContext;
  }

  requireModel(): ModelLayer {
    if (this.model === null) {
      throw new Error('本地数据尚未就绪，请稍后重试');
    }
    return this.model;
  }

  requireProtocol(): ProtocolLayer {
    if (this.protocol === null) {
      throw new Error('模型协议层尚未就绪，请稍后重试');
    }
    return this.protocol;
  }

  requireContextLayer(): ContextLayer {
    if (this.context === null) {
      throw new Error('提示词模块尚未就绪，请稍后重试');
    }
    return this.context;
  }

  requirePlugin(): PluginLayer {
    if (this.plugin === null) {
      throw new Error('技能模块尚未就绪，请稍后重试');
    }
    return this.plugin;
  }

  // ---------------------------------------------------------------------------
  // 模型选择
  // ---------------------------------------------------------------------------

  /** 是否已拉取到可用的真实模型（v3.2）。 */
  hasModels(): boolean {
    if (this.protocol === null) {
      return false;
    }
    return this.protocol.catalog.hasModels();
  }

  /**
   * 从设置中解析当前模型；模型全部来自真实探测（v3.2 无占位模型）。
   * 无可用模型时抛出带中文引导的 Error，由调用方降级显示。
   */
  async resolveActiveProfile(): Promise<ModelProfile> {
    const catalog: ModelCatalogApi = this.requireProtocol().catalog;
    const repo = this.requireModel().repo;
    const modelId = await repo.getString(SettingsKeys.ACTIVE_MODEL, '');
    if (modelId.length > 0) {
      const found = catalog.findByModelId(modelId);
      if (found !== null) {
        return found;
      }
    }
    const fallback: ModelProfile | null = catalog.defaultProfile();
    if (fallback !== null) {
      return fallback;
    }
    throw new Error('还没有可用的真实模型，请到「设置 → 模型与密钥」填写密钥并拉取模型');
  }

  /** 切换当前模型（落盘）。 */
  async setActiveProfile(providerId: string, modelId: string): Promise<void> {
    const repo = this.requireModel().repo;
    await repo.putString(SettingsKeys.ACTIVE_PROVIDER, providerId);
    await repo.putString(SettingsKeys.ACTIVE_MODEL, modelId);
  }

  /** 当前思考档位（6 档；兼容迁移旧的 quick/deep 存储值）。 */
  async currentThinkingLevel(): Promise<ThinkingLevel> {
    const raw: string = await this.requireModel().repo.getString(SettingsKeys.THINKING_LEVEL, 'med');
    return EffortLevels.normalize(raw);
  }

  /** 当前联网模式。 */
  async currentWebMode(): Promise<WebMode> {
    const raw = await this.requireModel().repo.getString(SettingsKeys.WEB_MODE, 'off');
    if (raw === 'server_managed') {
      return 'server_managed';
    }
    if (raw === 'standalone_clean') {
      return 'standalone_clean';
    }
    return 'off';
  }

  /** 当前角色提示词（空串表示默认）。 */
  async currentPersonaPrompt(): Promise<string> {
    return this.requireModel().repo.getString(SettingsKeys.PERSONA_PROMPT, '');
  }

  /** 当前角色 id。 */
  async currentPersonaId(): Promise<string> {
    return this.requireModel().repo.getString(SettingsKeys.PERSONA_ID, 'general');
  }

  /** 全部内置角色。 */
  personas(): PersonaPreset[] {
    return this.requireContextLayer().prompts.personas();
  }
}
