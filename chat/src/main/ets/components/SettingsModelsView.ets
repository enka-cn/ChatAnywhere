/**
 * 设置 · 模型与密钥（v3.4）。
 *
 * 三张厂商卡（独立 @Component VendorCard）：地址 / Key / 状态 / 测试连接 / 拉取模型；
 * 拉取后把真实模型写入 RDB 注册表，chips 为四态胶囊（idle/loading/success/error）：
 * 点击 idle/error = 添加；点击 success = 取消（活跃模型自动回退）；失败保留绿色并提示。
 */
import { ProviderModelRecord, SecretAliases, SettingsKeys } from '@app/core_model';
import { ConnectionTestResult, ModelCatalogApi, ModelProfile, ProtocolKind } from '@app/core_protocol';
import { AppServices } from '../app/AppServices';
import { Icons, Layout, Theme } from '../app/Theme';
import { ModelAddStatus } from './ModelProbeChip';
import { VendorCard } from './VendorCard';
const PID_DS: string = 'deepseek';
const PID_AN: string = 'anthropic';
const PID_OA: string = 'openai_compat';
@Component
export struct SettingsModelsView {
  @State private dsUrl: string = 'https://api.deepseek.com';
  @State private anUrl: string = '';
  @State private oaUrl: string = '';
  @State private oaModel: string = '';
  @State private dsConfigured: boolean = false;
  @State private anConfigured: boolean = false;
  @State private oaConfigured: boolean = false;
  @State private dsTesting: boolean = false;
  @State private anTesting: boolean = false;
  @State private oaTesting: boolean = false;
  @State private dsPulling: boolean = false;
  @State private anPulling: boolean = false;
  @State private oaPulling: boolean = false;
  @State private dsTestResult: string = '';
  @State private anTestResult: string = '';
  @State private oaTestResult: string = '';
  @State private dsPullResult: string = '';
  @State private anPullResult: string = '';
  @State private oaPullResult: string = '';
  @State private profiles: ModelProfile[] = [];
  @State private records: ProviderModelRecord[] = [];
  @State private activeModelId: string = '';
  @State private statusText: string = '';
  /** 模型胶囊四态（key = providerId:modelId；整体替换数组触发刷新）。 */
  @State private modelStatuses: ModelAddStatus[] = [];
  /** 取消失败提示（按 provider 归属，显示在对应厂商卡 chips 下方）。 */
  @State private toggleError: string = '';
  @State private toggleErrorProvider: string = '';
  aboutToAppear(): void {
    this.load();
  }
  private async load(): Promise<void> {
    this.toggleError = '';
    this.toggleErrorProvider = '';
    try {
      const services = AppServices.get();
      const model = services.requireModel();
      this.dsConfigured = await model.secrets.has(SecretAliases.DEEPSEEK);
      this.anConfigured = await model.secrets.has(SecretAliases.ANTHROPIC);
      this.oaConfigured = await model.secrets.has(SecretAliases.OPENAI_COMPAT);
      this.anUrl = await model.repo.getString(SettingsKeys.ANTHROPIC_BASE_URL, '');
      this.oaUrl = await model.repo.getString(SettingsKeys.CUSTOM_BASE_URL, '');
      this.oaModel = await model.repo.getString(SettingsKeys.CUSTOM_MODEL_ID, '');
      const catalog = services.requireProtocol().catalog;
      if (this.anUrl.length === 0) {
        const meta = catalog.providerMeta(PID_AN);
        this.anUrl = meta !== null ? meta.defaultBaseUrl : 'https://api.anthropic.com';
      }
      if (this.oaUrl.length === 0) {
        const meta = catalog.providerMeta(PID_OA);
        this.oaUrl = meta !== null ? meta.defaultBaseUrl : 'https://api.openai.com/v1';
      }
      await this.reloadCatalog();
      await this.reloadRecords();
      this.syncStatuses();
    } catch (e) {
      this.setStatus(`${(e as Error).message}`);
    }
  }
  private async reloadCatalog(): Promise<void> {
    try {
      const services = AppServices.get();
      const catalog = services.requireProtocol().catalog;
      this.profiles = catalog.listProfiles();
      const stored: string = await services.requireModel().repo.getString(SettingsKeys.ACTIVE_MODEL, '');
      const found: ModelProfile | null = stored.length > 0 ? catalog.findByModelId(stored) : null;
      this.activeModelId = found !== null ? found.modelId : '';
      if (this.activeModelId.length === 0 && this.profiles.length > 0) {
        const fallback: ModelProfile | null = catalog.defaultProfile();
        this.activeModelId = fallback !== null ? fallback.modelId : this.profiles[0].modelId;
      }
    } catch (e) {
      this.setStatus(`${(e as Error).message}`);
    }
  }
  private async reloadRecords(): Promise<void> {
    try {
      this.records = await AppServices.get().requireModel().repo.loadModels();
    } catch (e) {
      this.records = [];
    }
  }
  private setStatus(text: string): void {
    this.statusText = text;
  }
  private recordsFor(providerId: string): ProviderModelRecord[] {
    const out: ProviderModelRecord[] = [];
    for (const one of this.records) {
      if (one.providerId === providerId) {
        out.push(one);
      }
    }
    return out;
  }
  private profilesFor(providerId: string): ModelProfile[] {
    const out: ModelProfile[] = [];
    for (const one of this.profiles) {
      if (one.providerId === providerId) {
        out.push(one);
      }
    }
    return out;
  }
  private titleFor(providerId: string): string {
    if (providerId === PID_DS) {
      return 'DeepSeek';
    }
    if (providerId === PID_AN) {
      return 'Anthropic';
    }
    return 'OpenAI 兼容';
  }
  private aliasFor(providerId: string): string {
    if (providerId === PID_DS) {
      return SecretAliases.DEEPSEEK;
    }
    if (providerId === PID_AN) {
      return SecretAliases.ANTHROPIC;
    }
    return SecretAliases.OPENAI_COMPAT;
  }
  private urlFor(providerId: string): string {
    if (providerId === PID_DS) {
      return this.dsUrl.trim();
    }
    if (providerId === PID_AN) {
      return this.anUrl.trim();
    }
    return this.oaUrl.trim();
  }
  /** 探测/测试用模型 id：优先已启用，其次已发现；未知返回空串（/models 探测不需要模型 id）。 */
  private probeModelId(providerId: string): string {
    const enabled: ModelProfile[] = this.profilesFor(providerId);
    if (enabled.length > 0) {
      return enabled[0].modelId;
    }
    const discovered: ProviderModelRecord[] = this.recordsFor(providerId);
    if (discovered.length > 0) {
      return discovered[0].modelId;
    }
    if (providerId === PID_OA && this.oaModel.trim().length > 0) {
      return this.oaModel.trim();
    }
    return '';
  }
  private protocolFor(providerId: string): ProtocolKind {
    if (providerId === PID_DS) {
      return 'deepseek_responses';
    }
    if (providerId === PID_AN) {
      return 'anthropic_messages';
    }
    return 'openai_chat';
  }
  private buildProfileFor(providerId: string): ModelProfile {
    const modelId: string = this.probeModelId(providerId);
    const url: string = this.urlFor(providerId);
    try {
      const built: ModelProfile | null =
        AppServices.get().requireProtocol().catalog.buildProfile(providerId, modelId, url);
      if (built !== null) {
        return built;
      }
    } catch (e) {
    }
    const profile: ModelProfile = {
      providerId: providerId,
      modelId: modelId,
      protocol: this.protocolFor(providerId),
      baseUrl: url,
      assetKeyAlias: this.aliasFor(providerId),
      contextWindow: 128000,
      cacheMissToHitRatio: 4,
      cacheIdleTtlSec: 600,
      supportsServerWebTools: providerId === PID_DS,
      supportsThinking: true,
      supportsJsonSchema: true,
      label: this.titleFor(providerId),
      builtin: true
    };
    return profile;
  }
  private async saveKey(providerId: string, key: string): Promise<boolean> {
    const trimmed: string = key.trim();
    const title: string = this.titleFor(providerId);
    if (trimmed.length === 0) {
      this.setStatus(`${title}：请输入 Key`);
      return false;
    }
    if (providerId === PID_AN && !this.anUrl.trim().startsWith('http')) {
      this.setStatus('Anthropic：地址需以 http 开头');
      return false;
    }
    if (providerId === PID_OA && !this.oaUrl.trim().startsWith('http')) {
      this.setStatus('OpenAI 兼容：地址需以 http 开头');
      return false;
    }
    try {
      const services = AppServices.get();
      await services.requireModel().secrets.put(this.aliasFor(providerId), trimmed);
      if (providerId === PID_DS) {
        this.dsConfigured = true;
      } else if (providerId === PID_AN) {
        this.anConfigured = true;
        await services.requireModel().repo.putString(SettingsKeys.ANTHROPIC_BASE_URL, this.anUrl.trim());
      } else {
        this.oaConfigured = true;
        await services.requireModel().repo.putString(SettingsKeys.CUSTOM_BASE_URL, this.oaUrl.trim());
        if (this.oaModel.trim().length > 0) {
          await services.requireModel().repo.putString(SettingsKeys.CUSTOM_MODEL_ID, this.oaModel.trim());
        }
      }
      this.setStatus(`${title} 已加密保存`);
      return true;
    } catch (e) {
      this.setStatus(`保存失败：${(e as Error).message}`);
      return false;
    }
  }
  private async test(providerId: string, key: string): Promise<void> {
    const title: string = this.titleFor(providerId);
    this.setTesting(providerId, true);
    this.setTestResult(providerId, '');
    try {
      const override: string = key.trim();
      const result: ConnectionTestResult = await AppServices.get().requireProtocol().testConnection(
        this.buildProfileFor(providerId), override.length > 0 ? override : undefined);
      if (result.ok) {
        this.setTestResult(providerId, `连接成功 · ${result.latencyMs} 毫秒`);
      } else {
        const reason: string = result.message.length > 0 ? result.message : '请检查 Key 与网络';
        this.setTestResult(providerId, `连接失败：${reason}`);
      }
    } catch (e) {
      this.setTestResult(providerId, `连接失败：${(e as Error).message}`);
    }
    this.setTesting(providerId, false);
    this.setStatus(`${title} 测试完成`);
  }
  private async pull(providerId: string, key: string): Promise<void> {
    const title: string = this.titleFor(providerId);
    this.setPulling(providerId, true);
    this.setPullResult(providerId, '');
    try {
      const override: string = key.trim();
      const infos = await AppServices.get().requireProtocol().listRemoteModels(
        this.buildProfileFor(providerId), override.length > 0 ? override : undefined);
      if (infos.length === 0) {
        this.setPullResult(providerId, '没有拉到模型，检查 Key 与地址');
      } else {
        await AppServices.get().requireProtocol().catalog.applyDiscoveredModels(providerId, infos);
        await this.reloadRecords();
        await this.reloadCatalog();
        this.syncStatuses();
        this.setPullResult(providerId, `已发现 ${infos.length} 个模型`);
        this.setStatus(`${title}：${infos.length} 个模型待添加`);
      }
    } catch (e) {
      this.setPullResult(providerId, `拉取失败：${(e as Error).message}`);
    }
    this.setPulling(providerId, false);
  }
  /** 由 RDB 记录重建四态：已启用回显 success，其余 idle。 */
  private syncStatuses(): void {
    const next: ModelAddStatus[] = [];
    for (const one of this.records) {
      const entry: ModelAddStatus = {
        key: `${one.providerId}:${one.modelId}`,
        status: one.enabled ? 'success' : 'idle',
        error: ''
      };
      next.push(entry);
    }
    this.modelStatuses = next;
  }
  private statusOfKey(key: string): string {
    for (const one of this.modelStatuses) {
      if (one.key === key) {
        return one.status;
      }
    }
    return 'idle';
  }
  private setStatusFor(key: string, status: string, error: string): void {
    const next: ModelAddStatus[] = [];
    let found: boolean = false;
    for (const one of this.modelStatuses) {
      if (one.key === key) {
        const updated: ModelAddStatus = { key: key, status: status, error: error };
        next.push(updated);
        found = true;
      } else {
        next.push(one);
      }
    }
    if (!found) {
      const added: ModelAddStatus = { key: key, status: status, error: error };
      next.push(added);
    }
    this.modelStatuses = next;
  }
  /** 双向切换：idle/error → 添加；success → 取消；loading 直接 return（防连点）。 */
  private async toggleModel(providerId: string, modelId: string): Promise<void> {
    const key: string = `${providerId}:${modelId}`;
    const current: string = this.statusOfKey(key);
    if (current === 'loading') {
      return;
    }
    this.toggleError = '';
    this.toggleErrorProvider = '';
    if (current === 'success') {
      await this.removeModel(providerId, modelId);
      return;
    }
    await this.appendModel(providerId, modelId);
  }
  /** 添加：loading → setModelEnabled(true) → load → success。 */
  private async appendModel(providerId: string, modelId: string): Promise<void> {
    const key: string = `${providerId}:${modelId}`;
    this.setStatusFor(key, 'loading', '');
    const hadActive: boolean = this.activeModelId.length > 0;
    try {
      const services = AppServices.get();
      const catalog = services.requireProtocol().catalog;
      await catalog.setModelEnabled(providerId, modelId, true);
      await this.load();
      this.setStatusFor(key, 'success', '');
      if (!hadActive) {
        const found: ModelProfile | null = catalog.get(providerId, modelId);
        if (found !== null) {
          await services.setActiveProfile(found.providerId, found.modelId);
          this.activeModelId = found.modelId;
        }
      }
      this.setStatus(`${this.titleFor(providerId)}：已添加 ${modelId}`);
    } catch (e) {
      const raw: string = (e as Error).message;
      const reason: string = raw.length > 60 ? raw.substring(0, 60) : raw;
      this.setStatusFor(key, 'error', reason.length > 0 ? reason : '添加失败，请重试');
    } finally {
      if (this.statusOfKey(key) === 'loading') {
        this.setStatusFor(key, 'idle', '');
      }
    }
  }
  /** 取消：loading → unregister → load → idle；活跃模型被移除时自动回退。 */
  private async removeModel(providerId: string, modelId: string): Promise<void> {
    const key: string = `${providerId}:${modelId}`;
    const wasActive: boolean = this.activeModelId === modelId;
    this.setStatusFor(key, 'loading', '');
    try {
      const services = AppServices.get();
      const catalog = services.requireProtocol().catalog;
      await catalog.unregister(providerId, modelId);
      await this.load();
      this.setStatusFor(key, 'idle', '');
      this.toggleError = '';
      if (wasActive) {
        await this.rollbackActive(services, catalog, providerId);
      }
      this.setStatus(`${this.titleFor(providerId)}：已取消 ${modelId}`);
    } catch (e) {
      const raw: string = (e as Error).message;
      const reason: string = raw.length > 60 ? raw.substring(0, 60) : raw;
      this.setStatusFor(key, 'success', '');
      this.toggleErrorProvider = providerId;
      this.toggleError = `取消失败：${reason.length > 0 ? reason : '请重试'}`;
    } finally {
      if (this.statusOfKey(key) === 'loading') {
        this.setStatusFor(key, 'success', '');
      }
    }
  }
  /** 被移除的是当前模型：有剩余切第一项，无剩余清空；回退失败仅提示，不改胶囊状态。 */
  private async rollbackActive(services: AppServices, catalog: ModelCatalogApi, providerId: string): Promise<void> {
    try {
      const remaining: ModelProfile[] = catalog.listProfiles();
      if (remaining.length > 0) {
        await services.setActiveProfile(remaining[0].providerId, remaining[0].modelId);
        this.activeModelId = remaining[0].modelId;
      } else {
        await services.clearActiveProfile();
        this.activeModelId = '';
      }
    } catch (e) {
      const raw: string = (e as Error).message;
      const reason: string = raw.length > 60 ? raw.substring(0, 60) : raw;
      this.toggleErrorProvider = providerId;
      this.toggleError = `取消失败：${reason.length > 0 ? reason : '请重试'}`;
    }
  }
  private setTesting(providerId: string, value: boolean): void {
    if (providerId === PID_DS) { this.dsTesting = value; } else if (providerId === PID_AN) { this.anTesting = value; } else { this.oaTesting = value; }
  }
  private setPulling(providerId: string, value: boolean): void {
    if (providerId === PID_DS) { this.dsPulling = value; } else if (providerId === PID_AN) { this.anPulling = value; } else { this.oaPulling = value; }
  }
  private setTestResult(providerId: string, value: string): void {
    if (providerId === PID_DS) { this.dsTestResult = value; } else if (providerId === PID_AN) { this.anTestResult = value; } else { this.oaTestResult = value; }
  }
  private setPullResult(providerId: string, value: string): void {
    if (providerId === PID_DS) { this.dsPullResult = value; } else if (providerId === PID_AN) { this.anPullResult = value; } else { this.oaPullResult = value; }
  }
  private async pickActive(profile: ModelProfile): Promise<void> {
    try {
      await AppServices.get().setActiveProfile(profile.providerId, profile.modelId);
      this.activeModelId = profile.modelId;
      this.setStatus(`当前模型：${profile.label}`);
    } catch (e) {
      this.setStatus(`${(e as Error).message}`);
    }
  }
  @Builder
  modelRow(profile: ModelProfile) {
    Row({ space: Layout.s2 }) {
      Column({ space: 2 }) {
        Text(profile.label).fontSize(Layout.fontUi).fontColor(Theme.textPrimary)
        Text(profile.modelId).fontSize(Layout.fontCaption).fontColor(Theme.textTertiary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (profile.modelId === this.activeModelId) {
        SymbolGlyph(Icons.check).fontSize(Layout.iconM).fontColor([Theme.brand])
      }
    }.width('100%').height(48).padding({ left: Layout.s3, right: Layout.s3 })
    .onClick(() => {
      this.pickActive(profile);
    })
  }
  build() {
    Scroll() {
      Column({ space: Layout.s3 }) {
        if (this.statusText.length > 0) {
          Text(this.statusText).fontSize(Layout.fontSmall).fontColor(Theme.textSecondary).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        VendorCard({
          providerId: PID_DS, title: 'DeepSeek', configured: this.dsConfigured, urlEditable: false, url: $dsUrl,
          testing: this.dsTesting, pulling: this.dsPulling, testResult: this.dsTestResult, pullResult: this.dsPullResult,
          models: this.recordsFor(PID_DS), statuses: this.modelStatuses,
          notice: this.toggleErrorProvider === PID_DS ? this.toggleError : '',
          onSaveKey: (key: string) => this.saveKey(PID_DS, key), onTest: (key: string) => this.test(PID_DS, key),
          onPull: (key: string) => this.pull(PID_DS, key), onAddModel: (modelId: string) => this.toggleModel(PID_DS, modelId)
        })
        VendorCard({
          providerId: PID_AN, title: 'Anthropic', configured: this.anConfigured, urlEditable: true, url: $anUrl,
          testing: this.anTesting, pulling: this.anPulling, testResult: this.anTestResult, pullResult: this.anPullResult,
          models: this.recordsFor(PID_AN), statuses: this.modelStatuses,
          notice: this.toggleErrorProvider === PID_AN ? this.toggleError : '',
          onSaveKey: (key: string) => this.saveKey(PID_AN, key), onTest: (key: string) => this.test(PID_AN, key),
          onPull: (key: string) => this.pull(PID_AN, key), onAddModel: (modelId: string) => this.toggleModel(PID_AN, modelId)
        })
        Column({ space: Layout.s2 }) {
          VendorCard({
            providerId: PID_OA, title: 'OpenAI 兼容', configured: this.oaConfigured, urlEditable: true, url: $oaUrl,
            testing: this.oaTesting, pulling: this.oaPulling, testResult: this.oaTestResult, pullResult: this.oaPullResult,
            models: this.recordsFor(PID_OA), statuses: this.modelStatuses,
            notice: this.toggleErrorProvider === PID_OA ? this.toggleError : '',
            onSaveKey: (key: string) => this.saveKey(PID_OA, key), onTest: (key: string) => this.test(PID_OA, key),
            onPull: (key: string) => this.pull(PID_OA, key), onAddModel: (modelId: string) => this.toggleModel(PID_OA, modelId)
          })
          TextInput({ text: this.oaModel, placeholder: '模型名（可选）' }).fontSize(Layout.fontUi).height(36).width('100%').backgroundColor(Theme.bgInput).borderRadius(Layout.radiusM).padding({ left: Layout.s3, right: Layout.s3 })
            .onChange((value: string) => {
              this.oaModel = value;
            })
        }.width('100%')
        Text('当前模型').fontSize(Layout.fontSmall).fontColor(Theme.textSecondary).width('100%').padding({ left: Layout.s1, top: Layout.s2 })
        if (this.profiles.length === 0) {
          Text('填写密钥并拉取模型后才可对话').fontSize(Layout.fontUi).fontColor(Theme.textTertiary).width('100%').padding(Layout.s3).backgroundColor(Theme.bgSurface).borderRadius(Layout.radiusL)
        } else {
          Column() {
            ForEach(this.profiles, (profile: ModelProfile, index: number) => {
              this.modelRow(profile)
              if (index < this.profiles.length - 1) {
                Divider().color(Theme.divider).margin({ left: Layout.s3 })
              }
            }, (profile: ModelProfile) => `${profile.providerId}/${profile.modelId}`)
          }.width('100%').backgroundColor(Theme.bgSurface).borderRadius(Layout.radiusL).border({ width: 1, color: Theme.border })
        }
      }.width('100%').padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s3, bottom: Layout.s8 }).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
  }
}
