/**
 * 会话控制器：会话 CRUD、当前会话与记忆摘要、节点加载缓存、分支操作、标题回写。
 *
 * 所有会改变 UI 的写入都「先落盘再刷新快照」；节点缓存 nodeList 由本模块独占，
 * 门面的 nodes() 只读委派到这里，避免多处各自维护一份消息列表。
 */
import {
  ConversationNode, SessionMeta, SettingsKeys
} from '@app/core_model';
import { ModelProfile } from '@app/core_protocol';
import { BranchOption, AttachmentRef } from '../ChatRuntimeApi';
import { RuntimeHost } from './RuntimeTypes';
import { RoundResult } from './RoundTypes';
import { buildUserNode } from './NodeFactory';
import { checkpointText, collectNodeText } from './RuntimeUtils';

/** 新会话标题。 */
const DEFAULT_TITLE: string = '新对话';

export class SessionController {
  private host: RuntimeHost;
  /** 已落盘节点（活动路径）缓存。 */
  private nodeList: ConversationNode[] = [];
  private sessionIdValue: string = '';
  /** 当前会话记忆摘要（重启后从最近 checkpoint 恢复）。 */
  private memorySummaryText: string = '';

  constructor(host: RuntimeHost) {
    this.host = host;
  }

  // -------------------------------------------------------------------------
  // 只读访问
  // -------------------------------------------------------------------------

  /** 当前会话节点列表（门面 nodes() 直接返回该引用）。 */
  nodes(): ConversationNode[] {
    return this.nodeList;
  }

  currentSessionId(): string {
    return this.sessionIdValue;
  }

  memorySummary(): string {
    return this.memorySummaryText;
  }

  setMemorySummary(text: string): void {
    this.memorySummaryText = text;
  }

  // -------------------------------------------------------------------------
  // 会话 CRUD
  // -------------------------------------------------------------------------

  listSessions(): Promise<SessionMeta[]> {
    return this.host.appServices().requireModel().repo.listSessions(50);
  }

  /** 恢复上次会话；没有就新建（无可用模型时抛中文错误）。 */
  async openLastOrNewSession(): Promise<void> {
    const repo = this.host.appServices().requireModel().repo;
    const lastId: string = await repo.getString(SettingsKeys.LAST_SESSION_ID, '');
    if (lastId.length > 0) {
      const meta: SessionMeta | null = await repo.getSession(lastId);
      if (meta !== null) {
        await this.applySession(meta);
        return;
      }
    }
    const profile: ModelProfile | null = await this.host.ensureProfile();
    if (profile === null) {
      throw new Error('还没有可用的模型配置');
    }
    await this.createNewSessionInternal(profile);
  }

  /** 新建会话（门面已确保运行时就绪）。 */
  async newSession(): Promise<string> {
    const profile: ModelProfile | null = await this.host.ensureProfile();
    if (profile === null) {
      return '';
    }
    const id: string = await this.createNewSessionInternal(profile);
    this.host.notifyNow();
    return id;
  }

  /** 切换会话；切换前先停掉上一段会话的生成，避免内容写串。 */
  async openSession(sessionId: string): Promise<void> {
    if (sessionId.length === 0 || sessionId === this.sessionIdValue) {
      await this.refreshNodes(true);
      return;
    }
    let meta: SessionMeta | null = null;
    try {
      meta = await this.host.appServices().requireModel().repo.getSession(sessionId);
    } catch (e) {
      this.host.snapshot().errorMessage = `打开这段对话失败：${(e as Error).message}`;
      this.host.notifyNow();
      return;
    }
    if (meta === null) {
      this.host.snapshot().errorMessage = '找不到这段对话，可能已经被删除了';
      this.host.notifyNow();
      return;
    }
    this.host.stopGeneration();
    await this.applySession(meta);
    const snapshot = this.host.snapshot();
    snapshot.errorMessage = '';
    snapshot.noticeMessage = '';
    snapshot.streaming = false;
    snapshot.streamingText = '';
    snapshot.streamingReasoning = '';
    this.host.resetTurnTrace();
    await this.refreshNodes(true);
  }

