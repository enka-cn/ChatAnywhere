/**
 * 技能创造室（v3）：左栏技能列表 + 右侧 SKILL.md 编辑/预览/试跑/保存 + 底部一句话 AI 改写。
 *
 * 设计基准：`chatanywhere_v3_pura_x_max.html` 326–388（布局）、1135–1182（渲染）、543–544（ArkUI 指令）。
 * 交互：
 * - 展开态（≥600vp）Master-Detail 双栏（232vp 左栏）；折叠态列表 → 详情二级栈；
 * - 编辑区 = SKILL.md 原文，预览 = 自实现轻量渲染；
 * - 保存走「SKILL.md → SkillManifest → kernel.importManifest（原子升级 + 旧版快照）」；
 * - AI 改写直接走协议层一轮请求，只输出完整 SKILL.md。
 *
 * 视觉只用 Theme / Layout / Icons，无硬编码色值、无教学文案、不暴露 L3。
 */
import { ConversationNode, CanonicalItem, estimateNodeTokens, newItemId, newNodeId } from '@app/core_model';
import {
  ModelProfile, RequestOptions, StreamCallbacks, StreamEvent, StreamHandle
} from '@app/core_protocol';
import { DryRunReport, SkillMarkdownCodec, SkillMarkdownResult, SkillSummary, UpgradeResult, tierLabel } from '@app/core_plugin';
import { AppServices } from '../app/AppServices';
import { Breakpoint, BreakpointWatcher } from '../app/Breakpoint';
import { Icons, Layout, Theme } from '../app/Theme';
import { CreatorMasterList, CreatorSkillItem } from '../components/CreatorMasterList';
import { SkillMdPreview } from '../components/SkillMdPreview';

/** AI 改写的固定系统提示词。 */
const REWRITE_SYSTEM_PROMPT: string =
  '你是 SKILL.md 编辑助手，只输出改写后的完整 SKILL.md，不要解释。';

/** 试跑用的样例输入。 */
const DRY_RUN_SAMPLE: string = '鸿蒙 开发';

/** 列表里不出现的分级（v3：不暴露端侧脚本入口）。 */
const HIDDEN_TIER: string = 'L3_QUICKJS_SANDBOX';

/** 构造一次性的用户节点（AI 改写请求用，不落盘）。 */
function buildRewriteNode(sessionId: string, text: string): ConversationNode {
  const now: number = Date.now();
  const item: CanonicalItem = { id: newItemId(), kind: 'text', text: text, createdAt: now };
  const node: ConversationNode = {
    nodeId: newNodeId(),
    parentId: null,
    sessionId: sessionId,
    role: 'user',
    items: [item],
    tokenEstimate: 0,
    createdAt: now
  };
  node.tokenEstimate = estimateNodeTokens(node);
  return node;
}

/** 清洗模型返回的 SKILL.md（去掉代码围栏、前置解释）。 */
function cleanModelMarkdown(raw: string): string {
  let text: string = raw.trim();
  if (text.startsWith('```')) {
    const firstBreak: number = text.indexOf('\n');
    if (firstBreak >= 0) {
      text = text.substring(firstBreak + 1);
    }
    const fence: number = text.lastIndexOf('```');
    if (fence >= 0) {
      text = text.substring(0, fence);
    }
    text = text.trim();
  }
  if (!text.startsWith('---')) {
    const firstFront: number = text.indexOf('---');
    if (firstFront > 0) {
      const candidate: string = text.substring(firstFront).trim();
      if (candidate.startsWith('---')) {
        text = candidate;
      }
    }
  }
  return text;
}

@Entry
@Component
struct SkillCreatorPage {
  @State private loading: boolean = true;
  @State private ready: boolean = false;
  @State private pluginMissing: boolean = false;
  @State private pluginError: string = '';

  @State private unfolded: boolean = false;
  @State private foldedDetail: boolean = false;

  @State private items: CreatorSkillItem[] = [];
  @State private searchText: string = '';
  @State private selectedId: string = '';
  @State private titleName: string = '新技能';
  @State private markdown: string = '';
  @State private mode: string = 'edit';
  @State private dirty: boolean = false;

  @State private saving: boolean = false;
  @State private dryRunning: boolean = false;
  @State private rewriting: boolean = false;
  @State private aiInput: string = '';

