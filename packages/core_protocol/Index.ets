/**
 * core_protocol 公开 API（冻结契约）。
 *
 * 前半部分是跨模块共享的契约（类型/接口/工厂），后半部分是本模块实现类与纯函数，
 * 供 UI/QA 直接复用（例如 QA 会用 Node 跑 SseParser 与各 Adapter 的事件解析）。
 */
export {
  ProtocolKind, ThinkingLevel, WebMode, ModelProfile, ToolSpec, WebToolOption, RequestOptions, UsageInfo,
  StreamEventType, ToolCallPhase, StreamPayload, StreamEvent, HttpRequestSpec, ConnectionTestResult
} from './src/main/ets/interfaces/ProtocolTypes';

export { SseFrame, SseParserApi, ProviderAdapter } from './src/main/ets/interfaces/ProviderAdapter';

export {
  StreamCallbacks, StreamHandle, ModelCatalogApi, ProtocolDeps, ProtocolLayer, CreateProtocolLayer
} from './src/main/ets/interfaces/ProtocolLayer';

export { createProtocolLayer, ProtocolLayerImpl, ProtocolStreamRun } from './src/main/ets/ProtocolLayerFactory';

// ---- 实现类（新增导出，不删除任何既有契约导出）----
export { SseParser } from './src/main/ets/SseParser';
export { ModelCatalog } from './src/main/ets/ModelCatalog';
export { DeepSeekResponsesAdapter } from './src/main/ets/adapters/DeepSeekResponsesAdapter';
export { AnthropicAdapter } from './src/main/ets/adapters/AnthropicAdapter';
export { OpenAICompatAdapter } from './src/main/ets/adapters/OpenAICompatAdapter';
export { RcpStreamClient, RcpStreamSink, RcpSimpleResponse, RcpStreamConn } from './src/main/ets/impl/RcpStreamClient';

// ---- 纯逻辑（零平台依赖，可被 tools/logic-tests 直接跑）----
export {
  parseDeepSeekSse, deepSeekSearchStatusText, isDeepSeekTerminalEvent, extractDeepSeekTitle
} from './src/main/ets/adapters/DeepSeekSse';
export { parseAnthropicSse, AnthropicSseState } from './src/main/ets/adapters/AnthropicSse';
export { parseOpenAiSse, OpenAiSseState } from './src/main/ets/adapters/OpenAiSse';
export { NetErrorInfo, mapRcpError, mapHttpStatus, mapThrownError } from './src/main/ets/util/ErrorText';
export { buildLocalTitle, sanitizeTitleText, truncateTitle } from './src/main/ets/util/TitleUtil';
export { joinUrl, isHttpsUrl, bodySnippet } from './src/main/ets/util/UrlUtil';
export {
  newObjectRecord, asRecord, getStr, getNum, getBool, getObj, getObjList, getStrList, hasField, parseRecord,
  stringifyRecord
} from './src/main/ets/util/JsonLite';
