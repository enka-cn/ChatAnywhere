/**
 * 技能变更对比（中文逐字段 Diff）：供「技能创造室」的变更卡片直接展示。
 *
 * 纯逻辑，零平台依赖（只依赖同包纯工具/纯函数），可被 Node 逻辑测试覆盖。
 *
 * 输出约定（每行一个变化）：
 * - `+ ` 新增
 * - `~ ` 修改
 * - `- ` 移除
 * 末尾附「共 N 处变化」的汇总行；无变化时输出「（内容没有变化）」。
 */
import {
  displayValue, getBool, getNumber, getObject, getObjectList, getString, getStringList, hasValue,
  parseRecord, truncateText
} from './util/JsonLite';
import { tierLabel } from './SkillSchema';

/** 键值变化（值已转成展示文本）。 */
function pushChanged(out: string[], label: string, oldValue: string, newValue: string): void {
  if (oldValue === newValue) {
    return;
  }
  const oldText: string = oldValue.length === 0 ? '（空）' : oldValue;
  const newText: string = newValue.length === 0 ? '（空）' : newValue;
  out.push(`~ ${label}：${oldText} → ${newText}`);
}

/** 读取清单里的 allowedDomains。 */
function readDomains(rec: Record<string, Object>): string[] {
  const payload: Record<string, Object> | null = getObject(rec, 'runtimePayload');
  if (payload === null) {
    return [];
  }
  return getStringList(payload, 'allowedDomains');
}

/** 读取 HTTP 模板。 */
function readHttpTemplate(rec: Record<string, Object>): Record<string, Object> | null {
  const payload: Record<string, Object> | null = getObject(rec, 'runtimePayload');
  if (payload === null) {
    return null;
  }
  return getObject(payload, 'httpTemplate');
}

/** 读取工具声明。 */
function readToolSchema(rec: Record<string, Object>): Record<string, Object> | null {
  return parseRecord(getString(rec, 'toolSchemaJson', ''));
}

/** null 安全的 JSON 序列化（用于比较参数结构）。 */
function safeJsonText(value: Object | null): string {
  if (value === null) {
    return '';
  }
  return JSON.stringify(value);
}

/** 读取 configSchema 映射（key → 字段）。 */
function configSpecMap(rec: Record<string, Object>): Map<string, Record<string, Object>> {
  const map: Map<string, Record<string, Object>> = new Map<string, Record<string, Object>>();
  const specs: Record<string, Object>[] = getObjectList(rec, 'configSchema');
  for (const spec of specs) {
    const key: string = getString(spec, 'key', '').trim();
    if (key.length > 0) {
      map.set(key, spec);
    }
  }
  return map;
}

/** 读取已保存配置。 */
function savedConfigMap(rec: Record<string, Object>): Record<string, Object> {
  const parsed = parseRecord(getString(rec, 'savedConfigJson', ''));
  if (parsed === null) {
    return JSON.parse('{}') as Record<string, Object>;
  }
  return parsed;
}

/** Map 的键集合（保持插入顺序）。 */
function mapKeys(map: Map<string, Record<string, Object>>): string[] {
  const keys: string[] = [];
  map.forEach((_value: Record<string, Object>, key: string) => {
    keys.push(key);
  });
  return keys;
}

/** 基础字段对比。 */
function appendBasicDiff(out: string[], oldRec: Record<string, Object>, newRec: Record<string, Object>): void {
  pushChanged(out, '名称', getString(oldRec, 'name', ''), getString(newRec, 'name', ''));
  pushChanged(out, '说明', truncateText(getString(oldRec, 'description', ''), 80),
    truncateText(getString(newRec, 'description', ''), 80));
  pushChanged(out, '版本', getString(oldRec, 'version', ''), getString(newRec, 'version', ''));
  const oldTier: string = getString(oldRec, 'tier', '');
  const newTier: string = getString(newRec, 'tier', '');
  if (oldTier !== newTier) {
    out.push(`~ 分级：${tierLabel(oldTier)} → ${tierLabel(newTier)}`);
  }
  const oldEnabled: boolean = getBool(oldRec, 'enabled', true);
  const newEnabled: boolean = getBool(newRec, 'enabled', true);
  if (oldEnabled !== newEnabled) {
    out.push(`~ 启用状态：${oldEnabled ? '已启用' : '已停用'} → ${newEnabled ? '已启用' : '已停用'}`);
  }
  pushChanged(out, '作者', getString(oldRec, 'author', ''), getString(newRec, 'author', ''));
}

