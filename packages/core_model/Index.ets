/**
 * core_model 公开 API（冻结契约，跨模块只允许从这里 import）。
 *
 * 契约类型：interfaces/*（签名冻结，改动需先与 lead 确认）。
 * 实现类：impl/* 与 TrajectoryStore / ModelLayerFactory（可在包内与测试中直接使用）。
 * 纯逻辑工具：util/*（零平台依赖，QA 可用 Node 直接跑）。
 */
export {
  ItemKind, NodeRole, SearchKind, PageMeta, SourceRef, VendorRaw, CanonicalItem, ConversationNode,
  SessionMeta, NodeBrief
} from './src/main/ets/interfaces/ModelTypes';

export {
  SessionRepositoryApi, NodeRepositoryApi, SearchHit, SearchApi, SkillRecord, SkillSnapshot,
  SkillRepositoryApi, SettingsApi, RdbRepositoryApi
} from './src/main/ets/interfaces/RepositoryApi';

export { SecretApi } from './src/main/ets/interfaces/SecretApi';
export { ProviderModelRecord, ModelRegistryApi } from './src/main/ets/interfaces/ModelRegistryApi';
export { ExportResult, ImportResult, SessionExporterApi } from './src/main/ets/interfaces/ExportApi';
export { TrajectoryApi } from './src/main/ets/interfaces/TrajectoryApi';
export { ModelLayer, ModelLayerOptions, CreateModelLayer } from './src/main/ets/interfaces/ModelLayer';
export { SettingsKeys, SecretAliases } from './src/main/ets/interfaces/SettingsKeys';

export {
  estimateText, estimateItemTokens, estimateNodeTokens, estimateNodesTokens, contextUsageRatio,
  cacheHitRatio
} from './src/main/ets/util/Tokens';

export {
  newStringRecord, newObjectRecord, newNumberRecord, getString, getNumber, getBool, getStringList,
  getRecord, getRecordList, hasKey
} from './src/main/ets/util/JsonUtil';

export { newId, newSessionId, newNodeId, newItemId, newRunId } from './src/main/ets/util/Ids';

// ---- 实现类（包内装配与 UI 层诊断使用） ----
export { createModelLayer } from './src/main/ets/ModelLayerFactory';
export { RdbRepository } from './src/main/ets/impl/RdbRepository';
export { TrajectoryStore } from './src/main/ets/TrajectoryStore';
export { AssetSecretStore } from './src/main/ets/impl/AssetSecretStore';
export { SessionExporter } from './src/main/ets/impl/SessionExporter';
export { RootBranchStore, SessionArchiveStore } from './src/main/ets/impl/InternalStoreInterfaces';

// ---- 纯逻辑工具（QA 可直接用 Node 覆盖测试） ----
export {
  nodeToJson, nodeFromJson, nodeSearchText, nodePreview, briefFromNode, buildFtsQuery, likePattern,
  makeSnippet, splitJsonLines
} from './src/main/ets/util/NodeCodec';
export {
  resolveActiveLeafId, buildActivePath, pickDefaultChild, sortByCreated, groupByParent
} from './src/main/ets/util/TrajectoryLogic';

// ---- chat-demo v3 历史格式兼容（Milestone 5；纯逻辑，QA 可 Node 测试） ----
export {
  ChatDemoManifest, ChatDemoIndexEntry, ChatDemoSearchResult, ChatDemoFileEntry, ChatDemoFragment,
  ChatDemoMessage, ChatDemoSession, chatDemoTimeToMillis, millisToChatDemoTime,
  resultsToSources, chatDemoFragmentsToItems, chatDemoSessionToNodes,
  nodeItemsToChatDemoFragments, nodesToChatDemoSession, nodesToChatDemoIndexEntry
} from './src/main/ets/util/ChatDemoCodec';
