/**
 * 信源详情面板（展开态右侧按需滑出 288vp / 折叠态半模态复用）。
 */
import { SourceRef } from '@app/core_model';
import { Icons, Layout, Theme } from '../app/Theme';
import { IconBtn } from './IconBtn';

function siteOf(url: string): string {
  const s: string = url.trim();
  const idx: number = s.indexOf('://');
  const rest: string = idx >= 0 ? s.substring(idx + 3) : s;
  const slash: number = rest.indexOf('/');
  return slash >= 0 ? rest.substring(0, slash) : rest;
}

function scoreText(source: SourceRef): string {
  if (source.rerankScore !== undefined && source.rerankScore > 0) {
    return source.rerankScore.toFixed(1);
  }
  return '';
}

function authorityText(source: SourceRef): string {
  if (source.authority !== undefined && source.authority >= 0) {
    return `权威 ${source.authority}/4`;
  }
  return '';
}

@Component
export struct SourcePane {
  @Prop sources: SourceRef[] = [];
  @Prop showClose: boolean = true;
  onClose: () => void = () => {
  };

  @Builder
  header() {
    Row() {
      Text('本轮信源')
        .fontSize(Layout.fontBody)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
      if (this.showClose) {
        IconBtn({
          icon: Icons.close,
          iconSize: Layout.iconM,
          iconColor: Theme.iconSecondary,
          btnSize: 32,
          bgColor: Theme.bgSurface,
          radius: Layout.radiusS,
          onTap: () => {
            this.onClose();
          }
        })
      }
    }
    .width('100%')
    .height(Layout.topBarHeight)
    .padding({ left: Layout.s4, right: Layout.s3 })
    .border({ width: { bottom: 1 }, color: { bottom: Theme.divider } })
  }

  @Builder
  sourceCard(source: SourceRef, index: number) {
    Column({ space: 6 }) {
      Row({ space: Layout.s2 }) {
        Text(`${index + 1}. ${source.title.length > 0 ? source.title : siteOf(source.url)}`)
          .fontSize(Layout.fontUi)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (scoreText(source).length > 0) {
          Text(scoreText(source))
            .fontSize(Layout.fontCaption)
            .fontColor(Theme.brand)
            .fontFamily('monospace')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(Layout.radiusS)
            .backgroundColor(Theme.brandSubtle)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 6 }) {
        Text(siteOf(source.url))
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (authorityText(source).length > 0) {
          Text(authorityText(source))
            .fontSize(Layout.fontCaption)
            .fontColor(Theme.textTertiary)
            .fontFamily('monospace')
        }
      }
      .width('100%')

      if (source.snippet.length > 0) {
        Text(source.snippet)
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .lineHeight(Layout.lineTight)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .padding(Layout.s3)
    .borderRadius(Layout.radiusL)
    .backgroundColor(Theme.bgSurface)
    .border({ width: 1, color: Theme.border })
  }

  build() {
    Column() {
      this.header()
      if (this.sources.length === 0) {
        Column() {
          Text('暂无信源')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textTertiary)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: Layout.s2 }) {
          ForEach(this.sources, (source: SourceRef, index: number) => {
            ListItem() {
              this.sourceCard(source, index)
            }
          }, (source: SourceRef, index: number) => `${index}_${source.url}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Layout.s3, right: Layout.s3, top: Layout.s3, bottom: Layout.s3 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgPage)
  }
}
