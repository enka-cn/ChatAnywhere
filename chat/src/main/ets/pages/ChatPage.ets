/**
 * 主对话页（v3 · Pura X Max 双栏 / 折叠自适应）。
 *
 * 展开态（≥600vp）：224vp 会话侧栏 + 中间对话画布（最大 660vp）+ 按需 280vp 信源栏。
 * 折叠态（<600vp）：单栏 + 左侧覆盖抽屉 + 底部半模态快切。
 *
 * 视觉全部走 `Theme / Layout / Icons`；输入框「+」只做附件；
 * 长按消息保留复制 / 编辑 / 重试 / 分支 / 沉淀技能。
 */
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { ConversationNode, SessionMeta, SourceRef } from '@app/core_model';
import { ModelProfile, ThinkingLevel } from '@app/core_protocol';
import { AppServices } from '../app/AppServices';
import { Breakpoint, BreakpointWatcher } from '../app/Breakpoint';
import { PersonaProfile, SkillChipState } from '../app/PersonaStore';
import { Icons, Layout, Theme } from '../app/Theme';
import { AttachmentRef, BranchOption, RuntimeSnapshot } from '../model/ChatRuntimeApi';
import { getChatRuntime, getChatRuntimeConcrete } from '../model/RuntimeHolder';
import { ChatRuntime } from '../model/ChatRuntime';
import {
  asChatParams, ChatPageParams, RouteUrls, SettingsPageParams, SkillCreatorParams, SkillManagerParams
} from '../app/Routes';
import { MarkdownBlock } from '../components/MarkdownBlock';
import { StreamingMessage } from '../components/StreamingMessage';
import { MemoryGaugeBar } from '../components/MemoryGaugeBar';
import { ModelCapsule } from '../components/ModelCapsule';
import { BranchSelector } from '../components/BranchSelector';
import { MessageDataSource } from '../components/MessageDataSource';
import { SessionDrawer } from '../components/SessionDrawer';
import { SourcePane } from '../components/SourcePane';
import { AttachSheet } from '../components/AttachSheet';
import { IconBtn } from '../components/IconBtn';
import { PersonaSheet } from '../components/PersonaSheet';

/** 底部半模态模式。 */
const SHEET_PERSONA: string = 'persona';
const SHEET_ATTACH: string = 'attach';
const SHEET_SKILLS: string = 'skills';
const SHEET_SOURCES: string = 'sources';
const SHEET_BRANCH: string = 'branch';

/** 侧栏入口目标。 */
const NAV_CREATOR: number = 0;
const NAV_SKILLS: number = 1;
const NAV_SETTINGS: number = 2;

/** 消息分支信息（用于 < 1/3 > 切换）。 */
interface BranchInfo {
  nodeId: string;
  parentId: string;
  count: number;
  index: number;
  prevChildId: string;
  nextChildId: string;
}

/** 附件芯片展示项（图标 + 名称）。 */
interface AttachmentChipView {
  label: string;
  icon: Resource;
}

/** 取节点正文。 */
function nodeText(node: ConversationNode): string {
  const parts: string[] = [];
  for (const item of node.items) {
    if ((item.kind === 'text' || item.kind === 'checkpoint_summary')
      && item.text !== undefined && item.text.length > 0) {
      parts.push(item.text);
    }
  }
  return parts.join('\n\n');
}

/** 取节点思考过程。 */
function nodeReasoning(node: ConversationNode): string {
  const parts: string[] = [];
  for (const item of node.items) {
    if (item.kind === 'reasoning' && item.text !== undefined && item.text.length > 0) {
      parts.push(item.text);
    }
  }
  return parts.join('\n');
}

/** 取节点里的联网来源。 */
function nodeSources(node: ConversationNode): SourceRef[] {
  const out: SourceRef[] = [];
  const seen: Set<string> = new Set<string>();
  for (const item of node.items) {
    if (item.kind !== 'web_search_call' || item.vendorRaw === undefined) {
      continue;
    }
    const sources: SourceRef[] | undefined = item.vendorRaw.sources;
    if (sources === undefined) {
      continue;
    }
    for (const one of sources) {
      if (one.url.length === 0 || seen.has(one.url) || out.length >= 8) {
        continue;
      }
      seen.add(one.url);
      out.push(one);
    }
  }
  return out;
}

/** 取节点里调用的技能名。 */
function nodeToolNames(node: ConversationNode): string[] {
  const out: string[] = [];
  for (const item of node.items) {
    if (item.kind === 'tool_call' && item.toolName !== undefined && item.toolName.length > 0) {
      out.push(item.toolName);
    }
  }
  return out;
}

/** 取节点上的附件芯片（运行时已把附件落成 image / file_ref item）。 */
function nodeAttachmentChips(node: ConversationNode): AttachmentChipView[] {
  const out: AttachmentChipView[] = [];
  for (const item of node.items) {
    if (item.kind === 'image') {
      const uri: string = item.fileId === undefined ? '' : item.fileId;
      out.push({ label: uri.length > 0 ? fileNameOf(uri) : '图片', icon: Icons.image });
    } else if (item.kind === 'file_ref') {
      const uri: string = item.fileId === undefined ? '' : item.fileId;
      const isLink: boolean = item.mimeType !== undefined && item.mimeType === 'text/uri-list';
      let label: string = isLink ? hostOf(uri) : fileNameOf(uri);
      if (item.text !== undefined && item.text.length > 0) {
        label = item.text;
      }
      if (item.fallbackSummary !== undefined && item.fallbackSummary.length > 0) {
        label = item.fallbackSummary;
      }
      out.push({ label: label.length > 0 ? label : '附件', icon: isLink ? Icons.link : Icons.file });
    }
  }
  return out;
}

/** 站点短名。 */
function hostOf(url: string): string {
  let host: string = url;
  if (host.startsWith('https://')) {
    host = host.substring(8);
  } else if (host.startsWith('http://')) {
    host = host.substring(7);
  }
  const slash: number = host.indexOf('/');
  if (slash > 0) {
    host = host.substring(0, slash);
  }
  return host.length > 0 ? host : url;
}

/** 从 uri 里取文件名。 */
function fileNameOf(uri: string): string {
  const slash: number = uri.lastIndexOf('/');
  let name: string = slash >= 0 ? uri.substring(slash + 1) : uri;
  const query: number = name.indexOf('?');
  if (query > 0) {
    name = name.substring(0, query);
  }
  try {
    name = decodeURIComponent(name);
  } catch (e) {
    // 保留原始名
  }
  return name.length > 0 ? name : '附件';
}

@Entry
@Component
struct ChatPage {
  @State private snapshot: RuntimeSnapshot = getChatRuntime().snapshot();
  @State private nodes: ConversationNode[] = [];
  @State private ready: boolean = false;
  @State private inputText: string = '';
  @State private editingNodeId: string = '';
  @State private notice: string = '';
  @State private hiddenError: string = '';