/** 提示词片段对比。 */
function appendPromptDiff(out: string[], oldRec: Record<string, Object>, newRec: Record<string, Object>): void {
  const oldSnippet: string = getString(oldRec, 'promptSnippet', '').trim();
  const newSnippet: string = getString(newRec, 'promptSnippet', '').trim();
  if (oldSnippet.length === 0 && newSnippet.length > 0) {
    out.push(`+ 新增提示词片段（${newSnippet.length} 字）`);
    return;
  }
  if (oldSnippet.length > 0 && newSnippet.length === 0) {
    out.push('- 移除提示词片段');
    return;
  }
  if (oldSnippet === newSnippet) {
    return;
  }
  out.push(`~ 提示词片段：${oldSnippet.length} 字 → ${newSnippet.length} 字`);
  out.push(`  新版开头：${truncateText(newSnippet, 48)}`);
}

/** 可调用工具对比。 */
function appendToolDiff(out: string[], oldRec: Record<string, Object>, newRec: Record<string, Object>): void {
  const oldTool: Record<string, Object> | null = readToolSchema(oldRec);
  const newTool: Record<string, Object> | null = readToolSchema(newRec);
  if (oldTool === null && newTool === null) {
    return;
  }
  if (oldTool === null && newTool !== null) {
    out.push(`+ 新增可调用工具：${getString(newTool, 'name', '')}`);
    out.push(`+ 工具说明：${truncateText(getString(newTool, 'description', ''), 60)}`);
    return;
  }
  if (oldTool !== null && newTool === null) {
    out.push(`- 移除可调用工具：${getString(oldTool, 'name', '')}`);
    return;
  }
  if (oldTool === null || newTool === null) {
    return;
  }
  pushChanged(out, '工具名', getString(oldTool, 'name', ''), getString(newTool, 'name', ''));
  pushChanged(out, '工具说明', truncateText(getString(oldTool, 'description', ''), 60),
    truncateText(getString(newTool, 'description', ''), 60));
  const oldParams: string = safeJsonText(getObject(oldTool, 'parameters'));
  const newParams: string = safeJsonText(getObject(newTool, 'parameters'));
  if (oldParams !== newParams) {
    out.push('~ 工具参数结构已调整');
  }
}

/** 运行载荷（HTTP / MCP / 脚本）对比。 */
function appendRuntimeDiff(out: string[], oldRec: Record<string, Object>, newRec: Record<string, Object>): void {
  const oldHttp: Record<string, Object> | null = readHttpTemplate(oldRec);
  const newHttp: Record<string, Object> | null = readHttpTemplate(newRec);
  if (oldHttp === null && newHttp !== null) {
    out.push('+ 新增 HTTP 请求模板');
  } else if (oldHttp !== null && newHttp === null) {
    out.push('- 移除 HTTP 请求模板');
  } else if (oldHttp !== null && newHttp !== null) {
    pushChanged(out, '请求方式', getString(oldHttp, 'method', ''), getString(newHttp, 'method', ''));
    pushChanged(out, '请求地址', getString(oldHttp, 'urlTemplate', ''), getString(newHttp, 'urlTemplate', ''));
    const oldHeaders: string = getString(oldHttp, 'headersJson', '');
    const newHeaders: string = getString(newHttp, 'headersJson', '');
    if (oldHeaders !== newHeaders) {
      out.push('~ 请求头已调整');
    }
    const oldBody: string = getString(oldHttp, 'bodyTemplate', '');
    const newBody: string = getString(newHttp, 'bodyTemplate', '');
    if (oldBody !== newBody) {
      out.push('~ 请求体模板已调整');
    }
    pushChanged(out, '结果抽取路径', getString(oldHttp, 'responsePath', ''),
      getString(newHttp, 'responsePath', ''));
    const oldTimeout: number = getNumber(oldHttp, 'timeoutMs', 15000);
    const newTimeout: number = getNumber(newHttp, 'timeoutMs', 15000);
    if (oldTimeout !== newTimeout) {
      out.push(`~ 请求超时：${oldTimeout} 毫秒 → ${newTimeout} 毫秒`);
    }
  }
  const oldPayload: Record<string, Object> | null = getObject(oldRec, 'runtimePayload');
  const newPayload: Record<string, Object> | null = getObject(newRec, 'runtimePayload');
  if (oldPayload === null || newPayload === null) {
    return;
  }
  pushChanged(out, 'MCP 地址', getString(oldPayload, 'mcpEndpoint', ''),
    getString(newPayload, 'mcpEndpoint', ''));
  pushChanged(out, 'MCP 传输方式', getString(oldPayload, 'mcpTransport', ''),
    getString(newPayload, 'mcpTransport', ''));
  pushChanged(out, '鉴权密钥别名', getString(oldPayload, 'authSecretAlias', ''),
    getString(newPayload, 'authSecretAlias', ''));
  const oldCode: string = getString(oldPayload, 'quickJsCode', '');
  const newCode: string = getString(newPayload, 'quickJsCode', '');
  if (oldCode !== newCode) {
    if (oldCode.length === 0) {
      out.push(`+ 新增脚本代码（${newCode.length} 字）`);
    } else if (newCode.length === 0) {
      out.push('- 移除脚本代码');
    } else {
      out.push(`~ 脚本代码：${oldCode.length} 字 → ${newCode.length} 字`);
    }
  }
}

