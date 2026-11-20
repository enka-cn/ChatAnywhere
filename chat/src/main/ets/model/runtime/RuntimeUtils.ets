/**
 * 运行时纯解析 / 文本工具（零平台依赖，便于阅读与复用）。
 *
 * 这里只放「输入字符串 / 节点 → 输出纯数据」的函数，不放状态，
 * 因此可以被 StreamTurnExecutor、SearchTraceStore、SessionController 共用。
 */
import { ConversationNode, PageMeta, SearchKind, SourceRef, VendorRaw, estimateNodesTokens } from '@app/core_model';
import { RuntimeSnapshot } from '../ChatRuntimeApi';
import { ToolCallAcc } from './RoundTypes';

// ---------------------------------------------------------------------------
// 厂商原始 JSON 的形状（只取用得到的字段，其余忽略；JSON.parse 后逐字段取，不用 any）
// ---------------------------------------------------------------------------

interface VendorSourceJson {
  title?: string;
  url?: string;
  snippet?: string;
  site_name?: string;
  siteName?: string;
  published_at?: string;
}

interface VendorActionJson {
  type?: string;
  queries?: string[];
  sources?: VendorSourceJson[];
  pattern?: string;
}

interface VendorPageJson {
  url?: string;
  title?: string;
  published_at?: string;
}

interface VendorSearchItemJson {
  id?: string;
  type?: string;
  status?: string;
  kind?: string;
  action?: VendorActionJson;
  page?: VendorPageJson;
  signature?: string;
}

/** 安全 JSON 解析：失败返回 null，绝不抛错。 */
export function safeParse(json: string): Object | null {
  if (json === undefined || json === null || json.trim().length === 0) {
    return null;
  }
  try {
    return JSON.parse(json) as Object;
  } catch (e) {
    return null;
  }
}

/** 把 string 转成 SearchKind（非法值返回 undefined）。 */
export function toSearchKind(raw: string): SearchKind | undefined {
  if (raw === 'search') {
    return 'search';
  }
  if (raw === 'deep_search') {
    return 'deep_search';
  }
  if (raw === 'read_link') {
    return 'read_link';
  }
  if (raw === 'image_search') {
    return 'image_search';
  }
  if (raw === 'deep_image_search') {
    return 'deep_image_search';
  }
  return undefined;
}

/** 从适配器给的 sourcesJson（SourceRef[] JSON）解析出来源。 */
export function parseSourcesJson(json: string): SourceRef[] {
  const out: SourceRef[] = [];
  const parsed = safeParse(json);
  if (parsed === null || !Array.isArray(parsed)) {
    return out;
  }
  const list = parsed as Object[];
  for (const one of list) {
    if (one === null || typeof one !== 'object') {
      continue;
    }
    const rec = one as VendorSourceJson;
    const url: string = rec.url === undefined ? '' : rec.url;
    if (url.length === 0) {
      continue;
    }
    const title: string = rec.title === undefined ? '' : rec.title;
    const snippet: string = rec.snippet === undefined ? '' : rec.snippet;
    const siteName: string = rec.siteName !== undefined ? rec.siteName
      : (rec.site_name !== undefined ? rec.site_name : '');
    const ref: SourceRef = { title: title, url: url, snippet: snippet };
    if (siteName.length > 0) {
      ref.siteName = siteName;
    }
    out.push(ref);
  }
  return out;
}

