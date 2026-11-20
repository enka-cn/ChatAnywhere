/**
 * chat-demo 历史格式 v3（DeepSeek 官方 chat-demo 的归档格式）与 ChatAnyWhere 统一 Item 树的双向映射。
 *
 * 纯逻辑、零平台依赖，可被 Node 直接测试。
 *
 * 事实来源：`docs/API_REFERENCE.md` §12「chat-demo 兼容性（历史导出格式 v3）」：
 * - 结构：`manifest.json`（`{export_format_version:3}`）+ `chat_session_index.json` + `chat_sessions/<id>.json`
 *   + `chat_sessions/<id>_files/...`（图片原件，本项目暂无原件文件）；
 * - `ChatMessage`：数字 id、`parent_id`（必须小于自身 id）、`role: 'USER'|'ASSISTANT'`、`fragments[]` 判别联合；
 * - `current_message_id` 决定活动分支，其余节点默认选中 id 最大的子消息；
 * - 时间格式 RFC 3339 UTC（`Z` 结尾）。
 *
 * 映射策略（尽力而为，不追求 1:1）：
 * - 导入：REQUEST/RESPONSE/TEMPLATE_RESPONSE→text、THINK→reasoning、TOOL_SEARCH/TOOL_OPEN/READ_LINK/
 *   TOOL_IMAGE_SEARCH→web_search_call（保留来源与 signature）、FILE→image/file_ref、TIP/CONTENT_RISK→text，
 *   未知 fragment 转文字摘要并写 warning；始终生成新 sessionId（不覆盖本地数据）。
 * - 导出：text→REQUEST/RESPONSE、reasoning→THINK、web_search_call→TOOL_SEARCH/TOOL_OPEN、工具→TIP、
 *   image/file_ref→FILE；system 节点不导出（chat-demo 无角色承载），其子节点向上就近挂到被导出祖先。
 */
import {
  CanonicalItem,
  ConversationNode,
  ItemKind,
  NodeRole,
  PageMeta,
  SessionMeta,
  SourceRef,
  VendorRaw
} from '../interfaces/ModelTypes';
import { estimateNodeTokens } from './Tokens';
import { newNodeId, newItemId } from './Ids';
import { indexNodes, resolveActiveLeafId, sortByCreated } from './TrajectoryLogic';

/** chat-demo v3 归档清单。 */
export interface ChatDemoManifest {
  export_format_version?: number;
}

/** chat-demo v3 会话索引项。 */
export interface ChatDemoIndexEntry {
  id?: string;
  title?: string | null;
  pinned?: boolean;
  message_count?: number;
  inserted_at?: string;
  updated_at?: string;
}

/** chat-demo v3 搜索结果（也用于 READ_LINK 的 results）。 */
export interface ChatDemoSearchResult {
  url?: string;
  title?: string;
  snippet?: string;
  published_at?: string | null;
  site_name?: string | null;
  /** READ_LINK 的加密网页签名（同厂商多轮需原样回传）。 */
  signature?: string;
}

/** chat-demo v3 文件条目。 */
export interface ChatDemoFileEntry {
  id?: string;
  file_name?: string;
  file_size?: number;
  token_usage?: number | null;
  inserted_at?: string;
  export_path?: string | null;
  is_image?: boolean;
  width?: number;
  height?: number;
}

/** chat-demo v3 fragment 判别联合（只声明我们关心的字段，其余忽略）。 */
export interface ChatDemoFragment {
  type?: string;
  content?: string;
  elapsed_secs?: number | null;
  ratio?: number;
  status?: string;
  pattern?: string;
  queries?: string[];
  results?: ChatDemoSearchResult[];
  url?: string;
  title?: string;
  snippet?: string;
  site_name?: string;
  published_at?: string;
  signature?: string;
  files?: ChatDemoFileEntry[];
  style?: string;
}

/** chat-demo v3 消息。 */
export interface ChatDemoMessage {
  id?: number;
  parent_id?: number | null;
  role?: string;
  status?: string;
  thinking_enabled?: boolean;
  search_enabled?: boolean;
  accumulated_token_usage?: number | null;
  inserted_at?: string;
  fragments?: ChatDemoFragment[];
}

