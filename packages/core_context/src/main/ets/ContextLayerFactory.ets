/**
 * 上下文层工厂：把压缩器与提示词装配器组装成 ContextLayer，供 AppServices 使用。
 */
import { CompactorApi, ContextLayer, CreateContextLayer, PromptAssemblerApi } from './interfaces/ContextLayer';
import { CacheAwareCompactor } from './CacheAwareCompactor';
import { PromptAssembler } from './PromptAssembler';

/** 创建上下文层。纯逻辑组件，同步构造，不需要异步初始化。 */
export const createContextLayer: CreateContextLayer = (): ContextLayer => {
  const compactor: CompactorApi = new CacheAwareCompactor();
  const prompts: PromptAssemblerApi = new PromptAssembler();
  const layer: ContextLayer = {
    compactor: compactor,
    prompts: prompts
  };
  return layer;
};
