/**
 * 会话侧栏 / 折叠态会话抽屉（v3.1：全居中 IconBtn + 精致底部三入口卡片）。
 */
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { SessionMeta } from '@app/core_model';
import { Icons, Layout, Theme } from '../app/Theme';
import { IconBtn } from './IconBtn';

const NAV_CREATOR: number = 0;
const NAV_SKILLS: number = 1;
const NAV_SETTINGS: number = 2;

function sessionTime(ts: number): string {
  const now: number = Date.now();
  const diff: number = Math.max(0, now - ts);
  if (diff < 60000) {
    return '刚刚';
  }
  if (diff < 3600000) {
    return `${Math.floor(diff / 60000)}分钟前`;
  }
  const sameDay: boolean = new Date(ts).toDateString() === new Date(now).toDateString();
  if (sameDay) {
    return `${Math.floor(diff / 3600000)}小时前`;
  }
  const date: Date = new Date(ts);
  return `${date.getMonth() + 1}/${date.getDate()}`;
}

@Component
export struct SessionDrawer {
  @Prop sessions: SessionMeta[] = [];
  @Prop currentSessionId: string = '';
  @Prop folded: boolean = false;
  onNewChat: () => void = () => {
  };
  onOpen: (sessionId: string) => void = (sessionId: string) => {
  };
  onClose: () => void = () => {
  };
  onCollapse: () => void = () => {
  };
  onRename: (sessionId: string, title: string) => void = (sessionId: string, title: string) => {
  };
  onDelete: (sessionId: string) => void = (sessionId: string) => {
  };
  onNav: (target: number) => void = (target: number) => {
  };

  @State private query: string = '';
  @State private renamingId: string = '';
  @State private renameText: string = '';
  @State private menuSessionId: string = '';

  @Styles
  tilePressed() {
    .opacity(Layout.pressOpacity)
    .scale({ x: 0.97, y: 0.97 })
  }

  @Styles
  tileNormal() {
    .opacity(1)
    .scale({ x: 1, y: 1 })
  }

  private filtered(): SessionMeta[] {
    const q: string = this.query.trim().toLowerCase();
    if (q.length === 0) {
      return this.sessions;
    }
    const out: SessionMeta[] = [];
    for (const one of this.sessions) {
      if (one.title.toLowerCase().indexOf(q) >= 0) {
        out.push(one);
      }
    }
    return out;
  }

  private beginRename(session: SessionMeta): void {
    this.menuSessionId = '';
    this.renamingId = session.sessionId;
    this.renameText = session.title.length > 0 ? session.title : '新对话';
  }

  private commitRename(): void {
    const id: string = this.renamingId;
    const title: string = this.renameText.trim();
    this.renamingId = '';
    this.renameText = '';
    if (id.length === 0 || title.length === 0) {
      return;
    }
    this.onRename(id, title);
  }

  private cancelRename(): void {
    this.renamingId = '';
    this.renameText = '';
  }

