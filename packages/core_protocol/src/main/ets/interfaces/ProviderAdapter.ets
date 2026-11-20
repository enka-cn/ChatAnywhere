/**
 * 厂商适配器契约（Blueprint §3.2）。
 *
 * 关键规则：
 * - 同厂商：web_search_call / signature 必须原样透传 vendorRaw；
 * - 异构厂商：自动降级使用 fallbackSummary，严禁因未知字段导致 400；
 * - Responses API 无 [DONE]，终止事件为 response.completed。
 */
import { ConversationNode } from '@app/core_model';
import {
  ConnectionTestResult, HttpRequestSpec, ModelProfile, ProtocolKind, RequestOptions, StreamEvent
} from './ProtocolTypes';

/** 一个 SSE 原始帧。 */
export interface SseFrame {
  /** `event:` 字段（可能为空）。 */
  event: string;
  /** 多行 data 拼接后的内容。 */
  data: string;
  id?: string;
  retry?: number;
}

/** 增量 SSE 解析器：只负责"字节流 → 帧"，与厂商语义无关。 */
export interface SseParserApi {
  /** 输入任意分片（可能是半个 UTF-8 字符/半个帧），返回已闭合的帧。 */
  feed(chunk: string): SseFrame[];
  /** 流结束时冲出的残留帧。 */
  flush(): SseFrame[];
  reset(): void;
}

/** 适配器接口。 */
export interface ProviderAdapter {
  readonly protocol: ProtocolKind;

  /**
   * 将统一 Trajectory 投影为目标厂商请求体。
   * @param profile 模型配置（含 baseUrl / 协议差异）
   * @param nodes 根→叶的活动路径（已按时间升序）
   * @param options 思考档位 / 系统提示词 / 工具 / 联网
   */
  buildRequest(profile: ModelProfile, nodes: ConversationNode[], options: RequestOptions): HttpRequestSpec;

  /** 将原生 SSE 事件帧解析为统一 StreamEvent（Responses API 无 [DONE]）。 */
  parseSseEvent(eventName: string, dataJson: string): StreamEvent[];

  /** 连接探测（可选实现，默认由 ProtocolLayer 用 /models 探测）。 */
  buildPingRequest?(profile: ModelProfile): HttpRequestSpec;

  /** 解析探测响应。 */
  parsePingResponse?(statusCode: number, body: string): ConnectionTestResult;
}
