/**
 * 记忆压缩用的摘要器：真正调协议层生成中文摘要，失败由 core_context 压缩器回退到本地摘要。
 *
 * 摘要请求与正常对话隔离：thinkingLevel='off'、webMode='off'，带 45s 兜底超时，
 * 超时 / 无输出 / 协议错误都会 reject，由调用方决定回退方式。
 */
import {
  CanonicalItem, ConversationNode, estimateNodeTokens, newItemId, newNodeId
} from '@app/core_model';
import { ModelProfile, RequestOptions, StreamCallbacks, StreamEvent, StreamHandle } from '@app/core_protocol';
import { TextSummarizer } from '@app/core_context';
import { RuntimeHost } from './RuntimeTypes';
import { collectNodeText } from './RuntimeUtils';

/** 一次摘要最多塞给模型的对话字符数（避免为了整理记忆先把窗口撑爆）。 */
const SUMMARY_TRANSCRIPT_LIMIT: number = 6000;
/** 摘要请求的兜底超时（ms）。 */
const SUMMARY_TIMEOUT_MS: number = 45000;

/** 把一段历史压成给摘要模型的纯文本。 */
function buildTranscript(nodes: ConversationNode[], limit: number): string {
  const lines: string[] = [];
  for (const node of nodes) {
    const text: string = collectNodeText(node);
    if (text.length === 0) {
      continue;
    }
    let role: string = '对话';
    if (node.role === 'user') {
      role = '用户';
    } else if (node.role === 'assistant') {
      role = '助手';
    } else if (node.role === 'tool') {
      role = '工具';
    }
    lines.push(`${role}：${text.length > 600 ? `${text.substring(0, 600)}…` : text}`);
  }
  let joined: string = lines.join('\n');
  if (joined.length > limit) {
    joined = joined.substring(joined.length - limit);
    joined = `（较早的部分已省略）\n${joined}`;
  }
  return joined;
}

export class ProtocolTextSummarizer implements TextSummarizer {
  private host: RuntimeHost;
  private profile: ModelProfile;

  constructor(host: RuntimeHost, profile: ModelProfile) {
    this.host = host;
    this.profile = profile;
  }

  summarize(nodes: ConversationNode[]): Promise<string> {
    const transcript: string = buildTranscript(nodes, SUMMARY_TRANSCRIPT_LIMIT);
    if (transcript.trim().length === 0) {
      return Promise.resolve('');
    }
    return new Promise<string>((resolve, reject) => {
      const instruction: CanonicalItem = {
        id: newItemId(),
        kind: 'text',
        text: `请把下面这段对话压缩成不超过 300 字的中文「对话记忆摘要」，必须保留：关键事实、人名与数字、已达成的结论、还没做完的事。只输出摘要正文，不要客套话。\n\n${transcript}`,
        createdAt: Date.now()
      };
      const promptNode: ConversationNode = {
        nodeId: newNodeId(),
        parentId: null,
        sessionId: 'compact',
        role: 'user',
        items: [instruction],
        tokenEstimate: 0,
        createdAt: Date.now()
      };
      promptNode.tokenEstimate = estimateNodeTokens(promptNode);
      const options: RequestOptions = {
        thinkingLevel: 'off',
        webMode: 'off',
        systemPrompt: '你是对话记忆整理助手，只输出中文摘要正文。'
      };
      let text: string = '';
      let settled: boolean = false;
      let timer: number = -1;
      let handle: StreamHandle | null = null;
      const finish = (ok: boolean, message: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        if (handle !== null) {
          try {
            handle.cancel();
          } catch (e) {
            // 收尾取消失败不影响摘要结果
          }
          handle = null;
        }
        if (ok) {
          resolve(text.trim());
        } else {
          reject(new Error(message));
        }
      };
      timer = setTimeout(() => {
        finish(false, '整理对话记忆超时');
      }, SUMMARY_TIMEOUT_MS);
      const callbacks: StreamCallbacks = {
        onEvent: (event: StreamEvent) => {
          if (event.type === 'text_delta') {
            text += event.payload.delta === undefined ? '' : event.payload.delta;
          }
        },
        onError: (message: string, errorCode: string, retriable: boolean) => {
          finish(false, message);
        },
        onDone: () => {
          if (text.trim().length > 0) {
            finish(true, '');
          } else {
            finish(false, '模型没有返回摘要');
          }
        }
      };
      try {
        handle = this.host.appServices().requireProtocol().send(this.profile, [promptNode], options, callbacks);
      } catch (e) {
        finish(false, (e as Error).message);
      }
    });
  }
}
