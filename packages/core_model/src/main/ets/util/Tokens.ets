/**
 * 本地 Token 估算（纯函数，零平台依赖，可 Node 测试）。
 *
 * 不追求与厂商 tokenizer 完全一致，只用于「记忆条」进度与压缩决策，
 * 误差由 CacheAwareCompactor 的安全系数吸收。
 * 经验系数：中文 ≈ 1.5 字/token；ASCII ≈ 4 字符/token；每个 item 结构开销 4 token。
 */
import { CanonicalItem, ConversationNode } from '../interfaces/ModelTypes';

const CJK_REGEX: RegExp = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]/g;

/** 文本 token 估算。 */
export function estimateText(text: string): number {
  if (!text) {
    return 0;
  }
  const cjkHits = text.match(CJK_REGEX);
  const cjkCount = cjkHits === null ? 0 : cjkHits.length;
  const restCount = text.length - cjkCount;
  const tokens = cjkCount / 1.5 + restCount / 4;
  return Math.max(1, Math.ceil(tokens));
}

/** 单 item token 估算（含结构开销）。 */
export function estimateItemTokens(item: CanonicalItem): number {
  const overhead = 4;
  switch (item.kind) {
    case 'text':
    case 'reasoning':
    case 'checkpoint_summary':
      return overhead + estimateText(item.text ?? '');
    case 'tool_call':
      return overhead + estimateText(item.toolName ?? '') + estimateText(item.argumentsJson ?? '');
    case 'tool_result':
      return overhead + estimateText(item.text ?? '') + (item.isError === true ? 2 : 0);
    case 'web_search_call': {
      let n = overhead + 8;
      const raw = item.vendorRaw;
      if (raw !== undefined && raw.sources !== undefined) {
        for (const s of raw.sources) {
          n += estimateText(s.title) + estimateText(s.snippet);
        }
      }
      return n;
    }
    case 'image':
      return 256;
    case 'file_ref':
      return overhead + estimateText(item.fileId ?? '');
    default:
      return overhead + estimateText(item.text ?? '');
  }
}

/** 节点 token 估算。 */
export function estimateNodeTokens(node: ConversationNode): number {
  let total = 6;
  for (const item of node.items) {
    total += estimateItemTokens(item);
  }
  return total;
}

/** 一批节点 token 估算。 */
export function estimateNodesTokens(nodes: ConversationNode[]): number {
  let total = 0;
  for (const n of nodes) {
    total += n.tokenEstimate > 0 ? n.tokenEstimate : estimateNodeTokens(n);
  }
  return total;
}

/** 上下文占用比例 0..1（用于记忆条）。 */
export function contextUsageRatio(tokens: number, contextWindow: number): number {
  if (contextWindow <= 0) {
    return 0;
  }
  return Math.min(1, tokens / contextWindow);
}

/** 缓存命中率 0..1（cachedTokens / promptTokens）。 */
export function cacheHitRatio(cachedTokens: number, promptTokens: number): number {
  if (promptTokens <= 0) {
    return 0;
  }
  return Math.min(1, Math.max(0, cachedTokens / promptTokens));
}