  @State private bannerText: string = '';
  @State private bannerError: boolean = false;
  @State private dryRunText: string = '';
  @State private dryRunError: boolean = false;

  private baseManifestJson: string = '';
  private watcher: BreakpointWatcher | null = null;
  private rewriteBuffer: string = '';
  private rewriteHandle: StreamHandle | null = null;
  /** 改写请求版本号：切换技能/新建时自增，迟到的流式回调不再覆盖编辑区。 */
  private rewriteToken: number = 0;

  aboutToAppear(): void {
    this.watcher = Breakpoint.watch(this.getUIContext(), (unfolded: boolean) => {
      this.unfolded = unfolded;
      if (unfolded) {
        this.foldedDetail = false;
      }
    });
    this.unfolded = Breakpoint.isUnfolded(this.getUIContext());
    this.bootstrap();
  }

  aboutToDisappear(): void {
    if (this.watcher !== null) {
      this.watcher.dispose();
      this.watcher = null;
    }
    if (this.rewriteHandle !== null) {
      this.rewriteHandle.cancel();
      this.rewriteHandle = null;
    }
  }

  // ---------------------------------------------------------------------------
  // 数据
  // ---------------------------------------------------------------------------

  private async bootstrap(): Promise<void> {
    this.loading = true;
    const services = AppServices.get();
    this.ready = await services.waitReady();
    this.pluginError = services.pluginError;
    this.pluginMissing = !services.hasPlugin();
    if (this.ready && !this.pluginMissing) {
      this.refreshItems();
      const target: string = this.readTargetSkillId();
      if (target.length > 0 && this.findItem(target)) {
        this.openSkill(target);
      } else {
        this.startNewDraft();
      }
    }
    this.loading = false;
  }

  private readTargetSkillId(): string {
    try {
      const raw: Object = this.getUIContext().getRouter().getParams();
      if (raw === undefined || raw === null) {
        return '';
      }
      const record: Record<string, Object> = raw as Record<string, Object>;
      const target: Object = record['targetSkillId'];
      return typeof target === 'string' ? target as string : '';
    } catch (e) {
      return '';
    }
  }

  private refreshItems(): void {
    const services = AppServices.get();
    if (!services.hasPlugin()) {
      this.pluginMissing = true;
      return;
    }
    try {
      const list: SkillSummary[] = services.requirePlugin().kernel.list();
      const next: CreatorSkillItem[] = [];
      for (const one of list) {
        if (one.tier === HIDDEN_TIER) {
          continue;
        }
        const item: CreatorSkillItem = { id: one.id, name: one.name, tierText: tierLabel(one.tier) };
        next.push(item);
      }
      this.items = next;
    } catch (e) {
      this.showBanner(`读取技能失败：${(e as Error).message}`, true);
    }
  }

  private findItem(id: string): boolean {
    for (const one of this.items) {
      if (one.id === id) {
        return true;
      }
    }
    return false;
  }

  private filteredItems(): CreatorSkillItem[] {
    const keyword: string = this.searchText.trim().toLowerCase();
    if (keyword.length === 0) {
      return this.items;
    }
    const out: CreatorSkillItem[] = [];
    for (const one of this.items) {
      if (one.name.toLowerCase().includes(keyword)) {
        out.push(one);
      }
    }
    return out;
  }

  private openSkill(skillId: string): void {
    this.cancelRewrite();
    const services = AppServices.get();
    if (!services.hasPlugin()) {
      this.pluginMissing = true;
      return;
    }
    let baseJson: string = '';
    let name: string = '';
    try {
      baseJson = services.requirePlugin().kernel.exportManifest(skillId);
      const summary: SkillSummary[] = services.requirePlugin().kernel.list();
      for (const one of summary) {
        if (one.id === skillId) {
          name = one.name;
        }
      }
    } catch (e) {
      this.showBanner(`读取技能失败：${(e as Error).message}`, true);
      return;
    }
    if (baseJson.trim().length === 0) {
      this.showBanner('没有读取到这个技能的清单', true);
      return;
    }
    const markdown: string = SkillMarkdownCodec.toMarkdown(baseJson);
    if (markdown.trim().length === 0) {
      this.showBanner('这个技能的 SKILL.md 读不出来', true);
      return;
    }
    this.selectedId = skillId;
    this.titleName = name.length > 0 ? name : skillId;
    this.baseManifestJson = baseJson;
    this.markdown = markdown;
    this.mode = 'edit';
    this.dirty = false;
    this.foldedDetail = true;
    this.dryRunText = '';
    this.clearBanner();
  }

