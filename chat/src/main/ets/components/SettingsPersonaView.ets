/**
 * 设置 · 角色与提示词（v3.2 二级菜单 + 头像）。
 *
 * 一级：搜索 + 新建 + 角色行（40×40 圆形头像 / 名称 / 默认标识 / 绑定模型摘要）。
 * 二级：头像选择（10 图标 + 8 配色）、名称与默认、系统提示词与变量、
 *      模型/6 档思考/Temperature/Top-P/轮数、默认绑定技能、复制/删除/保存。
 */
import { SkillSummary } from '@app/core_plugin';
import { ModelProfile } from '@app/core_protocol';
import { AppServices } from '../app/AppServices';
import { EffortLevels, EffortOption } from '../app/EffortLevels';
import { PersonaProfile } from '../app/PersonaStore';
import { PersonaAvatars } from '../app/PersonaAvatars';
import { Icons, Layout, Theme } from '../app/Theme';
import { getChatRuntimeConcrete } from '../model/RuntimeHolder';
import { PersonaAvatarPicker } from './PersonaAvatarPicker';

const TIER_L3: string = 'L3_QUICKJS_SANDBOX';
const FOLLOW_MODEL: string = '跟随当前模型';

@Component
export struct SettingsPersonaView {
  @State private loading: boolean = true;
  @State private personas: PersonaProfile[] = [];
  @State private defaultId: string = '';
  @State private profiles: ModelProfile[] = [];
  @State private skills: SkillSummary[] = [];
  @State private searchText: string = '';
  @State private selectedId: string = '';
  @State private statusText: string = '';
  @State private busy: boolean = false;
  @State private pickerOpen: boolean = false;

  @State private draftName: string = '';
  @State private draftPrompt: string = '';
  @State private draftModelId: string = '';
  @State private draftProviderId: string = '';
  @State private draftEffortIndex: number = 3;
  @State private draftTemperature: number = 0.7;
  @State private draftTopP: number = 0.95;
  @State private draftMaxTurns: number = 20;
  @State private draftSkills: string[] = [];
  @State private draftIcon: string = PersonaAvatars.DEFAULT_ICON;
  @State private draftTone: string = PersonaAvatars.DEFAULT_TONE;

  aboutToAppear(): void {
    this.load();
  }

  private load(): void {
    try {
      const services = AppServices.get();
      const store = services.requirePersonas();
      this.personas = store.list();
      this.defaultId = store.defaultId();
      this.profiles = services.requireProtocol().catalog.listProfiles();
      this.skills = this.loadSkills();
    } catch (e) {
      this.statusText = `${(e as Error).message}`;
    }
    this.loading = false;
  }

  private loadSkills(): SkillSummary[] {
    const out: SkillSummary[] = [];
    const services = AppServices.get();
    if (!services.hasPlugin()) {
      return out;
    }
    try {
      const list: SkillSummary[] = services.requirePlugin().kernel.list();
      for (const one of list) {
        if (one.tier === TIER_L3) {
          continue;
        }
        out.push(one);
      }
    } catch (e) {
      return out;
    }
    return out;
  }

  private findPersona(id: string): PersonaProfile | null {
    for (const one of this.personas) {
      if (one.id === id) {
        return one;
      }
    }
    return null;
  }

  private filteredPersonas(): PersonaProfile[] {
    const key: string = this.searchText.trim().toLowerCase();
    if (key.length === 0) {
      return this.personas;
    }
    const out: PersonaProfile[] = [];
    for (const one of this.personas) {
      const nameHit: boolean = one.name.toLowerCase().indexOf(key) >= 0;
      const promptHit: boolean = one.prompt.toLowerCase().indexOf(key) >= 0;
      if (nameHit || promptHit) {
        out.push(one);
      }
    }
    return out;
  }

  private modelSummary(persona: PersonaProfile): string {
    if (persona.modelId.length === 0) {
      return FOLLOW_MODEL;
    }
    for (const one of this.profiles) {
      if (one.modelId === persona.modelId) {
        return one.label;
      }
    }
    return persona.modelId;
  }

  // ---------------------------------------------------------------------------
  // 选择 / 前进后退
  // ---------------------------------------------------------------------------

