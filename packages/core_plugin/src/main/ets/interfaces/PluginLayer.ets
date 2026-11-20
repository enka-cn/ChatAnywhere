/**
 * 插件层装配契约（入口 HAP 通过 createPluginLayer 一次拿到内核 + 联网清洗 + 创造模式）。
 */
import { SecretApi, SettingsApi, SkillRepositoryApi } from '@app/core_model';
import { ProtocolLayer } from '@app/core_protocol';
import { PluginKernelApi } from './PluginKernel';
import { WebCleanerApi } from './WebCleanerApi';
import { SkillCreatorApi } from './SkillCreator';

/** 插件层依赖（由 AppServices 注入，避免插件层反向依赖数据层实现）。 */
export interface PluginDeps {
  skills: SkillRepositoryApi;
  settings: SettingsApi;
  secrets: SecretApi;
  /** 创造模式需要模型驱动；未配置 Key 时自动降级到本地规则草稿。 */
  protocol: ProtocolLayer | null;
}

/** 插件层门面。 */
export interface PluginLayer {
  kernel: PluginKernelApi;
  web: WebCleanerApi;
  creator: SkillCreatorApi;
  /** 初始化：加载技能 + 播种内置技能（幂等）。 */
  init(): Promise<void>;
}

export type CreatePluginLayer = (deps: PluginDeps) => Promise<PluginLayer>;