  /** 生成带唯一 id 的新技能模板（避免多次新建覆盖同一技能）。 */
  private newSkillTemplate(): string {
    let template: string = SkillMarkdownCodec.newTemplate();
    const uniqueId: string = `user_skill_${Date.now().toString(36)}`;
    template = template.split('id: my_new_skill').join(`id: ${uniqueId}`);
    return template;
  }

  /** 取消进行中的 AI 改写（切换技能或新建时调用）。 */
  private cancelRewrite(): void {
    this.rewriteToken += 1;
    if (this.rewriteHandle !== null) {
      this.rewriteHandle.cancel();
      this.rewriteHandle = null;
    }
    this.rewriting = false;
  }

  private startNewDraft(): void {
    this.selectedId = '';
    this.titleName = '新技能';
    this.baseManifestJson = '';
    this.markdown = this.newSkillTemplate();
    this.mode = 'edit';
    this.dirty = false;
    this.foldedDetail = true;
    this.dryRunText = '';
    this.clearBanner();
  }

  // ---------------------------------------------------------------------------
  // 动作
  // ---------------------------------------------------------------------------

  private showBanner(text: string, isError: boolean): void {
    this.bannerText = text;
    this.bannerError = isError;
  }

  private clearBanner(): void {
    this.bannerText = '';
    this.bannerError = false;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (e) {
      // toast 失败不影响保存结果本身
    }
  }

  private backToChat(): void {
    this.getUIContext().getRouter().back();
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (this.rewriting) {
      this.showBanner('正在改写，稍等再保存', true);
      return;
    }
    this.clearBanner();
    const converted: SkillMarkdownResult = SkillMarkdownCodec.toManifestJson(this.markdown, this.baseManifestJson);
    if (!converted.ok) {
      const reason: string = converted.error === undefined ? 'SKILL.md 格式不对' : converted.error;
      this.showBanner(`保存失败：${reason}`, true);
      return;
    }
    this.saving = true;
    try {
      const result: UpgradeResult =
        await AppServices.get().requirePlugin().kernel.importManifest(converted.manifestJson);
      if (!result.ok) {
        const reason: string = result.error === undefined ? '校验未通过' : result.error;
        this.showBanner(`保存失败：${reason}`, true);
      } else {
        this.dirty = false;
        this.refreshItems();
        if (result.manifest !== undefined) {
          this.selectedId = result.manifest.id;
          this.titleName = result.manifest.name;
          this.baseManifestJson = JSON.stringify(result.manifest);
          this.markdown = SkillMarkdownCodec.toMarkdown(this.baseManifestJson);
        }
        const warning: string = converted.warnings.length > 0 ? `（${converted.warnings[0]}）` : '';
        this.showBanner(`已保存${warning}`, false);
        this.toast('已保存');
      }
    } catch (e) {
      this.showBanner(`保存失败：${(e as Error).message}`, true);
    }
    this.saving = false;
  }

  private async dryRun(): Promise<void> {
    if (this.dryRunning) {
      return;
    }
    const converted: SkillMarkdownResult = SkillMarkdownCodec.toManifestJson(this.markdown, this.baseManifestJson);
    if (!converted.ok) {
      const reason: string = converted.error === undefined ? 'SKILL.md 格式不对' : converted.error;
      this.dryRunText = `试跑失败：${reason}`;
      this.dryRunError = true;
      return;
    }
    this.dryRunning = true;
    this.dryRunText = '试跑中';
    this.dryRunError = false;
    try {
      const report: DryRunReport =
        await AppServices.get().requirePlugin().kernel.dryRun(converted.manifestJson, DRY_RUN_SAMPLE);
      if (report.passed) {
        let text: string = `试跑通过 · ${report.latencyMs}ms`;
        if (report.securityWarnings.length > 0) {
          text += ` · ${report.securityWarnings[0]}`;
        }
        this.dryRunText = text;
        this.dryRunError = false;
      } else {
        const reason: string = report.error === undefined ? '没有跑通' : report.error;
        this.dryRunText = `试跑失败：${reason}`;
        this.dryRunError = true;
      }
    } catch (e) {
      this.dryRunText = `试跑失败：${(e as Error).message}`;
      this.dryRunError = true;
    }
    this.dryRunning = false;
  }