/** 网络白名单对比。 */
function appendDomainDiff(out: string[], oldRec: Record<string, Object>, newRec: Record<string, Object>): void {
  const oldDomains: string[] = readDomains(oldRec);
  const newDomains: string[] = readDomains(newRec);
  for (const domain of newDomains) {
    if (oldDomains.indexOf(domain) < 0) {
      out.push(`+ 新增允许域名：${domain}`);
    }
  }
  for (const domain of oldDomains) {
    if (newDomains.indexOf(domain) < 0) {
      out.push(`- 移除允许域名：${domain}`);
    }
  }
}

/** 配置项定义对比。 */
function appendConfigSchemaDiff(out: string[], oldRec: Record<string, Object>, newRec: Record<string, Object>): void {
  const oldMap: Map<string, Record<string, Object>> = configSpecMap(oldRec);
  const newMap: Map<string, Record<string, Object>> = configSpecMap(newRec);
  const newKeys: string[] = mapKeys(newMap);
  for (const key of newKeys) {
    const newSpec: Record<string, Object> | undefined = newMap.get(key);
    if (newSpec === undefined) {
      continue;
    }
    const oldSpec: Record<string, Object> | undefined = oldMap.get(key);
    const label: string = getString(newSpec, 'label', key);
    if (oldSpec === undefined) {
      out.push(`+ 新增配置项：${label}（${key}）`);
      out.push(`  默认值：${displayValue(parseValueText(getString(newSpec, 'defaultValueJson', '')), 40)}`);
      continue;
    }
    const oldLabel: string = getString(oldSpec, 'label', key);
    if (oldLabel !== label) {
      out.push(`~ 配置项标签：${oldLabel} → ${label}`);
    }
    pushChanged(out, `配置项「${label}」类型`, getString(oldSpec, 'type', ''), getString(newSpec, 'type', ''));
    const oldDefault: string = displayValue(parseValueText(getString(oldSpec, 'defaultValueJson', '')), 40);
    const newDefault: string = displayValue(parseValueText(getString(newSpec, 'defaultValueJson', '')), 40);
    pushChanged(out, `配置项「${label}」默认值`, oldDefault, newDefault);
    const oldRange: string = describeRange(oldSpec);
    const newRange: string = describeRange(newSpec);
    if (oldRange !== newRange) {
      out.push(`~ 配置项「${label}」范围：${oldRange} → ${newRange}`);
    }
    const oldOptions: string = getStringList(oldSpec, 'options').join('/');
    const newOptions: string = getStringList(newSpec, 'options').join('/');
    if (oldOptions !== newOptions) {
      out.push(`~ 配置项「${label}」可选项：${oldOptions.length === 0 ? '（无）' : oldOptions} → ${newOptions.length === 0 ? '（无）' : newOptions}`);
    }
  }
  const oldKeys: string[] = mapKeys(oldMap);
  for (const key of oldKeys) {
    if (!newMap.has(key)) {
      const oldSpec: Record<string, Object> | undefined = oldMap.get(key);
      const label: string = oldSpec === undefined ? key : getString(oldSpec, 'label', key);
      out.push(`- 移除配置项：${label}（${key}）`);
    }
  }
}