  private openDetail(id: string): void {
    const persona: PersonaProfile | null = this.findPersona(id);
    if (persona === null) {
      return;
    }
    this.selectedId = persona.id;
    this.pickerOpen = false;
    this.statusText = '';
    this.draftName = persona.name;
    this.draftPrompt = persona.prompt;
    this.draftProviderId = persona.providerId;
    this.draftModelId = persona.modelId;
    this.draftEffortIndex = EffortLevels.indexOf(persona.effortLevel);
    this.draftTemperature = persona.temperature;
    this.draftTopP = persona.topP;
    this.draftMaxTurns = persona.maxTurns;
    this.draftIcon = persona.avatarIcon !== undefined ? persona.avatarIcon : PersonaAvatars.DEFAULT_ICON;
    this.draftTone = persona.avatarTone !== undefined ? persona.avatarTone : PersonaAvatars.DEFAULT_TONE;
    const next: string[] = [];
    for (const sid of persona.defaultSkills) {
      next.push(sid);
    }
    this.draftSkills = next;
  }

  private backToList(): void {
    this.selectedId = '';
    this.pickerOpen = false;
    this.statusText = '';
  }

  private buildDraft(): PersonaProfile {
    const base: PersonaProfile | null = this.findPersona(this.selectedId);
    const profile: PersonaProfile = {
      id: this.selectedId.length > 0 ? this.selectedId : `p_${Date.now().toString(36)}`,
      name: this.draftName.trim().length > 0 ? this.draftName.trim() : '未命名角色',
      prompt: this.draftPrompt,
      providerId: this.draftProviderId,
      modelId: this.draftModelId,
      effortLevel: EffortLevels.byIndex(this.draftEffortIndex).level,
      temperature: this.draftTemperature,
      topP: this.draftTopP,
      maxTurns: Math.round(this.draftMaxTurns),
      defaultSkills: this.draftSkills,
      avatarIcon: this.draftIcon.length > 0 ? this.draftIcon : PersonaAvatars.DEFAULT_ICON,
      avatarTone: this.draftTone.length > 0 ? this.draftTone : PersonaAvatars.DEFAULT_TONE,
      builtin: base !== null ? base.builtin : false,
      updatedAt: Date.now()
    };
    return profile;
  }

  private async refreshRuntime(): Promise<void> {
    try {
      await getChatRuntimeConcrete().refreshSettings();
    } catch (e) {
      // 运行时未初始化时忽略；下次进入对话会重新读取
    }
  }

  // ---------------------------------------------------------------------------
  // 角色操作
  // ---------------------------------------------------------------------------

  private newPersona(): void {
    try {
      const draft: PersonaProfile = AppServices.get().requirePersonas().newDraft();
      this.personas = this.personas.concat([draft]);
      this.openDetail(draft.id);
      this.statusText = '未保存';
    } catch (e) {
      this.statusText = `${(e as Error).message}`;
    }
  }