  async deleteSession(sessionId: string): Promise<void> {
    const repo = this.host.appServices().requireModel().repo;
    await repo.deleteSession(sessionId);
    if (sessionId === this.sessionIdValue) {
      const profile: ModelProfile | null = await this.host.ensureProfile();
      if (profile !== null) {
        await this.createNewSessionInternal(profile);
      }
    }
    await this.refreshNodes(true);
  }

  async renameSession(sessionId: string, title: string): Promise<void> {
    const trimmed: string = title.trim();
    if (trimmed.length === 0) {
      return;
    }
    await this.host.appServices().requireModel().repo.renameSession(sessionId, trimmed);
    if (sessionId === this.sessionIdValue) {
      this.host.snapshot().title = trimmed;
      this.host.notifyNow();
    }
  }

  // -------------------------------------------------------------------------
  // 会话状态与节点刷新
  // -------------------------------------------------------------------------

  /** 应用会话元信息并加载记忆摘要。 */
  async applySession(meta: SessionMeta): Promise<void> {
    this.sessionIdValue = meta.sessionId;
    const snapshot = this.host.snapshot();
    snapshot.sessionId = meta.sessionId;
    snapshot.title = meta.title;
    this.memorySummaryText = await this.loadMemorySummary(meta.sessionId);
    this.host.metrics().usageInputTokens = 0;
    this.host.metrics().cacheHitRatio = 0;
    try {
      await this.host.appServices().requireModel().repo.putString(SettingsKeys.LAST_SESSION_ID, meta.sessionId);
    } catch (e) {
      // 记住"上次会话"只是偏好，失败不影响本次使用
    }
  }

  /** 从最近一条 checkpoint 节点恢复记忆摘要（重启后仍在）。 */
  private async loadMemorySummary(sessionId: string): Promise<string> {
    try {
      const nodes: ConversationNode[] = await this.host.appServices().requireModel()
        .trajectory.sessionNodes(sessionId);
      let latest: ConversationNode | null = null;
      for (const node of nodes) {
        for (const item of node.items) {
          if (item.kind === 'checkpoint_summary') {
            if (latest === null || node.createdAt >= latest.createdAt) {
              latest = node;
            }
            break;
          }
        }
      }
      return latest === null ? '' : checkpointText(latest);
    } catch (e) {
      return '';
    }
  }

  private async createNewSessionInternal(profile: ModelProfile): Promise<string> {
    const repo = this.host.appServices().requireModel().repo;
    const meta: SessionMeta = await repo.createSession(DEFAULT_TITLE, profile.modelId, profile.providerId);
    this.sessionIdValue = meta.sessionId;
    const snapshot = this.host.snapshot();
    snapshot.sessionId = meta.sessionId;
    snapshot.title = meta.title.length > 0 ? meta.title : DEFAULT_TITLE;
    this.nodeList = [];
    this.memorySummaryText = '';
    this.host.metrics().usageInputTokens = 0;
    this.host.metrics().cacheHitRatio = 0;
    snapshot.nodeCount = 0;
    snapshot.streamingText = '';
    snapshot.streamingReasoning = '';
    snapshot.searchTrace = [];
    snapshot.sources = [];
    this.host.resetTurnTrace();
    // v3：新对话继承全局默认角色的模型与思考档位（写入设置 + 快照）。
    await this.host.applyPersonaDefaults();
    try {
      await repo.putString(SettingsKeys.LAST_SESSION_ID, meta.sessionId);
    } catch (e) {
      // 忽略：下次启动退化为新建会话
    }
    return meta.sessionId;
  }