/** 解析默认值文本为可展示值（失败返回文本本身）。 */
function parseValueText(text: string): Object | null {
  if (text === null || text === undefined || text.trim().length === 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(text.trim()) as Object;
    return parsed;
  } catch (e) {
    return text;
  }
}

/** 描述字段范围。 */
function describeRange(spec: Record<string, Object>): string {
  const hasMin: boolean = hasValue(spec, 'min');
  const hasMax: boolean = hasValue(spec, 'max');
  if (!hasMin && !hasMax) {
    return '不限';
  }
  const minText: string = hasMin ? `${getNumber(spec, 'min', 0)}` : '不限';
  const maxText: string = hasMax ? `${getNumber(spec, 'max', 0)}` : '不限';
  return `${minText} ~ ${maxText}`;
}

/** 域名列表变化的中文动词（屏蔽/允许）。 */
function listChangeVerb(label: string, added: boolean): string {
  if (label.indexOf('屏蔽') >= 0 || label.indexOf('排除') >= 0 || label.indexOf('禁用') >= 0) {
    return added ? '新增屏蔽域名' : '移除屏蔽域名';
  }
  if (label.indexOf('允许') >= 0 || label.indexOf('白名单') >= 0 || label.indexOf('来源') >= 0) {
    return added ? '新增允许域名' : '移除允许域名';
  }
  return '';
}

/** 已保存配置值对比（用户实际生效的设置）。 */
function appendConfigValueDiff(out: string[], oldRec: Record<string, Object>, newRec: Record<string, Object>): void {
  const oldValues: Record<string, Object> = savedConfigMap(oldRec);
  const newValues: Record<string, Object> = savedConfigMap(newRec);
  const specs: Map<string, Record<string, Object>> = configSpecMap(newRec);
  const keys: string[] = [];
  Object.keys(newValues).forEach((key: string) => keys.push(key));
  Object.keys(oldValues).forEach((key: string) => {
    if (keys.indexOf(key) < 0) {
      keys.push(key);
    }
  });
  for (const key of keys) {
    const spec: Record<string, Object> | undefined = specs.get(key);
    const label: string = spec === undefined ? key : getString(spec, 'label', key);
    const type: string = spec === undefined ? '' : getString(spec, 'type', '');
    const oldValue: Object = oldValues[key];
    const newValue: Object = newValues[key];
    if (type === 'string_list') {
      const oldList: string[] = toStringList(oldValue);
      const newList: string[] = toStringList(newValue);
      appendListChanges(out, label, oldList, newList);
      continue;
    }
    const oldText: string = displayValue(oldValue, 40);
    const newText: string = displayValue(newValue, 40);
    if (oldText !== newText) {
      out.push(`~ 配置「${label}」：${oldText} → ${newText}`);
    }
  }
}

/** Object → string[]。 */
function toStringList(value: Object | null | undefined): string[] {
  const out: string[] = [];
  if (value === null || value === undefined) {
    return out;
  }
  if (Array.isArray(value)) {
    const arr = value as Object[];
    for (const one of arr) {
      if (typeof one === 'string') {
        out.push(one as string);
      } else {
        out.push(`${one}`);
      }
    }
  } else if (typeof value === 'string') {
    out.push(value as string);
  }
  return out;
}

/** 列表型配置的逐项对比（域名类给出更直白的中文）。 */
function appendListChanges(out: string[], label: string, oldList: string[], newList: string[]): void {
  for (const item of newList) {
    if (oldList.indexOf(item) >= 0) {
      continue;
    }
    const verb: string = listChangeVerb(label, true);
    if (verb.length > 0) {
      out.push(`+ ${verb}：${item}`);
    } else {
      out.push(`+ 配置「${label}」新增：${item}`);
    }
  }
  for (const item of oldList) {
    if (newList.indexOf(item) >= 0) {
      continue;
    }
    const verb: string = listChangeVerb(label, false);
    if (verb.length > 0) {
      out.push(`- ${verb}：${item}`);
    } else {
      out.push(`- 配置「${label}」移除：${item}`);
    }
  }
}