  private confirmDelete(session: SessionMeta): void {
    this.menuSessionId = '';
    this.getUIContext().showAlertDialog({
      title: '删除对话',
      message: session.title.length > 0 ? session.title : '新对话',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: () => {
          this.onDelete(session.sessionId);
        }
      }
    });
  }

  private sessionMenu(session: SessionMeta): MenuElement[] {
    const out: MenuElement[] = [];
    out.push({
      value: '重命名',
      symbolIcon: new SymbolGlyphModifier(Icons.edit),
      action: () => {
        this.beginRename(session);
      }
    });
    out.push({
      value: '删除',
      symbolIcon: new SymbolGlyphModifier(Icons.trash),
      action: () => {
        this.confirmDelete(session);
      }
    });
    return out;
  }

  @Builder
  header() {
    if (this.folded) {
      Column({ space: Layout.s2 }) {
        Row({ space: Layout.s2 }) {
          Text('对话')
            .fontSize(Layout.fontHeadline)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
          IconBtn({
            icon: Icons.close,
            iconSize: Layout.iconM,
            iconColor: Theme.iconSecondary,
            btnSize: 34,
            bgColor: Theme.bgSurface,
            radius: Layout.radiusM,
            onTap: () => {
              this.onClose();
            }
          })
        }
        .width('100%')
        .height(Layout.topBarHeight)
        .padding({ left: Layout.s3, right: Layout.s2 })

        Row({ space: 6 }) {
          SymbolGlyph(Icons.plus).fontSize(Layout.iconM).fontColor([Theme.textOnBrand])
          Text('新对话')
            .fontSize(Layout.fontUi)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textOnBrand)
        }
        .width('100%')
        .height(38)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Layout.radiusM)
        .backgroundColor(Theme.brand)
        .stateStyles({ pressed: this.tilePressed, normal: this.tileNormal })
        .onClick(() => {
          this.onNewChat();
        })
      }
      .width('100%')
      .padding({ left: Layout.s2, right: Layout.s2, bottom: Layout.s2 })
    } else {
      Row({ space: Layout.s2 }) {
        Row({ space: 6 }) {
          SymbolGlyph(Icons.plus).fontSize(Layout.iconM).fontColor([Theme.textOnBrand])
          Text('新对话')
            .fontSize(Layout.fontUi)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textOnBrand)
        }
        .layoutWeight(1)
        .height(38)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Layout.radiusM)
        .backgroundColor(Theme.brand)
        .stateStyles({ pressed: this.tilePressed, normal: this.tileNormal })
        .onClick(() => {
          this.onNewChat();
        })

        IconBtn({
          icon: Icons.panelClose,
          iconSize: Layout.iconM,
          iconColor: Theme.iconSecondary,
          btnSize: 38,
          bgColor: Theme.bgSurface,
          radius: Layout.radiusM,
          onTap: () => {
            this.onCollapse();
          }
        })
      }
      .width('100%')
      .padding({ left: Layout.s3, right: Layout.s3, top: Layout.s3, bottom: Layout.s2 })
    }
  }

  @Builder
  searchBox() {
    Row({ space: 8 }) {
      SymbolGlyph(Icons.search).fontSize(Layout.iconS).fontColor([Theme.textTertiary])
      TextInput({ text: this.query, placeholder: '搜索对话' })
        .onChange((value: string) => {
          this.query = value;
        })
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textPrimary)
        .placeholderColor(Theme.textTertiary)
        .backgroundColor(Color.Transparent)
        .borderRadius(0)
        .padding(0)
        .layoutWeight(1)
        .height(34)
    }
    .width('100%')
    .height(36)
    .padding({ left: 12, right: Layout.s2 })
    .borderRadius(Layout.radiusM)
    .backgroundColor(Theme.bgInput)
    .margin({ left: Layout.s3, right: Layout.s3, bottom: Layout.s2 })
  }

  @Builder
  sessionRow(session: SessionMeta) {
    Row({ space: 6 }) {
      if (this.renamingId === session.sessionId) {
        TextInput({ text: this.renameText })
          .onChange((value: string) => {
            this.renameText = value;
          })
          .onSubmit(() => {
            this.commitRename();
          })
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textPrimary)
          .backgroundColor(Theme.bgInput)
          .borderRadius(Layout.radiusS)
          .height(32)
          .layoutWeight(1)
        IconBtn({
          icon: Icons.check,
          iconSize: Layout.iconM,
          iconColor: Theme.brand,
          btnSize: 28,
          onTap: () => {
            this.commitRename();
          }
        })
        IconBtn({
          icon: Icons.close,
          iconSize: Layout.iconS,
          iconColor: Theme.textTertiary,
          btnSize: 28,
          onTap: () => {
            this.cancelRename();
          }
        })
      } else {
        Text(session.title.length > 0 ? session.title : '新对话')
          .fontSize(Layout.fontUi)
          .fontColor(session.sessionId === this.currentSessionId ? Theme.textPrimary : Theme.textSecondary)
          .fontWeight(session.sessionId === this.currentSessionId ? FontWeight.Medium : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .onClick(() => {
            this.onOpen(session.sessionId);
          })
        Text(sessionTime(session.updatedAt))
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
          .maxLines(1)
        IconBtn({
          icon: Icons.more,
          iconSize: Layout.iconS,
          iconColor: Theme.textTertiary,
          btnSize: 26,
          radius: Layout.radiusS,
          onTap: () => {
            this.menuSessionId = session.sessionId;
          }
        })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 6, top: 8, bottom: 8 })
    .borderRadius(Layout.radiusM)
    .backgroundColor(session.sessionId === this.currentSessionId ? Theme.bgSurface2 : Color.Transparent)
    .gesture(LongPressGesture().onAction(() => {
      if (this.renamingId.length === 0) {
        this.menuSessionId = session.sessionId;
      }
    }))
    .bindMenu(this.menuSessionId === session.sessionId, this.sessionMenu(session), {
      onDisappear: () => {
        this.menuSessionId = '';
      }
    })
  }

  @Builder
  navEntry(icon: Resource, label: string, target: number) {
    Column({ space: 5 }) {
      SymbolGlyph(icon).fontSize(Layout.iconM).fontColor([Theme.iconSecondary])
      Text(label)
        .fontSize(Layout.fontCaption)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textSecondary)
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(54)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Layout.radiusM)
    .backgroundColor(Theme.bgSurface)
    .stateStyles({ pressed: this.tilePressed, normal: this.tileNormal })
    .onClick(() => {
      this.onNav(target);
    })
  }

  build() {
    Column() {
      this.header()
      this.searchBox()

      if (this.filtered().length === 0) {
        Column() {
          Text('无匹配对话')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textTertiary)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 3 }) {
          ForEach(this.filtered(), (session: SessionMeta) => {
            ListItem() {
              this.sessionRow(session)
            }
          }, (session: SessionMeta) => session.sessionId)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Layout.s2, right: Layout.s2 })
        .scrollBar(BarState.Off)
      }

      Divider().color(Theme.divider)

      Row({ space: 6 }) {
        this.navEntry(Icons.creator, '创造室', NAV_CREATOR)
        this.navEntry(Icons.skills, '技能', NAV_SKILLS)
        this.navEntry(Icons.settings, '设置', NAV_SETTINGS)
      }
      .width('100%')
      .padding({ left: Layout.s2, right: Layout.s2, top: Layout.s2, bottom: Layout.s3 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.drawerBg)
  }
}
