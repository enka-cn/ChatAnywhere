/**
 * 轨迹节点构造工厂：把「一轮结果 / 用户输入 / 工具结果」变成可落盘的 ConversationNode。
 *
 * 统一在这里计算 tokenEstimate、生成 id，保证落盘节点形状与历史版本完全一致。
 * 纯构造，不落盘（落盘由 SessionController.appendNode 负责）。
 */
import {
  CanonicalItem, ConversationNode, VendorRaw, estimateNodeTokens, newItemId, newNodeId
} from '@app/core_model';
import { ModelProfile } from '@app/core_protocol';
import { AttachmentRef } from '../ChatRuntimeApi';
import { RoundResult } from './RoundTypes';
import { toolKey } from './RuntimeUtils';

/**
 * 用户提问节点。
 *
 * v3 附件映射（text item 永远排在最前，保证模型先看到用户的话再看附件）：
 * - image → `{kind:'image', fileId:uri, mimeType?}`
 * - file  → `{kind:'file_ref', fileId:uri, mimeType?}`
 * - link  → `{kind:'file_ref', fileId:uri, fallbackSummary:name, mimeType:'text/uri-list'}`
 */
export function buildUserNode(sessionId: string, text: string, parentId: string | null,
  attachments?: AttachmentRef[]): ConversationNode {
  const now: number = Date.now();
  const items: CanonicalItem[] = [];
  if (text.length > 0) {
    const textItem: CanonicalItem = { id: newItemId(), kind: 'text', text: text, createdAt: now };
    items.push(textItem);
  }
  if (attachments !== undefined) {
    for (const one of attachments) {
      items.push(buildAttachmentItem(one, now));
    }
  }
  const node: ConversationNode = {
    nodeId: newNodeId(),
    parentId: parentId,
    sessionId: sessionId,
    role: 'user',
    items: items,
    tokenEstimate: 0,
    createdAt: now
  };
  node.tokenEstimate = estimateNodeTokens(node);
  return node;
}

/** 单个附件 → CanonicalItem（无法识别的 kind 按普通文件处理，绝不丢附件）。 */
function buildAttachmentItem(ref: AttachmentRef, now: number): CanonicalItem {
  if (ref.kind === 'image') {
    const image: CanonicalItem = { id: newItemId(), kind: 'image', fileId: ref.uri, createdAt: now };
    if (ref.mimeType !== undefined && ref.mimeType.length > 0) {
      image.mimeType = ref.mimeType;
    }
    return image;
  }
  if (ref.kind === 'link') {
    const link: CanonicalItem = {
      id: newItemId(),
      kind: 'file_ref',
      fileId: ref.uri,
      fallbackSummary: ref.name,
      mimeType: 'text/uri-list',
      createdAt: now
    };
    return link;
  }
  const file: CanonicalItem = { id: newItemId(), kind: 'file_ref', fileId: ref.uri, createdAt: now };
  if (ref.mimeType !== undefined && ref.mimeType.length > 0) {
    file.mimeType = ref.mimeType;
  }
  return file;
}

/**
 * 助手回复节点。
 * @param includeToolCalls 仅「本轮还要继续执行工具」时为 true，把 tool_call 一并落盘
 */
export function buildAssistantNode(sessionId: string, profile: ModelProfile, parentId: string | null,
  result: RoundResult, includeToolCalls: boolean): ConversationNode {
  const now: number = Date.now();
  const items: CanonicalItem[] = [];
  if (result.reasoning.trim().length > 0) {
    const vendorRaw: VendorRaw = { provider: profile.providerId };
    const reasoningItem: CanonicalItem = {
      id: newItemId(),
      kind: 'reasoning',
      text: result.reasoning,
      createdAt: now,
      vendorRaw: vendorRaw
    };
    items.push(reasoningItem);
  }
  if (result.text.trim().length > 0) {
    const textItem: CanonicalItem = { id: newItemId(), kind: 'text', text: result.text, createdAt: now };
    items.push(textItem);
  }
  for (const webCall of result.webCalls) {
    const raw: VendorRaw | null = webCall.vendorRaw;
    if (raw === null) {
      continue;
    }
    if (raw.provider.length === 0) {
      raw.provider = profile.providerId;
    }
    const item: CanonicalItem = {
      id: webCall.itemId.length > 0 ? webCall.itemId : newItemId(),
      kind: 'web_search_call',
      vendorRaw: raw,
      createdAt: now
    };
    let fallback: string = '';
    if (raw.pageMeta !== undefined) {
      fallback = `[网页：${raw.pageMeta.title}（${raw.pageMeta.url}）]`;
    } else if (raw.sources !== undefined && raw.sources.length > 0) {
      const titles: string[] = [];
      for (const one of raw.sources) {
        if (one.title.length > 0 && titles.length < 5) {
          titles.push(one.title);
        }
      }
      fallback = `[联网检索来源 ${raw.sources.length} 条] ${titles.join('；')}`;
    }
    if (fallback.length > 0) {
      item.fallbackSummary = fallback;
    }
    items.push(item);
  }
  if (includeToolCalls) {
    for (const call of result.toolCalls) {
      const callId: string = toolKey(call);
      const toolItem: CanonicalItem = {
        id: call.itemId.length > 0 ? call.itemId : newItemId(),
        kind: 'tool_call',
        callId: callId,
        toolName: call.toolName,
        argumentsJson: call.argumentsJson.length > 0 ? call.argumentsJson : '{}',
        createdAt: now
      };
      items.push(toolItem);
    }
  }
  const node: ConversationNode = {
    nodeId: newNodeId(),
    parentId: parentId,
    sessionId: sessionId,
    role: 'assistant',
    items: items,
    modelId: profile.modelId,
    providerId: profile.providerId,
    tokenEstimate: 0,
    createdAt: now
  };
  node.tokenEstimate = estimateNodeTokens(node);
  return node;
}

/** 工具结果节点（一个节点可承载同一轮的多条 tool_result）。 */
export function buildToolNode(sessionId: string, parentId: string,
  items: CanonicalItem[]): ConversationNode {
  const node: ConversationNode = {
    nodeId: newNodeId(),
    parentId: parentId,
    sessionId: sessionId,
    role: 'tool',
    items: items,
    tokenEstimate: 0,
    createdAt: Date.now()
  };
  node.tokenEstimate = estimateNodeTokens(node);
  return node;
}
