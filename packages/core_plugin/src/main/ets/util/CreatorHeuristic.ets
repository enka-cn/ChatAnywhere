/**
 * 「技能创造室」的本地规则兜底（无模型 Key 也能离线演示）。
 *
 * 纯函数，零平台依赖，可被 Node 逻辑测试覆盖。
 * 输入自然语言需求 + 可选的旧版清单 JSON，输出草稿清单、中文 Diff、一句话摘要与安全告警。
 *
 * 规则覆盖（对应产品验收场景）：
 * - 「屏蔽 / 排除 / 不要 xxx.com」→ 写入「屏蔽站点」配置并合成 `-site:` 检索条件；
 * - 「只搜 / 限定 xxx.com」→ 写入「限定站点」配置；
 * - 「输出 markdown / 摘要 / 要点」→ 改输出格式并追加提示词要求；
 * - 「取 5 篇 / 抓取前 3 篇 / 8 秒 / 相关度 2 分」→ 调整对应配置；
 * - 没有匹配到任何关键词 → 生成只注入提示词的「提示词技能」。
 */
import {
  asRecord, emptyRecord, getObject, getString, getStringList, parseJsonValueText, parseRecord,
  parseStringArray, putNumber, putString, putValue, toJsonText, truncateText
} from './JsonLite';
import { normalizeHost } from './DomainUtil';
import { diffManifestJson } from '../SkillDiff';
import {
  bumpPatchVersion, collectSecurityWarnings, defaultJsonForType, normalizeManifestJson,
  validateManifestJson
} from '../SkillSchema';
import {
  builtinFxRateJson, builtinWeatherJson, builtinWebExtractJson, builtinWebSearchJson
} from '../BuiltinSkills';

/** 本地规则草稿结果（JSON 出参，方便内核/UI 直接消费且保持纯逻辑零类型耦合）。 */
export interface HeuristicDraftResult {
  ok: boolean;
  error: string;
  draftManifestJson: string;
  diffText: string;
  summary: string;
  securityWarningsJson: string;
  /** 建议试跑输入（JSON 文本）。 */
  sampleInput: string;
}

/** 需求里识别出的域名。 */
interface DomainMention {
  domain: string;
  exclude: boolean;
}

/** 判断文本是否包含任一关键词。 */
function containsAny(text: string, words: string[]): boolean {
  for (const word of words) {
    if (text.indexOf(word) >= 0) {
      return true;
    }
  }
  return false;
}

/** 正则第一段整数（找不到返回 -1）。 */
function firstNumber(text: string, pattern: RegExp): number {
  const match = pattern.exec(text);
  if (match === null) {
    return -1;
  }
  const value: number = Number.parseInt(match[1], 10);
  return Number.isNaN(value) ? -1 : value;
}

/** 正则第一段小数（找不到返回 -1；用于「相关度 2.5」这类阈值）。 */
function firstDecimal(text: string, pattern: RegExp): number {
  const match = pattern.exec(text);
  if (match === null) {
    return -1;
  }
  const value: number = Number.parseFloat(match[1]);
  return Number.isNaN(value) ? -1 : value;
}

/** 从需求里识别域名与屏蔽/允许意图。 */
function extractDomains(text: string): DomainMention[] {
  const out: DomainMention[] = [];
  const lower: string = text.toLowerCase();
  const pattern: RegExp = new RegExp('[a-z0-9][a-z0-9-]*(?:\\.[a-z0-9][a-z0-9-]*)+', 'gi');
  let match = pattern.exec(lower);
  let guard: number = 0;
  while (match !== null && guard < 40) {
    guard = guard + 1;
    const domain: string = normalizeHost(match[0]);
    const start: number = match.index;
    const before: string = lower.substring(Math.max(0, start - 16), start);
    if (domain.length > 2 && domain.indexOf('.') > 0) {
      let exclude: boolean = false;
      if (containsAny(before, ['屏蔽', '排除', '不要', '禁用', '过滤', '不看', '去除'])) {
        exclude = true;
      } else if (containsAny(before, ['允许', '限定', '只搜', '只查', '优先', '来源', '信任', '只看'])) {
        exclude = false;
      } else {
        exclude = containsAny(lower, ['屏蔽', '排除', '不要', '禁用', '过滤']);
      }
      let duplicated: boolean = false;
      for (const one of out) {
        if (one.domain === domain && one.exclude === exclude) {
          duplicated = true;
        }
      }
      if (!duplicated) {
        out.push({ domain, exclude });
      }
    }
    match = pattern.exec(lower);
  }
  return out;
}

