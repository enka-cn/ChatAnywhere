/**
 * core_plugin 公开 API（冻结契约）。
 *
 * 契约导出不得删除；以下补充导出为纯逻辑工具与实现类，供 UI / QA 使用：
 * - SkillSchema / SkillDiff：可在 Node 逻辑测试中直接跑；
 * - PluginKernelImpl / WebCleanerImpl / SkillCreatorAgentImpl：实现类（含扩展方法）；
 * - 内置技能 JSON / 各分级执行器 / 清洗与 MCP 纯函数。
 */
export {
  PluginTier, Disposable, ConfigFieldType, SkillConfigField, HttpTemplate, SkillRuntimePayload,
  SkillManifest, UpgradeResult, DryRunReport, ToolExecutionResult, ToolDefinition, SkillSummary,
  UiShortcut, SkillPromptSnippet
} from './src/main/ets/interfaces/SkillManifest';

export {
  PluginHookName, PluginHookEvent, PluginKernelApi, PluginEventsApi
} from './src/main/ets/interfaces/PluginKernel';

export { WebCleanPolicy, CleanedWebDoc, defaultWebCleanPolicy } from './src/main/ets/interfaces/WebTypes';
export { WebCleanerApi, CleanedWebPolicyLike } from './src/main/ets/interfaces/WebCleanerApi';

export {
  CreatorSessionState, CreatorDraft, CreatorCallbacks, SkillCreatorApi, CREATOR_TOOL_NAMES, CreatorSampleInput
} from './src/main/ets/interfaces/SkillCreator';

export {
  PluginDeps, PluginLayer, CreatePluginLayer
} from './src/main/ets/interfaces/PluginLayer';

export { createPluginLayer } from './src/main/ets/PluginLayerFactory';
export { PluginLayerImpl } from './src/main/ets/PluginLayerFactory';

// ---- 技能清单 Schema（纯逻辑） ----
export {
  SkillValidateResult, SkillNormalizeResult, SkillConfigResult, ConfigFieldInput, SKILL_TIERS,
  CONFIG_FIELD_TYPES, HTTP_METHODS, L3_FORBIDDEN_TOKENS, tierLabel, isKnownTier, isValidSkillId,
  isValidVersion, bumpPatchVersion, defaultJsonForType, validateConfigValue, normalizeManifestJson,
  validateManifestJson, collectSecurityWarnings, buildDefaultConfigJson, normalizeConfigJson,
  validateConfigJson, withConfigJson, buildConfigSchema, configEntries, manifestDomains, describeManifest,
  findSecretLiteral, validateQuickJsCode, serializeManifestJson
} from './src/main/ets/SkillSchema';

// ---- 中文变更对比（纯逻辑） ----
export {
  diffManifestJson, summarizeDiff, countDiffChanges, hasDiffChanges
} from './src/main/ets/SkillDiff';

// ---- SKILL.md ↔ SkillManifest 编解码（纯逻辑；创造室/技能页用） ----
export { SkillMarkdownCodec, SkillMarkdownResult } from './src/main/ets/SkillMarkdown';

// ---- 实现类 ----
export { PluginKernelImpl, PluginKernelDeps } from './src/main/ets/PluginKernelImpl';
export { WebCleanerImpl, WebCleanerDeps } from './src/main/ets/WebCleaner';
export { SkillCreatorAgentImpl, SkillCreatorDeps } from './src/main/ets/SkillCreatorAgent';

// ---- 内置技能 ----
export {
  builtinSkillJsonList, builtinSkillIds, builtinWebSearchJson, builtinWebExtractJson,
  builtinFxRateJson, builtinWeatherJson
} from './src/main/ets/BuiltinSkills';

// ---- 分级执行器 ----
export { L1DeclarativeRunner } from './src/main/ets/runners/L1DeclarativeRunner';
export { L2McpClient } from './src/main/ets/runners/L2McpClient';
export { L3SandboxRunner } from './src/main/ets/runners/L3SandboxRunner';
export { ToolRunner } from './src/main/ets/runners/ToolRunner';
export { NetHttp, HttpOutcome } from './src/main/ets/runners/NetHttp';

// ---- 双轨清洗纯逻辑 ----
export {
  buildQueryText, cleanSearchDocs, cleanFetchDoc, buildPromptBlock, sortDocsByQuality, dedupeDocs,
  buildSearchRequestBody, buildFetchRequestBody, describeApiError
} from './src/main/ets/util/WebClean';

// ---- MCP 协议纯逻辑 ----
export {
  buildJsonRpcRequest, buildJsonRpcNotification, buildInitializeParams, buildToolCallParams,
  buildToolsListParams, parseRpcBody, extractTools, extractCallOutcome, McpToolInfo, McpRpcResult,
  McpCallOutcome
} from './src/main/ets/util/McpProtocol';

// ---- 创造模式本地规则 ----
export {
  heuristicDraftRaw, distillDraftRaw, HeuristicDraftResult
} from './src/main/ets/util/CreatorHeuristic';

// ---- L1 模板与域名工具 ----
export {
  renderTemplate, extractSecretAliases, extractByResponsePath, parseHeaderText
} from './src/main/ets/util/L1Template';
export { isDomainAllowed, extractHost, normalizeHost } from './src/main/ets/util/DomainUtil';
