/**
 * 真实模型目录（v3.2，**不含任何硬编码模型 id**）。
 *
 * 设计原则（lead 的 v3.2 契约）：
 * - 本文件只保留「厂商预设」（providerId / 协议 / 默认地址 / 缓存经济性 / 能力标志）；
 * - 具体模型必须由用户在设置页对真实端点执行探测（`/models`）后写入 RDB 注册表，
 *   且只有 `enabled = true`（用户勾选）的模型才会出现在 `listProfiles()`；
 * - 无任何已启用模型时 `listProfiles() === []`、`defaultProfile() === null`，
 *   UI 据此引导用户去「设置 → 模型与密钥」拉取模型，而不是展示占位假模型。
 *
 * 依赖方向：core_protocol → core_model（只依赖 ModelRegistryApi / ProviderModelRecord 契约）。
 */
import { ModelRegistryApi, ProviderModelRecord, SettingsKeys } from '@app/core_model';
import { ModelCatalogApi, ProtocolDeps, ProviderPreset } from './interfaces/ProtocolLayer';
import { ModelProfile, ProtocolKind, RemoteModelInfo } from './interfaces/ProtocolTypes';

/** 自定义 OpenAI 兼容端点的固定 providerId（历史数据也用它）。 */
const CUSTOM_PROVIDER_ID: string = 'openai_compat';
/** 用户自定义端点的兜底地址（与 OpenAI 官方地址同形）。 */
const DEFAULT_CUSTOM_BASE_URL: string = 'https://api.openai.com/v1';

/** providerId::modelId 组合键。 */
function profileKey(providerId: string, modelId: string): string {
  return `${providerId}::${modelId}`;
}

export class ModelCatalog implements ModelCatalogApi {
  private readonly deps: ProtocolDeps;
  /** 厂商预设（唯一允许的"内置"信息，不含任何模型 id）。 */
  private readonly presets: ProviderPreset[] = [
    {
      providerId: 'deepseek',
      label: '深度求索',
      protocol: 'deepseek_responses',
      defaultBaseUrl: 'https://api.deepseek.com',
      assetKeyAlias: 'deepseek.apiKey',
      contextWindow: 1000000,
      cacheMissToHitRatio: 50,
      cacheIdleTtlSec: 14400,
      supportsServerWebTools: true,
      supportsThinking: true,
      supportsJsonSchema: true
    },
    {
      providerId: 'anthropic',
      label: '克劳德',
      protocol: 'anthropic_messages',
      defaultBaseUrl: 'https://api.anthropic.com',
      assetKeyAlias: 'anthropic.apiKey',
      contextWindow: 200000,
      cacheMissToHitRatio: 4,
      cacheIdleTtlSec: 300,
      supportsServerWebTools: false,
      supportsThinking: true,
      supportsJsonSchema: true
    },
    {
      providerId: CUSTOM_PROVIDER_ID,
      label: '自定义兼容接口',
      protocol: 'openai_chat',
      defaultBaseUrl: DEFAULT_CUSTOM_BASE_URL,
      assetKeyAlias: 'openaiCompat.apiKey',
      contextWindow: 128000,
      cacheMissToHitRatio: 4,
      cacheIdleTtlSec: 600,
      supportsServerWebTools: false,
      supportsThinking: true,
      supportsJsonSchema: true
    }
  ];
  /** 由 RDB 注册表「已启用」记录构建出的 profile。 */
  private enabledProfiles: ModelProfile[] = [];
  /** 运行时临时注册/覆盖（`register`，不落库）。 */
  private overrides: Map<string, ModelProfile> = new Map<string, ModelProfile>();
  /** 用户自定义端点地址（来自 SettingsKeys.CUSTOM_BASE_URL）。 */
  private customBaseUrl: string = '';
  /** 用户自定义 Anthropic 端点（来自 SettingsKeys.ANTHROPIC_BASE_URL，空表示用官方地址）。 */
  private anthropicBaseUrl: string = '';

  constructor(deps: ProtocolDeps) {
    this.deps = deps;
  }

  /**
   * 启动装载：读取设置里的自定义地址 + RDB 注册表，幂等。
   * 设置页可能在运行期改地址（例如把 Anthropic 换到自建代理），因此 `reload()` 每次都会
   * 重新读取一次地址，保证「探测用的地址」与「真正发消息用的地址」始终一致。
   */
  async init(): Promise<void> {
    await this.reload();
  }

  // ------------------------------------------------------------ 查询

  /** 已启用（用户勾选）的真实模型 + 运行时临时注册；未拉取过模型时为空数组。 */
  listProfiles(): ModelProfile[] {
    return this.mergedProfiles();
  }

  get(providerId: string, modelId: string): ModelProfile | null {
    const key: string = profileKey(providerId, modelId);
    for (const one of this.mergedProfiles()) {
      if (profileKey(one.providerId, one.modelId) === key) {
        return one;
      }
    }
    return null;
  }

