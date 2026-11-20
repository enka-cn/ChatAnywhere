/**
 * 插件层工厂：构造微内核 + 双轨联网清洗 + 技能创造室，并串起初始化顺序。
 *
 * 初始化顺序：先播种内置技能（只落盘，不挂载），再由内核统一加载并挂载启用项；
 * 这样首次启动与二次启动行为一致，且每个技能的挂载失败都被隔离（不会拖垮整个应用初始化）。
 */
import { CreatePluginLayer, PluginDeps, PluginLayer } from './interfaces/PluginLayer';
import { WebCleanerApi } from './interfaces/WebCleanerApi';
import { PluginKernelApi } from './interfaces/PluginKernel';
import { SkillCreatorApi } from './interfaces/SkillCreator';
import { PluginKernelImpl } from './PluginKernelImpl';
import { SkillCreatorAgentImpl } from './SkillCreatorAgent';
import { WebCleanerImpl } from './WebCleaner';

/** PluginLayer 的类实现（ArkTS 中类比对象字面量更稳，且便于保留实现类引用）。 */
export class PluginLayerImpl implements PluginLayer {
  readonly kernel: PluginKernelApi;
  readonly web: WebCleanerApi;
  readonly creator: SkillCreatorApi;
  private readonly kernelImpl: PluginKernelImpl;

  constructor(kernel: PluginKernelImpl, web: WebCleanerImpl, creator: SkillCreatorAgentImpl) {
    this.kernelImpl = kernel;
    this.kernel = kernel;
    this.web = web;
    this.creator = creator;
  }

  /** 初始化：先播种内置技能（幂等），再由内核加载并挂载启用项。 */
  async init(): Promise<void> {
    await this.kernelImpl.seedBuiltins();
    await this.kernelImpl.init();
  }
}

export const createPluginLayer: CreatePluginLayer = async (deps: PluginDeps): Promise<PluginLayer> => {
  const kernel: PluginKernelImpl = new PluginKernelImpl({
    skills: deps.skills,
    secrets: deps.secrets,
    settings: deps.settings
  });
  const web: WebCleanerImpl = new WebCleanerImpl({
    secrets: deps.secrets,
    settings: deps.settings
  });
  const creator: SkillCreatorAgentImpl = new SkillCreatorAgentImpl({
    kernel,
    skills: deps.skills,
    secrets: deps.secrets,
    settings: deps.settings,
    protocol: deps.protocol
  });
  return new PluginLayerImpl(kernel, web, creator);
};