/** chat-demo v3 单个会话文件。 */
export interface ChatDemoSession {
  id?: string;
  title?: string | null;
  pinned?: boolean;
  current_message_id?: number | null;
  inserted_at?: string;
  updated_at?: string;
  messages?: ChatDemoMessage[];
}

const ARK_UNKNOWN_FRAGMENT_PREFIX: string = '未识别的记录';

// ---------------------------------------------------------------------------
// 时间（RFC 3339 UTC 字符串 ↔ 毫秒）
// ---------------------------------------------------------------------------

/** chat-demo 时间字符串 → 毫秒；非法/缺失返回 0。 */
export function chatDemoTimeToMillis(value: string | null | undefined): number {
  if (value === undefined || value === null || value.length === 0) {
    return 0;
  }
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? 0 : parsed;
}

/** 毫秒 → chat-demo 时间字符串（UTC、Z 结尾）。 */
export function millisToChatDemoTime(millis: number): string {
  const safe = millis > 0 ? millis : Date.now();
  return new Date(safe).toISOString();
}

// ---------------------------------------------------------------------------
// 构造小工具
// ---------------------------------------------------------------------------

function makeTextItem(text: string, kind: ItemKind): CanonicalItem {
  const item: CanonicalItem = {
    id: newItemId(),
    kind: kind,
    text: text,
    createdAt: Date.now()
  };
  return item;
}

function chatDemoRoleToNodeRole(role: string): NodeRole {
  return role === 'USER' ? 'user' : 'assistant';
}

/** chat-demo 搜索结果 → 模型来源引用（保留可展示字段）。 */
export function resultsToSources(results: ChatDemoSearchResult[] | undefined): SourceRef[] {
  const out: SourceRef[] = [];
  if (results === undefined || results === null) {
    return out;
  }
  for (const result of results) {
    const url = result.url ?? '';
    const title = result.title ?? '';
    const snippet = result.snippet ?? '';
    if (url.length === 0 && title.length === 0) {
      continue;
    }
    const source: SourceRef = { title: title, url: url, snippet: snippet };
    const siteName = result.site_name;
    if (siteName !== undefined && siteName !== null && siteName.length > 0) {
      source.siteName = siteName;
    }
    out.push(source);
  }
  return out;
}

/** 来源引用 → chat-demo 搜索结果。 */
function sourcesToResults(sources: SourceRef[] | undefined): ChatDemoSearchResult[] {
  const out: ChatDemoSearchResult[] = [];
  if (sources === undefined || sources === null) {
    return out;
  }
  for (const source of sources) {
    const result: ChatDemoSearchResult = {
      url: source.url,
      title: source.title,
      snippet: source.snippet
    };
    if (source.siteName !== undefined) {
      result.site_name = source.siteName;
    }
    out.push(result);
  }
  return out;
}

/** 从 READ_LINK / 任意 results 里取第一个 signature（同厂商原样回传关键字段）。 */
function firstSignature(fragment: ChatDemoFragment): string | undefined {
  if (fragment.signature !== undefined && fragment.signature.length > 0) {
    return fragment.signature;
  }
  if (fragment.results === undefined || fragment.results === null) {
    return undefined;
  }
  for (const result of fragment.results) {
    if (result.signature !== undefined && result.signature.length > 0) {
      return result.signature;
    }
  }
  return undefined;
}