  findByModelId(modelId: string): ModelProfile | null {
    for (const one of this.mergedProfiles()) {
      if (one.modelId === modelId) {
        return one;
      }
    }
    return null;
  }

  hasModels(): boolean {
    return this.mergedProfiles().length > 0;
  }

  /** 默认模型：按预设厂商顺序取第一个已启用模型；无模型返回 null。 */
  defaultProfile(): ModelProfile | null {
    const profiles: ModelProfile[] = this.mergedProfiles();
    if (profiles.length === 0) {
      return null;
    }
    for (const preset of this.presets) {
      for (const one of profiles) {
        if (one.providerId === preset.providerId) {
          return one;
        }
      }
    }
    return profiles[0];
  }

  /** 运行时临时注册/覆盖（不落库；同 providerId+modelId 覆盖）。 */
  register(profile: ModelProfile): void {
    this.overrides.set(profileKey(profile.providerId, profile.modelId), profile);
  }

  /** 是否为内置厂商（三类预设都算内置；未知 providerId 返回 false）。 */
  isBuiltin(providerId: string): boolean {
    return this.findPreset(providerId) !== null;
  }

  /** 厂商预设（设置页展示地址/能力用；未知厂商返回 null）。 */
  providerMeta(providerId: string): ProviderPreset | null {
    const preset: ProviderPreset | null = this.findPreset(providerId);
    if (preset === null) {
      return null;
    }
    return this.copyPreset(preset);
  }

  /**
   * 用「厂商预设 + 模型 id」构造 ModelProfile（探测 / 测试连接用）。
   *
   * 特例：`modelId` 为空串时返回一个 **探测用 profile**（modelId 为空），
   * 供设置页在"还没选模型、只想验 Key"时调用 `testConnection` / `listRemoteModels`；
   * 这种 profile 不会进入目录，也不会出现在对话页。
   */
  buildProfile(providerId: string, modelId: string, baseUrl?: string): ModelProfile | null {
    const preset: ProviderPreset | null = this.findPreset(providerId);
    if (preset === null) {
      return null;
    }
    const trimmedModelId: string = modelId === undefined || modelId === null ? '' : modelId.trim();
    const effectiveBaseUrl: string = baseUrl !== undefined && baseUrl !== null && baseUrl.trim().length > 0
      ? baseUrl.trim() : this.resolveBaseUrl(preset);
    const profile: ModelProfile = {
      providerId: preset.providerId,
      modelId: trimmedModelId,
      protocol: preset.protocol as ProtocolKind,
      baseUrl: effectiveBaseUrl,
      assetKeyAlias: preset.assetKeyAlias,
      contextWindow: preset.contextWindow,
      cacheMissToHitRatio: preset.cacheMissToHitRatio,
      cacheIdleTtlSec: preset.cacheIdleTtlSec,
      supportsServerWebTools: preset.supportsServerWebTools,
      supportsThinking: this.supportsThinkingFor(preset, trimmedModelId),
      supportsJsonSchema: preset.supportsJsonSchema,
      label: trimmedModelId.length > 0 ? `${preset.label} · ${trimmedModelId}` : preset.label,
      builtin: true
    };
    return profile;
  }

  // ------------------------------------------------------------ 写入（落库）

  /**
   * 探测结果落库：整体替换该厂商清单（保留同 modelId 的旧勾选状态），然后重载内存目录。
   * 新出现的模型默认 **未勾选**（enabled=false），必须由用户显式勾选后才会进入对话页。
   */
  async applyDiscoveredModels(providerId: string, models: RemoteModelInfo[]): Promise<void> {
    if (this.findPreset(providerId) === null) {
      return;
    }
    const existingEnabled: Map<string, boolean> = new Map<string, boolean>();
    try {
      const all: ProviderModelRecord[] = await this.deps.models.loadModels();
      for (const one of all) {
        if (one.providerId === providerId) {
          existingEnabled.set(one.modelId, one.enabled);
        }
      }
    } catch (e) {
      // 读取失败时按"全新清单"处理，不阻断落库
    }
    const now: number = Date.now();
    const records: ProviderModelRecord[] = [];
    const seen: Set<string> = new Set<string>();
    for (const one of models) {
      const modelId: string = one.modelId === undefined || one.modelId === null ? '' : one.modelId.trim();
      if (modelId.length === 0 || seen.has(modelId)) {
        continue;
      }
      seen.add(modelId);
      const previous: boolean | undefined = existingEnabled.get(modelId);
      const displayName: string = one.displayName === undefined ? '' : one.displayName.trim();
      const record: ProviderModelRecord = {
        providerId: providerId,
        modelId: modelId,
        displayName: displayName.length > 0 ? displayName : modelId,
        metaJson: one.metaJson === undefined ? '' : one.metaJson,
        enabled: previous === undefined ? false : previous,
        discoveredAt: now
      };
      records.push(record);
    }
    await this.deps.models.saveDiscoveredModels(providerId, records);
    await this.reload();
  }

