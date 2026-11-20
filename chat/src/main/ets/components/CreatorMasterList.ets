/**
 * 技能创造室左栏：返回对话 + 「创造室」+「新建」+ 搜索 + 技能纵向列表。
 *
 * 对齐 v3 设计（`chatanywhere_v3_pura_x_max.html` 328–349）：
 * - 宽度由页面控制（展开态 232vp / 折叠态全宽）；
 * - 列表项 = 名称 + 分级，选中态用 `Theme.brandSubtle`；
 * - 大量技能用纵向滚动列表承载，不再用胶囊平铺。
 */
import { Icons, Layout, Theme } from '../app/Theme';

/** 左栏列表项。 */
export interface CreatorSkillItem {
  id: string;
  name: string;
  /** 分级中文名（如「L1 声明式」）。 */
  tierText: string;
}

@Component
export struct CreatorMasterList {
  skills: CreatorSkillItem[] = [];
  selectedId: string = '';
  searchText: string = '';

  onSearch: (text: string) => void = () => {
  };
  onSelect: (id: string) => void = () => {
  };
  onNew: () => void = () => {
  };
  onBackChat: () => void = () => {
  };

  @Builder
  topBar() {
    Row({ space: Layout.s2 }) {
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
        this.onBackChat();
      })

      Text('创造室')
        .fontSize(Layout.fontTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)

      Row({ space: Layout.s1 }) {
        SymbolGlyph(Icons.plus)
          .fontSize(Layout.iconS)
          .fontColor([Theme.textOnBrand])
        Text('新建')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textOnBrand)
      }
      .height(28)
      .padding({ left: Layout.s2, right: Layout.s2 })
      .borderRadius(Layout.radiusS)
      .backgroundColor(Theme.brand)
      .onClick(() => {
        this.onNew();
      })
    }
    .width('100%')
    .height(Layout.topBarHeight)
    .padding({ left: Layout.s2, right: Layout.s3 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  searchBox() {
    Row({ space: Layout.s1 }) {
      SymbolGlyph(Icons.search)
        .fontSize(Layout.iconS)
        .fontColor([Theme.textTertiary])
      TextInput({ text: this.searchText, placeholder: '搜索技能' })
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textPrimary)
        .placeholderColor(Theme.textTertiary)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(32)
        .layoutWeight(1)
        .onChange((value: string) => {
          this.onSearch(value);
        })
    }
    .width('100%')
    .height(32)
    .padding({ left: 10, right: 10 })
    .borderRadius(Layout.radiusS)
    .backgroundColor(Theme.bgInput)
    .margin({ left: 10, right: 10, top: 10, bottom: Layout.s2 })
  }

  @Builder
  skillRow(item: CreatorSkillItem) {
    Row({ space: Layout.s2 }) {
      Column({ space: 2 }) {
        Text(item.name)
          .fontSize(Layout.fontUi)
          .fontWeight(item.id === this.selectedId ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(Theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.tierText)
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
          .maxLines(1)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph(Icons.chevronRight)
        .fontSize(Layout.iconS)
        .fontColor([Theme.iconSecondary])
        .opacity(0.6)
    }
    .width('100%')
    .padding({ left: Layout.s3, right: Layout.s2, top: 10, bottom: 10 })
    .borderRadius(Layout.radiusM)
    .backgroundColor(item.id === this.selectedId ? Theme.brandSubtle : Color.Transparent)
    .onClick(() => {
      this.onSelect(item.id);
    })
  }

  build() {
    Column() {
      this.topBar()
      Divider()
        .color(Theme.divider)
        .strokeWidth(1)
      this.searchBox()

      if (this.skills.length === 0) {
        Text(this.searchText.length > 0 ? '没有匹配的技能' : '还没有技能')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textTertiary)
          .width('100%')
          .padding({ left: Layout.s3, top: Layout.s4 })
      } else {
        Scroll() {
          Column({ space: 2 }) {
            ForEach(this.skills, (item: CreatorSkillItem) => {
              this.skillRow(item)
            }, (item: CreatorSkillItem) => item.id)
          }
          .width('100%')
          .padding({ left: Layout.s2, right: Layout.s2, bottom: Layout.s2 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgPage)
  }
}