  private async rewrite(): Promise<void> {
    if (this.rewriting) {
      return;
    }
    const instruction: string = this.aiInput.trim();
    if (instruction.length === 0) {
      this.showBanner('请输入修改要求', true);
      return;
    }
    const services = AppServices.get();
    let profile: ModelProfile;
    try {
      profile = await services.resolveActiveProfile();
    } catch (e) {
      this.showBanner(`模型读取失败：${(e as Error).message}`, true);
      return;
    }
    let hasKey: boolean = false;
    try {
      hasKey = await services.requireModel().secrets.has(profile.assetKeyAlias);
    } catch (e) {
      hasKey = false;
    }
    if (!hasKey) {
      this.showBanner('还没有配置模型密钥，请到设置里填写', true);
      return;
    }
    const before: string = this.markdown;
    this.rewriting = true;
    this.rewriteBuffer = '';
    this.rewriteToken += 1;
    const token: number = this.rewriteToken;
    this.clearBanner();
    this.aiInput = '';
    const promptText: string = `当前 SKILL.md：\n\n${before}\n\n修改要求：${instruction}`;
    const node: ConversationNode = buildRewriteNode('creator_rewrite', promptText);
    const options: RequestOptions = {
      thinkingLevel: 'off',
      webMode: 'off',
      maxOutputTokens: 4096,
      temperature: 0.2,
      systemPrompt: REWRITE_SYSTEM_PROMPT
    };
    let failed: boolean = false;
    const callbacks: StreamCallbacks = {
      onEvent: (event: StreamEvent) => {
        if (token !== this.rewriteToken) {
          return;
        }
        if (event.type === 'text_delta') {
          const delta: string = event.payload.delta === undefined ? '' : event.payload.delta;
          if (delta.length > 0) {
            this.rewriteBuffer += delta;
            this.markdown = this.rewriteBuffer;
          }
        } else if (event.type === 'error') {
          failed = true;
          const message: string = event.payload.message === undefined ? '模型返回了错误' : event.payload.message;
          this.showBanner(`改写失败：${message}`, true);
        }
      },
      onError: (message: string) => {
        if (token !== this.rewriteToken) {
          return;
        }
        failed = true;
        this.showBanner(`改写失败：${message}`, true);
      },
      onDone: () => {
      }
    };
    try {
      const handle: StreamHandle = services.requireProtocol().send(profile, [node], options, callbacks);
      this.rewriteHandle = handle;
      await handle.finished;
    } catch (e) {
      failed = true;
      this.showBanner(`改写失败：${(e as Error).message}`, true);
    }
    this.rewriteHandle = null;
    if (token !== this.rewriteToken) {
      // 已被「切换技能 / 新建」取消，丢弃本次改写结果。
      return;
    }
    if (!failed) {
      const cleaned: string = cleanModelMarkdown(this.rewriteBuffer);
      if (cleaned.length === 0) {
        this.markdown = before;
        this.showBanner('模型没有返回内容，请再试一次', true);
      } else {
        this.markdown = cleaned;
        this.dirty = true;
        this.mode = 'edit';
        this.showBanner('已改写，记得保存', false);
      }
    } else if (this.rewriteBuffer.trim().length === 0) {
      this.markdown = before;
    }
    this.rewriting = false;
  }

  private setMode(mode: string): void {
    this.mode = mode;
  }

  // ---------------------------------------------------------------------------
  // UI —— 顶栏 / 操作
  // ---------------------------------------------------------------------------

  @Builder
  modeSwitch() {
    Row() {
      Text('编辑')
        .fontSize(Layout.fontSmall)
        .fontColor(this.mode === 'edit' ? Theme.brand : Theme.textSecondary)
        .fontWeight(this.mode === 'edit' ? FontWeight.Medium : FontWeight.Normal)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(Layout.radiusS)
        .backgroundColor(this.mode === 'edit' ? Theme.brandSubtle : Color.Transparent)
        .onClick(() => {
          this.setMode('edit');
        })
      Text('预览')
        .fontSize(Layout.fontSmall)
        .fontColor(this.mode === 'preview' ? Theme.brand : Theme.textSecondary)
        .fontWeight(this.mode === 'preview' ? FontWeight.Medium : FontWeight.Normal)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(Layout.radiusS)
        .backgroundColor(this.mode === 'preview' ? Theme.brandSubtle : Color.Transparent)
        .onClick(() => {
          this.setMode('preview');
        })
    }
    .padding(2)
    .borderRadius(Layout.radiusS)
    .backgroundColor(Theme.bgSurface)
  }

