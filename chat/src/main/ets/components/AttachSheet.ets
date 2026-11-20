/**
 * 「+」附件半模态内容（v3：输入框「+」只做附件，不做能力入口）。
 *
 * 选项：相册图片 / PDF 文档 / 网页链接。拍照入口依赖相机 Kit 与运行时权限，
 * 当前构建不提供（不出现，避免点了没反应）。
 */
import { Icons, Layout, Theme } from '../app/Theme';

/**
 * 附件选择面板。
 *
 * @param onPickImage 打开系统相册选择器
 * @param onPickFile 打开系统文件选择器
 * @param onPickLink 用户输入网页链接后回调
 */
@Component
export struct AttachSheet {
  onPickImage: () => void = () => {
  };
  onPickFile: () => void = () => {
  };
  onPickLink: (url: string) => void = (url: string) => {
  };

  @State private linkMode: boolean = false;
  @State private linkText: string = '';

  private submitLink(): void {
    const url: string = this.linkText.trim();
    if (url.length === 0) {
      return;
    }
    this.linkMode = false;
    this.linkText = '';
    this.onPickLink(url);
  }

  @Builder
  optionCard(icon: Resource, label: string, index: number) {
    Row({ space: Layout.s2 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(icon).fontSize(Layout.iconM).fontColor([Theme.brand])
      }
      .width(36)
      .height(36)
      .borderRadius(Layout.radiusM)
      .backgroundColor(Theme.brandSubtle)
      Text(label)
        .fontSize(Layout.fontUi)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: Layout.s3 - 2, right: Layout.s3 - 2, top: Layout.s3, bottom: Layout.s3 })
    .borderRadius(Layout.radiusL)
    .backgroundColor(Theme.bgSurface)
    .border({ width: 1, color: Theme.border })
    .onClick(() => {
      if (index === 0) {
        this.onPickImage();
      } else if (index === 1) {
        this.onPickFile();
      } else {
        this.linkMode = true;
      }
    })
  }

  @Builder
  linkEditor() {
    Column({ space: Layout.s3 }) {
      Row({ space: Layout.s2 }) {
        SymbolGlyph(Icons.link).fontSize(Layout.iconS).fontColor([Theme.textTertiary])
        TextInput({ text: this.linkText, placeholder: '粘贴网页链接' })
          .onChange((value: string) => {
            this.linkText = value;
          })
          .onSubmit(() => {
            this.submitLink();
          })
          .fontSize(Layout.fontBody)
          .fontColor(Theme.textPrimary)
          .placeholderColor(Theme.textTertiary)
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding(0)
          .height(34)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: Layout.s3, right: Layout.s3 })
      .borderRadius(Layout.radiusM)
      .backgroundColor(Theme.bgInput)
      .border({ width: 1, color: Theme.border })

      Row({ space: Layout.s3 }) {
        Blank()
        Text('取消')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textSecondary)
          .padding({ left: Layout.s3, right: Layout.s3, top: 7, bottom: 7 })
          .borderRadius(Layout.radiusM)
          .backgroundColor(Theme.bgSurface2)
          .onClick(() => {
            this.linkMode = false;
            this.linkText = '';
          })
        Text('添加')
          .fontSize(Layout.fontUi)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textOnBrand)
          .padding({ left: Layout.s4, right: Layout.s4, top: 7, bottom: 7 })
          .borderRadius(Layout.radiusM)
          .backgroundColor(this.linkText.trim().length > 0 ? Theme.brand : Theme.toggleOff)
          .onClick(() => {
            if (this.linkText.trim().length > 0) {
              this.submitLink();
            }
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  build() {
    Column({ space: Layout.s4 }) {
      Row() {
        Text(this.linkMode ? '添加链接' : '添加附件')
          .fontSize(Layout.fontHeadline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
        SymbolGlyph(this.linkMode ? Icons.link : Icons.attach)
          .fontSize(Layout.iconM)
          .fontColor([Theme.textTertiary])
      }
      .width('100%')

      if (this.linkMode) {
        this.linkEditor()
      } else {
        Column({ space: Layout.s2 }) {
          this.optionCard(Icons.image, '相册图片', 0)
          this.optionCard(Icons.file, 'PDF / 文档', 1)
          this.optionCard(Icons.link, '网页链接', 2)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s5, bottom: Layout.s6 })
  }
}