function makeWebSearchItem(fragment: ChatDemoFragment, searchKind: string): CanonicalItem {
  const raw: VendorRaw = {
    provider: 'deepseek',
    searchKind: searchKind === 'read_link' ? 'read_link' : 'search'
  };
  if (searchKind === 'image_search') {
    raw.searchKind = 'image_search';
  } else if (searchKind === 'deep_search') {
    raw.searchKind = 'deep_search';
  }
  const results = fragment.results;
  const sources = resultsToSources(results);
  if (sources.length > 0) {
    raw.sources = sources;
  }
  if (fragment.status !== undefined && fragment.status !== null && fragment.status.length > 0) {
    raw.status = fragment.status;
  }
  if (fragment.url !== undefined || fragment.title !== undefined) {
    const page: PageMeta = {
      url: fragment.url ?? '',
      title: fragment.title ?? ''
    };
    if (fragment.published_at !== undefined && fragment.published_at !== null && fragment.published_at.length > 0) {
      page.publishedAt = fragment.published_at;
    }
    raw.pageMeta = page;
  }
  const signature = firstSignature(fragment);
  if (signature !== undefined) {
    raw.signature = signature;
  }
  const item: CanonicalItem = {
    id: newItemId(),
    kind: 'web_search_call',
    vendorRaw: raw,
    createdAt: Date.now()
  };
  if (fragment.snippet !== undefined && fragment.snippet !== null && fragment.snippet.length > 0) {
    item.fallbackSummary = fragment.snippet;
  } else if (fragment.queries !== undefined && fragment.queries.length > 0) {
    item.fallbackSummary = `搜索：${fragment.queries.join(' / ')}`;
  }
  return item;
}

/**
 * chat-demo fragments → 统一 items。
 * 未知类型统一转文字摘要并写 warning（绝不丢内容、绝不抛错）。
 */
export function chatDemoFragmentsToItems(
  fragments: ChatDemoFragment[] | undefined,
  warnings: string[]
): CanonicalItem[] {
  const items: CanonicalItem[] = [];
  if (fragments === undefined || fragments === null) {
    return items;
  }
  for (const fragment of fragments) {
    const type = fragment.type ?? '';
    if (type === 'REQUEST' || type === 'RESPONSE' || type === 'TEMPLATE_RESPONSE') {
      const content = fragment.content ?? '';
      if (content.length > 0) {
        items.push(makeTextItem(content, 'text'));
      }
      continue;
    }
    if (type === 'THINK') {
      const content = fragment.content ?? '';
      if (content.length > 0) {
        items.push(makeTextItem(content, 'reasoning'));
      }
      continue;
    }
    if (type === 'TIP' || type === 'CONTENT_RISK') {
      const content = fragment.content ?? '';
      if (content.length > 0) {
        items.push(makeTextItem(content, 'text'));
      }
      continue;
    }
    if (type === 'PARTIAL_FILE_READ') {
      const ratio = fragment.ratio ?? 0;
      items.push(makeTextItem(`[文件读取进度 ${ratio}%]`, 'text'));
      continue;
    }
    if (type === 'TOOL_SEARCH') {
      items.push(makeWebSearchItem(fragment, 'search'));
      continue;
    }
    if (type === 'TOOL_OPEN') {
      items.push(makeWebSearchItem(fragment, 'read_link'));
      continue;
    }
    if (type === 'READ_LINK') {
      items.push(makeWebSearchItem(fragment, 'read_link'));
      continue;
    }
    if (type === 'TOOL_IMAGE_SEARCH') {
      items.push(makeWebSearchItem(fragment, 'image_search'));
      continue;
    }
    if (type === 'TOOL_FIND') {
      const item: CanonicalItem = {
        id: newItemId(),
        kind: 'tool_call',
        toolName: 'find',
        argumentsJson: fragment.pattern ?? '',
        createdAt: Date.now()
      };
      items.push(item);
      continue;
    }
    if (type === 'FILE') {
      const files = fragment.files ?? [];
      for (const file of files) {
        const isImage = file.is_image === true;
        const item: CanonicalItem = {
          id: newItemId(),
          kind: isImage ? 'image' : 'file_ref',
          fileId: file.id ?? file.export_path ?? file.file_name ?? '',
          createdAt: Date.now()
        };
        items.push(item);
      }
      continue;
    }
    // 未知 fragment：转文字摘要 + warning，绝不丢内容
    const summary = fragment.content ?? '';
    items.push(makeTextItem(`[${ARK_UNKNOWN_FRAGMENT_PREFIX}：${type.length > 0 ? type : '空'}类型] ${summary}`, 'text'));
    warnings.push(`遇到未识别的片段类型「${type.length > 0 ? type : '空'}」，已转为文字摘要`);
  }
  return items;
}