/** 输出格式识别（返回配置枚举值；识别不到返回空串）。 */
function detectOutputFormat(text: string): string {
  const lower: string = text.toLowerCase();
  if (lower.indexOf('markdown') >= 0 || lower.indexOf('md 格式') >= 0) {
    return 'markdown';
  }
  if (lower.indexOf('摘要') >= 0 || lower.indexOf('总结') >= 0 || lower.indexOf('summary') >= 0) {
    return 'summary';
  }
  if (lower.indexOf('要点') >= 0 || lower.indexOf('列表') >= 0 || lower.indexOf('bullet') >= 0) {
    return 'bullets';
  }
  return '';
}

/** 输出格式的中文名。 */
function outputFormatLabel(format: string): string {
  switch (format) {
    case 'markdown':
      return 'Markdown';
    case 'bullets':
      return '要点列表';
    case 'summary':
      return '摘要';
    default:
      return '默认格式';
  }
}

/** 在 configSchema 里按 key 找字段。 */
function findConfigSpec(schema: Object[], key: string): Record<string, Object> | null {
  for (const one of schema) {
    const record = asRecord(one);
    if (record === null) {
      continue;
    }
    if (getString(record, 'key', '') === key) {
      return record;
    }
  }
  return null;
}

/** 添加（或补齐）一个配置字段。 */
function ensureConfigField(schema: Object[], key: string, label: string, type: string,
  defaultValueJson: string, options: string[]): void {
  const existing = findConfigSpec(schema, key);
  if (existing !== null) {
    return;
  }
  const record: Record<string, Object> = emptyRecord();
  putString(record, 'key', key);
  putString(record, 'label', label);
  putString(record, 'type', type);
  putString(record, 'defaultValueJson', defaultValueJson);
  if (options.length > 0) {
    putValue(record, 'options', options);
  }
  schema.push(record);
}

/** 设置配置字段默认值。 */
function setConfigDefault(schema: Object[], key: string, defaultValueJson: string): boolean {
  const spec = findConfigSpec(schema, key);
  if (spec === null) {
    return false;
  }
  putString(spec, 'defaultValueJson', defaultValueJson);
  return true;
}

/** 读取列表型配置默认值。 */
function readListDefault(schema: Object[], key: string): string[] {
  const spec = findConfigSpec(schema, key);
  if (spec === null) {
    return [];
  }
  return parseStringArray(getString(spec, 'defaultValueJson', '[]'));
}

/** 把新增项合并进列表型配置默认值。 */
function mergeListConfigDefault(schema: Object[], key: string, additions: string[]): void {
  if (additions.length === 0) {
    return;
  }
  const current: string[] = readListDefault(schema, key);
  for (const one of additions) {
    if (current.indexOf(one) < 0) {
      current.push(one);
    }
  }
  setConfigDefault(schema, key, JSON.stringify(current));
}

/** 由 configSchema 默认值构造配置值对象。 */
function buildConfigValues(schema: Object[]): Record<string, Object> {
  const values: Record<string, Object> = emptyRecord();
  for (const one of schema) {
    const spec = asRecord(one);
    if (spec === null) {
      continue;
    }
    const key: string = getString(spec, 'key', '');
    if (key.length === 0) {
      continue;
    }
    const type: string = getString(spec, 'type', 'string');
    const options: string[] = getStringList(spec, 'options');
    let defaultText: string = getString(spec, 'defaultValueJson', '').trim();
    if (defaultText.length === 0) {
      defaultText = defaultJsonForType(type, options);
    }
    const parsed: Object | null = parseJsonValueText(defaultText);
    if (parsed !== null) {
      values[key] = parsed;
    }
  }
  return values;
}

/** 该技能是否属于联网检索类（决定是否改域名/格式配置）。 */
function isWebSkill(manifest: Record<string, Object>): boolean {
  const tool = parseRecord(getString(manifest, 'toolSchemaJson', ''));
  const toolName: string = tool === null ? '' : getString(tool, 'name', '').toLowerCase();
  const id: string = getString(manifest, 'id', '').toLowerCase();
  if (containsAny(toolName, ['search', 'web', 'doc'])) {
    return true;
  }
  return containsAny(id, ['search', 'web', 'doc', 'clean']);
}