  // 响应式布局
  @State private unfolded: boolean = false;
  @State private sidebarCollapsed: boolean = false;
  /** 抽屉节点是否常驻可见（退场动画结束后才置 false，避免 if 卸载闪变）。 */
  @State private drawerVisible: boolean = false;
  /** 抽屉层唯一横向位移：-W（收起）…0（展开）；拖动时直接把 offsetX 写进来。 */
  @State private drawerTranslateX: number = -Layout.drawerMaxWidth;
  /** 遮罩透明度：与位移同步（1 → 0），拖动时不包动画直接跟手。 */
  @State private scrimOpacity: number = 0;
  @State private sourcePaneOpen: boolean = false;
  @State private sourceNodeId: string = '';

  // 单实例半模态（按模式切换内容，避免同一页面多个 bindSheet 抢状态）
  @State private sheetOpen: boolean = false;
  @State private sheetMode: string = SHEET_PERSONA;

  // 数据
  @State private sessions: SessionMeta[] = [];
  @State private profiles: ModelProfile[] = [];
  @State private personas: PersonaProfile[] = [];
  @State private activePersonaId: string = '';
  @State private branchInfos: BranchInfo[] = [];
  @State private branchOptions: BranchOption[] = [];
  @State private branchParentId: string = '';
  @State private pendingAttachments: AttachmentRef[] = [];
  @State private expandedThinkingId: string = '';
  @State private menuNodeId: string = '';
  @State private inputFocused: boolean = false;

  private runtime: ChatRuntime = getChatRuntimeConcrete();
  private scroller: Scroller = new Scroller();
  private dataSource: MessageDataSource = new MessageDataSource();
  private subId: number = -1;
  private watcher: BreakpointWatcher | null = null;
  private autoFollow: boolean = true;
  private busyScroll: boolean = false;
  private noticeTimer: number = -1;
  private branchSignature: string = '';
  private branchRefreshing: boolean = false;

  aboutToAppear(): void {
    this.subId = this.runtime.subscribe((snapshot: RuntimeSnapshot) => {
      this.applySnapshot(snapshot);
    });
    this.unfolded = Breakpoint.isUnfolded(this.getUIContext());
    this.watcher = Breakpoint.watch(this.getUIContext(), (unfolded: boolean) => {
      this.unfolded = unfolded;
      if (unfolded) {
        this.setDrawerOpen(false);
      } else {
        this.sourcePaneOpen = false;
      }
    });
    this.bootstrap();
  }

  aboutToDisappear(): void {
    if (this.subId >= 0) {
      this.runtime.unsubscribe(this.subId);
      this.subId = -1;
    }
    if (this.watcher !== null) {
      this.watcher.dispose();
      this.watcher = null;
    }
    if (this.noticeTimer >= 0) {
      clearTimeout(this.noticeTimer);
      this.noticeTimer = -1;
    }
  }

  onPageShow(): void {
    if (!this.ready) {
      return;
    }
    this.refreshAfterReturn();
  }

  private async refreshAfterReturn(): Promise<void> {
    await this.runtime.refreshSettings();
    await this.refreshAux();
    await this.refreshSessions();
    this.applySnapshot(this.runtime.snapshot());
  }

  // -------------------------------------------------------------------------
  // 初始化
  // -------------------------------------------------------------------------

  private async bootstrap(): Promise<void> {
    let params: ChatPageParams = { sessionId: '' };
    try {
      params = asChatParams(this.getUIContext().getRouter().getParams() as Object);
    } catch (e) {
      params = { sessionId: '' };
    }
    try {
      await AppServices.get().waitReady();
      if (params.sessionId.length > 0) {
        await this.runtime.openSession(params.sessionId);
      } else {
        await this.runtime.init();
      }
    } catch (e) {
      // 运行时把中文原因写进快照
    }
    await this.refreshAux();
    await this.refreshSessions();
    this.applySnapshot(this.runtime.snapshot());
    if (params.draftText !== undefined && params.draftText.length > 0) {
      this.inputText = params.draftText;
    }
    this.ready = true;
    this.scrollToBottomSoon();
  }

  private async refreshAux(): Promise<void> {
    const services = AppServices.get();
    try {
      this.profiles = services.requireProtocol().catalog.listProfiles();
    } catch (e) {
      this.profiles = [];
    }
    await this.refreshPersonas();
  }

  private async refreshPersonas(): Promise<void> {
    const services = AppServices.get();
    if (!services.hasPersonas()) {
      this.personas = [];
      this.activePersonaId = '';
      return;
    }
    try {
      this.personas = services.requirePersonas().list();
      this.activePersonaId = await services.requirePersonas()
        .sessionPersonaId(this.runtime.currentSessionId());
    } catch (e) {
      this.personas = [];
      this.activePersonaId = '';
    }
  }

  private async refreshSessions(): Promise<void> {
    try {
      this.sessions = await this.runtime.listSessions();
    } catch (e) {
      this.sessions = [];
    }
  }

  private applySnapshot(snapshot: RuntimeSnapshot): void {
    this.snapshot = snapshot;
    this.syncNodes();
    if (snapshot.noticeMessage.length > 0 && snapshot.noticeMessage !== this.notice) {
      this.notice = snapshot.noticeMessage;
      if (this.noticeTimer >= 0) {
        clearTimeout(this.noticeTimer);
      }
      this.noticeTimer = setTimeout(() => {
        this.noticeTimer = -1;
        this.notice = '';
      }, 4000);
    }
    if (snapshot.streaming && this.autoFollow) {
      this.scrollToBottomSoon();
    }
  }

  private syncNodes(): void {
    const list: ConversationNode[] = this.runtime.nodes();
    if (list.length === this.nodes.length) {
      let same: boolean = true;
      for (let i = 0; i < list.length; i++) {
        if (list[i].nodeId !== this.nodes[i].nodeId
          || list[i].items.length !== this.nodes[i].items.length
          || nodeText(list[i]).length !== nodeText(this.nodes[i]).length) {
          same = false;
          break;
        }
      }
      if (same) {
        return;
      }
    }
    this.nodes = list.slice();
    this.dataSource.update(this.nodes);
    this.refreshBranchesIfNeeded();
    if (this.autoFollow) {
      this.scrollToBottomSoon();
    }
  }

  /** 只在节点结构变化时重算分支信息（避免每个流式帧都查库）。 */
  private refreshBranchesIfNeeded(): void {
    let sign: string = '';
    for (const node of this.nodes) {
      if (node.role === 'assistant') {
        sign += `${node.nodeId},`;
      }
    }
    if (sign === this.branchSignature || this.branchRefreshing) {
      return;
    }
    this.branchSignature = sign;
    this.refreshBranches();
  }