  @Builder
  dryRunButton() {
    Text(this.dryRunning ? '试跑中' : '试跑')
      .fontSize(Layout.fontSmall)
      .fontColor(Theme.textPrimary)
      .height(28)
      .padding({ left: Layout.s2, right: Layout.s2 })
      .borderRadius(Layout.radiusS)
      .backgroundColor(Theme.bgSurface)
      .opacity(this.dryRunning ? Layout.disabledOpacity : 1)
      .onClick(() => {
        this.dryRun();
      })
  }

  @Builder
  saveButton() {
    Text(this.saving ? '保存中' : '保存')
      .fontSize(Layout.fontSmall)
      .fontColor(Theme.textOnBrand)
      .height(28)
      .padding({ left: Layout.s3, right: Layout.s3 })
      .borderRadius(Layout.radiusS)
      .backgroundColor(Theme.brand)
      .opacity(this.saving ? Layout.disabledOpacity : 1)
      .onClick(() => {
        this.save();
      })
  }

  @Builder
  titleRow(showListBack: boolean, showActions: boolean) {
    Row({ space: Layout.s2 }) {
      if (showListBack) {
        Stack() {
          SymbolGlyph(Icons.backArrow)
            .fontSize(Layout.iconM)
            .fontColor([Theme.iconPrimary])
        }
        .width(28)
        .height(28)
        .borderRadius(Layout.radiusS)
        .backgroundColor(Theme.bgSurface)
        .onClick(() => {
          this.foldedDetail = false;
        })
      }

      Text(this.titleName)
        .fontSize(Layout.fontTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      if (this.dirty) {
        Text('未保存')
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.warning)
      }

      Text('SKILL.md')
        .fontSize(Layout.fontCaption)
        .fontFamily('monospace')
        .fontColor(Theme.textSecondary)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(6)
        .backgroundColor(Theme.bgSurface2)

      if (showActions) {
        this.modeSwitch()
        this.dryRunButton()
        this.saveButton()
      }
    }
    .width('100%')
    .height(Layout.topBarHeight)
    .padding({ left: Layout.s2, right: Layout.s3 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  detailTopBar() {
    if (this.unfolded) {
      this.titleRow(false, true)
    } else {
      Column() {
        this.titleRow(true, false)
        Row({ space: Layout.s2 }) {
          this.modeSwitch()
          Blank()
          this.dryRunButton()
          this.saveButton()
        }
        .width('100%')
        .padding({ left: Layout.s3, right: Layout.s3, bottom: Layout.s2 })
      }
      .width('100%')
    }
  }

  // ---------------------------------------------------------------------------
  // UI —— 编辑区 / 状态条
  // ---------------------------------------------------------------------------

  @Builder
  statusBanner() {
    if (this.bannerText.length > 0) {
      Row({ space: 6 }) {
        SymbolGlyph(this.bannerError ? Icons.warnCircle : Icons.checkmarkCircle)
          .fontSize(Layout.iconS)
          .fontColor([this.bannerError ? Theme.danger : Theme.success])
        Text(this.bannerText)
          .fontSize(Layout.fontSmall)
          .fontColor(this.bannerError ? Theme.danger : Theme.success)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph(Icons.close)
          .fontSize(Layout.iconS)
          .fontColor([Theme.textTertiary])
          .onClick(() => {
            this.clearBanner();
          })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: Layout.s2, bottom: Layout.s2 })
      .borderRadius(Layout.radiusM)
      .backgroundColor(this.bannerError ? Theme.dangerSubtle : Theme.successSubtle)
      .alignItems(VerticalAlign.Top)
    }
  }

  @Builder
  dryRunBanner() {
    Row({ space: Layout.s2 }) {
      Text(this.dryRunText)
        .fontSize(Layout.fontSmall)
        .fontColor(this.dryRunError ? Theme.danger : Theme.textSecondary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('关闭')
        .fontSize(Layout.fontSmall)
        .fontColor(Theme.textTertiary)
        .onClick(() => {
          this.dryRunText = '';
        })
    }
    .width('100%')
    .padding({ left: Layout.s3, right: Layout.s3, top: Layout.s2, bottom: Layout.s2 })
    .backgroundColor(Theme.brandSubtle)
    .border({ width: { top: 1 }, color: Theme.divider })
  }

  @Builder
  editorCard() {
    Column() {
      if (this.mode === 'edit') {
        TextArea({ text: this.markdown, placeholder: 'SKILL.md' })
          .fontSize(Layout.fontUi)
          .fontFamily('monospace')
          .fontColor(Theme.textPrimary)
          .placeholderColor(Theme.textTertiary)
          .lineHeight(19) // 12 × 1.6 ≈ 19（对齐设计稿 leading-relaxed）
          .backgroundColor(Color.Transparent)
          .padding(Layout.s3)
          .width('100%')
          .layoutWeight(1)
          .onChange((value: string) => {
            this.markdown = value;
            this.dirty = true;
          })
      } else {
        Column() {
          SkillMdPreview({ markdown: this.markdown })
        }
        .layoutWeight(1)
        .width('100%')
      }

      if (this.dryRunText.length > 0) {
        this.dryRunBanner()
      }
    }
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.divider })
    .clip(true)
  }

  @Builder
  aiBar() {
    Row({ space: Layout.s2 }) {
      SymbolGlyph(Icons.sparkles)
        .fontSize(Layout.iconM)
        .fontColor([Theme.brand])
      TextInput({ text: this.aiInput, placeholder: '输入修改要求…' })
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textPrimary)
        .placeholderColor(Theme.textTertiary)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(32)
        .layoutWeight(1)
        .enabled(!this.rewriting)
        .onChange((value: string) => {
          this.aiInput = value;
        })
      Text(this.rewriting ? '改写中' : '改写')
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textOnBrand)
        .padding({ left: Layout.s3, right: Layout.s3, top: 6, bottom: 6 })
        .borderRadius(Layout.radiusM)
        .backgroundColor(this.rewriting ? Theme.bgSurface3 : Theme.brand)
        .onClick(() => {
          this.rewrite();
        })
    }
    .width('100%')
    .height(48)
    .padding({ left: 10, right: 6 })
    .borderRadius(Layout.radiusL)
    .backgroundColor(Theme.bgInput)
    .border({ width: 1, color: Theme.border })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  detailContent() {
    Column() {
      this.detailTopBar()
      Divider()
        .color(Theme.divider)
        .strokeWidth(1)

      Column({ space: Layout.s2 }) {
        this.statusBanner()
        this.editorCard()
        this.aiBar()
      }
      .layoutWeight(1)
      .width('100%')
      .padding(Layout.s3)
    }
    .width('100%')
    .height('100%')
  }