  /** 刷新消息列表与记忆条指标。 */
  async refreshNodes(notifyNowFlag: boolean): Promise<void> {
    try {
      this.nodeList = await this.host.appServices().requireModel().trajectory.activePath(this.sessionIdValue);
    } catch (e) {
      // 读列表失败时保留上一份，避免界面抖动
    }
    this.host.snapshot().nodeCount = this.nodeList.length;
    this.host.recomputeMetrics();
    if (notifyNowFlag) {
      this.host.notifyNow();
    } else {
      this.host.notifyImmediate();
    }
  }

  // -------------------------------------------------------------------------
  // 节点落盘 / 路径
  // -------------------------------------------------------------------------

  /** 落盘 + 设为父节点的激活子分支（先落盘再通知 UI 的红线在这里统一保证）。 */
  async appendNode(node: ConversationNode): Promise<void> {
    const trajectory = this.host.appServices().requireModel().trajectory;
    await trajectory.append(node);
    try {
      await trajectory.switchBranch(node.sessionId, node.parentId, node.nodeId);
    } catch (e) {
      // 激活失败时下次仍可按「最新子节点」兜底
    }
  }

  /** 用户提问：构造 + 落盘 + 刷新列表（返回落盘节点；v3 附件一并映射进 items）。 */
  async appendUserNode(text: string, parentId: string | null,
    attachments?: AttachmentRef[]): Promise<ConversationNode> {
    const node: ConversationNode = buildUserNode(this.sessionIdValue, text, parentId, attachments);
    await this.appendNode(node);
    await this.refreshNodes(false);
    return node;
  }

  /**
   * 编辑历史提问：在原提问的父节点下开一条新分支并刷新列表。
   * 返回新提问节点，供调用方继续生成助手回复。
   */
  async appendEditedUserNode(newText: string, parentId: string | null): Promise<ConversationNode> {
    const node: ConversationNode = buildUserNode(this.sessionIdValue, newText, parentId);
    await this.appendNode(node);
    this.host.snapshot().noticeMessage = '已经按你的修改开了一条新分支，原来的回答还能切换回去';
    await this.refreshNodes(false);
    return node;
  }

  /** 刷新会话 updated_at（只影响会话列表排序，失败不影响对话）。 */
  async touchSession(): Promise<void> {
    try {
      await this.host.appServices().requireModel().repo.touchSession(this.sessionIdValue);
    } catch (e) {
      // 会话 updated_at 只是列表排序用；saveNode 里也会刷新，失败不影响本轮
    }
  }

  /** 从叶子回溯到根（按 parentId，不依赖 activeChildId）。 */
  async pathTo(leafId: string | null): Promise<ConversationNode[]> {
    if (leafId === null || leafId.length === 0) {
      return [];
    }
    const trajectory = this.host.appServices().requireModel().trajectory;
    const chain: ConversationNode[] = [];
    const visited: Set<string> = new Set<string>();
    let cursor: string | null = leafId;
    while (cursor !== null && cursor.length > 0) {
      if (visited.has(cursor)) {
        break;
      }
      visited.add(cursor);
      const node: ConversationNode | null = await trajectory.getNode(cursor);
      if (node === null) {
        break;
      }
      chain.push(node);
      cursor = node.parentId;
    }
    chain.reverse();
    return chain;
  }