  private async refreshBranches(): Promise<void> {
    this.branchRefreshing = true;
    const infos: BranchInfo[] = [];
    try {
      for (const node of this.nodes) {
        if (node.role !== 'assistant') {
          continue;
        }
        try {
          const options: BranchOption[] = await this.runtime.branches(node.nodeId);
          if (options.length <= 1) {
            continue;
          }
          const sorted: BranchOption[] = options.slice();
          sorted.sort((a: BranchOption, b: BranchOption): number => a.createdAt - b.createdAt);
          let activeIndex: number = 0;
          for (let i = 0; i < sorted.length; i++) {
            if (sorted[i].active) {
              activeIndex = i;
              break;
            }
          }
          const info: BranchInfo = {
            nodeId: node.nodeId,
            parentId: node.parentId === null ? '' : node.parentId,
            count: sorted.length,
            index: activeIndex + 1,
            prevChildId: sorted[activeIndex > 0 ? activeIndex - 1 : activeIndex].childId,
            nextChildId: sorted[activeIndex < sorted.length - 1 ? activeIndex + 1 : activeIndex].childId
          };
          infos.push(info);
        } catch (e) {
          // 单条分支读取失败不影响其它消息
        }
      }
      this.branchInfos = infos;
    } finally {
      this.branchRefreshing = false;
    }
  }

  private branchInfoFor(nodeId: string): BranchInfo | null {
    for (const info of this.branchInfos) {
      if (info.nodeId === nodeId) {
        return info;
      }
    }
    return null;
  }

  private branchLabel(nodeId: string): string {
    const info: BranchInfo | null = this.branchInfoFor(nodeId);
    if (info === null) {
      return '1/1';
    }
    return `${info.index}/${info.count}`;
  }

  private branchCanGo(nodeId: string, forward: boolean): boolean {
    const info: BranchInfo | null = this.branchInfoFor(nodeId);
    if (info === null) {
      return false;
    }
    return forward ? info.index < info.count : info.index > 1;
  }

  private branchGo(nodeId: string, forward: boolean): void {
    const info: BranchInfo | null = this.branchInfoFor(nodeId);
    if (info === null) {
      return;
    }
    const target: string = forward ? info.nextChildId : info.prevChildId;
    this.runtime.switchBranch(info.parentId, target);
    this.branchSignature = '';
  }

  private scrollToBottomSoon(): void {
    if (this.busyScroll) {
      return;
    }
    this.busyScroll = true;
    setTimeout(() => {
      this.busyScroll = false;
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 列表尚未布局时忽略
      }
    }, 24);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  // -------------------------------------------------------------------------
  // 会话操作
  // -------------------------------------------------------------------------

