/**
 * 一轮对话的编排器：发送 / 重试 / 编辑重发 / 手动整理记忆。
 *
 * 职责：忙碌互斥、密钥校验、用户节点落盘、委派 StreamTurnExecutor 生成，
 * 以及失败时的中文提示与「finally 收尾」（清流式字段 + 刷新消息列表）。
 * 生成细节（流式事件、落盘、工具循环、压缩）全部在 StreamTurnExecutor 及其协作者里。
 */
import { ConversationNode } from '@app/core_model';
import { ModelProfile } from '@app/core_protocol';
import { AttachmentRef } from '../ChatRuntimeApi';
import { RuntimeHost } from './RuntimeTypes';
import { SessionController } from './SessionController';
import { SettingsController } from './SettingsController';
import { StreamTurnExecutor } from './StreamTurnExecutor';

/** 无 Key 时统一的直白中文引导。 */
const NO_KEY_HINT: string = '还没有配置模型密钥，请到「设置」里填写后再聊';

export class TurnCoordinator {
  private host: RuntimeHost;
  private sessions: SessionController;
  private settings: SettingsController;
  private turn: StreamTurnExecutor;
  /** 正在生成 / 整理中（门面 isBusy 用它做输入互斥）。 */
  private busy: boolean = false;

  constructor(host: RuntimeHost, sessions: SessionController, settings: SettingsController,
    turn: StreamTurnExecutor) {
    this.host = host;
    this.sessions = sessions;
    this.settings = settings;
    this.turn = turn;
  }

  /** 是否正忙（正在生成或正在整理记忆）。 */
  isBusy(): boolean {
    const snapshot = this.host.snapshot();
    return this.busy || snapshot.streaming || snapshot.compacting;
  }

  /** 发送一条消息（v3 附件随用户节点一起落盘，附件-only 也允许发送）。 */
  async send(text: string, attachments?: AttachmentRef[]): Promise<void> {
    const snapshot = this.host.snapshot();
    const content: string = text.trim();
    const hasAttachments: boolean = attachments !== undefined && attachments.length > 0;
    if (content.length === 0 && !hasAttachments) {
      return;
    }
    let profile: ModelProfile | null = await this.settings.ensureProfile();
    if (profile === null) {
      return;
    }
    snapshot.errorMessage = '';
    snapshot.noticeMessage = '';
    if (this.sessions.currentSessionId().length === 0) {
      await this.sessions.openLastOrNewSession();
      await this.settings.refreshPersonaState();
      // 新会话可能套用了默认角色的模型，这里重新取一次，避免第一条消息用旧模型。
      const refreshed: ModelProfile | null = await this.settings.ensureProfile();
      if (refreshed !== null) {
        profile = refreshed;
      }
    }
    const hasKey: boolean = await this.settings.checkHasApiKey(profile);
    snapshot.hasApiKey = hasKey;
    if (!hasKey) {
      snapshot.errorMessage = NO_KEY_HINT;
      this.host.notifyNow();
      return;
    }
    this.busy = true;
    this.turn.resetTurn();
    snapshot.searchTrace = [];
    snapshot.sources = [];
    try {
      const leafId: string | null = await this.host.appServices().requireModel().trajectory
        .getActiveLeafId(this.sessions.currentSessionId());
      const userNode: ConversationNode = await this.sessions.appendUserNode(content, leafId, attachments);
      await this.turn.runAssistantTurn(profile, userNode.nodeId);
    } catch (e) {
      snapshot.errorMessage = `发送失败：${(e as Error).message}`;
      snapshot.streaming = false;
      this.host.notifyNow();
    } finally {
      this.busy = false;
      snapshot.streaming = false;
      snapshot.streamingText = '';
      snapshot.streamingReasoning = '';
      await this.sessions.refreshNodes(true);
    }
  }

  /** 重新生成最后一条助手回复（生成新分支，旧回答保留）。 */
  async retryLast(): Promise<void> {
    const snapshot = this.host.snapshot();
    const profile: ModelProfile | null = await this.settings.ensureProfile();
    if (profile === null) {
      return;
    }
    const hasKey: boolean = await this.settings.checkHasApiKey(profile);
    snapshot.hasApiKey = hasKey;
    if (!hasKey) {
      snapshot.errorMessage = NO_KEY_HINT;
      this.host.notifyNow();
      return;
    }
    const trajectory = this.host.appServices().requireModel().trajectory;
    const path: ConversationNode[] = await trajectory.activePath(this.sessions.currentSessionId());
    let lastUser: ConversationNode | null = null;
    for (let i = path.length - 1; i >= 0; i--) {
      if (path[i].role === 'user') {
        lastUser = path[i];
        break;
      }
    }
    if (lastUser === null) {
      snapshot.noticeMessage = '还没有可以重新生成的内容';
      this.host.notifyNow();
      return;
    }
    this.busy = true;
    this.turn.resetTurn();
    snapshot.errorMessage = '';
    snapshot.noticeMessage = '';
    snapshot.searchTrace = [];
    try {
      // 先用 forkFrom 在该条提问下建一个空的助手占位节点（自动激活为新分支），
      // 生成完成后用同一个 nodeId UPSERT 填内容：旧回答作为兄弟分支保留，可随时切回。
      let reuseNodeId: string = '';
      try {
        reuseNodeId = await trajectory.forkFrom(lastUser.nodeId, 'assistant', '');
      } catch (e) {
        reuseNodeId = '';
      }
      await this.turn.runAssistantTurn(profile, lastUser.nodeId, reuseNodeId);
    } catch (e) {
      snapshot.errorMessage = `重新生成失败：${(e as Error).message}`;
    } finally {
      this.busy = false;
      snapshot.streaming = false;
      await this.sessions.refreshNodes(true);
    }
  }