  // ---------------------------------------------------------------------------
  // UI —— 状态页
  // ---------------------------------------------------------------------------

  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(32)
        .height(32)
        .color(Theme.brand)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  missingView() {
    Column({ space: Layout.s2 }) {
      Text('技能模块不可用')
        .fontSize(Layout.fontBody)
        .fontColor(Theme.warning)
      Text(this.pluginError.length > 0 ? this.pluginError : '请重启应用后再试')
        .fontSize(Layout.fontSmall)
        .fontColor(Theme.textTertiary)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(Layout.pagePadding)
    .alignItems(HorizontalAlign.Start)
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @Builder
  masterList() {
    CreatorMasterList({
      skills: this.filteredItems(),
      selectedId: this.selectedId,
      searchText: this.searchText,
      onSearch: (text: string) => {
        this.searchText = text;
      },
      onSelect: (id: string) => {
        this.openSkill(id);
      },
      onNew: () => {
        this.startNewDraft();
      },
      onBackChat: () => {
        this.backToChat();
      }
    })
  }

  build() {
    Column() {
      if (this.loading) {
        this.loadingView()
      } else if (this.pluginMissing) {
        this.missingView()
      } else if (this.unfolded) {
        Row() {
          Column() {
            this.masterList()
          }
          .width(Layout.sidebarSkills)
          .height('100%')

          Divider()
            .vertical(true)
            .color(Theme.divider)
            .strokeWidth(1)
            .height('100%')

          Column() {
            this.detailContent()
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.foldedDetail) {
        Column() {
          this.detailContent()
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        Column() {
          this.masterList()
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgPage)
  }
}