  /** 真正发给模型的上下文：只保留未归档节点（压缩后旧节点不再进入活跃上下文）。 */
  async requestPathTo(leafId: string | null): Promise<ConversationNode[]> {
    const full: ConversationNode[] = await this.pathTo(leafId);
    const out: ConversationNode[] = [];
    for (const node of full) {
      if (node.archived !== true) {
        out.push(node);
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // 分支
  // -------------------------------------------------------------------------

  /** 某个节点同父的所有兄弟分支（checkpoint 与空预览按兜底文案处理）。 */
  async branches(nodeId: string): Promise<BranchOption[]> {
    const out: BranchOption[] = [];
    try {
      const trajectory = this.host.appServices().requireModel().trajectory;
      const node: ConversationNode | null = await trajectory.getNode(nodeId);
      if (node === null) {
        return out;
      }
      const briefs = await this.host.appServices().requireModel().repo
        .loadChildren(this.sessionIdValue, node.parentId);
      for (const brief of briefs) {
        let preview: string = '';
        // 优先取分支首条内容的真实预览（archived 的分支同样可切换，不能跳过）。
        try {
          const child: ConversationNode | null = await trajectory.getNode(brief.nodeId);
          if (child !== null) {
            // 压缩产生的 checkpoint 不是用户可以选的分支，跳过。
            let isCheckpoint: boolean = false;
            for (const item of child.items) {
              if (item.kind === 'checkpoint_summary') {
                isCheckpoint = true;
                break;
              }
            }
            if (isCheckpoint) {
              continue;
            }
            preview = collectNodeText(child);
          }
        } catch (e) {
          preview = '';
        }
        if (preview.length === 0) {
          preview = brief.preview;
        }
        preview = preview.trim();
        if (preview.length > 40) {
          preview = `${preview.substring(0, 40)}…`;
        }
        if (preview.length === 0) {
          preview = brief.nodeId === nodeId ? '当前这条' : '另一条分支';
        }
        const option: BranchOption = {
          childId: brief.nodeId,
          preview: preview,
          active: brief.nodeId === nodeId,
          createdAt: brief.createdAt
        };
        out.push(option);
      }
    } catch (e) {
      // 分支菜单失败时返回空列表，UI 会提示"没有其它分支"
    }
    return out;
  }

  /** 切换活动分支（先停生成，避免在切换过程中继续写节点）。 */
  async switchBranch(parentId: string, childId: string): Promise<void> {
    if (childId.length === 0) {
      return;
    }
    this.host.stopGeneration();
    const pid: string | null = parentId.length === 0 ? null : parentId;
    try {
      await this.host.appServices().requireModel().trajectory.switchBranch(this.sessionIdValue, pid, childId);
      const snapshot = this.host.snapshot();
      snapshot.noticeMessage = '已经切换到另一条分支';
      snapshot.errorMessage = '';
      this.host.metrics().usageInputTokens = 0;
    } catch (e) {
      this.host.snapshot().errorMessage = `切换分支失败：${(e as Error).message}`;
    }
    await this.refreshNodes(true);
  }

  // -------------------------------------------------------------------------
  // 标题回写
  // -------------------------------------------------------------------------

  /** 标题：优先用服务端标题，否则第一轮本地生成一个。 */
  async applyTitle(profile: ModelProfile, result: RoundResult, node: ConversationNode,
    path: ConversationNode[]): Promise<void> {
    const fromServer: string = result.title.trim();
    if (fromServer.length > 0) {
      await this.writeTitle(fromServer);
      return;
    }
    const current: string = this.host.snapshot().title;
    if (current.length > 0 && current !== DEFAULT_TITLE) {
      return;
    }
    let firstUserText: string = '';
    for (const one of path) {
      if (one.role === 'user') {
        firstUserText = collectNodeText(one);
        break;
      }
    }
    const assistantText: string = collectNodeText(node);
    try {
      const title: string = await this.host.appServices().requireProtocol()
        .synthesizeTitle(profile, firstUserText, assistantText);
      if (title.trim().length > 0) {
        await this.writeTitle(title.trim());
      }
    } catch (e) {
      this.writeLocalTitle(firstUserText);
    }
  }

  private async writeTitle(title: string): Promise<void> {
    this.host.snapshot().title = title;
    try {
      await this.host.appServices().requireModel().repo.renameSession(this.sessionIdValue, title);
    } catch (e) {
      // 标题只是展示，写失败不影响对话
    }
  }

  private writeLocalTitle(firstUserText: string): void {
    const trimmed: string = firstUserText.trim();
    if (trimmed.length === 0) {
      return;
    }
    const title: string = trimmed.length > 16 ? `${trimmed.substring(0, 16)}…` : trimmed;
    this.host.snapshot().title = title;
    this.host.appServices().requireModel().repo.renameSession(this.sessionIdValue, title).catch(() => {
      // 忽略标题落盘失败
    });
  }
}