/**
 * chat-demo 单会话 → 统一节点树（始终生成全新 nodeId；sessionId 由调用方指定）。
 * current_message_id 对应的分支会被激活，其余父节点默认取最新子节点（与 chat-demo 规则一致）。
 */
export function chatDemoSessionToNodes(
  session: ChatDemoSession,
  sessionId: string,
  warnings: string[]
): ConversationNode[] {
  const rawMessages = session.messages;
  if (rawMessages === undefined || rawMessages === null || rawMessages.length === 0) {
    return [];
  }
  const ordered: ChatDemoMessage[] = [];
  for (const message of rawMessages) {
    ordered.push(message);
  }
  ordered.sort((a: ChatDemoMessage, b: ChatDemoMessage): number => {
    const left = a.id ?? 0;
    const right = b.id ?? 0;
    return left - right;
  });
  const idToNodeId: Map<number, string> = new Map<number, string>();
  for (const message of ordered) {
    const numId = message.id ?? 0;
    if (!idToNodeId.has(numId)) {
      idToNodeId.set(numId, newNodeId());
    }
  }
  const baseTime = chatDemoTimeToMillis(session.inserted_at);
  const now = Date.now();
  const nodes: ConversationNode[] = [];
  const numToNode: Map<number, ConversationNode> = new Map<number, ConversationNode>();
  const numToParent: Map<number, number | null> = new Map<number, number | null>();
  for (const message of ordered) {
    const numId = message.id ?? 0;
    let parentId: string | null = null;
    const parentNum = message.parent_id;
    if (parentNum !== undefined && parentNum !== null) {
      const mapped = idToNodeId.get(parentNum);
      if (mapped !== undefined) {
        parentId = mapped;
      } else {
        warnings.push(`有一条消息的上级（编号 ${parentNum}）缺失，已作为新开头导入`);
      }
    }
    const role = chatDemoRoleToNodeRole(message.role ?? '');
    if (message.role !== 'USER' && message.role !== 'ASSISTANT') {
      warnings.push(`消息角色「${message.role ?? ''}」不是 USER/ASSISTANT，已按助手消息导入`);
    }
    let createdAt = chatDemoTimeToMillis(message.inserted_at);
    if (createdAt <= 0) {
      createdAt = (baseTime > 0 ? baseTime : now) + numId;
    }
    const items = chatDemoFragmentsToItems(message.fragments, warnings);
    const node: ConversationNode = {
      nodeId: idToNodeId.get(numId) ?? newNodeId(),
      parentId: parentId,
      sessionId: sessionId,
      role: role,
      items: items,
      tokenEstimate: 0,
      createdAt: createdAt
    };
    const usage = message.accumulated_token_usage;
    if (usage !== undefined && usage !== null && usage > 0) {
      node.tokenEstimate = usage;
    } else {
      node.tokenEstimate = estimateNodeTokens(node);
    }
    const status = message.status ?? '';
    if (status === 'FAILED' || status === 'TIMEOUT' || status === 'CONTENT_FILTER' ||
      status === 'CONTEXT_LENGTH_EXCEEDED') {
      if (node.items.length === 0) {
        node.items.push(makeTextItem(`[这条回复未能完成：${status}]`, 'text'));
      }
      warnings.push('有消息状态不是正常完成，已保留可见提示');
    }
    numToNode.set(numId, node);
    numToParent.set(numId, message.parent_id === undefined ? null : message.parent_id);
    nodes.push(node);
  }
  applyCurrentBranch(numToNode, numToParent, session.current_message_id);
  return nodes;
}

/** 按 current_message_id 标注活动分支（沿父链把子节点设为父的 activeChildId）。 */
function applyCurrentBranch(
  numToNode: Map<number, ConversationNode>,
  numToParent: Map<number, number | null>,
  currentMessageId: number | null | undefined
): void {
  if (currentMessageId === undefined || currentMessageId === null) {
    return;
  }
  let cursor: number | null = currentMessageId;
  const visited: Set<number> = new Set<number>();
  while (cursor !== null) {
    if (visited.has(cursor)) {
      break;
    }
    visited.add(cursor);
    const child = numToNode.get(cursor);
    if (child === undefined) {
      break;
    }
    const parentNum = numToParent.get(cursor);
    if (parentNum === undefined || parentNum === null) {
      break;
    }
    const parentNode = numToNode.get(parentNum);
    if (parentNode === undefined) {
      break;
    }
    parentNode.activeChildId = child.nodeId;
    cursor = parentNum;
  }
}