/** 该技能的示例输入。 */
function sampleInputFor(manifest: Record<string, Object>): string {
  const tool = parseRecord(getString(manifest, 'toolSchemaJson', ''));
  const toolName: string = tool === null ? '' : getString(tool, 'name', '').toLowerCase();
  const id: string = getString(manifest, 'id', '').toLowerCase();
  if (toolName.indexOf('currency') >= 0 || id.indexOf('fx') >= 0) {
    return '{"from":"USD","to":"CNY","amount":100}';
  }
  if (toolName.indexOf('weather') >= 0 || id.indexOf('weather') >= 0) {
    return '{"latitude":39.9,"longitude":116.4}';
  }
  if (toolName.indexOf('extract') >= 0 || id.indexOf('extract') >= 0) {
    return '{"url":"https://example.com"}';
  }
  if (toolName.length > 0) {
    return '{"query":"DeepSeek V4 发布"}';
  }
  return '{}';
}

/** 按关键词挑选内置模板作为改造基底（返回空串表示生成提示词技能）。 */
function pickBaseTemplate(requirement: string): string {
  const lower: string = requirement.toLowerCase();
  if (containsAny(lower, ['网页', '搜索', '检索', '资料', '文档', '链接', '来源', '资讯', '清洗'])) {
    return builtinWebSearchJson();
  }
  if (containsAny(lower, ['汇率', '货币', '美元', '人民币', '换算'])) {
    return builtinFxRateJson();
  }
  if (containsAny(lower, ['天气', '气温', '降雨', '温度'])) {
    return builtinWeatherJson();
  }
  if (containsAny(lower, ['正文', '抽取文章', '抓取'])) {
    return builtinWebExtractJson();
  }
  return '';
}

/** 从需求里挑一个技能名（去掉标点，最多 12 字）。 */
function makeSkillName(requirement: string): string {
  const punctuation: RegExp = new RegExp('[，。！？、,.!?；;：:\\s]+', 'g');
  const cleaned: string = requirement.replace(punctuation, '').trim();
  if (cleaned.length === 0) {
    return '自定义技能';
  }
  if (cleaned.length <= 12) {
    return cleaned;
  }
  return cleaned.substring(0, 12);
}

/** 生成只注入提示词的技能草稿。 */
function buildPromptOnlyManifest(requirement: string, name: string): string {
  const manifest: Record<string, Object> = emptyRecord();
  const id: string = 'custom_' + Date.now().toString(36);
  putString(manifest, 'id', id);
  putString(manifest, 'version', '1.0.0');
  putString(manifest, 'name', name);
  putString(manifest, 'description', truncateText(requirement, 80));
  putString(manifest, 'tier', 'L1_DECLARATIVE');
  putValue(manifest, 'enabled', true);
  putString(manifest, 'author', 'creator');
  putNumber(manifest, 'updatedAt', Date.now());
  putValue(manifest, 'configSchema', [] as Object[]);
  putString(manifest, 'savedConfigJson', '{}');
  putString(manifest, 'promptSnippet', `当用户需要「${name}」相关能力时，请按下面的要求处理：${truncateText(requirement, 600)}`);
  const payload: Record<string, Object> = emptyRecord();
  putValue(payload, 'allowedDomains', [] as string[]);
  putValue(manifest, 'runtimePayload', payload);
  return toJsonText(manifest);
}

/** 把规则命中情况汇总成一句话摘要。 */
function buildSummary(phrases: string[]): string {
  if (phrases.length === 0) {
    return '按你的描述调整了技能内容';
  }
  return phrases.join('、');
}

/**
 * 本地规则生成/改造技能草稿。
 * @param requirementText 用户自然语言需求
 * @param baseManifestJson 旧版清单 JSON（空串表示新建）
 */