  private async savePersona(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.draftName.trim().length === 0) {
      this.statusText = '请填写角色名称';
      return;
    }
    this.busy = true;
    try {
      const store = AppServices.get().requirePersonas();
      await store.save(this.buildDraft());
      this.personas = store.list();
      this.defaultId = store.defaultId();
      this.statusText = '已保存';
      await this.refreshRuntime();
    } catch (e) {
      this.statusText = `保存失败：${(e as Error).message}`;
    }
    this.busy = false;
  }

  private async setDefaultPersona(): Promise<void> {
    try {
      const store = AppServices.get().requirePersonas();
      await store.setDefault(this.selectedId);
      this.defaultId = store.defaultId();
      this.statusText = '已设为默认角色';
      await this.refreshRuntime();
    } catch (e) {
      this.statusText = `设置失败：${(e as Error).message}`;
    }
  }

  private async duplicatePersona(): Promise<void> {
    try {
      const store = AppServices.get().requirePersonas();
      const copy: PersonaProfile | null = await store.duplicate(this.selectedId);
      if (copy === null) {
        this.statusText = '复制失败';
        return;
      }
      this.personas = store.list();
      this.openDetail(copy.id);
      this.statusText = '已复制角色';
    } catch (e) {
      this.statusText = `复制失败：${(e as Error).message}`;
    }
  }

  private async removePersona(): Promise<void> {
    if (this.personas.length <= 1) {
      return;
    }
    try {
      const store = AppServices.get().requirePersonas();
      const persisted: PersonaProfile | null = store.get(this.selectedId);
      if (persisted === null) {
        const next: PersonaProfile[] = [];
        for (const one of this.personas) {
          if (one.id !== this.selectedId) {
            next.push(one);
          }
        }
        this.personas = next;
        this.backToList();
        this.statusText = '已放弃草稿';
        return;
      }
      const ok: boolean = await store.remove(this.selectedId);
      if (!ok) {
        this.statusText = '删除失败';
        return;
      }
      this.personas = store.list();
      this.defaultId = store.defaultId();
      this.backToList();
      await this.refreshRuntime();
    } catch (e) {
      this.statusText = `删除失败：${(e as Error).message}`;
    }
  }

  // ---------------------------------------------------------------------------
  // 字段操作
  // ---------------------------------------------------------------------------

  private insertVariable(text: string): void {
    const current: string = this.draftPrompt;
    if (current.length === 0) {
      this.draftPrompt = text;
      return;
    }
    const tail: string = current.substring(current.length - 1);
    this.draftPrompt = tail === ' ' ? current + text : `${current} ${text}`;
  }

  private toggleSkill(skillId: string): void {
    const next: string[] = [];
    let found: boolean = false;
    for (const sid of this.draftSkills) {
      if (sid === skillId) {
        found = true;
      } else {
        next.push(sid);
      }
    }
    if (!found) {
      next.push(skillId);
    }
    this.draftSkills = next;
  }

  private isSkillBound(skillId: string): boolean {
    return this.draftSkills.indexOf(skillId) >= 0;
  }

  private modelOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    const follow: SelectOption = { value: FOLLOW_MODEL };
    out.push(follow);
    for (const one of this.profiles) {
      const option: SelectOption = { value: one.label };
      out.push(option);
    }
    return out;
  }

  private modelIndex(): number {
    if (this.draftModelId.length === 0) {
      return 0;
    }
    for (let i = 0; i < this.profiles.length; i++) {
      if (this.profiles[i].modelId === this.draftModelId) {
        return i + 1;
      }
    }
    return 0;
  }

  private modelLabelText(): string {
    const index: number = this.modelIndex();
    if (index === 0) {
      return FOLLOW_MODEL;
    }
    return this.profiles[index - 1].label;
  }

  private pickModel(index: number): void {
    if (index <= 0) {
      this.draftModelId = '';
      this.draftProviderId = '';
      return;
    }
    if (index > this.profiles.length) {
      return;
    }
    this.draftModelId = this.profiles[index - 1].modelId;
    this.draftProviderId = this.profiles[index - 1].providerId;
  }

  private effortShort(): string {
    return EffortLevels.byIndex(this.draftEffortIndex).short;
  }

  // ---------------------------------------------------------------------------
  // 一级列表 UI
  // ---------------------------------------------------------------------------

  @Builder
  listHeader() {
    Row({ space: Layout.s2 }) {
      Row({ space: Layout.s1 }) {
        SymbolGlyph(Icons.search)
          .fontSize(Layout.iconS)
          .fontColor([Theme.iconSecondary])
        TextInput({ text: this.searchText, placeholder: '搜索角色' })
          .fontSize(Layout.fontUi)
          .height(34)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .padding({ left: 0, right: 0 })
          .onChange((value: string) => {
            this.searchText = value;
          })
      }
      .layoutWeight(1)
      .padding({ left: Layout.s3, right: Layout.s3 })
      .borderRadius(Layout.radiusPill)
      .backgroundColor(Theme.bgSurface)

      Text('新建')
        .fontSize(Layout.fontUi)
        .fontColor(Theme.textOnBrand)
        .padding({ left: Layout.s3, right: Layout.s3, top: 7, bottom: 7 })
        .borderRadius(Layout.radiusPill)
        .backgroundColor(Theme.brand)
        .onClick(() => {
          this.newPersona();
        })
    }
    .width('100%')
    .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s3, bottom: Layout.s2 })
  }

  @Builder
  personaRow(persona: PersonaProfile) {
    Row({ space: Layout.s3 }) {
      Row() {
        SymbolGlyph(PersonaAvatars.iconOf(persona.avatarIcon))
          .fontSize(Layout.iconL)
          .fontColor([PersonaAvatars.foreground()])
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(PersonaAvatars.toneOf(persona.avatarTone))

      Column({ space: 2 }) {
        Row({ space: Layout.s2 }) {
          Text(persona.name)
            .fontSize(Layout.fontUi)
            .fontColor(Theme.textPrimary)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.defaultId === persona.id) {
            Text('默认')
              .fontSize(Layout.fontCaption)
              .fontColor(Theme.brand)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(Layout.radiusS)
              .backgroundColor(Theme.brandSubtle)
          }
        }
        .width('100%')

        Text(this.modelSummary(persona))
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph(Icons.chevronRight)
        .fontSize(Layout.iconM)
        .fontColor([Theme.iconSecondary])
    }
    .width('100%')
    .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s2, bottom: Layout.s2 })
    .onClick(() => {
      this.openDetail(persona.id);
    })
  }

  @Builder
  listView() {
    Column() {
      this.listHeader()
      if (this.filteredPersonas().length === 0) {
        Text('没有匹配的角色')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textTertiary)
          .width('100%')
          .padding(Layout.pagePadding)
      } else {
        Scroll() {
          Column() {
            ForEach(this.filteredPersonas(), (persona: PersonaProfile, index: number) => {
              this.personaRow(persona)
              if (index < this.filteredPersonas().length - 1) {
                Divider().color(Theme.divider).margin({ left: Layout.pagePadding + 52 })
              }
            }, (persona: PersonaProfile) => persona.id)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  // ---------------------------------------------------------------------------
  // 二级详情 UI
  // ---------------------------------------------------------------------------

  @Builder
  avatarRow() {
    Row({ space: Layout.s3 }) {
      Row() {
        SymbolGlyph(PersonaAvatars.iconOf(this.draftIcon))
          .fontSize(Layout.iconL)
          .fontColor([PersonaAvatars.foreground()])
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(PersonaAvatars.toneOf(this.draftTone))
      .border({ width: 1, color: Theme.border })
      .onClick(() => {
        this.pickerOpen = !this.pickerOpen;
      })

      Column({ space: Layout.s2 }) {
        TextInput({ text: this.draftName, placeholder: '角色名称' })
          .fontSize(Layout.fontUi)
          .height(36)
          .width('100%')
          .backgroundColor(Theme.bgPage)
          .borderRadius(Layout.radiusM)
          .padding({ left: Layout.s3, right: Layout.s3 })
          .onChange((value: string) => {
            this.draftName = value;
          })
        Row({ space: Layout.s2 }) {
          Text(this.defaultId === this.selectedId ? '默认角色' : '设为默认')
            .fontSize(Layout.fontCaption)
            .fontColor(this.defaultId === this.selectedId ? Theme.textOnBrand : Theme.brand)
            .padding({ left: Layout.s3, right: Layout.s3, top: 5, bottom: 5 })
            .borderRadius(Layout.radiusPill)
            .backgroundColor(this.defaultId === this.selectedId ? Theme.brand : Theme.brandSubtle)
            .onClick(() => {
              this.setDefaultPersona();
            })
          Blank()
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
  }

  @Builder
  promptCard() {
    Column({ space: Layout.s2 }) {
      Row({ space: Layout.s1 }) {
        Text('系统提示词')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .layoutWeight(1)
        Text('{{date}}')
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textSecondary)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(Layout.radiusS)
          .backgroundColor(Theme.bgPage)
          .onClick(() => {
            this.insertVariable('{{date}}');
          })
        Text('{{clipboard}}')
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textSecondary)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(Layout.radiusS)
          .backgroundColor(Theme.bgPage)
          .onClick(() => {
            this.insertVariable('{{clipboard}}');
          })
      }
      .width('100%')

      TextArea({ text: this.draftPrompt, placeholder: '角色设定与回答要求' })
        .fontSize(Layout.fontSmall)
        .height(120)
        .width('100%')
        .backgroundColor(Theme.bgPage)
        .borderRadius(Layout.radiusM)
        .padding(Layout.s3)
        .onChange((value: string) => {
          this.draftPrompt = value;
        })
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  samplingCard() {
    Column({ space: Layout.s3 }) {
      Column({ space: Layout.s1 }) {
        Text('默认模型')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .width('100%')
        Select(this.modelOptions())
          .selected(this.modelIndex())
          .value(this.modelLabelText())
          .font({ size: Layout.fontUi })
          .fontColor(Theme.textPrimary)
          .selectedOptionBgColor(Theme.brandSubtle)
          .selectedOptionFontColor(Theme.brand)
          .onSelect((index: number) => {
            this.pickModel(index);
          })
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: Layout.s1 }) {
        Row() {
          Text('默认思考')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .layoutWeight(1)
          Text(this.effortShort())
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.brand)
        }
        .width('100%')
        Slider({ value: this.draftEffortIndex, min: 0, max: 5, step: 1 })
          .selectedColor(Theme.brand)
          .trackColor(Theme.bgSurface3)
          .blockColor(Theme.bgSurface)
          .width('100%')
          .onChange((value: number) => {
            this.draftEffortIndex = Math.round(value);
          })
        Row() {
          ForEach(EffortLevels.ALL, (one: EffortOption, index: number) => {
            Text(one.short)
              .fontSize(Layout.fontCaption)
              .fontColor(this.draftEffortIndex === index ? Theme.brand : Theme.textTertiary)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.draftEffortIndex = index;
              })
          }, (one: EffortOption) => one.level)
        }
        .width('100%')
      }
      .width('100%')

      Row({ space: Layout.s4 }) {
        Column({ space: Layout.s1 }) {
          Row() {
            Text('Temperature')
              .fontSize(Layout.fontSmall)
              .fontColor(Theme.textSecondary)
              .layoutWeight(1)
            Text(this.draftTemperature.toFixed(1))
              .fontSize(Layout.fontSmall)
              .fontColor(Theme.brand)
          }
          .width('100%')
          Slider({ value: this.draftTemperature, min: 0, max: 2, step: 0.1 })
            .selectedColor(Theme.brand)
            .trackColor(Theme.bgSurface3)
            .blockColor(Theme.bgSurface)
            .width('100%')
            .onChange((value: number) => {
              this.draftTemperature = value;
            })
        }
        .layoutWeight(1)

        Column({ space: Layout.s1 }) {
          Row() {
            Text('Top-P')
              .fontSize(Layout.fontSmall)
              .fontColor(Theme.textSecondary)
              .layoutWeight(1)
            Text(this.draftTopP.toFixed(2))
              .fontSize(Layout.fontSmall)
              .fontColor(Theme.brand)
          }
          .width('100%')
          Slider({ value: this.draftTopP, min: 0.1, max: 1, step: 0.05 })
            .selectedColor(Theme.brand)
            .trackColor(Theme.bgSurface3)
            .blockColor(Theme.bgSurface)
            .width('100%')
            .onChange((value: number) => {
              this.draftTopP = value;
            })
        }
        .layoutWeight(1)
      }
      .width('100%')

      Column({ space: Layout.s1 }) {
        Row() {
          Text('上下文携带轮数')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .layoutWeight(1)
          Text(`${Math.round(this.draftMaxTurns)} 轮`)
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.brand)
        }
        .width('100%')
        Slider({ value: this.draftMaxTurns, min: 4, max: 50, step: 2 })
          .selectedColor(Theme.brand)
          .trackColor(Theme.bgSurface3)
          .blockColor(Theme.bgSurface)
          .width('100%')
          .onChange((value: number) => {
            this.draftMaxTurns = value;
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
  }

  @Builder
  skillsCard() {
    Column({ space: Layout.s2 }) {
      Text('默认绑定技能')
        .fontSize(Layout.fontSmall)
        .fontColor(Theme.textSecondary)
        .width('100%')
      if (this.skills.length === 0) {
        Text('暂无可用技能')
          .fontSize(Layout.fontCaption)
          .fontColor(Theme.textTertiary)
          .width('100%')
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.skills, (one: SkillSummary) => {
            Row({ space: 4 }) {
              SymbolGlyph(this.isSkillBound(one.id) ? Icons.check : Icons.plus)
                .fontSize(Layout.iconS)
                .fontColor([this.isSkillBound(one.id) ? Theme.textOnBrand : Theme.textSecondary])
              Text(one.name)
                .fontSize(Layout.fontUi)
                .fontColor(this.isSkillBound(one.id) ? Theme.textOnBrand : Theme.textSecondary)
            }
            .padding({ left: Layout.s3, right: Layout.s3, top: 5, bottom: 5 })
            .borderRadius(Layout.radiusPill)
            .backgroundColor(this.isSkillBound(one.id) ? Theme.brand : Theme.bgPage)
            .margin({ right: Layout.s2, bottom: Layout.s2 })
            .onClick(() => {
              this.toggleSkill(one.id);
            })
          }, (one: SkillSummary) => one.id)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(Layout.s3)
    .backgroundColor(Theme.bgSurface)
    .borderRadius(Layout.radiusL)
    .border({ width: 1, color: Theme.border })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  actionsRow() {
    Row({ space: Layout.s3 }) {
      Row({ space: 4 }) {
        SymbolGlyph(Icons.copy)
          .fontSize(Layout.iconS)
          .fontColor([Theme.textSecondary])
        Text('复制')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textSecondary)
      }
      .padding({ left: Layout.s2, right: Layout.s2, top: 6, bottom: 6 })
      .onClick(() => {
        this.duplicatePersona();
      })

      if (this.personas.length > 1) {
        Row({ space: 4 }) {
          SymbolGlyph(Icons.trash)
            .fontSize(Layout.iconS)
            .fontColor([Theme.danger])
          Text('删除')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.danger)
        }
        .padding({ left: Layout.s2, right: Layout.s2, top: 6, bottom: 6 })
        .onClick(() => {
          this.removePersona();
        })
      }
      Blank()
      Text(this.busy ? '保存中' : '保存角色')
        .fontSize(Layout.fontUi)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textOnBrand)
        .padding({ left: Layout.s5, right: Layout.s5, top: 8, bottom: 8 })
        .borderRadius(Layout.radiusM)
        .backgroundColor(Theme.brand)
        .onClick(() => {
          this.savePersona();
        })
    }
    .width('100%')
  }

  @Builder
  detailView() {
    Column() {
      Row({ space: Layout.s2 }) {
        SymbolGlyph(Icons.backArrow)
          .fontSize(Layout.iconM)
          .fontColor([Theme.iconSecondary])
          .padding(Layout.s1)
          .borderRadius(Layout.radiusS)
          .backgroundColor(Theme.bgSurface)
          .onClick(() => {
            this.backToList();
          })
        Text('角色详情')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.textSecondary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s2, bottom: Layout.s2 })

      Scroll() {
        Column({ space: Layout.s3 }) {
          this.avatarRow()
          if (this.pickerOpen) {
            PersonaAvatarPicker({
              currentIcon: this.draftIcon,
              currentTone: this.draftTone,
              onPickIcon: (key: string) => {
                this.draftIcon = key;
              },
              onPickTone: (key: string) => {
                this.draftTone = key;
              },
              onClose: () => {
                this.pickerOpen = false;
              }
            })
          }
          this.promptCard()
          this.samplingCard()
          this.skillsCard()
          this.actionsRow()
          if (this.statusText.length > 0) {
            Text(this.statusText)
              .fontSize(Layout.fontSmall)
              .fontColor(this.statusText === '已保存' ? Theme.success : Theme.warning)
              .width('100%')
          }
        }
        .width('100%')
        .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s2, bottom: Layout.s8 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    if (this.loading) {
      Column() {
        LoadingProgress().width(Layout.s6).height(Layout.s6).color(Theme.brand)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else if (this.selectedId.length === 0) {
      this.listView()
    } else {
      this.detailView()
    }
  }
}
