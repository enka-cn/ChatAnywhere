/**
 * 设置 · 模型与密钥（v3 卡片）。
 *
 * DeepSeek / Anthropic / OpenAI 兼容三张卡片：名称 + 状态 + 地址 + API Key；
 * Key 只进 Asset Store，界面只显示「已加密保存」。另有当前模型选择列表。
 */
import { SecretAliases, SettingsKeys } from '@app/core_model';
import { ConnectionTestResult, ModelProfile } from '@app/core_protocol';
import { AppServices } from '../app/AppServices';
import { Icons, Layout, Theme } from '../app/Theme';

const VENDOR_DS: string = 'deepseek';
const VENDOR_AN: string = 'anthropic';
const VENDOR_OA: string = 'custom';

@Component
export struct SettingsModelsView {
  @State private dsConfigured: boolean = false;
  @State private anConfigured: boolean = false;
  @State private oaConfigured: boolean = false;

  @State private dsUrl: string = 'https://api.deepseek.com';
  @State private anUrl: string = 'https://api.anthropic.com';
  @State private oaUrl: string = '';
  @State private oaModel: string = '';
  @State private dsKey: string = '';
  @State private anKey: string = '';
  @State private oaKey: string = '';

  @State private dsTesting: boolean = false;
  @State private anTesting: boolean = false;
  @State private oaTesting: boolean = false;
  @State private dsResult: string = '';
  @State private anResult: string = '';
  @State private oaResult: string = '';