export function heuristicDraftRaw(requirementText: string, baseManifestJson: string): HeuristicDraftResult {
  const requirement: string = requirementText === null || requirementText === undefined
    ? '' : (requirementText as string).trim();
  if (requirement.length === 0) {
    return {
      ok: false,
      error: '请先用一句话说说你想让技能做什么',
      draftManifestJson: '',
      diffText: '',
      summary: '',
      securityWarningsJson: '[]',
      sampleInput: '{}'
    };
  }
  const phrases: string[] = [];
  const baseRecord: Record<string, Object> | null = parseRecord(baseManifestJson);
  let draft: Record<string, Object> | null = null;
  let baseJson: string = '';
  if (baseRecord !== null) {
    draft = parseRecord(toJsonText(baseRecord));
    baseJson = toJsonText(baseRecord);
  } else {
    const template: string = pickBaseTemplate(requirement);
    if (template.length > 0) {
      draft = parseRecord(template);
      baseJson = template;
      const name: string = makeSkillName(requirement);
      if (draft !== null) {
        putString(draft, 'name', name);
        putString(draft, 'description', truncateText(requirement, 80));
        putString(draft, 'author', 'creator');
        phrases.push(`新建技能「${name}」`);
      }
    } else {
      const name: string = makeSkillName(requirement);
      const promptOnly: string = buildPromptOnlyManifest(requirement, name);
      draft = parseRecord(promptOnly);
      baseJson = '';
      phrases.push(`新建提示词技能「${name}」`);
    }
  }
  if (draft === null) {
    return {
      ok: false,
      error: '无法构造技能草稿，请换一种说法再试',
      draftManifestJson: '',
      diffText: '',
      summary: '',
      securityWarningsJson: '[]',
      sampleInput: '{}'
    };
  }
  const schemaValue: Object = draft['configSchema'] === undefined ? ([] as Object[]) : draft['configSchema'];
  const schema: Object[] = Array.isArray(schemaValue) ? (schemaValue as Object[]) : ([] as Object[]);
  if (!Array.isArray(schemaValue)) {
    putValue(draft, 'configSchema', schema);
  }
  const webSkill: boolean = isWebSkill(draft);
  const modifiedKeys: string[] = [];
  // 1. 域名黑白名单（仅联网检索类技能）
  const mentions: DomainMention[] = extractDomains(requirement);
  const excludeDomains: string[] = [];
  const includeDomains: string[] = [];
  for (const mention of mentions) {
    if (mention.exclude) {
      excludeDomains.push(mention.domain);
    } else {
      includeDomains.push(mention.domain);
    }
  }
  if (webSkill && (excludeDomains.length > 0 || includeDomains.length > 0)) {
    ensureConfigField(schema, 'blockedSites', '屏蔽站点', 'string_list', '[]', []);
    ensureConfigField(schema, 'allowedSites', '限定站点', 'string_list', '[]', []);
    if (excludeDomains.length > 0) {
      mergeListConfigDefault(schema, 'blockedSites', excludeDomains);
      modifiedKeys.push('blockedSites');
      for (const one of excludeDomains) {
        phrases.push(`屏蔽 ${one}`);
      }
    }
    if (includeDomains.length > 0) {
      mergeListConfigDefault(schema, 'allowedSites', includeDomains);
      modifiedKeys.push('allowedSites');
      for (const one of includeDomains) {
        phrases.push(`只检索 ${one}`);
      }
    }
  }
  // 2. 输出格式
  const outputFormat: string = detectOutputFormat(requirement);
  if (outputFormat.length > 0) {
    if (webSkill && findConfigSpec(schema, 'outputFormat') !== null) {
      setConfigDefault(schema, 'outputFormat', JSON.stringify(outputFormat));
      modifiedKeys.push('outputFormat');
    }
    const formatLabel: string = outputFormatLabel(outputFormat);
    const oldPrompt: string = getString(draft, 'promptSnippet', '');
    const sentence: string = `输出格式统一使用${formatLabel}。`;
    if (oldPrompt.indexOf(sentence) < 0) {
      putString(draft, 'promptSnippet', oldPrompt.length > 0 ? `${oldPrompt} ${sentence}` : sentence);
    }
    phrases.push(`输出改为${formatLabel}`);
  }
  // 3. 条数 / 抓取篇数 / 超时 / 相关度阈值
  const countValue: number = firstNumber(requirement, new RegExp('([0-9]{1,2})\\s*(?:条|篇)'));
  if (countValue > 0 && findConfigSpec(schema, 'count') !== null) {
    setConfigDefault(schema, 'count', `${countValue}`);
    modifiedKeys.push('count');
    phrases.push(`每次取 ${countValue} 条结果`);
  }
  const fetchValue: number = firstNumber(requirement, new RegExp('(?:抓取|读取|展开|取|前)\\s*([0-9]{1,2})\\s*(?:篇|条)'));
  if (fetchValue > 0) {
    ensureConfigField(schema, 'fetchTopK', '抓取正文篇数', 'number', '0', []);
    const spec = findConfigSpec(schema, 'fetchTopK');
    if (spec !== null) {
      putNumber(spec, 'min', 0);
      putNumber(spec, 'max', 10);
    }
    setConfigDefault(schema, 'fetchTopK', `${fetchValue}`);
    modifiedKeys.push('fetchTopK');
    phrases.push(`抓取前 ${fetchValue} 篇正文`);
  }
  const timeoutValue: number = firstNumber(requirement, new RegExp('([0-9]{1,2})\\s*秒'));
  if (timeoutValue > 0) {
    ensureConfigField(schema, 'fetchTimeoutMs', '抓取超时（毫秒）', 'number', '8000', []);
    setConfigDefault(schema, 'fetchTimeoutMs', `${timeoutValue * 1000}`);
    modifiedKeys.push('fetchTimeoutMs');
    phrases.push(`超时设为 ${timeoutValue} 秒`);
  }
  const scoreValue: number = firstDecimal(requirement,
    new RegExp('(?:相关度|质量分|分数)[^0-9]{0,6}([0-9](?:\\.[0-9])?)'));
  if (scoreValue > 0) {
    ensureConfigField(schema, 'minRerankScore', '最低相关度', 'number', '1.5', []);
    setConfigDefault(schema, 'minRerankScore', `${scoreValue}`);
    modifiedKeys.push('minRerankScore');
    phrases.push(`相关度阈值设为 ${scoreValue}`);
  }
  // 4. 合并已有配置值（未被本次规则修改的项保留用户原值）
  const values: Record<string, Object> = buildConfigValues(schema);
  if (baseRecord !== null) {
    const oldSaved = parseRecord(getString(baseRecord, 'savedConfigJson', ''));
    if (oldSaved !== null) {
      Object.keys(oldSaved).forEach((key: string) => {
        if (modifiedKeys.indexOf(key) >= 0) {
          return;
        }
        if (values[key] === undefined) {
          return;
        }
        const value: Object = oldSaved[key];
        if (value !== undefined && value !== null) {
          values[key] = value;
        }
      });
    }
  }
  putString(draft, 'savedConfigJson', toJsonText(values));
  putNumber(draft, 'updatedAt', Date.now());
  // 5. 版本递增
  const oldVersion: string = getString(draft, 'version', '1.0.0');
  if (baseRecord !== null) {
    putString(draft, 'version', bumpPatchVersion(oldVersion));
  }
  const draftJson: string = toJsonText(draft);
  const validation = validateManifestJson(draftJson);
  if (!validation.ok) {
    return {
      ok: false,
      error: `生成的草稿没通过校验：${validation.error}`,
      draftManifestJson: draftJson,
      diffText: diffManifestJson(baseJson, draftJson),
      summary: '',
      securityWarningsJson: JSON.stringify(validation.warnings),
      sampleInput: sampleInputFor(draft)
    };
  }
  const normalized = normalizeManifestJson(draftJson);
  const finalDraftJson: string = normalized.ok ? normalized.manifestJson : draftJson;
  const diffText: string = diffManifestJson(baseJson, finalDraftJson);
  const warnings: string[] = collectSecurityWarnings(finalDraftJson);
  const domains: string[] = extractDomainsFromManifest(finalDraftJson);
  if (domains.length > 0) {
    warnings.push(`该技能会访问 ${domains.length} 个外部域名：${domains.join('、')}`);
  }
  if (getString(draft, 'toolSchemaJson', '').trim().length === 0) {
    warnings.push('该技能只注入提示词，不会调用外部工具');
  }
  return {
    ok: true,
    error: '',
    draftManifestJson: finalDraftJson,
    diffText,
    summary: buildSummary(phrases),
    securityWarningsJson: JSON.stringify(warnings),
    sampleInput: sampleInputFor(draft)
  };
}

