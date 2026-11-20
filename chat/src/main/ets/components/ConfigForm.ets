/**
 * 技能「能力设置」表单：按技能自带的参数定义自动渲染原生控件。
 *
 * boolean → 开关；number → 滑块/数字框；string → 输入框；
 * enum → 选项胶囊；string_list → 标签芯片。
 */
import { SkillConfigField } from '@app/core_plugin';
import { newObjectRecord } from '@app/core_model';
import { Icons, Layout, Theme } from '../app/Theme';

/** 单个参数的编辑状态（@Observed 供 ConfigRow 双向刷新）。 */
@Observed
export class ConfigEntryState {
  key: string = '';
  label: string = '';
  /** boolean / number / string / enum / string_list */
  type: string = '';
  hint: string = '';
  hasRange: boolean = false;
  min: number = 0;
  max: number = 100;
  step: number = 1;
  options: string[] = [];
  boolValue: boolean = false;
  numberValue: number = 0;
  stringValue: string = '';
  listValue: string[] = [];
  listDraft: string = '';
}

/** 一行参数控件。 */
@Component
struct ConfigRow {
  @ObjectLink entry: ConfigEntryState;

  private displayNumber(): string {
    const value: number = this.entry.numberValue;
    if (Number.isInteger(value)) {
      return `${value}`;
    }
    return value.toFixed(2);
  }

  private addListItem(): void {
    const text: string = this.entry.listDraft.trim();
    if (text.length === 0) {
      return;
    }
    if (this.entry.listValue.indexOf(text) >= 0) {
      this.entry.listDraft = '';
      return;
    }
    this.entry.listValue = this.entry.listValue.concat([text]);
    this.entry.listDraft = '';
  }

  private removeListItem(target: string): void {
    const next: string[] = [];
    for (const one of this.entry.listValue) {
      if (one !== target) {
        next.push(one);
      }
    }
    this.entry.listValue = next;
  }