  /**
   * 折叠抽屉开关（统一入口；GPU 常驻挂载 + 240ms 进出场）。
   *
   * 所有位移只读写 `drawerTranslateX` 一个状态，`scrimOpacity` 与其同步；
   * 关闭动画结束后才 `drawerVisible=false`，组件树全程不卸载，且拖动回弹不会跳变。
   */
  private setDrawerOpen(open: boolean): void {
    if (open) {
      this.drawerVisible = true;
      this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
        this.drawerTranslateX = 0;
        this.scrimOpacity = 1;
      });
      return;
    }
    const width: number = Layout.drawerMaxWidth;
    this.getUIContext().animateTo({
      duration: 240,
      curve: Curve.FastOutSlowIn,
      onFinish: () => {
        if (this.drawerTranslateX <= -width * 0.999) {
          this.drawerVisible = false;
        }
      }
    }, () => {
      this.drawerTranslateX = -width;
      this.scrimOpacity = 0;
    });
  }

  private async newChat(): Promise<void> {
    this.setDrawerOpen(false);
    this.editingNodeId = '';
    this.inputText = '';
    this.pendingAttachments = [];
    await this.runtime.newSession();
    await this.refreshSessions();
    await this.refreshPersonas();
    this.applySnapshot(this.runtime.snapshot());
    this.scrollToBottomSoon();
  }

  private async openSession(sessionId: string): Promise<void> {
    this.setDrawerOpen(false);
    this.editingNodeId = '';
    this.inputText = '';
    this.pendingAttachments = [];
    this.sourcePaneOpen = false;
    this.sourceNodeId = '';
    await this.runtime.openSession(sessionId);
    await this.refreshSessions();
    await this.refreshPersonas();
    this.applySnapshot(this.runtime.snapshot());
    this.scrollToBottomSoon();
  }

  private async renameSession(sessionId: string, title: string): Promise<void> {
    try {
      await this.runtime.renameSession(sessionId, title);
      await this.refreshSessions();
    } catch (e) {
      this.toast('重命名失败');
    }
  }

  private async deleteSession(sessionId: string): Promise<void> {
    try {
      await this.runtime.deleteSession(sessionId);
      await this.refreshSessions();
      await this.refreshPersonas();
      this.applySnapshot(this.runtime.snapshot());
    } catch (e) {
      this.toast('删除失败');
    }
  }

  private navTo(target: number): void {
    this.setDrawerOpen(false);
    if (target === NAV_CREATOR) {
      const params: SkillCreatorParams = { targetSkillId: '', nodeId: '' };
      this.getUIContext().getRouter().pushUrl({ url: RouteUrls.SKILL_CREATOR, params: params }).catch(() => {
        this.toast('打开失败');
      });
    } else if (target === NAV_SKILLS) {
      const params: SkillManagerParams = { openSkillId: '' };
      this.getUIContext().getRouter().pushUrl({ url: RouteUrls.SKILL_MANAGER, params: params }).catch(() => {
        this.toast('打开失败');
      });
    } else {
      const params: SettingsPageParams = { from: 'chat' };
      this.getUIContext().getRouter().pushUrl({ url: RouteUrls.SETTINGS, params: params }).catch(() => {
        this.toast('打开失败');
      });
    }
  }

  private goSettings(): void {
    const params: SettingsPageParams = { from: 'chat' };
    this.getUIContext().getRouter().pushUrl({ url: RouteUrls.SETTINGS, params: params }).catch(() => {
      this.toast('打开失败');
    });
  }

  /** 无模型 / 模型胶囊半模态：直达设置「模型与密钥」拉取真实模型。 */
  private goSettingsModels(): void {
    const params: SettingsPageParams = { from: 'chat', category: 'models' };
    this.getUIContext().getRouter().pushUrl({ url: RouteUrls.SETTINGS, params: params }).catch(() => {
      this.toast('打开失败');
    });
  }

  private goPersonaSettings(): void {
    this.sheetOpen = false;
    const params: SettingsPageParams = { from: 'chat', category: 'personas' };
    this.getUIContext().getRouter().pushUrl({ url: RouteUrls.SETTINGS, params: params }).catch(() => {
      this.toast('打开失败');
    });
  }

  private goSkillCreator(nodeId: string): void {
    this.menuNodeId = '';
    const params: SkillCreatorParams = { targetSkillId: '', nodeId: nodeId };
    this.getUIContext().getRouter().pushUrl({ url: RouteUrls.SKILL_CREATOR, params: params }).catch(() => {
      this.toast('打开失败');
    });
  }

  // -------------------------------------------------------------------------
  // 半模态
  // -------------------------------------------------------------------------

  private openSheet(mode: string): void {
    this.sheetMode = mode;
    this.sheetOpen = true;
  }

  private currentSources(): SourceRef[] {
    if (this.sourceNodeId.length === 0) {
      return [];
    }
    for (const node of this.nodes) {
      if (node.nodeId === this.sourceNodeId) {
        return nodeSources(node);
      }
    }
    return [];
  }

  private openSources(node: ConversationNode): void {
    this.sourceNodeId = node.nodeId;
    if (this.unfolded) {
      this.sourcePaneOpen = true;
    } else {
      this.openSheet(SHEET_SOURCES);
    }
  }

  private async pickPersona(personaId: string): Promise<void> {
    this.sheetOpen = false;
    await this.runtime.setPersona(personaId);
    this.activePersonaId = personaId;
  }

  private async toggleSkill(chip: SkillChipState): Promise<void> {
    if (!chip.globalEnabled) {
      this.toast(`「${chip.name}」在全局已停用`);
      return;
    }
    await this.runtime.toggleSessionSkill(chip.skillId);
  }

  // -------------------------------------------------------------------------
  // 附件
  // -------------------------------------------------------------------------

  private addAttachment(uri: string, kind: string): void {
    if (uri.length === 0) {
      return;
    }
    for (const one of this.pendingAttachments) {
      if (one.uri === uri) {
        return;
      }
    }
    const id: string = `att_${Date.now()}_${this.pendingAttachments.length}`;
    const name: string = kind === 'link' ? hostOf(uri) : fileNameOf(uri);
    const ref: AttachmentRef = { id: id, name: name, kind: kind, uri: uri };
    this.pendingAttachments = this.pendingAttachments.concat([ref]);
  }

  private removeAttachment(id: string): void {
    const next: AttachmentRef[] = [];
    for (const one of this.pendingAttachments) {
      if (one.id !== id) {
        next.push(one);
      }
    }
    this.pendingAttachments = next;
  }

  private async pickImages(): Promise<void> {
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 9;
      const result: photoAccessHelper.PhotoSelectResult =
        await new photoAccessHelper.PhotoViewPicker().select(options);
      for (const uri of result.photoUris) {
        this.addAttachment(uri, 'image');
      }
      this.sheetOpen = false;
    } catch (e) {
      this.toast('无法打开相册');
    }
  }

  private async pickFiles(): Promise<void> {
    try {
      const context = AppServices.get().requireContext();
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 5;
      const uris: string[] = await documentPicker.select(options);
      for (const uri of uris) {
        this.addAttachment(uri, 'file');
      }
      this.sheetOpen = false;
    } catch (e) {
      this.toast('无法打开文件选择器');
    }
  }

  private attachIcon(kind: string): Resource {
    if (kind === 'image') {
      return Icons.image;
    }
    if (kind === 'link') {
      return Icons.link;
    }
    return Icons.file;
  }

  // -------------------------------------------------------------------------
  // 发送 / 停止 / 编辑
  // -------------------------------------------------------------------------

  private async onSendOrStop(): Promise<void> {
    if (this.snapshot.streaming) {
      this.runtime.stop();
      return;
    }
    const text: string = this.inputText.trim();
    if (text.length === 0) {
      if (this.pendingAttachments.length > 0) {
        this.toast('补一句话再发送');
      }
      return;
    }
    if (!this.snapshot.hasModel) {
      // 没有可用模型：输入与附件都保留，交给运行时给中文引导（不在这里堆教程）。
      const pending: AttachmentRef[] = this.pendingAttachments.slice();
      try {
        if (pending.length > 0) {
          await this.runtime.send(text, pending);
        } else {
          await this.runtime.send(text);
        }
      } catch (e) {
        // 运行时会写 errorMessage
      }
      return;
    }
    if (!this.snapshot.hasApiKey) {
      this.goSettings();
      return;
    }
    if (this.runtime.isBusy()) {
      this.toast('稍等一下');
      return;
    }
    const editingId: string = this.editingNodeId;
    const attachments: AttachmentRef[] = this.pendingAttachments.slice();
    this.inputText = '';
    this.editingNodeId = '';
    try {
      if (editingId.length > 0) {
        // 编辑历史提问不走附件（附件属于新消息），待发附件保留给下一条消息。
        await this.runtime.editUserNode(editingId, text);
      } else if (attachments.length > 0) {
        this.pendingAttachments = [];
        await this.runtime.send(text, attachments);
      } else {
        this.pendingAttachments = [];
        await this.runtime.send(text);
      }
    } catch (e) {
      this.toast('发送失败');
    }
  }

  private copyText(text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast('已复制');
      }).catch(() => {
        this.toast('复制失败');
      });
    } catch (e) {
      this.toast('复制失败');
    }
  }

  private startEdit(node: ConversationNode): void {
    this.menuNodeId = '';
    this.editingNodeId = node.nodeId;
    this.inputText = nodeText(node);
  }

  private cancelEdit(): void {
    this.editingNodeId = '';
    this.inputText = '';
  }

  private async openBranches(node: ConversationNode): Promise<void> {
    this.menuNodeId = '';
    const options: BranchOption[] = await this.runtime.branches(node.nodeId);
    if (options.length <= 1) {
      this.toast('暂无其它分支');
      return;
    }
    this.branchOptions = options;
    this.branchParentId = node.parentId === null ? '' : node.parentId;
    this.openSheet(SHEET_BRANCH);
  }

  private menuElementsFor(node: ConversationNode): MenuElement[] {
    const out: MenuElement[] = [];
    const isUser: boolean = node.role === 'user';
    out.push({
      value: '复制',
      symbolIcon: new SymbolGlyphModifier(Icons.copy),
      action: () => {
        this.copyText(nodeText(node));
      }
    });
    out.push({
      value: isUser ? '编辑' : '重新生成',
      symbolIcon: new SymbolGlyphModifier(isUser ? Icons.edit : Icons.retry),
      action: () => {
        if (isUser) {
          this.startEdit(node);
        } else {
          this.runtime.regenerateNode(node.nodeId);
        }
      }
    });
    out.push({
      value: '切换分支',
      symbolIcon: new SymbolGlyphModifier(Icons.chevronRight),
      action: () => {
        this.openBranches(node);
      }
    });
    out.push({
      value: '沉淀为技能',
      symbolIcon: new SymbolGlyphModifier(Icons.creator),
      action: () => {
        this.goSkillCreator(node.nodeId);
      }
    });
    return out;
  }

  // -------------------------------------------------------------------------
  // 顶栏
  // -------------------------------------------------------------------------

  private personaLabel(): string {
    if (this.snapshot.personaName.length > 0) {
      return this.snapshot.personaName;
    }
    return this.personas.length > 0 ? this.personas[0].name : '默认助手';
  }

  @Builder
  topBar() {
    Row({ space: Layout.s2 }) {
      if (!this.unfolded || this.sidebarCollapsed) {
        IconBtn({
          icon: Icons.panelOpen,
          iconSize: Layout.iconM,
          iconColor: Theme.iconSecondary,
          btnSize: 34,
          bgColor: Theme.bgSurface,
          radius: Layout.radiusM,
          onTap: () => {
            if (this.unfolded) {
              this.sidebarCollapsed = false;
            } else {
              this.setDrawerOpen(true);
              this.refreshSessions();
            }
          }
        })
      }
      ModelCapsule({
        modelLabel: this.snapshot.modelLabel,
        modelId: this.snapshot.modelId,
        providerId: this.snapshot.providerId,
        thinkingLevel: this.snapshot.thinkingLevel,
        profiles: this.profiles,
        onSelectModel: (providerId: string, modelId: string) => {
          this.runtime.setModel(providerId, modelId);
        },
        onSelectThinking: (level: ThinkingLevel) => {
          this.runtime.setThinkingLevel(level);
        },
        onGoSettings: () => {
          this.goSettingsModels();
        }
      })
      Blank()
      Row({ space: 4 }) {
        SymbolGlyph(Icons.persona).fontSize(Layout.iconS).fontColor([Theme.iconSecondary])
        Text(this.personaLabel())
          .fontSize(Layout.fontSmall)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 96 })
      }
      .height(34)
      .padding({ left: 10, right: 10 })
      .borderRadius(Layout.radiusPill)
      .backgroundColor(Theme.bgSurface)
      .border({ width: 1, color: Theme.border })
      .onClick(() => {
        this.refreshPersonas();
        this.openSheet(SHEET_PERSONA);
      })
      IconBtn({
        icon: Icons.newChat,
        iconSize: Layout.iconM,
        iconColor: Theme.iconSecondary,
        btnSize: 34,
        bgColor: Theme.bgSurface,
        radius: Layout.radiusM,
        onTap: () => {
          this.newChat();
        }
      })
    }
    .width('100%')
    .height(this.unfolded ? Layout.topBarHeight : Layout.topBarFoldedHeight)
    .padding({ left: Layout.s3, right: Layout.s3 })
    .border({ width: { bottom: 1 }, color: { bottom: Theme.divider } })
  }

  // -------------------------------------------------------------------------
  // 消息
  // -------------------------------------------------------------------------

  @Builder
  userBubble(node: ConversationNode) {
    Column() {
      if (nodeAttachmentChips(node).length > 0) {
        Row({ space: 4 }) {
          ForEach(nodeAttachmentChips(node), (chip: AttachmentChipView, index: number) => {
            Row({ space: 4 }) {
              SymbolGlyph(chip.icon).fontSize(Layout.fontCaption).fontColor([Theme.textTertiary])
              Text(chip.label)
                .fontSize(Layout.fontCaption)
                .fontColor(Theme.textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 140 })
            }
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(Layout.radiusS)
            .backgroundColor(Theme.bgSurface)
            .border({ width: 1, color: Theme.border })
          }, (chip: AttachmentChipView, index: number) => `${index}_${chip.label}`)
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ bottom: 4 })
      }
      Row() {
        Blank()
        Text(nodeText(node))
          .fontSize(Layout.fontChat)
          .fontColor(Theme.bubbleUserText)
          .lineHeight(Layout.lineChat)
          .padding({ left: 15, right: 15, top: 10, bottom: 10 })
          .constraintSize({ maxWidth: '82%' })
          .borderRadius({
            topLeft: Layout.bubbleRadius,
            topRight: Layout.bubbleRadius,
            bottomLeft: Layout.bubbleRadius,
            bottomRight: Layout.bubbleTail
          })
          .backgroundColor(Theme.bubbleUser)
      }
      .width('100%')
    }
    .width('100%')
    .gesture(LongPressGesture().onAction(() => {
      this.menuNodeId = node.nodeId;
    }))
    .bindMenu(this.menuNodeId === node.nodeId, this.menuElementsFor(node), {
      onDisappear: () => {
        this.menuNodeId = '';
      }
    })
  }

  @Builder
  thinkingCapsule(node: ConversationNode) {
    Column() {
      Row({ space: 6 }) {
        SymbolGlyph(Icons.thinking).fontSize(Layout.iconS).fontColor([Theme.brand])
        Text(nodeSources(node).length > 0 ? `思考过程 · ${nodeSources(node).length} 篇` : '思考过程')
          .fontSize(Layout.fontSmall)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary)
        SymbolGlyph(this.expandedThinkingId === node.nodeId ? Icons.chevronUp : Icons.chevronDown)
          .fontSize(Layout.iconS)
          .fontColor([Theme.textTertiary])
      }
      .height(28)
      .padding({ left: 10, right: Layout.s2 })
      .borderRadius(Layout.radiusPill)
      .backgroundColor(Theme.bgSurface)
      .onClick(() => {
        this.expandedThinkingId = this.expandedThinkingId === node.nodeId ? '' : node.nodeId;
      })

      if (this.expandedThinkingId === node.nodeId) {
        Column({ space: 6 }) {
          Text(nodeReasoning(node))
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .lineHeight(Layout.lineTight)
            .width('100%')
          if (nodeSources(node).length > 0) {
            Scroll() {
              Row({ space: 6 }) {
                ForEach(nodeSources(node), (source: SourceRef, index: number) => {
                  Row({ space: 4 }) {
                    SymbolGlyph(Icons.search).fontSize(Layout.fontCaption).fontColor([Theme.brand])
                    Text(`检索 · ${hostOf(source.url)}`)
                      .fontSize(Layout.fontSmall)
                      .fontColor(Theme.brand)
                      .maxLines(1)
                  }
                  .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                  .borderRadius(Layout.radiusS)
                  .backgroundColor(Theme.brandSubtle)
                }, (source: SourceRef, index: number) => `${index}_${source.url}`)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }
        }
        .width('100%')
        .padding({ left: Layout.s3, top: Layout.s2, bottom: Layout.s1 })
        .margin({ top: Layout.s2 })
        .border({ width: { left: 2 }, color: { left: Theme.border } })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: Layout.s2 })
  }

  @Builder
  branchSwitcher(node: ConversationNode) {
    if (this.branchInfoFor(node.nodeId) !== null) {
      Row({ space: 2 }) {
        IconBtn({
          icon: Icons.back,
          iconSize: Layout.fontSmall,
          iconColor: Theme.textSecondary,
          btnSize: 22,
          radius: Layout.radiusS,
          btnDisabled: !this.branchCanGo(node.nodeId, false),
          onTap: () => {
            this.branchGo(node.nodeId, false);
          }
        })
        Text(this.branchLabel(node.nodeId))
          .fontSize(Layout.fontSmall)
          .fontFamily('monospace')
          .fontColor(Theme.textSecondary)
        IconBtn({
          icon: Icons.chevronRight,
          iconSize: Layout.fontSmall,
          iconColor: Theme.textSecondary,
          btnSize: 22,
          radius: Layout.radiusS,
          btnDisabled: !this.branchCanGo(node.nodeId, true),
          onTap: () => {
            this.branchGo(node.nodeId, true);
          }
        })
      }
      .height(26)
      .padding({ left: 4, right: 4 })
      .borderRadius(Layout.radiusS)
      .backgroundColor(Theme.bgSurface)
    }
  }

  @Builder
  actionRow(node: ConversationNode) {
    Row({ space: 4 }) {
      IconBtn({
        icon: Icons.copy,
        iconSize: Layout.iconS,
        iconColor: Theme.textTertiary,
        btnSize: 30,
        radius: Layout.radiusS,
        onTap: () => {
          this.copyText(nodeText(node));
        }
      })
      IconBtn({
        icon: Icons.retry,
        iconSize: Layout.iconS,
        iconColor: Theme.textTertiary,
        btnSize: 30,
        radius: Layout.radiusS,
        onTap: () => {
          this.runtime.regenerateNode(node.nodeId);
        }
      })
      this.branchSwitcher(node)
      Blank()
      if (nodeSources(node).length > 0) {
        Row({ space: 4 }) {
          SymbolGlyph(Icons.web).fontSize(Layout.iconS).fontColor([Theme.brand])
          Text(`来源 · ${nodeSources(node).length}`)
            .fontSize(Layout.fontSmall)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textSecondary)
        }
        .height(24)
        .padding({ left: Layout.s2, right: Layout.s2 })
        .borderRadius(Layout.radiusPill)
        .backgroundColor(Theme.bgSurface)
        .border({ width: 1, color: Theme.border })
        .onClick(() => {
          this.openSources(node);
        })
      }
    }
    .width('100%')
    .margin({ top: 2 })
  }

  @Builder
  assistantBlock(node: ConversationNode) {
    Column() {
      if (nodeReasoning(node).length > 0) {
        this.thinkingCapsule(node)
      }
      MarkdownBlock({ markdown: nodeText(node) })
      if (nodeToolNames(node).length > 0) {
        Row({ space: 6 }) {
          SymbolGlyph(Icons.skills).fontSize(Layout.iconS).fontColor([Theme.textTertiary])
          ForEach(nodeToolNames(node), (name: string, index: number) => {
            Text(name)
              .fontSize(Layout.fontCaption)
              .fontColor(Theme.chipText)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(Layout.radiusS)
              .backgroundColor(Theme.chipBg)
          }, (name: string, index: number) => `${index}_${name}`)
        }
        .width('100%')
        .margin({ top: Layout.s1 })
      }
      this.actionRow(node)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .gesture(LongPressGesture().onAction(() => {
      this.menuNodeId = node.nodeId;
    }))
    .bindMenu(this.menuNodeId === node.nodeId, this.menuElementsFor(node), {
      onDisappear: () => {
        this.menuNodeId = '';
      }
    })
  }

  @Builder
  toolRow(node: ConversationNode) {
    Row({ space: 6 }) {
      SymbolGlyph(Icons.skills).fontSize(Layout.iconS).fontColor([Theme.textTertiary])
      Text(nodeToolNames(node).length > 0 ? nodeToolNames(node).join('、') : '技能结果')
        .fontSize(Layout.fontCaption)
        .fontColor(Theme.textTertiary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .padding({ left: Layout.s2, right: Layout.s2, top: 4, bottom: 4 })
    .borderRadius(Layout.radiusS)
    .backgroundColor(Theme.chipBg)
  }

  @Builder
  messageItem(node: ConversationNode) {
    if (node.role === 'user') {
      this.userBubble(node)
    } else if (node.role === 'assistant') {
      if (nodeText(node).length === 0 && nodeReasoning(node).length === 0
        && nodeSources(node).length === 0 && nodeToolNames(node).length === 0) {
        Row().height(0)
      } else {
        this.assistantBlock(node)
      }
    } else {
      this.toolRow(node)
    }
  }

  // -------------------------------------------------------------------------
  // 输入区
  // -------------------------------------------------------------------------

  @Builder
  attachmentChips() {
    if (this.pendingAttachments.length > 0) {
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.pendingAttachments, (attachment: AttachmentRef) => {
            Row({ space: 4 }) {
              SymbolGlyph(this.attachIcon(attachment.kind))
                .fontSize(Layout.iconS)
                .fontColor([Theme.textSecondary])
              Text(attachment.name)
                .fontSize(Layout.fontCaption)
                .fontColor(Theme.textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 140 })
              IconBtn({
                icon: Icons.close,
                iconSize: 12,
                iconColor: Theme.textTertiary,
                btnSize: 20,
                radius: Layout.radiusPill,
                onTap: () => {
                  this.removeAttachment(attachment.id);
                }
              })
            }
            .padding({ left: Layout.s2, right: 6, top: 4, bottom: 4 })
            .borderRadius(Layout.radiusM)
            .backgroundColor(Theme.bgSurface)
            .border({ width: 1, color: Theme.border })
          }, (attachment: AttachmentRef) => attachment.id)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ bottom: 6 })
    }
  }

  @Builder
  skillChipsBar() {
    if (this.snapshot.skillChips.length > 0) {
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.snapshot.skillChips, (chip: SkillChipState) => {
            Row({ space: 4 }) {
              SymbolGlyph(chip.active ? Icons.check : Icons.plus)
                .fontSize(Layout.fontCaption)
                .fontColor([chip.active ? Theme.brand : Theme.textTertiary])
              Text(chip.name)
                .fontSize(Layout.fontSmall)
                .fontWeight(FontWeight.Medium)
                .fontColor(chip.active ? Theme.brand : Theme.textSecondary)
                .maxLines(1)
                .constraintSize({ maxWidth: 120 })
            }
            .height(28)
            .padding({ left: 10, right: 10 })
            .borderRadius(Layout.radiusPill)
            .backgroundColor(chip.active ? Theme.brandSubtle : Theme.bgSurface)
            .border({ width: 1, color: chip.active ? Color.Transparent : Theme.border })
            .opacity(chip.globalEnabled ? 1 : Layout.disabledOpacity)
            .onClick(() => {
              this.toggleSkill(chip);
            })
          }, (chip: SkillChipState) => `${chip.skillId}_${chip.active}_${chip.globalEnabled}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ bottom: 6 })
    }
  }

  private canSend(): boolean {
    return this.inputText.trim().length > 0 || this.pendingAttachments.length > 0;
  }

  private hasActiveSkill(): boolean {
    for (const chip of this.snapshot.skillChips) {
      if (chip.active) {
        return true;
      }
    }
    return false;
  }

  @Builder
  inputArea() {
    Column() {
      MemoryGaugeBar({
        ratio: this.snapshot.memoryRatio,
        cacheRatio: this.snapshot.cacheHitRatio,
        compacting: this.snapshot.compacting,
        onCompact: () => {
          this.runtime.compactNow();
        }
      })

      if (this.unfolded) {
        this.skillChipsBar()
      }

      this.attachmentChips()

      if (this.editingNodeId.length > 0) {
        Row({ space: 6 }) {
          SymbolGlyph(Icons.edit).fontSize(Layout.iconS).fontColor([Theme.warning])
          Text('修改中')
            .fontSize(Layout.fontCaption)
            .fontColor(Theme.warning)
            .layoutWeight(1)
          Text('取消')
            .fontSize(Layout.fontCaption)
            .fontColor(Theme.textTertiary)
            .onClick(() => {
              this.cancelEdit();
            })
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(Layout.radiusS)
        .backgroundColor(Theme.warningSubtle)
        .margin({ bottom: 6 })
      }

      if (this.notice.length > 0) {
        Text(this.notice)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ bottom: 4 })
      }

      if (!this.snapshot.hasModel) {
        Row({ space: 6 }) {
          SymbolGlyph(Icons.model).fontSize(Layout.fontCaption).fontColor([Theme.warning])
          Text('还没有可用模型 · 去设置拉取')
            .fontSize(Layout.fontCaption)
            .fontColor(Theme.warning)
        }
        .width('100%')
        .padding({ bottom: 6 })
        .onClick(() => {
          this.goSettingsModels();
        })
      } else if (!this.snapshot.hasApiKey) {
        Row({ space: 6 }) {
          SymbolGlyph(Icons.key).fontSize(Layout.fontCaption).fontColor([Theme.warning])
          Text('未配置密钥，点此填写')
            .fontSize(Layout.fontCaption)
            .fontColor(Theme.warning)
        }
        .width('100%')
        .padding({ bottom: 6 })
        .onClick(() => {
          this.goSettings();
        })
      }

      Row({ space: 6 }) {
        IconBtn({
          icon: Icons.attach,
          iconSize: Layout.iconL,
          iconColor: Theme.iconSecondary,
          btnSize: 36,
          radius: Layout.radiusPill,
          onTap: () => {
            this.openSheet(SHEET_ATTACH);
          }
        })

        TextArea({
          text: this.inputText,
          placeholder: this.snapshot.streaming ? '正在回答…' : '发消息…'
        })
          .onChange((value: string) => {
            this.inputText = value;
          })
          .onFocus(() => {
            this.inputFocused = true;
          })
          .onBlur(() => {
            this.inputFocused = false;
          })
          .fontSize(Layout.fontBody)
          .fontColor(Theme.textPrimary)
          .placeholderColor(Theme.textTertiary)
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding({ left: 2, right: 2, top: 8, bottom: 8 })
          .constraintSize({ minHeight: 36, maxHeight: 120 })
          .layoutWeight(1)

        if (!this.unfolded) {
          IconBtn({
            icon: Icons.skills,
            iconSize: Layout.iconM,
            iconColor: this.hasActiveSkill() ? Theme.brand : Theme.textTertiary,
            btnSize: 36,
            bgColor: this.hasActiveSkill() ? Theme.brandSubtle : Color.Transparent,
            radius: Layout.radiusPill,
            onTap: () => {
              this.openSheet(SHEET_SKILLS);
            }
          })
        }

        IconBtn({
          icon: this.snapshot.streaming ? Icons.stop : Icons.send,
          iconSize: Layout.iconM,
          iconColor: Theme.textOnBrand,
          btnSize: 36,
          bgColor: this.snapshot.streaming ? Theme.danger
            : (this.canSend() ? Theme.brand : Theme.toggleOff),
          radius: Layout.radiusPill,
          onTap: () => {
            this.onSendOrStop();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 6, right: 6, top: 5, bottom: 5 })
      .borderRadius(Layout.inputRadius)
      .backgroundColor(Theme.bgInput)
      .border({ width: 1, color: this.inputFocused ? Theme.brand : Theme.border })
    }
    .width('100%')
    .constraintSize({ maxWidth: Layout.chatMaxWidth })
    .padding({ left: Layout.s3, right: Layout.s3, top: Layout.s1, bottom: Layout.s3 })
  }

  // -------------------------------------------------------------------------
  // 半模态内容
  // -------------------------------------------------------------------------

  @Builder
  skillSheetContent() {
    Column({ space: Layout.s3 }) {
      Row({ space: Layout.s2 }) {
        SymbolGlyph(Icons.skills).fontSize(Layout.iconM).fontColor([Theme.brand])
        Text('本对话技能')
          .fontSize(Layout.fontHeadline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')

      if (this.snapshot.skillChips.length === 0) {
        Text('暂无技能')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textTertiary)
          .width('100%')
      } else {
        Column({ space: Layout.s1 }) {
          ForEach(this.snapshot.skillChips, (chip: SkillChipState) => {
            Row({ space: Layout.s2 }) {
              Column({ space: 2 }) {
                Text(chip.name)
                  .fontSize(Layout.fontBody)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(chip.globalEnabled ? Theme.textPrimary : Theme.textTertiary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (!chip.globalEnabled) {
                  Text('已停用')
                    .fontSize(Layout.fontCaption)
                    .fontColor(Theme.textTertiary)
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: chip.active })
                .selectedColor(Theme.brand)
                .enabled(chip.globalEnabled)
                .onChange((isOn: boolean) => {
                  if (isOn !== chip.active) {
                    this.toggleSkill(chip);
                  }
                })
            }
            .width('100%')
            .padding({ left: Layout.s3, right: Layout.s2, top: 8, bottom: 8 })
            .borderRadius(Layout.radiusM)
            .backgroundColor(Theme.bgSurface)
          }, (chip: SkillChipState) => `${chip.skillId}_${chip.active}_${chip.globalEnabled}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s5, bottom: Layout.s6 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sheetContent() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.sheetMode === SHEET_PERSONA) {
        PersonaSheet({
          personas: this.personas,
          activeId: this.activePersonaId,
          onPick: (personaId: string) => {
            this.pickPersona(personaId);
          },
          onOpenSettings: () => {
            this.goPersonaSettings();
          }
        })
      } else if (this.sheetMode === SHEET_ATTACH) {
        AttachSheet({
          onPickImage: () => {
            this.pickImages();
          },
          onPickFile: () => {
            this.pickFiles();
          },
          onPickLink: (url: string) => {
            this.addAttachment(url, 'link');
            this.sheetOpen = false;
          }
        })
      } else if (this.sheetMode === SHEET_SKILLS) {
        this.skillSheetContent()
      } else if (this.sheetMode === SHEET_SOURCES) {
        SourcePane({
          sources: this.currentSources(),
          showClose: false,
          onClose: () => {
          }
        })
      } else {
        BranchSelector({
          options: this.branchOptions,
          onPick: (childId: string) => {
            this.sheetOpen = false;
            this.runtime.switchBranch(this.branchParentId, childId);
            this.branchSignature = '';
          }
        })
      }
      // 统一自定义关闭按钮（与各内容标题行垂直居中；系统关闭按钮已 showClose:false）
      IconBtn({
        icon: Icons.close,
        iconSize: 14,
        iconColor: Theme.iconSecondary,
        btnSize: 28,
        bgColor: Theme.bgSurface3,
        radius: Layout.radiusPill,
        onTap: () => {
          this.sheetOpen = false;
        }
      })
        .margin({
          top: this.sheetMode === SHEET_SOURCES ? Layout.s2 : Layout.s5,
          right: Layout.s3
        })
    }
    .width('100%')
    .height('100%')
  }

  // -------------------------------------------------------------------------
  // 布局片段
  // -------------------------------------------------------------------------

  @Builder
  drawerForFolded() {
    SessionDrawer({
      sessions: this.sessions,
      currentSessionId: this.snapshot.sessionId,
      folded: true,
      onNewChat: () => {
        this.newChat();
      },
      onOpen: (sessionId: string) => {
        this.openSession(sessionId);
      },
      onClose: () => {
        this.setDrawerOpen(false);
      },
      onCollapse: () => {
      },
      onRename: (sessionId: string, title: string) => {
        this.renameSession(sessionId, title);
      },
      onDelete: (sessionId: string) => {
        this.deleteSession(sessionId);
      },
      onNav: (target: number) => {
        this.navTo(target);
      }
    })
  }

  @Builder
  sidebarForUnfolded() {
    SessionDrawer({
      sessions: this.sessions,
      currentSessionId: this.snapshot.sessionId,
      folded: false,
      onNewChat: () => {
        this.newChat();
      },
      onOpen: (sessionId: string) => {
        this.openSession(sessionId);
      },
      onClose: () => {
      },
      onCollapse: () => {
        this.sidebarCollapsed = true;
      },
      onRename: (sessionId: string, title: string) => {
        this.renameSession(sessionId, title);
      },
      onDelete: (sessionId: string) => {
        this.deleteSession(sessionId);
      },
      onNav: (target: number) => {
        this.navTo(target);
      }
    })
  }

  @Builder
  emptyState() {
    Column({ space: Layout.s3 }) {
      Stack({ alignContent: Alignment.Center }) {
        Text('C')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textOnBrand)
      }
      .width(48)
      .height(48)
      .borderRadius(Layout.radiusL)
      .backgroundColor(Theme.brand)
      Text('开始一段新对话')
        .fontSize(Layout.fontBody)
        .fontColor(Theme.textSecondary)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: Layout.s8 })
  }

  @Builder
  loadingState() {
    Column({ space: Layout.s3 }) {
      LoadingProgress().width(26).height(26).color(Theme.brand)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  errorRow() {
    Row({ space: Layout.s2 }) {
      SymbolGlyph(Icons.warnCircle).fontSize(Layout.iconS).fontColor([Theme.danger])
      Text(this.snapshot.errorMessage)
        .fontSize(Layout.fontSmall)
        .fontColor(Theme.textSecondary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('知道了')
        .fontSize(Layout.fontCaption)
        .fontColor(Theme.textTertiary)
        .onClick(() => {
          this.hiddenError = this.snapshot.errorMessage;
        })
    }
    .width('100%')
    .padding({ left: Layout.s3, right: Layout.s3, top: 6, bottom: 6 })
    .borderRadius(Layout.radiusM)
    .backgroundColor(Theme.dangerSubtle)
    .margin({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s2 })
  }

  @Builder
  messageList() {
    Column() {
      List({ space: Layout.s5, scroller: this.scroller }) {
        LazyForEach(this.dataSource, (node: ConversationNode) => {
          ListItem() {
            this.messageItem(node)
          }
        }, (node: ConversationNode) => node.nodeId)
        if (this.snapshot.streaming || this.snapshot.streamingText.length > 0
          || this.snapshot.streamingReasoning.length > 0) {
          ListItem() {
            StreamingMessage({
              text: this.snapshot.streamingText,
              reasoning: this.snapshot.streamingReasoning,
              streaming: this.snapshot.streaming,
              sources: this.snapshot.sources,
              searchTrace: this.snapshot.searchTrace,
              onCopyText: (text: string) => {
                this.copyText(text);
              },
              onRegenerate: () => {
                this.runtime.retryLast();
              }
            })
          }
        }
        ListItem() {
          Row().height(Layout.s3)
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: Layout.chatMaxWidth })
      .layoutWeight(1)
      .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s2 })
      .scrollBar(BarState.Off)
      .cachedCount(6)
      .onScrollIndex((first: number, last: number) => {
        this.autoFollow = last >= this.nodes.length - 1;
      })
    }
    .layoutWeight(1)
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        if (this.unfolded && !this.sidebarCollapsed) {
          Column() {
            this.sidebarForUnfolded()
          }
          .width(Layout.sidebarChat)
          .height('100%')
          .border({ width: { right: 1 }, color: { right: Theme.divider } })
        }

        Column() {
          this.topBar()
          if (this.ready && this.snapshot.errorMessage.length > 0
            && this.snapshot.errorMessage !== this.hiddenError) {
            this.errorRow()
          }
          if (!this.ready) {
            this.loadingState()
          } else if (this.nodes.length === 0 && !this.snapshot.streaming) {
            this.emptyState()
          } else {
            this.messageList()
          }
          this.inputArea()
        }
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(Theme.bgPage)

        if (this.unfolded && this.sourcePaneOpen) {
          Column() {
            SourcePane({
              sources: this.currentSources(),
              showClose: true,
              onClose: () => {
                this.sourcePaneOpen = false;
              }
            })
          }
          .width(Layout.sourcePaneWidth)
          .height('100%')
          .border({ width: { left: 1 }, color: { left: Theme.divider } })
          .transition(TransitionEffect.move(TransitionEdge.END).animation({ duration: Layout.animDuration, curve: Curve.EaseOut }))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bgPage)

      // 折叠态会话抽屉：常驻挂载（GPU 层动画，不做 if 卸载，拖动/关闭零闪变）。
      // ① 遮罩：opacity 与位移同步（拖动 1:1 跟手，不走动画）。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.scrim)
        .opacity(this.scrimOpacity)
        .visibility(this.drawerVisible ? Visibility.Visible : Visibility.None)
        .onClick(() => {
          this.setDrawerOpen(false);
        })
      // ② 抽屉层：位移只读写 drawerTranslateX；右空白点击关闭 + 左滑 48vp 关闭。
      Row() {
        Column() {
          this.drawerForFolded()
        }
        .width('78%')
        .constraintSize({ maxWidth: Layout.drawerMaxWidth })
        .height('100%')
        Column()
          .layoutWeight(1)
          .height('100%')
          .onClick(() => {
            this.setDrawerOpen(false);
          })
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.drawerTranslateX })
      .visibility(this.drawerVisible ? Visibility.Visible : Visibility.None)
      .gesture(PanGesture({ direction: PanDirection.Left, distance: 8 })
        .onActionUpdate((e: GestureEvent) => {
          const width: number = Layout.drawerMaxWidth;
          this.drawerTranslateX = Math.max(-width, Math.min(0, e.offsetX));
          this.scrimOpacity = 1 + this.drawerTranslateX / width;
        })
        .onActionEnd((e: GestureEvent) => {
          // 从当前位移继续动画（禁止先归零），位移过 1/4 或快速左滑则收起。
          const width: number = Layout.drawerMaxWidth;
          const fastSwipe: boolean = e.velocityX < -800;
          const close: boolean = this.drawerTranslateX < -width * 0.25 || fastSwipe;
          this.getUIContext().animateTo({
            duration: close ? 240 : 180,
            curve: close ? Curve.FastOutSlowIn : Curve.EaseOut,
            onFinish: () => {
              if (close && this.drawerTranslateX <= -width * 0.999) {
                this.drawerVisible = false;
              }
            }
          }, () => {
            this.drawerTranslateX = close ? -width : 0;
            this.scrimOpacity = close ? 0 : 1;
          });
        }))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgPage)
    .bindSheet($$this.sheetOpen, this.sheetContent(), {
      height: SheetSize.MEDIUM,
      preferType: SheetType.BOTTOM,
      showClose: false,
      dragBar: true,
      backgroundColor: Theme.sheetBg,
      radius: { topLeft: Layout.sheetTopRadius, topRight: Layout.sheetTopRadius },
      keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL
    })
  }
}
