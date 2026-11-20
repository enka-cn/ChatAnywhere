/**
 * 分支切换半模态内容区（外壳由页面 bindSheet 提供）。
 *
 * 列出同一条消息的其它版本：首条内容预览 + 时间 + 当前标记。只切换激活指针，不删除历史。
 */
import { Icons, Layout, Theme } from '../app/Theme';
import { BranchOption } from '../model/ChatRuntimeApi';

/** 时间格式化（今天只显示时分）。 */
function timeText(ts: number): string {
  const date: Date = new Date(ts);
  const now: Date = new Date();
  const sameDay: boolean = date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth()
    && date.getDate() === now.getDate();
  const hour: string = date.getHours() < 10 ? `0${date.getHours()}` : `${date.getHours()}`;
  const minute: string = date.getMinutes() < 10 ? `0${date.getMinutes()}` : `${date.getMinutes()}`;
  if (sameDay) {
    return `${hour}:${minute}`;
  }
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

/**
 * 分支选择内容。
 *
 * @param options 候选分支（`active` 标记当前这条）
 */
@Component
export struct BranchSelector {
  @Prop options: BranchOption[] = [];
  onPick: (childId: string) => void = (childId: string) => {
  };

  build() {
    Column({ space: Layout.s3 }) {
      Text('分支')
        .fontSize(Layout.fontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary)
        .width('100%')

      if (this.options.length === 0) {
        Text('暂无其它分支')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textTertiary)
          .width('100%')
          .padding({ top: Layout.s2, bottom: Layout.s2 })
      } else {
        Scroll() {
          Column({ space: Layout.s1 }) {
            ForEach(this.options, (option: BranchOption, index: number) => {
              Row({ space: Layout.s2 }) {
                Column({ space: 2 }) {
                  Text(option.preview.length > 0 ? option.preview : '（空）')
                    .fontSize(Layout.fontBody)
                    .fontColor(option.active ? Theme.brand : Theme.textPrimary)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${timeText(option.createdAt)}`)
                    .fontSize(Layout.fontCaption)
                    .fontColor(Theme.textTertiary)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (option.active) {
                  SymbolGlyph(Icons.check).fontSize(16).fontColor([Theme.brand])
                }
              }
              .width('100%')
              .padding({ left: Layout.s3, right: Layout.s3, top: 10, bottom: 10 })
              .borderRadius(Layout.radiusM)
              .backgroundColor(option.active ? Theme.chipBg : Color.Transparent)
              .onClick(() => {
                if (!option.active) {
                  this.onPick(option.childId);
                }
              })
            }, (option: BranchOption) => `${option.childId}_${option.active}`)
          }
          .width('100%')
          .padding({ bottom: Layout.s4 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s5 })
    .alignItems(HorizontalAlign.Start)
  }
}
