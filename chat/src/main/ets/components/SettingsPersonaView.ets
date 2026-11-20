/**
 * 设置 · 角色与提示词（Cherry Studio 级配置）。
 *
 * 角色 CRUD + 设默认 + 系统提示词变量插入 + 采样参数（模型/6 档思考/Temperature/Top-P/轮数）
 * + 默认绑定技能。全部落盘到 PersonaStore，保存后刷新运行时设置。
 */
import { SkillSummary } from '@app/core_plugin';
import { ModelProfile } from '@app/core_protocol';
import { AppServices } from '../app/AppServices';
import { EffortLevels, EffortOption } from '../app/EffortLevels';
import { PersonaProfile } from '../app/PersonaStore';
import { Icons, Layout, Theme } from '../app/Theme';
import { getChatRuntimeConcrete } from '../model/RuntimeHolder';

const TIER_L3: string = 'L3_QUICKJS_SANDBOX';

@Component
export struct SettingsPersonaView {
  @State private loading: boolean = true;
  @State private personas: PersonaProfile[] = [];
  @State private editingId: string = '';
  @State private defaultId: string = '';
  @State private profiles: ModelProfile[] = [];
  @State private skills: SkillSummary[] = [];
  @State private statusText: string = '';
  @State private busy: boolean = false;

  // 当前草稿（拆成基础字段，避免深层对象改动不触发刷新）
  @State private draftName: string = '';
  @State private draftPrompt: string = '';
  @State private draftModelId: string = '';
  @State private draftProviderId: string = '';
  @State private draftEffortIndex: number = 3;
  @State private draftTemperature: number = 0.7;
  @State private draftTopP: number = 0.95;
  @State private draftMaxTurns: number = 20;
  @State private draftSkills: string[] = [];

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
      const first: string = this.personas.length > 0 ? this.personas[0].id : '';
      this.selectPersona(first);
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

  private selectPersona(id: string): void {
    const persona: PersonaProfile | null = this.findPersona(id);
    if (persona === null) {
      this.editingId = '';
      return;
    }
    this.editingId = persona.id;
    this.draftName = persona.name;
    this.draftPrompt = persona.prompt;
    this.draftProviderId = persona.providerId;
    this.draftModelId = persona.modelId;
    this.draftEffortIndex = EffortLevels.indexOf(persona.effortLevel);
    this.draftTemperature = persona.temperature;
    this.draftTopP = persona.topP;
    this.draftMaxTurns = persona.maxTurns;
    this.draftSkills = [];
    for (const sid of persona.defaultSkills) {
      this.draftSkills.push(sid);
    }
    this.statusText = '';
  }

  private buildDraft(): PersonaProfile {
    const base: PersonaProfile | null = this.findPersona(this.editingId);
    const profile: PersonaProfile = {
      id: this.editingId.length > 0 ? this.editingId : `p_${Date.now().toString(36)}`,
      name: this.draftName.trim().length > 0 ? this.draftName.trim() : '未命名角色',
      prompt: this.draftPrompt,
      providerId: this.draftProviderId,
      modelId: this.draftModelId,
      effortLevel: EffortLevels.byIndex(this.draftEffortIndex).level,
      temperature: this.draftTemperature,
      topP: this.draftTopP,
      maxTurns: Math.round(this.draftMaxTurns),
      defaultSkills: this.draftSkills,
      builtin: base !== null ? base.builtin : false,
      updatedAt: Date.now()
    };
    return profile;
  }

  private async refreshRuntime(): Promise<void> {
    try {
      await getChatRuntimeConcrete().refreshSettings();
    } catch (e) {
      // 运行时未初始化时忽略，下一次进入对话会重新读取
    }
  }

  // ---------------------------------------------------------------------------
  // 角色操作
  // ---------------------------------------------------------------------------

