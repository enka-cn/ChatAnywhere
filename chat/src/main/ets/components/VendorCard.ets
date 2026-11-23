/**
 * 厂商卡片（v3.2）：DeepSeek / Anthropic / OpenAI 兼容。
 *
 * 独立 @Component（@Prop 接收父级状态），保证保存密钥后立刻显示「已加密保存」、
 * 测试连接/拉取模型实时反馈；Key 只在子组件内暂存，保存后清空。
 */
import { ProviderModelRecord } from '@app/core_model';
import { Icons, Layout, Theme } from '../app/Theme';
import { ModelAddStatus, ModelProbeChip } from './ModelProbeChip';

@Component
export struct VendorCard {
  @Prop providerId: string = '';
  @Prop title: string = '';
  @Prop configured: boolean = false;
  @Prop urlEditable: boolean = false;
  @Link url: string;
  @Prop testing: boolean = false;
  @Prop pulling: boolean = false;
  @Prop testResult: string = '';
  @Prop pullResult: string = '';
  @Prop models: ProviderModelRecord[] = [];
  @Prop statuses: ModelAddStatus[] = [];
  /** 取消失败提示（danger 小字，显示在模型 chips 下方）。 */
  @Prop notice: string = '';

  onSaveKey: (key: string) => Promise<boolean> = (key: string) => Promise.resolve(false);
  onTest: (key: string) => void = (key: string) => {
  };
  onPull: (key: string) => void = (key: string) => {
  };
  onAddModel: (modelId: string) => void = (modelId: string) => {
  };

  @State private keyInput: string = '';

  /** 按 `${providerId}:${modelId}` 取四态。 */
  private statusOf(modelId: string): string {
    const key: string = `${this.providerId}:${modelId}`;
    for (const one of this.statuses) {
      if (one.key === key) {
        return one.status;
      }
    }
    return 'idle';
  }

  private errorOf(modelId: string): string {
    const key: string = `${this.providerId}:${modelId}`;
    for (const one of this.statuses) {
      if (one.key === key) {
        return one.error;
      }
    }
    return '';
  }

  private save(): void {
    this.onSaveKey(this.keyInput).then((ok: boolean) => {
      if (ok) {
        this.keyInput = '';
      }
    });
  }

  @Builder
  stateChip() {
    Text(this.configured ? '已加密保存' : '未配置')
      .fontSize(Layout.fontSmall)
      .fontColor(this.configured ? Theme.brand : Theme.textTertiary)
  }

  @Builder
  actionText(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(Layout.fontSmall)
      .fontColor(active ? Theme.textTertiary : Theme.textPrimary)
      .padding({ left: Layout.s3, right: Layout.s3, top: 6, bottom: 6 })
      .borderRadius(Layout.radiusM)
      .backgroundColor(Theme.bgPage)
      .onClick(() => {
        if (!active) {
          onTap();
        }
      })
  }

  build() {
    Column({ space: Layout.s2 }) {
      Row({ space: Layout.s2 }) {
        SymbolGlyph(Icons.key)
          .fontSize(Layout.iconM)
          .fontColor([this.configured ? Theme.brand : Theme.iconSecondary])
        Text(this.title)
          .fontSize(Layout.fontUi)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
        this.stateChip()
      }
      .width('100%')

      if (this.urlEditable) {
        TextInput({ text: this.url, placeholder: '接口地址' })
          .fontSize(Layout.fontUi)
          .height(36)
          .width('100%')
          .backgroundColor(Theme.bgPage)
          .borderRadius(Layout.radiusM)
          .padding({ left: Layout.s3, right: Layout.s3 })
          .onChange((value: string) => {
            this.url = value;
          })
      } else {
        TextInput({ text: this.url, placeholder: '接口地址' })
          .fontSize(Layout.fontUi)
          .height(36)
          .width('100%')
          .backgroundColor(Theme.bgPage)
          .borderRadius(Layout.radiusM)
          .padding({ left: Layout.s3, right: Layout.s3 })
          .enabled(false)
      }

      TextInput({ text: this.keyInput, placeholder: this.configured ? '已保存，输入新 Key 可替换' : 'API Key' })
        .type(InputType.Password)
        .fontSize(Layout.fontUi)
        .height(36)
        .width('100%')
        .backgroundColor(Theme.bgPage)
        .borderRadius(Layout.radiusM)
        .padding({ left: Layout.s3, right: Layout.s3 })
        .onChange((value: string) => {
          this.keyInput = value;
        })

      Row({ space: Layout.s2 }) {
        this.actionText(this.testing ? '测试中' : '测试连接', this.testing, () => {
          this.onTest(this.keyInput);
        })
        this.actionText(this.pulling ? '拉取中' : '拉取模型', this.pulling, () => {
          this.onPull(this.keyInput);
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
            this.save();
          })
      }
      .width('100%')

      if (this.testing) {
        Text('测试中')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textTertiary)
          .width('100%')
      } else if (this.testResult.length > 0) {
        Text(this.testResult)
          .fontSize(Layout.fontSmall)
          .fontColor(this.testResult.startsWith('连接成功') ? Theme.success : Theme.danger)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (this.pulling) {
        Text('拉取中')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textTertiary)
          .width('100%')
      } else if (this.pullResult.length > 0) {
        Text(this.pullResult)
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (this.models.length > 0) {
        Text(`模型 · ${this.models.length}`)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textSecondary)
          .width('100%')
          .padding({ top: Layout.s1 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.models, (one: ProviderModelRecord) => {
            ModelProbeChip({
              modelId: one.modelId,
              displayName: one.displayName.length > 0 ? one.displayName : one.modelId,
              status: this.statusOf(one.modelId),
              errorText: this.errorOf(one.modelId),
              onTap: (modelId: string) => {
                this.onAddModel(modelId);
              }
            })
          }, (one: ProviderModelRecord) => one.modelId)
        }
        .width('100%')
      }

      if (this.notice.length > 0) {
        Text(this.notice)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.danger)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
    .alignItems(HorizontalAlign.Start)
  }
}