  @Builder
  labelText() {
    Text(this.entry.label)
      .fontSize(Layout.fontSmall)
      .fontColor(Theme.textPrimary)
      .layoutWeight(1)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  @Builder
  boolRow() {
    Row({ space: Layout.s3 }) {
      this.labelText()
      Toggle({ type: ToggleType.Switch, isOn: this.entry.boolValue })
        .selectedColor(Theme.brand)
        .onChange((isOn: boolean) => {
          this.entry.boolValue = isOn;
        })
    }
    .width('100%')
    .height(48)
  }

  @Builder
  numberRow() {
    Column({ space: Layout.s1 }) {
      Row({ space: Layout.s3 }) {
        this.labelText()
        Text(this.displayNumber())
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.brand)
      }
      .width('100%')

      if (this.entry.hasRange) {
        Slider({
          value: this.entry.numberValue,
          min: this.entry.min,
          max: this.entry.max,
          step: this.entry.step
        })
          .selectedColor(Theme.brand)
          .trackColor(Theme.bgSurface3)
          .blockColor(Theme.bgSurface)
          .width('100%')
          .onChange((value: number) => {
            this.entry.numberValue = value;
          })
      } else {
        TextInput({ text: this.displayNumber(), placeholder: '数字' })
          .type(InputType.Number)
          .fontSize(Layout.fontSmall)
          .height(36)
          .backgroundColor(Theme.bgInput)
          .borderRadius(Layout.radiusS)
          .onChange((value: string) => {
            const parsed: number = Number.parseFloat(value);
            if (!Number.isNaN(parsed)) {
              this.entry.numberValue = parsed;
            }
          })
      }
    }
    .width('100%')
    .padding({ top: Layout.s2, bottom: Layout.s2 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  enumRow() {
    Column({ space: Layout.s2 }) {
      this.labelText()
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.entry.options, (option: string) => {
          Text(option)
            .fontSize(Layout.fontSmall)
            .fontColor(this.entry.stringValue === option ? Theme.textOnBrand : Theme.textSecondary)
            .padding({ left: Layout.s3, right: Layout.s3, top: 5, bottom: 5 })
            .borderRadius(Layout.radiusPill)
            .backgroundColor(this.entry.stringValue === option ? Theme.brand : Theme.bgSurface2)
            .margin({ right: Layout.s2, bottom: Layout.s2 })
            .onClick(() => {
              this.entry.stringValue = option;
            })
        }, (option: string) => option)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: Layout.s2, bottom: Layout.s2 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  textRow() {
    Column({ space: Layout.s2 }) {
      this.labelText()
      TextInput({ text: this.entry.stringValue, placeholder: this.entry.hint.length > 0 ? this.entry.hint : '文本' })
        .fontSize(Layout.fontSmall)
        .height(38)
        .backgroundColor(Theme.bgInput)
        .borderRadius(Layout.radiusS)
        .onChange((value: string) => {
          this.entry.stringValue = value;
        })
    }
    .width('100%')
    .padding({ top: Layout.s2, bottom: Layout.s2 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  listRow() {
    Column({ space: Layout.s2 }) {
      this.labelText()
      if (this.entry.listValue.length === 0) {
        Text('未添加').fontSize(Layout.fontCaption).fontColor(Theme.textTertiary).width('100%')
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.entry.listValue, (one: string) => {
            Row({ space: 4 }) {
              Text(one)
                .fontSize(Layout.fontSmall)
                .fontColor(Theme.chipText)
              SymbolGlyph(Icons.close)
                .fontSize(12)
                .fontColor([Theme.textTertiary])
                .onClick(() => {
                  this.removeListItem(one);
                })
            }
            .padding({ left: Layout.s2, right: Layout.s2, top: 5, bottom: 5 })
            .borderRadius(Layout.radiusPill)
            .backgroundColor(Theme.chipBg)
            .margin({ right: Layout.s2, bottom: Layout.s2 })
          }, (one: string) => one)
        }
        .width('100%')
      }
      Row({ space: Layout.s2 }) {
        TextInput({ text: this.entry.listDraft, placeholder: '新增一项' })
          .fontSize(Layout.fontSmall)
          .height(36)
          .layoutWeight(1)
          .backgroundColor(Theme.bgInput)
          .borderRadius(Layout.radiusS)
          .onChange((value: string) => {
            this.entry.listDraft = value;
          })
          .onSubmit(() => {
            this.addListItem();
          })
        Text('添加')
          .fontSize(Layout.fontSmall)
          .fontColor(Theme.brand)
          .padding({ left: Layout.s2, right: Layout.s2, top: 5, bottom: 5 })
          .onClick(() => {
            this.addListItem();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: Layout.s2, bottom: Layout.s2 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      if (this.entry.type === 'boolean') {
        this.boolRow()
      } else if (this.entry.type === 'number') {
        this.numberRow()
      } else if (this.entry.type === 'enum') {
        this.enumRow()
      } else if (this.entry.type === 'string_list') {
        this.listRow()
      } else {
        this.textRow()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 能力设置表单容器。父组件在展开时创建它，`aboutToAppear` 把已保存的值灌进控件。
 */
@Component
export struct ConfigForm {
  skillId: string = '';
  fields: SkillConfigField[] = [];
  savedConfigJson: string = '';
  onSave: (configJson: string) => void = (configJson: string) => {
  };

  @State private entries: ConfigEntryState[] = [];

  aboutToAppear(): void {
    this.entries = this.buildEntries();
  }

  private buildEntries(): ConfigEntryState[] {
    const saved: Record<string, Object> = this.parseSaved();
    const out: ConfigEntryState[] = [];
    for (const field of this.fields) {
      const entry: ConfigEntryState = new ConfigEntryState();
      entry.key = field.key;
      entry.label = field.label.length > 0 ? field.label : field.key;
      entry.type = field.type;
      entry.hint = field.hint !== undefined ? field.hint : '';
      entry.options = field.options !== undefined ? field.options : [];
      this.applyRange(entry, field);

      const raw: Object | undefined = saved[field.key];
      const value: Object = raw === undefined || raw === null ? this.parseDefault(field)
        : this.unwrapForType(raw, field.type);
      this.applyValue(entry, value);
      out.push(entry);
    }
    return out;
  }

  private applyRange(entry: ConfigEntryState, field: SkillConfigField): void {
    if (field.min !== undefined && field.max !== undefined && field.max > field.min) {
      entry.hasRange = true;
      entry.min = field.min;
      entry.max = field.max;
      entry.step = (field.max - field.min) <= 5 ? 0.1 : 1;
    } else {
      entry.hasRange = false;
      entry.min = 0;
      entry.max = 100;
      entry.step = 1;
    }
  }

  private parseSaved(): Record<string, Object> {
    const text: string = this.savedConfigJson.trim();
    if (text.length === 0) {
      return newObjectRecord();
    }
    try {
      const parsed: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      return parsed === null || parsed === undefined ? newObjectRecord() : parsed;
    } catch (e) {
      return newObjectRecord();
    }
  }

  private parseDefault(field: SkillConfigField): Object {
    const text: string = field.defaultValueJson.trim();
    if (text.length === 0) {
      return '';
    }
    try {
      const parsed: Object = JSON.parse(text) as Object;
      return parsed;
    } catch (e) {
      return text;
    }
  }

  private unwrapForType(raw: Object, type: string): Object {
    if (type === 'string' || type === 'enum') {
      return raw;
    }
    return this.unwrap(raw);
  }

  private unwrap(raw: Object): Object {
    if (typeof raw === 'string') {
      const text: string = raw as string;
      const trimmed: string = text.trim();
      if (trimmed.startsWith('[') || trimmed.startsWith('{') || trimmed === 'true' || trimmed === 'false'
        || this.looksLikeNumber(trimmed)) {
        try {
          return JSON.parse(trimmed) as Object;
        } catch (e) {
          return raw;
        }
      }
      return raw;
    }
    return raw;
  }

  private looksLikeNumber(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    const parsed: number = Number.parseFloat(text);
    return !Number.isNaN(parsed);
  }

  private applyValue(entry: ConfigEntryState, value: Object): void {
    if (entry.type === 'boolean') {
      entry.boolValue = typeof value === 'boolean' ? value as boolean : false;
    } else if (entry.type === 'number') {
      if (typeof value === 'number') {
        entry.numberValue = value as number;
      } else if (typeof value === 'string') {
        const parsed: number = Number.parseFloat(value as string);
        entry.numberValue = Number.isNaN(parsed) ? 0 : parsed;
      }
    } else if (entry.type === 'string_list') {
      entry.listValue = [];
      if (Array.isArray(value)) {
        const arr: Object[] = value as Object[];
        const list: string[] = [];
        for (const one of arr) {
          if (typeof one === 'string') {
            list.push(one as string);
          }
        }
        entry.listValue = list;
      }
    } else {
      if (typeof value === 'string') {
        entry.stringValue = value as string;
      } else if (value !== undefined && value !== null) {
        entry.stringValue = value.toString();
      }
    }
  }

  private toJson(): string {
    const record: Record<string, Object> = newObjectRecord();
    for (const entry of this.entries) {
      if (entry.type === 'boolean') {
        record[entry.key] = entry.boolValue;
      } else if (entry.type === 'number') {
        record[entry.key] = entry.numberValue;
      } else if (entry.type === 'string_list') {
        record[entry.key] = entry.listValue;
      } else {
        record[entry.key] = entry.stringValue;
      }
    }
    return JSON.stringify(record);
  }

  build() {
    Column({ space: Layout.s1 }) {
      if (this.entries.length === 0) {
        Text('无可调参数').fontSize(Layout.fontSmall).fontColor(Theme.textTertiary).width('100%')
      } else {
        ForEach(this.entries, (entry: ConfigEntryState) => {
          ConfigRow({ entry: entry })
        }, (entry: ConfigEntryState) => entry.key)

        Row() {
          Text('保存参数')
            .fontSize(Layout.fontSmall)
            .fontColor(Theme.textOnBrand)
            .padding({ left: Layout.s4, right: Layout.s4, top: 7, bottom: 7 })
            .borderRadius(Layout.radiusS)
            .backgroundColor(Theme.brand)
            .onClick(() => {
              this.onSave(this.toJson());
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ top: Layout.s2 })
      }
    }
    .width('100%')
    .padding({ left: Layout.s3, right: Layout.s3, top: Layout.s1, bottom: Layout.s3 })
    .borderRadius(Layout.radiusM)
    .backgroundColor(Theme.bgSurface2)
    .alignItems(HorizontalAlign.Start)
  }
}