// ---------------------------------------------------------------------------
// 导出方向：统一 Item 树 → chat-demo v3
// ---------------------------------------------------------------------------

/** items → chat-demo fragments（按角色决定 text 落在 REQUEST 还是 RESPONSE）。 */
export function nodeItemsToChatDemoFragments(
  items: CanonicalItem[],
  isUser: boolean
): ChatDemoFragment[] {
  const fragments: ChatDemoFragment[] = [];
  for (const item of items) {
    if (item.kind === 'text' || item.kind === 'checkpoint_summary') {
      const text = item.text ?? '';
      if (text.length === 0) {
        continue;
      }
      const fragment: ChatDemoFragment = { type: isUser ? 'REQUEST' : 'RESPONSE', content: text };
      fragments.push(fragment);
      continue;
    }
    if (item.kind === 'reasoning') {
      const text = item.text ?? '';
      if (text.length === 0) {
        continue;
      }
      const fragment: ChatDemoFragment = { type: 'THINK', content: text, elapsed_secs: null };
      fragments.push(fragment);
      continue;
    }
    if (item.kind === 'tool_call') {
      const content = `调用工具 ${item.toolName ?? ''}：${item.argumentsJson ?? ''}`;
      const fragment: ChatDemoFragment = { type: 'TIP', content: content, style: 'INFO' };
      fragments.push(fragment);
      continue;
    }
    if (item.kind === 'tool_result') {
      const tipFragment: ChatDemoFragment = {
        type: 'TIP',
        content: item.text ?? '',
        style: item.isError === true ? 'WARNING' : 'INFO'
      };
      fragments.push(tipFragment);
      continue;
    }
    if (item.kind === 'web_search_call') {
      fragments.push(webSearchItemToFragment(item));
      continue;
    }
    if (item.kind === 'image' || item.kind === 'file_ref') {
      const entry: ChatDemoFileEntry = {
        id: item.fileId ?? item.id,
        file_name: item.fileId ?? '',
        is_image: item.kind === 'image'
      };
      const fragment: ChatDemoFragment = { type: 'FILE', files: [entry] };
      fragments.push(fragment);
      continue;
    }
    const fallback: ChatDemoFragment = {
      type: 'TIP',
      content: item.fallbackSummary ?? item.text ?? '',
      style: 'INFO'
    };
    fragments.push(fallback);
  }
  return fragments;
}

/** web_search_call item → chat-demo TOOL_SEARCH / TOOL_OPEN。 */
function webSearchItemToFragment(item: CanonicalItem): ChatDemoFragment {
  const raw = item.vendorRaw;
  const searchKind = raw === undefined || raw === null ? '' : (raw.searchKind ?? '');
  if (searchKind === 'read_link') {
    const page = raw === undefined || raw === null ? undefined : raw.pageMeta;
    const fragment: ChatDemoFragment = {
      type: 'TOOL_OPEN',
      status: raw === undefined || raw === null ? 'FINISHED' : (raw.status ?? 'FINISHED')
    };
    if (page !== undefined && page !== null) {
      fragment.url = page.url;
      fragment.title = page.title;
      if (page.publishedAt !== undefined) {
        fragment.published_at = page.publishedAt;
      }
    }
    if (item.fallbackSummary !== undefined) {
      fragment.snippet = item.fallbackSummary;
    }
    if (raw !== undefined && raw !== null && raw.signature !== undefined) {
      fragment.signature = raw.signature;
    }
    return fragment;
  }
  const sources = raw === undefined || raw === null ? undefined : raw.sources;
  const results = sourcesToResults(sources);
  const fragment: ChatDemoFragment = {
    type: 'TOOL_SEARCH',
    status: raw === undefined || raw === null ? 'FINISHED' : (raw.status ?? 'FINISHED'),
    results: results,
    queries: item.fallbackSummary !== undefined ? [item.fallbackSummary] : []
  };
  return fragment;
}