  /**
   * 重新生成指定某条回答（长按老消息用）。
   * 语义与 retryLast 相同：在该回答所属的提问下 fork 一条新的助手分支，旧分支完整保留。
   */
  async regenerateNode(nodeId: string): Promise<void> {
    const snapshot = this.host.snapshot();
    const profile: ModelProfile | null = await this.settings.ensureProfile();
    if (profile === null) {
      return;
    }
    const trajectory = this.host.appServices().requireModel().trajectory;
    const source: ConversationNode | null = await trajectory.getNode(nodeId);
    if (source === null || source.role !== 'assistant' || source.parentId === null) {
      snapshot.noticeMessage = '这条回答暂时不能重新生成';
      this.host.notifyNow();
      return;
    }
    const hasKey: boolean = await this.settings.checkHasApiKey(profile);
    snapshot.hasApiKey = hasKey;
    if (!hasKey) {
      snapshot.errorMessage = NO_KEY_HINT;
      this.host.notifyNow();
      return;
    }
    this.busy = true;
    this.turn.resetTurn();
    snapshot.errorMessage = '';
    snapshot.noticeMessage = '';
    snapshot.searchTrace = [];
    try {
      let reuseNodeId: string = '';
      try {
        reuseNodeId = await trajectory.forkFrom(source.parentId, 'assistant', '');
      } catch (e) {
        reuseNodeId = '';
      }
      await this.turn.runAssistantTurn(profile, source.parentId, reuseNodeId);
    } catch (e) {
      snapshot.errorMessage = `重新生成失败：${(e as Error).message}`;
    } finally {
      this.busy = false;
      snapshot.streaming = false;
      await this.sessions.refreshNodes(true);
    }
  }

  /** 编辑历史提问并生成新分支（原分支保留）。 */
  async editUserNode(nodeId: string, newText: string): Promise<void> {
    const snapshot = this.host.snapshot();
    const content: string = newText.trim();
    if (content.length === 0) {
      return;
    }
    const profile: ModelProfile | null = await this.settings.ensureProfile();
    if (profile === null) {
      return;
    }
    const trajectory = this.host.appServices().requireModel().trajectory;
    const source: ConversationNode | null = await trajectory.getNode(nodeId);
    if (source === null) {
      snapshot.errorMessage = '找不到要修改的这条提问，可能已被清理';
      this.host.notifyNow();
      return;
    }
    const hasKey: boolean = await this.settings.checkHasApiKey(profile);
    snapshot.hasApiKey = hasKey;
    if (!hasKey) {
      snapshot.errorMessage = NO_KEY_HINT;
      this.host.notifyNow();
      return;
    }
    this.busy = true;
    this.turn.resetTurn();
    snapshot.errorMessage = '';
    snapshot.noticeMessage = '';
    try {
      const userNode: ConversationNode = await this.sessions.appendEditedUserNode(content, source.parentId);
      await this.turn.runAssistantTurn(profile, userNode.nodeId);
    } catch (e) {
      snapshot.errorMessage = `修改提问失败：${(e as Error).message}`;
    } finally {
      this.busy = false;
      snapshot.streaming = false;
      await this.sessions.refreshNodes(true);
    }
  }

  /** 手动整理一次对话记忆（缓存感知压缩；失败只给中文提示，不打断对话）。 */
  async compactNow(): Promise<void> {
    const snapshot = this.host.snapshot();
    const profile: ModelProfile | null = await this.settings.ensureProfile();
    if (profile === null) {
      return;
    }
    this.busy = true;
    try {
      const path: ConversationNode[] = await this.host.appServices().requireModel().trajectory
        .activePath(this.sessions.currentSessionId());
      await this.turn.compactMemory(profile, path, false);
    } catch (e) {
      snapshot.noticeMessage = `这次没有整理对话记忆：${(e as Error).message}`;
      snapshot.compacting = false;
      this.host.notifyNow();
    } finally {
      this.busy = false;
      await this.sessions.refreshNodes(true);
    }
  }
}