/** 把 web_search_call item 的原始 JSON 解析成 VendorRaw（同厂商多轮回传用）。 */
export function readVendorRaw(json: string): VendorRaw | null {
  const parsed = safeParse(json);
  if (parsed === null) {
    return null;
  }
  const item = parsed as VendorSearchItemJson;
  const raw: VendorRaw = { provider: 'deepseek' };
  const rawType: string = item.type === undefined ? 'web_search_call' : item.type;
  raw.rawType = rawType;
  if (item.status !== undefined && item.status.length > 0) {
    raw.status = item.status;
  }
  const searchKind = toSearchKind(item.kind === undefined ? '' : item.kind);
  if (searchKind !== undefined) {
    raw.searchKind = searchKind;
  }
  if (item.signature !== undefined && item.signature.length > 0) {
    raw.signature = item.signature;
  }
  if (item.page !== undefined) {
    const page = item.page;
    const url: string = page.url === undefined ? '' : page.url;
    if (url.length > 0) {
      const pageMeta: PageMeta = { url: url, title: page.title === undefined ? '' : page.title };
      if (page.published_at !== undefined && page.published_at.length > 0) {
        pageMeta.publishedAt = page.published_at;
      }
      raw.pageMeta = pageMeta;
    }
  }
  const sources: SourceRef[] = [];
  if (item.action !== undefined && item.action.sources !== undefined) {
    for (const one of item.action.sources) {
      const url: string = one.url === undefined ? '' : one.url;
      if (url.length === 0) {
        continue;
      }
      const source: SourceRef = {
        title: one.title === undefined ? '' : one.title,
        url: url,
        snippet: one.snippet === undefined ? '' : one.snippet
      };
      const siteName: string = one.site_name !== undefined ? one.site_name
        : (one.siteName !== undefined ? one.siteName : '');
      if (siteName.length > 0) {
        source.siteName = siteName;
      }
      sources.push(source);
    }
  }
  if (sources.length > 0) {
    raw.sources = sources;
  }
  return raw;
}

/** 合并两次解析结果：新值缺字段时保留旧值（signature / page 尤其不能丢）。 */
export function mergeVendorRaw(old: VendorRaw | null, next: VendorRaw): VendorRaw {
  if (old === null) {
    return next;
  }
  const merged: VendorRaw = { provider: next.provider };
  merged.rawType = next.rawType !== undefined ? next.rawType : old.rawType;
  merged.status = next.status !== undefined ? next.status : old.status;
  merged.searchKind = next.searchKind !== undefined ? next.searchKind : old.searchKind;
  merged.signature = next.signature !== undefined ? next.signature : old.signature;
  merged.pageMeta = next.pageMeta !== undefined ? next.pageMeta : old.pageMeta;
  if (next.sources !== undefined && next.sources.length > 0) {
    merged.sources = next.sources;
  } else {
    merged.sources = old.sources;
  }
  return merged;
}

/** 节点里的可读正文（用于标题兜底 / 摘要 / 分支预览）。 */
export function collectNodeText(node: ConversationNode): string {
  const chunks: string[] = [];
  for (const item of node.items) {
    if (item.text !== undefined && item.text.trim().length > 0) {
      chunks.push(item.text.trim());
    }
  }
  return chunks.join('\n');
}

/** 从 checkpoint 节点里取出摘要正文。 */
export function checkpointText(node: ConversationNode): string {
  for (const item of node.items) {
    if (item.kind === 'checkpoint_summary' && item.text !== undefined) {
      return item.text;
    }
  }
  return '';
}

/** 百分比文本。 */
export function percentText(ratio: number): string {
  return `${Math.round(Math.max(0, Math.min(1, ratio)) * 100)}%`;
}

/** 工具调用的稳定 key（callId 优先，其次 itemId）。 */
export function toolKey(call: ToolCallAcc): string {
  if (call.callId.length > 0) {
    return call.callId;
  }
  return call.itemId.length > 0 ? call.itemId : 'unknown';
}

/** 复制来源数组（快照外发前深拷贝，避免外部改到运行时内部状态）。 */
export function copySources(list: SourceRef[]): SourceRef[] {
  const out: SourceRef[] = [];
  for (const one of list) {
    const copy: SourceRef = {
      title: one.title,
      url: one.url,
      snippet: one.snippet,
      siteName: one.siteName,
      rerankScore: one.rerankScore,
      authority: one.authority
    };
    out.push(copy);
  }
  return out;
}

/** 记忆条说明（供 UI 直接复用，避免组件里重复拼中文）。 */
export function describeMemoryUsage(snapshot: RuntimeSnapshot): string {
  const ratio: number = Math.round(Math.max(0, Math.min(1, snapshot.memoryRatio)) * 100);
  const cache: number = Math.round(Math.max(0, Math.min(1, snapshot.cacheHitRatio)) * 100);
  return `对话记忆 ${ratio}% · 本轮省钱命中 ${cache}%`;
}

/** 统计未归档节点的估算 token（供记忆条组件在无快照时兜底）。 */
export function estimateActiveTokens(nodes: ConversationNode[]): number {
  const alive: ConversationNode[] = [];
  for (const node of nodes) {
    if (node.archived !== true) {
      alive.push(node);
    }
  }
  return estimateNodesTokens(alive);
}
