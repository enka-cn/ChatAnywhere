/**
 * Skill 契约（Blueprint §3.5）。
 *
 * 对 Blueprint 的两处 ArkTS 适配（已在 docs/DEV_GUIDE.md §7 登记）：
 * - `configSchema: Record<string, ...>` → `SkillConfigField[]`（ArkTS 禁止 Record 字面量，
 *   数组还附带稳定渲染顺序）；
 * - `toolSchema: Record<string, Object>` → `toolSchemaJson: string`（JSON Schema 原文）。
 */
import { SourceRef } from '@app/core_model';

/** 插件分级（受鸿蒙安全边界约束，禁止动态下发 .so）。 */
export type PluginTier = 'L1_DECLARATIVE' | 'L2_REMOTE_MCP' | 'L3_QUICKJS_SANDBOX';

/** 可逆副作用回收句柄（Cordis 微内核语义）。 */
export interface Disposable {
  dispose(): void;
}

/** 配置字段类型（决定手机端自动渲染的控件）。 */
export type ConfigFieldType = 'boolean' | 'number' | 'string' | 'string_list' | 'enum';

/** 一个可自动渲染的配置字段。 */
export interface SkillConfigField {
  /** 配置键（英文标识，如 minRerankScore）。 */
  key: string;
  /** 直白中文标签，如「最低相关度」。 */
  label: string;
  type: ConfigFieldType;
  /** 默认值的 JSON 文本（boolean/number/string/string[] 的序列化）。 */
  defaultValueJson: string;
  min?: number;
  max?: number;
  /** type=enum 时的选项。 */
  options?: string[];
  /** 一句话说明。 */
  hint?: string;
}

/** L1 声明式 HTTP 模板。 */
export interface HttpTemplate {
  method: string;
  /** 支持 {{input.xxx}} 与 {{config.xxx}} 占位符。 */
  urlTemplate: string;
  /** 附加头，JSON 文本。 */
  headersJson?: string;
  /** 请求体模板（JSON 文本，支持占位符）。 */
  bodyTemplate?: string;
  /** 从响应 JSON 抽取结果的点路径，如 `data.results.0.summary`。 */
  responsePath?: string;
  timeoutMs?: number;
}

/** 运行时载荷：三种分级各取所需。 */
export interface SkillRuntimePayload {
  httpTemplate?: HttpTemplate;
  /** L2 MCP 端点（Streamable HTTP / SSE）。 */
  mcpEndpoint?: string;
  mcpTransport?: string;
  /** L3 QuickJS 脚本源码（当前构建未启用执行后端，见 DEV_GUIDE §7）。 */
  quickJsCode?: string;
  /** 网络访问白名单（默认拒绝）。 */
  allowedDomains: string[];
  /** MCP 鉴权凭证的 Asset 别名。 */
  authSecretAlias?: string;
}

/** 完整技能清单（落盘即 JSON.stringify(manifest)）。 */
export interface SkillManifest {
  id: string;
  version: string;
  /** 直白中文名，如「技术文档联网清洗」。 */
  name: string;
  description: string;
  tier: PluginTier;
  enabled: boolean;
  /** 作者/来源，如 'builtin' | 'user' | 'git:repo'。 */
  author?: string;
  /** 创建/更新时间 ms。 */
  updatedAt?: number;
  configSchema: SkillConfigField[];
  /** 当前用户配置值，JSON 文本（Record<string,string>）。空串表示用默认。 */
  savedConfigJson?: string;
  /** Function Calling Schema（JSON 文本）。 */
  toolSchemaJson?: string;
  /** 挂载的提示词片段（按 skill.id 排序注入，保障 KV Cache 前缀稳定）。 */
  promptSnippet?: string;
  runtimePayload: SkillRuntimePayload;
}

/** 技能校验/升级结果（含中文 Diff 与安全告警）。 */
export interface UpgradeResult {
  ok: boolean;
  /** 失败原因（直白中文）。 */
  error?: string;
  /** 中文变更对比（旧版→新版）。 */
  diffText: string;
  securityWarnings: string[];
  /** 落盘后的清单。 */
  manifest?: SkillManifest;
}

/** 试跑报告。 */
export interface DryRunReport {
  passed: boolean;
  latencyMs: number;
  /** 试跑产物（截断到 800 字，避免撑爆 UI）。 */
  sampleOutput: string;
  /** 直白中文安全告警，如「该技能可访问 3 个外部域名」。 */
  securityWarnings: string[];
  /** 失败原因。 */
  error?: string;
}

/** 工具执行结果（喂回模型）。 */
export interface ToolExecutionResult {
  ok: boolean;
  content: string;
  elapsedMs: number;
  error?: string;
  sources?: SourceRef[];
}

/** 暴露给模型的工具定义（已按 skillId 排序）。 */
export interface ToolDefinition {
  name: string;
  description: string;
  parametersJson: string;
  skillId: string;
}

/** 技能管理页展示项（含运行状态）。 */
export interface SkillSummary {
  id: string;
  version: string;
  name: string;
  description: string;
  tier: PluginTier;
  enabled: boolean;
  /** 运行期是否已成功挂载。 */
  mounted: boolean;
  configSchema: SkillConfigField[];
  savedConfigJson: string;
  promptSnippet?: string;
  allowedDomains: string[];
}

/** UI 快捷入口（注册即返回 Disposable，卸载零残留）。 */
export interface UiShortcut {
  id: string;
  label: string;
  /** 点击行为标识，由 UI 层解释。 */
  action: string;
  skillId: string;
}

/** 启用技能的提示词片段（按 skillId 字典序注入 system prompt，保障 KV Cache 前缀稳定）。 */
export interface SkillPromptSnippet {
  skillId: string;
  name: string;
  snippet: string;
}