/** 找 node 最近一个会被导出的祖先的数字 id（跳过 system 节点）。 */
function findExportedAncestorId(
  node: ConversationNode,
  idMap: Map<string, number>,
  allById: Map<string, ConversationNode>
): number | null {
  let cursor: string | null = node.parentId;
  let guard = 0;
  while (cursor !== null && cursor.length > 0 && guard < 10000) {
    guard += 1;
    const mapped = idMap.get(cursor);
    if (mapped !== undefined) {
      return mapped;
    }
    const parent = allById.get(cursor);
    if (parent === undefined) {
      return null;
    }
    cursor = parent.parentId;
  }
  return null;
}

/** 节点是否含推理/联网片段（用于 chat-demo 的 thinking_enabled / search_enabled）。 */
function hasReasoning(node: ConversationNode): boolean {
  for (const item of node.items) {
    if (item.kind === 'reasoning') {
      return true;
    }
  }
  return false;
}

function hasWebSearch(node: ConversationNode): boolean {
  for (const item of node.items) {
    if (item.kind === 'web_search_call') {
      return true;
    }
  }
  return false;
}

/**
 * 统一会话 → chat-demo v3 会话文件内容。
 * @param activeLeafId 由 NodeRepositoryApi.getActiveLeafId 得到，用于写 current_message_id。
 */
export function nodesToChatDemoSession(
  meta: SessionMeta,
  nodes: ConversationNode[],
  activeLeafId: string | null
): ChatDemoSession {
  const sorted = sortByCreated(nodes);
  const exported: ConversationNode[] = [];
  for (const node of sorted) {
    if (node.role !== 'system') {
      exported.push(node);
    }
  }
  const idMap: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < exported.length; i++) {
    idMap.set(exported[i].nodeId, i + 1);
  }
  const allById = indexNodes(nodes);
  const messages: ChatDemoMessage[] = [];
  for (const node of exported) {
    const numId = idMap.get(node.nodeId) ?? 0;
    const isUser = node.role === 'user';
    const message: ChatDemoMessage = {
      id: numId,
      parent_id: findExportedAncestorId(node, idMap, allById),
      role: isUser ? 'USER' : 'ASSISTANT',
      status: 'FINISHED',
      inserted_at: millisToChatDemoTime(node.createdAt),
      fragments: nodeItemsToChatDemoFragments(node.items, isUser)
    };
    message.thinking_enabled = hasReasoning(node);
    message.search_enabled = hasWebSearch(node);
    message.accumulated_token_usage = node.tokenEstimate;
    messages.push(message);
  }
  let currentId: number | null = null;
  if (activeLeafId !== null && activeLeafId.length > 0) {
    const mapped = idMap.get(activeLeafId);
    currentId = mapped === undefined ? null : mapped;
  }
  if (currentId === null) {
    const leafResolved = resolveActiveLeafId(nodes, null);
    if (leafResolved !== null) {
      const mapped = idMap.get(leafResolved);
      currentId = mapped === undefined ? null : mapped;
    }
  }
  if (currentId === null && messages.length > 0) {
    const last = messages[messages.length - 1].id;
    currentId = last === undefined ? null : last;
  }
  const session: ChatDemoSession = {
    id: meta.sessionId,
    title: meta.title,
    pinned: meta.pinned === true,
    current_message_id: currentId,
    inserted_at: millisToChatDemoTime(meta.createdAt),
    updated_at: millisToChatDemoTime(meta.updatedAt),
    messages: messages
  };
  return session;
}

/** 会话索引项（chat_session_index.json 数组元素）。 */
export function nodesToChatDemoIndexEntry(
  meta: SessionMeta,
  messageCount: number
): ChatDemoIndexEntry {
  const entry: ChatDemoIndexEntry = {
    id: meta.sessionId,
    title: meta.title,
    pinned: meta.pinned === true,
    message_count: messageCount,
    inserted_at: millisToChatDemoTime(meta.createdAt),
    updated_at: millisToChatDemoTime(meta.updatedAt)
  };
  return entry;
}

