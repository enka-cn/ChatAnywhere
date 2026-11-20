/**
 * 工具执行器统一接口（内核注册表只认这个接口，便于 L1/L2/L3 热插拔）。
 */
import { ToolExecutionResult } from '../interfaces/SkillManifest';

/** 一个可被模型调用的工具执行器。 */
export interface ToolRunner {
  /** 执行工具；argumentsJson 为模型给出的参数 JSON。 */
  execute(argumentsJson: string): Promise<ToolExecutionResult>;
}