/** 新建技能时的字段清单（全部以 `+ ` 开头）。 */
function appendNewSkillFields(out: string[], rec: Record<string, Object>): void {
  out.push(`+ 名称：${getString(rec, 'name', '未命名技能')}`);
  out.push(`+ 分级：${tierLabel(getString(rec, 'tier', ''))}`);
  const description: string = getString(rec, 'description', '').trim();
  if (description.length > 0) {
    out.push(`+ 说明：${truncateText(description, 60)}`);
  }
  const domains: string[] = readDomains(rec);
  if (domains.length === 0) {
    out.push('+ 不访问外部网络');
  } else {
    out.push(`+ 允许访问域名：${domains.join('、')}`);
  }
  const tool: Record<string, Object> | null = readToolSchema(rec);
  if (tool !== null) {
    out.push(`+ 可调用工具：${getString(tool, 'name', '')}`);
  }
  const prompt: string = getString(rec, 'promptSnippet', '').trim();
  if (prompt.length > 0) {
    out.push(`+ 提示词片段：${prompt.length} 字`);
  }
  const specs: Record<string, Object>[] = getObjectList(rec, 'configSchema');
  for (const spec of specs) {
    out.push(`+ 配置项：${getString(spec, 'label', getString(spec, 'key', ''))}`);
  }
}

/**
 * 生成两个技能清单之间的中文变更对比。
 * @param oldJson 旧版清单（空串表示新建）
 * @param newJson 新版清单
 */
export function diffManifestJson(oldJson: string, newJson: string): string {
  const out: string[] = [];
  const oldRec: Record<string, Object> | null = parseRecord(oldJson);
  const newRec: Record<string, Object> | null = parseRecord(newJson);
  if (newRec === null) {
    return '（新版技能清单无法解析，无法生成对比）';
  }
  if (oldRec === null) {
    const name: string = getString(newRec, 'name', '未命名技能');
    const id: string = getString(newRec, 'id', '');
    out.push(`+ 新建技能：${name}${id.length > 0 ? `（${id}）` : ''}`);
    appendNewSkillFields(out, newRec);
  } else {
    appendBasicDiff(out, oldRec, newRec);
    appendPromptDiff(out, oldRec, newRec);
    appendToolDiff(out, oldRec, newRec);
    appendRuntimeDiff(out, oldRec, newRec);
    appendDomainDiff(out, oldRec, newRec);
    appendConfigSchemaDiff(out, oldRec, newRec);
    appendConfigValueDiff(out, oldRec, newRec);
  }
  if (out.length === 0) {
    return '（内容没有变化）';
  }
  out.push(summarizeDiff(out.join('\n')));
  return out.join('\n');
}

/** 统计变化行数（3 种前缀）。 */
export function countDiffChanges(diffText: string): number {
  if (diffText === null || diffText === undefined || diffText.trim().length === 0) {
    return 0;
  }
  if (diffText.indexOf('（内容没有变化）') >= 0) {
    return 0;
  }
  let count: number = 0;
  const lines: string[] = (diffText as string).split('\n');
  for (const line of lines) {
    const text: string = line.trim();
    if (text.startsWith('+ ') || text.startsWith('~ ') || text.startsWith('- ')) {
      count = count + 1;
    }
  }
  return count;
}

/** 是否包含实际变化。 */
export function hasDiffChanges(diffText: string): boolean {
  return countDiffChanges(diffText) > 0;
}

/** 一句话中文摘要，如「共 3 处变化（新增 1 项、修改 2 项）」。 */
export function summarizeDiff(diffText: string): string {
  if (diffText === null || diffText === undefined || diffText.trim().length === 0) {
    return '没有变化';
  }
  if (diffText.indexOf('（内容没有变化）') >= 0) {
    return '内容没有变化';
  }
  let added: number = 0;
  let changed: number = 0;
  let removed: number = 0;
  const lines: string[] = (diffText as string).split('\n');
  for (const line of lines) {
    const text: string = line.trim();
    if (text.startsWith('+ ')) {
      added = added + 1;
    } else if (text.startsWith('~ ')) {
      changed = changed + 1;
    } else if (text.startsWith('- ')) {
      removed = removed + 1;
    }
  }
  const total: number = added + changed + removed;
  if (total === 0) {
    return '内容没有变化';
  }
  const parts: string[] = [];
  if (added > 0) {
    parts.push(`新增 ${added} 项`);
  }
  if (changed > 0) {
    parts.push(`修改 ${changed} 项`);
  }
  if (removed > 0) {
    parts.push(`移除 ${removed} 项`);
  }
  return `共 ${total} 处变化（${parts.join('、')}）`;
}