  /** 勾选/取消勾选并落库，随后重载内存目录。 */
  async setModelEnabled(providerId: string, modelId: string, enabled: boolean): Promise<void> {
    await this.deps.models.setModelEnabled(providerId, modelId, enabled);
    await this.reload();
  }

  // ------------------------------------------------------------ 内部

  /** 从 RDB 注册表重建已启用 profile 列表。 */
  private async reload(): Promise<void> {
    await this.refreshBaseUrls();
    const records: ProviderModelRecord[] = await this.deps.models.loadModels();
    const profiles: ModelProfile[] = [];
    for (const record of records) {
      if (!record.enabled) {
        continue;
      }
      const profile: ModelProfile | null = this.buildProfile(record.providerId, record.modelId);
      if (profile === null) {
        // 未知厂商（例如历史遗留的自定义 providerId）：跳过，等待用户重新探测
        continue;
      }
      const displayName: string = record.displayName === undefined ? '' : record.displayName.trim();
      if (displayName.length > 0) {
        profile.label = displayName;
      }
      profiles.push(profile);
    }
    this.enabledProfiles = profiles;
  }

  /** 从设置里重新读取自定义端点地址（每次 reload 都读，保证探测/发消息地址一致）。 */
  private async refreshBaseUrls(): Promise<void> {
    try {
      const custom: string = await this.deps.settings.getString(SettingsKeys.CUSTOM_BASE_URL, '');
      this.customBaseUrl = custom === undefined || custom === null ? '' : custom.trim();
    } catch (e) {
      // 设置读取失败不影响已装载模型
    }
    try {
      const anthropic: string = await this.deps.settings.getString(SettingsKeys.ANTHROPIC_BASE_URL, '');
      this.anthropicBaseUrl = anthropic === undefined || anthropic === null ? '' : anthropic.trim();
    } catch (e) {
      // 同上
    }
  }

  /** 已启用 profile + 运行时临时注册（覆盖同键）。 */
  private mergedProfiles(): ModelProfile[] {
    const out: ModelProfile[] = [];
    const used: Set<string> = new Set<string>();
    for (const one of this.enabledProfiles) {
      const key: string = profileKey(one.providerId, one.modelId);
      const override: ModelProfile | undefined = this.overrides.get(key);
      if (override !== undefined) {
        out.push(override);
        used.add(key);
      } else {
        out.push(one);
      }
    }
    this.overrides.forEach((value: ModelProfile, key: string) => {
      if (!used.has(key)) {
        out.push(value);
      }
    });
    return out;
  }

  private findPreset(providerId: string): ProviderPreset | null {
    for (const one of this.presets) {
      if (one.providerId === providerId) {
        return one;
      }
    }
    return null;
  }

  private copyPreset(preset: ProviderPreset): ProviderPreset {
    const copy: ProviderPreset = {
      providerId: preset.providerId,
      label: preset.label,
      protocol: preset.protocol,
      defaultBaseUrl: this.resolveBaseUrl(preset),
      assetKeyAlias: preset.assetKeyAlias,
      contextWindow: preset.contextWindow,
      cacheMissToHitRatio: preset.cacheMissToHitRatio,
      cacheIdleTtlSec: preset.cacheIdleTtlSec,
      supportsServerWebTools: preset.supportsServerWebTools,
      supportsThinking: preset.supportsThinking,
      supportsJsonSchema: preset.supportsJsonSchema
    };
    return copy;
  }

  /**
   * 实际 baseUrl：用户自定义地址优先（设置页保存后，重新装载的 profile 也要用同一个地址，
   * 否则探测用自定义地址、真正发消息却回落到官方地址）。
   */
  private resolveBaseUrl(preset: ProviderPreset): string {
    if (preset.providerId === CUSTOM_PROVIDER_ID && this.customBaseUrl.length > 0) {
      return this.customBaseUrl;
    }
    if (preset.providerId === 'anthropic' && this.anthropicBaseUrl.length > 0) {
      return this.anthropicBaseUrl;
    }
    return preset.defaultBaseUrl;
  }

  /**
   * 思考能力判定：
   * - DeepSeek / Anthropic 预设一律支持（它们探测到的模型都在思考模型线上）；
   * - 自定义 OpenAI 兼容端点按模型名保守推断，避免对非推理模型发送 `reasoning_effort` 导致 400。
   */
  private supportsThinkingFor(preset: ProviderPreset, modelId: string): boolean {
    if (preset.providerId !== CUSTOM_PROVIDER_ID) {
      return preset.supportsThinking;
    }
    const id: string = modelId.toLowerCase();
    if (id.length === 0) {
      return false;
    }
    if (id.indexOf('gpt-5') >= 0 || id.indexOf('deepseek-r') >= 0 || id.indexOf('reasoner') >= 0
      || id.indexOf('thinking') >= 0 || id.indexOf('reasoning') >= 0 || id.indexOf('qwq') >= 0) {
      return true;
    }
    if (id.substring(0, 2) === 'o1' || id.substring(0, 2) === 'o3' || id.substring(0, 2) === 'o4') {
      return true;
    }
    return false;
  }
}