/** 读清单的 allowedDomains。 */
function extractDomainsFromManifest(manifestJson: string): string[] {
  const record = parseRecord(manifestJson);
  if (record === null) {
    return [];
  }
  const payload = getObject(record, 'runtimePayload');
  if (payload === null) {
    return [];
  }
  return getStringList(payload, 'allowedDomains');
}

/**
 * 从一段真实对话反向提炼技能草稿（长按消息「沉淀为技能」）。
 * 本地规则版：把对话里的关键要求整理成提示词技能；有旧版清单时在其基础上补充提示词。
 */
export function distillDraftRaw(chatText: string, baseManifestJson: string): HeuristicDraftResult {
  const text: string = chatText === null || chatText === undefined ? '' : (chatText as string).trim();
  if (text.length === 0) {
    return {
      ok: false,
      error: '这段对话里没有可以提炼的文字内容',
      draftManifestJson: '',
      diffText: '',
      summary: '',
      securityWarningsJson: '[]',
      sampleInput: '{}'
    };
  }
  const condensed: string = truncateText(text.replace(new RegExp('\\n{2,}', 'g'), '\n'), 800);
  const baseRecord: Record<string, Object> | null = parseRecord(baseManifestJson);
  let draft: Record<string, Object> | null = null;
  let baseJson: string = '';
  if (baseRecord !== null) {
    draft = parseRecord(toJsonText(baseRecord));
    baseJson = toJsonText(baseRecord);
  }
  if (draft !== null && baseRecord !== null) {
    const current: Record<string, Object> = draft;
    const oldPrompt: string = getString(current, 'promptSnippet', '');
    const addition: string = `以下是从真实对话沉淀的处理要点，请照着做：${condensed}`;
    putString(current, 'promptSnippet', oldPrompt.length > 0 ? `${oldPrompt} ${addition}` : addition);
    putString(current, 'version', bumpPatchVersion(getString(current, 'version', '1.0.0')));
    putNumber(current, 'updatedAt', Date.now());
    draft = current;
  } else if (baseRecord === null || draft === null) {
    const name: string = '对话沉淀技能';
    const manifest: Record<string, Object> = emptyRecord();
    putString(manifest, 'id', 'custom_' + Date.now().toString(36));
    putString(manifest, 'version', '1.0.0');
    putString(manifest, 'name', name);
    putString(manifest, 'description', `从对话沉淀：${truncateText(text, 60)}`);
    putString(manifest, 'tier', 'L1_DECLARATIVE');
    putValue(manifest, 'enabled', true);
    putString(manifest, 'author', 'creator');
    putNumber(manifest, 'updatedAt', Date.now());
    putValue(manifest, 'configSchema', [] as Object[]);
    putString(manifest, 'savedConfigJson', '{}');
    putString(manifest, 'promptSnippet',
      `当用户提出与下面这段对话相似的需求时，请沿用其中的处理方式：${condensed}`);
    const payload: Record<string, Object> = emptyRecord();
    putValue(payload, 'allowedDomains', [] as string[]);
    putValue(manifest, 'runtimePayload', payload);
    draft = manifest;
  }
  if (draft === null) {
    return {
      ok: false,
      error: '无法生成沉淀草稿',
      draftManifestJson: '',
      diffText: '',
      summary: '',
      securityWarningsJson: '[]',
      sampleInput: '{}'
    };
  }
  const draftJson: string = toJsonText(draft);
  const validation = validateManifestJson(draftJson);
  if (!validation.ok) {
    return {
      ok: false,
      error: `沉淀出的草稿没通过校验：${validation.error}`,
      draftManifestJson: draftJson,
      diffText: diffManifestJson(baseJson, draftJson),
      summary: '',
      securityWarningsJson: JSON.stringify(validation.warnings),
      sampleInput: '{}'
    };
  }
  const normalized = normalizeManifestJson(draftJson);
  const finalDraftJson: string = normalized.ok ? normalized.manifestJson : draftJson;
  const warnings: string[] = collectSecurityWarnings(finalDraftJson);
  warnings.push('该技能只注入提示词，不会调用外部工具');
  return {
    ok: true,
    error: '',
    draftManifestJson: finalDraftJson,
    diffText: diffManifestJson(baseJson, finalDraftJson),
    summary: baseRecord !== null ? '在现有技能里补充了从对话沉淀的处理要点' : '从这段对话沉淀了一个提示词技能',
    securityWarningsJson: JSON.stringify(warnings),
    sampleInput: '{}'
  };
}