  private newPersona(): void {
    try {
      const draft: PersonaProfile = AppServices.get().requirePersonas().newDraft();
      this.personas = this.personas.concat([draft]);
      this.selectPersona(draft.id);
      this.statusText = '新角色未保存';
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
      this.selectPersona(this.editingId);
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
      await store.setDefault(this.editingId);
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
      const copy: PersonaProfile | null = await store.duplicate(this.editingId);
      if (copy === null) {
        this.statusText = '复制失败';
        return;
      }
      this.personas = store.list();
      this.selectPersona(copy.id);
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
      const persisted: PersonaProfile | null = store.get(this.editingId);
      if (persisted === null) {
        // 尚未保存的新角色：直接从本地列表放弃
        const next: PersonaProfile[] = [];
        for (const one of this.personas) {
          if (one.id !== this.editingId) {
            next.push(one);
          }
        }
        this.personas = next;
        this.selectPersona(next.length > 0 ? next[0].id : '');
        this.statusText = '已放弃草稿';
        return;
      }
      const ok: boolean = await store.remove(this.editingId);
      if (!ok) {
        this.statusText = '删除失败';
        return;
      }
      this.personas = store.list();
      this.defaultId = store.defaultId();
      this.selectPersona(this.personas.length > 0 ? this.personas[0].id : '');
      this.statusText = '已删除角色';
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

  private selectOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    for (const one of this.profiles) {
      const option: SelectOption = { value: one.label };
      out.push(option);
    }
    return out;
  }

  private modelIndex(): number {
    for (let i = 0; i < this.profiles.length; i++) {
      if (this.profiles[i].modelId === this.draftModelId) {
        return i;
      }
    }
    return 0;
  }

  private modelLabel(): string {
    const idx: number = this.modelIndex();
    return this.profiles.length > idx ? this.profiles[idx].label : '';
  }

  private pickModel(index: number): void {
    if (index < 0 || index >= this.profiles.length) {
      return;
    }
    this.draftModelId = this.profiles[index].modelId;
    this.draftProviderId = this.profiles[index].providerId;
  }

  private effortShort(): string {
    return EffortLevels.byIndex(this.draftEffortIndex).short;
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @Builder
  personaChips() {
    Scroll() {
      Row({ space: Layout.s2 }) {
        ForEach(this.personas, (one: PersonaProfile) => {
          Row({ space: 6 }) {
            Text(one.name)
              .fontSize(Layout.fontUi)
              .fontColor(this.editingId === one.id ? Theme.brand : Theme.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.defaultId === one.id) {
              Circle({ width: 6, height: 6 }).fill(Theme.brand)
            }
          }
          .padding({ left: Layout.s3, right: Layout.s3, top: 6, bottom: 6 })
          .borderRadius(Layout.radiusPill)
          .backgroundColor(this.editingId === one.id ? Theme.brandSubtle : Theme.bgSurface)
          .onClick(() => {
            this.selectPersona(one.id);
          })
        }, (one: PersonaProfile) => one.id)

        Row({ space: 4 }) {
          SymbolGlyph(Icons.plus)
            .fontSize(Layout.iconS)
            .fontColor([Theme.brand])
          Text('新建角色')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.brand)
        }
        .padding({ left: Layout.s3, right: Layout.s3, top: 6, bottom: 6 })
        .borderRadius(Layout.radiusPill)
        .backgroundColor(Theme.bgSurface)
        .onClick(() => {
          this.newPersona();
        })
      }
      .padding({ right: Layout.s4 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  @Builder
  baseCard() {
    Column({ space: Layout.s3 }) {
      Row({ space: Layout.s2 }) {
        TextInput({ text: this.draftName, placeholder: '角色名称' })
          .fontSize(Layout.fontUi)
          .height(38)
          .layoutWeight(1)
          .backgroundColor(Theme.bgPage)
          .borderRadius(Layout.radiusM)
          .padding({ left: Layout.s3, right: Layout.s3 })
          .onChange((value: string) => {
            this.draftName = value;
          })
        Text(this.defaultId === this.editingId ? '默认角色' : '设为默认')
          .fontSize(Layout.fontUi)
          .fontColor(this.defaultId === this.editingId ? Theme.textOnBrand : Theme.textSecondary)
          .padding({ left: Layout.s3, right: Layout.s3, top: 7, bottom: 7 })
          .borderRadius(Layout.radiusM)
          .backgroundColor(this.defaultId === this.editingId ? Theme.brand : Theme.bgPage)
          .onClick(() => {
            this.setDefaultPersona();
          })
      }
      .width('100%')

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
        .height(130)
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
  }

  @Builder
  samplingCard() {
    Column({ space: Layout.s4 }) {
      Row({ space: Layout.s3 }) {
        Column({ space: Layout.s1 }) {
          Text('默认模型')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textSecondary)
            .width('100%')
          Select(this.selectOptions())
            .selected(this.modelIndex())
            .value(this.modelLabel())
            .font({ size: Layout.fontUi })
            .fontColor(Theme.textPrimary)
            .selectedOptionBgColor(Theme.brandSubtle)
            .selectedOptionFontColor(Theme.brand)
            .onSelect((index: number) => {
              this.pickModel(index);
            })
            .width('100%')
        }
        .layoutWeight(1)
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
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
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
  }

  @Builder
  actionsRow() {
    Row({ space: Layout.s3 }) {
      Row({ space: 4 }) {
        SymbolGlyph(Icons.copy)
          .fontSize(Layout.iconS)
          .fontColor([Theme.textSecondary])
        Text('复制角色')
          .fontSize(Layout.fontUi)
          .fontColor(Theme.textSecondary)
      }
      .padding({ left: Layout.s2, right: Layout.s2, top: 7, bottom: 7 })
      .onClick(() => {
        this.duplicatePersona();
      })

      if (this.personas.length > 1) {
        Row({ space: 4 }) {
          SymbolGlyph(Icons.trash)
            .fontSize(Layout.iconS)
            .fontColor([Theme.danger])
          Text('删除角色')
            .fontSize(Layout.fontUi)
            .fontColor(Theme.danger)
        }
        .padding({ left: Layout.s2, right: Layout.s2, top: 7, bottom: 7 })
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

  build() {
    if (this.loading) {
      Column() {
        LoadingProgress().width(Layout.s6).height(Layout.s6).color(Theme.brand)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column({ space: Layout.s4 }) {
          this.personaChips()
          this.baseCard()
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
        .padding({ left: Layout.pagePadding, right: Layout.pagePadding, top: Layout.s3, bottom: Layout.s8 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
  }
}