  @State private profiles: ModelProfile[] = [];
  @State private activeModelId: string = '';
  @State private statusText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const services = AppServices.get();
      const model = services.requireModel();
      this.dsConfigured = await model.secrets.has(SecretAliases.DEEPSEEK);
      this.anConfigured = await model.secrets.has(SecretAliases.ANTHROPIC);
      this.oaConfigured = await model.secrets.has(SecretAliases.OPENAI_COMPAT);
      this.anUrl = await model.repo.getString(SettingsKeys.ANTHROPIC_BASE_URL, 'https://api.anthropic.com');
      this.oaUrl = await model.repo.getString(SettingsKeys.CUSTOM_BASE_URL, '');
      this.oaModel = await model.repo.getString(SettingsKeys.CUSTOM_MODEL_ID, '');
      const active: ModelProfile = await services.resolveActiveProfile();
      this.activeModelId = active.modelId;
      this.applyProfiles(services.requireProtocol().catalog.listProfiles());
    } catch (e) {
      this.statusText = `${(e as Error).message}`;
    }
  }

  private applyProfiles(all: ModelProfile[]): void {
    const custom: string = this.oaModel.trim();
    const list: ModelProfile[] = [];
    for (const one of all) {
      if (one.providerId === VENDOR_OA && custom.length > 0 && one.modelId !== custom) {
        continue;
      }
      list.push(one);
    }
    this.profiles = list;
  }

  private setStatus(text: string): void {
    this.statusText = text;
  }

  private findProfile(providerId: string): ModelProfile | null {
    for (const one of this.profiles) {
      if (one.providerId === providerId) {
        return one;
      }
    }
    return null;
  }

  private findProfileByProtocol(protocol: string): ModelProfile | null {
    for (const one of this.profiles) {
      if (one.protocol === protocol) {
        return one;
      }
    }
    return null;
  }

  private defaultProfile(): ModelProfile {
    return AppServices.get().requireProtocol().catalog.defaultProfile();
  }

  private withBaseUrl(source: ModelProfile, baseUrl: string): ModelProfile {
    const out: ModelProfile = {
      providerId: source.providerId,
      modelId: source.modelId,
      protocol: source.protocol,
      baseUrl: baseUrl,
      assetKeyAlias: source.assetKeyAlias,
      contextWindow: source.contextWindow,
      cacheMissToHitRatio: source.cacheMissToHitRatio,
      cacheIdleTtlSec: source.cacheIdleTtlSec,
      supportsServerWebTools: source.supportsServerWebTools,
      supportsThinking: source.supportsThinking,
      supportsJsonSchema: source.supportsJsonSchema,
      label: source.label,
      builtin: source.builtin
    };
    return out;
  }

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  private async saveKey(alias: string, value: string, label: string): Promise<boolean> {
    const trimmed: string = value.trim();
    if (trimmed.length === 0) {
      this.setStatus(`${label}：请输入 Key`);
      return false;
    }
    try {
      await AppServices.get().requireModel().secrets.put(alias, trimmed);
      if (alias === SecretAliases.DEEPSEEK) {
        this.dsConfigured = true;
      } else if (alias === SecretAliases.ANTHROPIC) {
        this.anConfigured = true;
      } else {
        this.oaConfigured = true;
      }
      this.setStatus(`${label} 已加密保存`);
      return true;
    } catch (e) {
      this.setStatus(`保存失败：${(e as Error).message}`);
      return false;
    }
  }

  private async saveDeepSeek(): Promise<void> {
    const ok: boolean = await this.saveKey(SecretAliases.DEEPSEEK, this.dsKey, 'DeepSeek');
    if (ok) {
      this.dsKey = '';
    }
  }

  private async saveAnthropic(): Promise<void> {
    const ok: boolean = await this.saveKey(SecretAliases.ANTHROPIC, this.anKey, 'Anthropic');
    if (ok) {
      this.anKey = '';
    }
    if (!ok && !this.anConfigured) {
      return;
    }
    try {
      const services = AppServices.get();
      const url: string = this.anUrl.trim();
      if (url.startsWith('http')) {
        await services.requireModel().repo.putString(SettingsKeys.ANTHROPIC_BASE_URL, url);
        const base: ModelProfile | null = this.findProfile(VENDOR_AN);
        if (base !== null) {
          services.requireProtocol().catalog.register(this.withBaseUrl(base, url));
        }
      }
      this.applyProfiles(services.requireProtocol().catalog.listProfiles());
    } catch (e) {
      this.setStatus(`保存失败：${(e as Error).message}`);
    }
  }

  private async saveOpenAICompat(): Promise<void> {
    const url: string = this.oaUrl.trim();
    const model: string = this.oaModel.trim();
    if (!url.startsWith('http')) {
      this.setStatus('地址需以 http 开头');
      return;
    }
    if (model.length === 0) {
      this.setStatus('请填写模型名');
      return;
    }
    const ok: boolean = await this.saveKey(SecretAliases.OPENAI_COMPAT, this.oaKey, 'OpenAI 兼容');
    if (ok) {
      this.oaKey = '';
    }
    if (!ok && !this.oaConfigured) {
      return;
    }
    try {
      const services = AppServices.get();
      const profile: ModelProfile = {
        providerId: VENDOR_OA,
        modelId: model,
        protocol: 'openai_chat',
        baseUrl: url,
        assetKeyAlias: SecretAliases.OPENAI_COMPAT,
        contextWindow: 128000,
        cacheMissToHitRatio: 4,
        cacheIdleTtlSec: 600,
        supportsServerWebTools: false,
        supportsThinking: true,
        supportsJsonSchema: true,
        label: '自定义兼容接口',
        builtin: false
      };
      services.requireProtocol().catalog.register(profile);
      await services.requireModel().repo.putString(SettingsKeys.CUSTOM_BASE_URL, url);
      await services.requireModel().repo.putString(SettingsKeys.CUSTOM_MODEL_ID, model);
      await services.setActiveProfile(profile.providerId, profile.modelId);
      this.activeModelId = profile.modelId;
      this.applyProfiles(services.requireProtocol().catalog.listProfiles());
    } catch (e) {
      this.setStatus(`保存失败：${(e as Error).message}`);
    }
  }

  // ---------------------------------------------------------------------------
  // 测试连接
  // ---------------------------------------------------------------------------

  private async testProfile(profile: ModelProfile | null): Promise<string> {
    if (profile === null) {
      return '没有可用配置';
    }
    try {
      const result: ConnectionTestResult =
        await AppServices.get().requireProtocol().testConnection(profile);
      if (result.ok) {
        return `连接成功 · ${result.latencyMs} 毫秒`;
      }
      return `连接失败：${result.message.length > 0 ? result.message : '请检查 Key 与网络'}`;
    } catch (e) {
      return `连接失败：${(e as Error).message}`;
    }
  }

  private async testDeepSeek(): Promise<void> {
    this.dsTesting = true;
    this.dsResult = '测试中';
    const found: ModelProfile | null = this.findProfile(VENDOR_DS);
    const base: ModelProfile = found !== null ? found : this.defaultProfile();
    this.dsResult = await this.testProfile(this.withBaseUrl(base, this.dsUrl.trim()));
    this.dsTesting = false;
  }

  private async testAnthropic(): Promise<void> {
    this.anTesting = true;
    this.anResult = '测试中';
    const found: ModelProfile | null = this.findProfile(VENDOR_AN);
    const base: ModelProfile | null = found !== null ? found : this.findProfileByProtocol('anthropic_messages');
    this.anResult = await this.testProfile(base === null ? null : this.withBaseUrl(base, this.anUrl.trim()));
    this.anTesting = false;
  }

  private async testOpenAICompat(): Promise<void> {
    this.oaTesting = true;
    this.oaResult = '测试中';
    const model: string = this.oaModel.trim().length > 0 ? this.oaModel.trim() : 'custom-model';
    const profile: ModelProfile = {
      providerId: VENDOR_OA,
      modelId: model,
      protocol: 'openai_chat',
      baseUrl: this.oaUrl.trim(),
      assetKeyAlias: SecretAliases.OPENAI_COMPAT,
      contextWindow: 128000,
      cacheMissToHitRatio: 4,
      cacheIdleTtlSec: 600,
      supportsServerWebTools: false,
      supportsThinking: true,
      supportsJsonSchema: true,
      label: '自定义兼容接口',
      builtin: false
    };
    this.oaResult = await this.testProfile(profile);
    this.oaTesting = false;
  }

  private async selectModel(profile: ModelProfile): Promise<void> {
    try {
      await AppServices.get().setActiveProfile(profile.providerId, profile.modelId);
      this.activeModelId = profile.modelId;
      this.setStatus(`当前模型：${profile.label}`);
    } catch (e) {
      this.setStatus(`${(e as Error).message}`);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @Builder
  stateChip(configured: boolean) {
    Text(configured ? '已加密保存' : '未配置')
      .fontSize(Layout.fontSmall)
      .fontColor(configured ? Theme.brand : Theme.textTertiary)
  }

  @Builder
  urlInput(url: string, editable: boolean, onChange: (value: string) => void) {
    if (editable) {
      TextInput({ text: url, placeholder: '接口地址' })
        .fontSize(Layout.fontUi)
        .height(36)
        .width('100%')
        .backgroundColor(Theme.bgPage)
        .borderRadius(Layout.radiusM)
        .padding({ left: Layout.s3, right: Layout.s3 })
        .onChange((value: string) => {
          onChange(value);
        })
    } else {
      TextInput({ text: url, placeholder: '接口地址' })
        .fontSize(Layout.fontUi)
        .height(36)
        .width('100%')
        .backgroundColor(Theme.bgPage)
        .borderRadius(Layout.radiusM)
        .padding({ left: Layout.s3, right: Layout.s3 })
        .enabled(false)
    }
  }

  @Builder
  keyInput(value: string, placeholder: string, onChange: (value: string) => void) {
    TextInput({ text: value, placeholder: placeholder })
      .type(InputType.Password)
      .fontSize(Layout.fontUi)
      .height(36)
      .width('100%')
      .backgroundColor(Theme.bgPage)
      .borderRadius(Layout.radiusM)
      .padding({ left: Layout.s3, right: Layout.s3 })
      .onChange((text: string) => {
        onChange(text);
      })
  }

  @Builder
  resultLine(isTesting: boolean, result: string) {
    if (isTesting || result.length > 0) {
      Text(isTesting ? '测试中' : result)
        .fontSize(Layout.fontSmall)
        .fontColor(result.startsWith('连接成功') ? Theme.success : Theme.textSecondary)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  @Builder
  vendorCard(name: string, configured: boolean, url: string, urlEditable: boolean,
    keyPlaceholder: string, testing: boolean, result: string,
    onUrlChange: (value: string) => void, onTest: () => void, onSave: () => void) {
    Column({ space: Layout.s2 }) {
      Row({ space: Layout.s2 }) {
        SymbolGlyph(Icons.key)
          .fontSize(Layout.iconM)
          .fontColor([configured ? Theme.brand : Theme.iconSecondary])
        Text(name)
          .fontSize(Layout.fontUi)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
        this.stateChip(configured)
      }
      .width('100%')

      this.urlInput(url, urlEditable, onUrlChange)

      if (name === 'DeepSeek') {
        this.keyInput(this.dsKey, keyPlaceholder, (value: string) => {
          this.dsKey = value;
        })
      } else if (name === 'Anthropic') {
        this.keyInput(this.anKey, keyPlaceholder, (value: string) => {
          this.anKey = value;
        })
      } else {
        this.keyInput(this.oaKey, keyPlaceholder, (value: string) => {
          this.oaKey = value;
        })
      }

      Row({ space: Layout.s2 }) {
        Text(testing ? '测试中' : '测试连接')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .padding({ left: Layout.s3, right: Layout.s3, top: 6, bottom: 6 })
          .borderRadius(Layout.radiusM)
          .backgroundColor(Theme.bgPage)
          .onClick(() => {
            onTest();
          })
        Blank()
        Text('保存')
          .fontSize(Layout.fontSmall)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textOnBrand)
          .padding({ left: Layout.s4, right: Layout.s4, top: 6, bottom: 6 })
          .borderRadius(Layout.radiusM)
          .backgroundColor(Theme.brand)
          .onClick(() => {
            onSave();
          })
      }
      .width('100%')

      this.resultLine(testing, result)
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
  }

  @Builder
  modelRow(profile: ModelProfile) {
    Row({ space: Layout.s2 }) {
      Column({ space: 2 }) {
        Text(profile.label)
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textPrimary)
        Text(profile.modelId)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (profile.modelId === this.activeModelId) {
        SymbolGlyph(Icons.check)
          .fontSize(Layout.iconM)
          .fontColor([Theme.brand])
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: Layout.s3, right: Layout.s3 })
    .onClick(() => {
      this.selectModel(profile);
    })
  }

  build() {
    Scroll() {
      Column({ space: Layout.s3 }) {
        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .width('100%')
        }

        this.vendorCard('DeepSeek', this.dsConfigured, this.dsUrl, false,
          this.dsConfigured ? '已保存，输入新 Key 可替换' : 'API Key',
          this.dsTesting, this.dsResult,
          (value: string) => {
          }, () => {
            this.testDeepSeek();
          }, () => {
            this.saveDeepSeek();
          })

        this.vendorCard('Anthropic', this.anConfigured, this.anUrl, true,
          this.anConfigured ? '已保存，输入新 Key 可替换' : 'API Key',
          this.anTesting, this.anResult,
          (value: string) => {
            this.anUrl = value;
          }, () => {
            this.testAnthropic();
          }, () => {
            this.saveAnthropic();
          })

        Column({ space: Layout.s2 }) {
          this.vendorCard('OpenAI 兼容', this.oaConfigured, this.oaUrl, true,
            this.oaConfigured ? '已保存，输入新 Key 可替换' : 'API Key',
            this.oaTesting, this.oaResult,
            (value: string) => {
              this.oaUrl = value;
            }, () => {
              this.testOpenAICompat();
            }, () => {
              this.saveOpenAICompat();
            })
          TextInput({ text: this.oaModel, placeholder: '模型名，如 gpt-4o-mini' })
            .fontSize(Layout.fontUi)
            .height(36)
            .width('100%')
            .backgroundColor(Theme.bgInput)
            .borderRadius(Layout.radiusM)
            .padding({ left: Layout.s3, right: Layout.s3 })
            .onChange((value: string) => {
              this.oaModel = value;
            })
        }
        .width('100%')

        Text('当前模型')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .width('100%')
          .padding({ left: Layout.s1, top: Layout.s2 })
        Column() {
          ForEach(this.profiles, (profile: ModelProfile, index: number) => {
            this.modelRow(profile)
            if (index < this.profiles.length - 1) {
              Divider().color(Theme.divider).margin({ left: Layout.s3 })
            }
          }, (profile: ModelProfile) => `${profile.providerId}/${profile.modelId}`)
        }
        .width('100%')
        .backgroundColor(Theme.bgSurface)
        .borderRadius(Layout.radiusL)
        .border({ width: 1, color: Theme.border })
      }
      .width('100%')
      .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s3, bottom: Layout.s8 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }
}
