/**
 * 运行时单例持有者（全应用共享一个 ChatRuntime，跨页面保持流式状态）。
 *
 * 页面通常用 `getChatRuntime()`（只暴露 ChatRuntimeApi 契约）渲染；
 * 需要调用契约之外的增强能力（如「重新生成某条历史回答」）时用 `getChatRuntimeConcrete()`。
 */
import { AppServices } from '../app/AppServices';
import { ChatRuntime } from './ChatRuntime';
import { ChatRuntimeApi } from './ChatRuntimeApi';

let runtime: ChatRuntime | null = null;

/** 具体实现（含契约外的增强方法）。 */
export function getChatRuntimeConcrete(): ChatRuntime {
  if (runtime === null) {
    runtime = new ChatRuntime(AppServices.get());
  }
  return runtime;
}

/** 契约视角（页面默认用这个，便于换实现）。 */
export function getChatRuntime(): ChatRuntimeApi {
  return getChatRuntimeConcrete();
}
