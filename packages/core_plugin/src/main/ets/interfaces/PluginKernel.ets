/**
 * 插件微内核契约（Blueprint §3.5，Cordis 可逆副作用）。
 */
import { SkillManifest, Disposable, DryRunReport, SkillSummary, ToolDefinition, ToolExecutionResult,
  UiShortcut, UpgradeResult, SkillPromptSnippet } from './SkillManifest';

/** 内核 Hook 事件名。 */
export type PluginHookName = 'skill_mounted' | 'skill_unmounted' | 'skill_updated' | 'tool_invoked';

/** Hook 回调载荷（显式字段）。 */
export interface PluginHookEvent {
  name: PluginHookName;
  skillId: string;
  /** 附加上下文（如工具名/错误）。 */
  detail?: string;
}

/** 内核接口。 */
export interface PluginKernelApi {
  /** 从 RDB 加载全部技能并挂载启用项（幂等）。 */
  init(): Promise<void>;

  /** 全部技能（管理页）。 */
  list(): SkillSummary[];

  get(skillId: string): SkillManifest | null;

  /** 挂载并注册其工具/Hook/UI 入口；重复挂载先卸载旧实例。 */
  mount(manifest: SkillManifest): Promise<Disposable>;

  /** 卸载，零残留。 */
  unmount(skillId: string): Promise<void>;

  /** 启用/禁用（落盘 + 挂载/卸载）。 */
  setEnabled(skillId: string, enabled: boolean): Promise<void>;

  /** 保存用户配置（校验类型与范围，落盘 json）。 */
  updateConfig(skillId: string, configJson: string): Promise<UpgradeResult>;

  /**
   * 原子升级：Schema 校验 → 沙箱试跑 → 旧版入快照 → 落盘 → 热挂载。
   * 任一步失败必须回滚到旧版。
   */
  atomicUpgrade(manifest: SkillManifest, dryRunInput?: string): Promise<UpgradeResult>;

  /** 回滚到上一个版本快照。 */
  rollback(skillId: string): Promise<boolean>;

  /** 删除技能（含快照）。 */
  remove(skillId: string): Promise<void>;

  /** 导入 JSON 清单（L1 声明式热添加），等价于 atomicUpgrade。 */
  importManifest(manifestJson: string): Promise<UpgradeResult>;

  /** 导出清单 JSON（供分享/局域网编辑）。 */
  exportManifest(skillId: string): string;

  /** 启用技能的提示词片段（按 skillId 字典序，保证缓存前缀稳定）。 */
  promptSnippets(): SkillPromptSnippet[];

  /** 启用技能的工具定义（按 skillId 字典序）。 */
  toolDefinitions(): ToolDefinition[];

  /** 执行工具调用（由 ChatRuntime 在收到 tool_call 时调用）。 */
  executeTool(name: string, argumentsJson: string): Promise<ToolExecutionResult>;

  /** 仅在沙箱中试跑（不落盘）。 */
  dryRun(manifestJson: string, sampleInput: string): Promise<DryRunReport>;

  /** 注册 Hook，返回 Disposable（卸载时自动回收）。 */
  on(event: PluginHookName, handler: (event: PluginHookEvent) => void): Disposable;

  /** 当前注册的 UI 快捷入口。 */
  uiShortcuts(): UiShortcut[];

  /** 内置示例技能播种（首次启动调用一次，已存在则跳过）。 */
  seedBuiltins(): Promise<void>;
}

/** 事件派发器（供 UI 刷新列表）。 */
export interface PluginEventsApi {
  onChanged(handler: () => void): Disposable;
}
