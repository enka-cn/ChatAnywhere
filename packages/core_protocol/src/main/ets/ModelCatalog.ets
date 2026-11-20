/**
 * 内置模型目录（纯逻辑，零平台依赖）。
 *
 * 契约来源：packages/core_protocol/src/main/ets/interfaces/ProtocolLayer.ets（ModelCatalogApi）
 * 经济性字段来源：docs/API_REFERENCE.md §4（缓存价差倍率）与 Blueprint §3.2。
 *
 * 说明：
 * - `cacheMissToHitRatio` 供 core_context 的缓存感知压缩器做经济性决策：
 *   deepseek-flash 缓存未命中/命中价差 50 倍、deepseek-v4-pro 30 倍、其它厂商约 4 倍。
 * - DeepSeek 官方未公布缓存 TTL（"几个小时到几天"），`cacheIdleTtlSec` 取保守值，仅作压缩触发参考。
 * - `label` 全部是直白中文，供 UI 直接展示。
 */
import { ModelCatalogApi } from './interfaces/ProtocolLayer';
import { ModelProfile, ProtocolKind } from './interfaces/ProtocolTypes';

/** 空字符串安全的模型键。 */
function profileKey(providerId: string, modelId: string): string {
  return `${providerId}::${modelId}`;
}

export class ModelCatalog implements ModelCatalogApi {
  private profiles: ModelProfile[] = [];
  /** 内置厂商（决定设置页是否允许删除）。 */
  private builtinProviders: Set<string> = new Set<string>();

  constructor() {
    this.resetToBuiltin();
  }

  /** 内置目录（可重复调用以恢复默认）。 */
  resetToBuiltin(): void {
    this.profiles = [];
    this.builtinProviders = new Set<string>();
    this.builtinProviders.add('deepseek');
    this.builtinProviders.add('anthropic');

    // DeepSeek 两个模型（Responses API，端点无 /v1）
    this.profiles.push(this.createProfile('deepseek', 'deepseek-flash', 'deepseek_responses',
      'https://api.deepseek.com', 'deepseek.apiKey', 1000000, 50, 14400, true, true, true,
      '深度求索 极速版', true));
    this.profiles.push(this.createProfile('deepseek', 'deepseek-v4-pro', 'deepseek_responses',
      'https://api.deepseek.com', 'deepseek.apiKey', 1000000, 30, 14400, true, true, true,
      '深度求索 旗舰版', true));

    // Anthropic Claude 系列（Messages API）
    this.profiles.push(this.createProfile('anthropic', 'claude-sonnet-4-5', 'anthropic_messages',
      'https://api.anthropic.com', 'anthropic.apiKey', 200000, 4, 300, false, true, true,
      '克劳德 4.5 标准版', true));
    this.profiles.push(this.createProfile('anthropic', 'claude-opus-4-5', 'anthropic_messages',
      'https://api.anthropic.com', 'anthropic.apiKey', 200000, 4, 300, false, true, true,
      '克劳德 4.5 旗舰版', true));

    // 任意 OpenAI 兼容端点（用户可在设置页改 baseUrl / modelId）
    this.profiles.push(this.createProfile('openai_compat', 'gpt-4.1-mini', 'openai_chat',
      'https://api.openai.com/v1', 'openaiCompat.apiKey', 128000, 4, 600, false, true, true,
      '自定义兼容接口', false));
  }

  private createProfile(providerId: string, modelId: string, protocol: ProtocolKind, baseUrl: string,
    assetKeyAlias: string, contextWindow: number, cacheMissToHitRatio: number, cacheIdleTtlSec: number,
    supportsServerWebTools: boolean, supportsThinking: boolean, supportsJsonSchema: boolean,
    label: string, builtin: boolean): ModelProfile {
    const profile: ModelProfile = {
      providerId: providerId,
      modelId: modelId,
      protocol: protocol,
      baseUrl: baseUrl,
      assetKeyAlias: assetKeyAlias,
      contextWindow: contextWindow,
      cacheMissToHitRatio: cacheMissToHitRatio,
      cacheIdleTtlSec: cacheIdleTtlSec,
      supportsServerWebTools: supportsServerWebTools,
      supportsThinking: supportsThinking,
      supportsJsonSchema: supportsJsonSchema,
      label: label,
      builtin: builtin
    };
    return profile;
  }

  listProfiles(): ModelProfile[] {
    const out: ModelProfile[] = [];
    for (const one of this.profiles) {
      out.push(one);
    }
    return out;
  }

  get(providerId: string, modelId: string): ModelProfile | null {
    const key: string = profileKey(providerId, modelId);
    for (const one of this.profiles) {
      if (profileKey(one.providerId, one.modelId) === key) {
        return one;
      }
    }
    return null;
  }

  findByModelId(modelId: string): ModelProfile | null {
    for (const one of this.profiles) {
      if (one.modelId === modelId) {
        return one;
      }
    }
    return null;
  }

  defaultProfile(): ModelProfile {
    const found: ModelProfile | null = this.get('deepseek', 'deepseek-flash');
    if (found !== null) {
      return found;
    }
    // 理论上不会发生；兜底保证永远返回一个可用 profile。
    return this.createProfile('deepseek', 'deepseek-flash', 'deepseek_responses',
      'https://api.deepseek.com', 'deepseek.apiKey', 1000000, 50, 14400, true, true, true,
      '深度求索 极速版', true);
  }

  /** 注册/覆盖（同 providerId + modelId 覆盖；新 providerId 视为自定义，不占用内置标记）。 */
  register(profile: ModelProfile): void {
    const key: string = profileKey(profile.providerId, profile.modelId);
    for (let i = 0; i < this.profiles.length; i++) {
      const one: ModelProfile = this.profiles[i];
      if (profileKey(one.providerId, one.modelId) === key) {
        this.profiles[i] = profile;
        return;
      }
    }
    this.profiles.push(profile);
  }

  /** 是否为内置厂商（内置厂商不允许在设置页删除）。 */
  isBuiltin(providerId: string): boolean {
    return this.builtinProviders.has(providerId);
  }

  /** 某协议下的默认 profile（用于把 adapter 与模型对上）。 */
  findByProtocol(protocol: ProtocolKind): ModelProfile | null {
    for (const one of this.profiles) {
      if (one.protocol === protocol) {
        return one;
      }
    }
    return null;
  }

  /** 内置模型数量（设置页展示用）。 */
  builtinCount(): number {
    let count: number = 0;
    for (const one of this.profiles) {
      if (one.builtin === true) {
        count++;
      }
    }
    return count;
  }
}
