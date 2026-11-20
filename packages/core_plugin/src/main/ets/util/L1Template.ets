/**
 * L1 声明式 HTTP 模板渲染（纯函数，零平台依赖，可 Node 逻辑测试）。
 *
 * 支持的占位符：
 * - `{{input.字段}}` / `{{config.字段}}`（可多级点路径，如 `{{input.user.name}}`）
 * - `{{input}}` / `{{config}}`（整段 JSON）
 * - `{{secret:别名}}`（由执行器从 Asset 密钥托管中取值，模板本身不落明文）
 * - `{{now}}` / `{{date}}`
 *
 * 支持的格式化后缀（`|` 之后）：
 * - `json`          序列化为 JSON（数组/对象原样）
 * - `join_space`    数组以空格连接
 * - `include_sites` 域名数组 → ` site:a OR site:b`
 * - `exclude_sites` 域名数组 → ` -site:a -site:b`
 * - `lines`         数组以换行连接
 */
import { asRecord, getObject, getStringList, parseRecord, valueToText } from './JsonLite';

/** 摘出模板中引用到的密钥别名（去重、忽略空）。 */
export function extractSecretAliases(template: string): string[] {
  const out: string[] = [];
  if (template === null || template === undefined || template.length === 0) {
    return out;
  }
  let rest: string = template;
  let guard: number = 0;
  while (guard < 200) {
    guard = guard + 1;
    const start: number = rest.indexOf('{{');
    if (start < 0) {
      break;
    }
    const end: number = rest.indexOf('}}', start + 2);
    if (end < 0) {
      break;
    }
    const token: string = rest.substring(start + 2, end).trim();
    rest = rest.substring(end + 2);
    if (token.startsWith('secret:')) {
      const alias: string = token.substring('secret:'.length).trim();
      if (alias.length > 0 && out.indexOf(alias) < 0) {
        out.push(alias);
      }
    }
  }
  return out;
}

/** JSON 字符串内的安全转义（不含外层引号）。 */
export function escapeJsonString(value: string): string {
  const quoted: string = JSON.stringify(value);
  if (quoted.length >= 2) {
    return quoted.substring(1, quoted.length - 1);
  }
  return value;
}

/** 把字符串按格式化后缀处理。 */
function formatString(value: string, formatter: string): string {
  if (formatter.length === 0) {
    return value;
  }
  if (formatter === 'json') {
    return JSON.stringify(value);
  }
  return value;
}

/** 把数组按格式化后缀处理。 */
function formatArray(values: string[], formatter: string): string {
  if (formatter === 'join_space') {
    return values.join(' ');
  }
  if (formatter === 'include_sites') {
    const parts: string[] = [];
    for (const one of values) {
      if (one.length > 0) {
        parts.push(`site:${one}`);
      }
    }
    return parts.length === 0 ? '' : ' ' + parts.join(' OR ');
  }
  if (formatter === 'exclude_sites') {
    const parts: string[] = [];
    for (const one of values) {
      if (one.length > 0) {
        parts.push(`-site:${one}`);
      }
    }
    return parts.length === 0 ? '' : ' ' + parts.join(' ');
  }
  if (formatter === 'lines') {
    return values.join('\n');
  }
  return JSON.stringify(values);
}

/** 从 JSON 文本中按点路径取值（数组用数字下标）；取不到返回空串。 */
export function readPathValue(record: Record<string, Object> | null, path: string): string {
  if (record === null || path === null || path === undefined) {
    return '';
  }
  const trimmed: string = (path as string).trim();
  if (trimmed.length === 0) {
    return '';
  }
  const segments: string[] = trimmed.split('.');
  let current: Object = record;
  for (const segment of segments) {
    if (segment.length === 0) {
      return '';
    }
    if (Array.isArray(current)) {
      const index: number = Number.parseInt(segment, 10);
      const arr = current as Object[];
      if (Number.isNaN(index) || index < 0 || index >= arr.length) {
        return '';
      }
      current = arr[index];
    } else {
      const sub = asRecord(current);
      if (sub === null) {
        return '';
      }
      const next: Object = sub[segment];
      if (next === undefined || next === null) {
        return '';
      }
      current = next;
    }
  }
  if (typeof current === 'string') {
    return current as string;
  }
  return valueToText(current);
}

/** 单个占位符求值。 */
function resolveToken(token: string, inputJson: string, configJson: string,
  secretValues: Map<string, string>, textMode: boolean): string {
  let rawToken: string = token.trim();
  let formatter: string = '';
  const pipeIndex: number = rawToken.indexOf('|');
  if (pipeIndex >= 0) {
    formatter = rawToken.substring(pipeIndex + 1).trim();
    rawToken = rawToken.substring(0, pipeIndex).trim();
  }
  if (rawToken.startsWith('secret:')) {
    const alias: string = rawToken.substring('secret:'.length).trim();
    const secret: string | undefined = secretValues.get(alias);
    return secret === undefined ? '' : secret;
  }
  if (rawToken === 'now') {
    return new Date().toISOString();
  }
  if (rawToken === 'date') {
    return new Date().toISOString().substring(0, 10);
  }
  if (rawToken === 'input') {
    return inputJson;
  }
  if (rawToken === 'config') {
    return configJson;
  }
  let source: Record<string, Object> | null = null;
  let keyPath: string = '';
  if (rawToken.startsWith('input.')) {
    source = parseRecord(inputJson);
    keyPath = rawToken.substring('input.'.length);
  } else if (rawToken.startsWith('config.')) {
    source = parseRecord(configJson);
    keyPath = rawToken.substring('config.'.length);
  } else {
    return `{{${token}}}`;
  }
  if (source === null) {
    return '';
  }
  // 支持多级点路径：逐段下钻后按 formatter 渲染
  const nameOnly: string = keyPath;
  if (nameOnly.length === 0) {
    return '';
  }
  const headSegments: string[] = nameOnly.split('.');
  let cursor: Record<string, Object> | null = source;
  let resolved: Object | null = null;
  for (let i = 0; i < headSegments.length; i++) {
    const segment: string = headSegments[i];
    if (cursor === null) {
      resolved = null;
      break;
    }
    const next: Object = cursor[segment];
    if (next === undefined || next === null) {
      resolved = null;
      break;
    }
    if (i === headSegments.length - 1) {
      resolved = next;
    } else {
      cursor = asRecord(next);
    }
  }
  if (resolved === null) {
    return '';
  }
  if (Array.isArray(resolved)) {
    const arr = resolved as Object[];
    const values: string[] = [];
    for (const one of arr) {
      values.push(valueToText(one));
    }
    return formatArray(values, formatter);
  }
  const asText: string = valueToText(resolved);
  const formatted: string = formatString(asText, formatter);
  if (textMode && formatter.length === 0) {
    // 正文/请求体中的字符串值必须 JSON 转义，避免引号破坏 JSON
    if (typeof resolved === 'string') {
      return escapeJsonString(asText);
    }
  }
  return formatted;
}

/**
 * 渲染模板。
 * @param urlMode true=用于 URL（字符串值做 URL 编码）；false=用于请求体/头（字符串值做 JSON 转义）
 */
export function renderTemplate(template: string, inputJson: string, configJson: string,
  secretValues: Map<string, string>, urlMode: boolean): string {
  if (template === null || template === undefined) {
    return '';
  }
  let out: string = '';
  let rest: string = template;
  let guard: number = 0;
  while (guard < 400) {
    guard = guard + 1;
    const start: number = rest.indexOf('{{');
    if (start < 0) {
      out = out + rest;
      break;
    }
    out = out + rest.substring(0, start);
    const end: number = rest.indexOf('}}', start + 2);
    if (end < 0) {
      out = out + rest.substring(start);
      break;
    }
    const token: string = rest.substring(start + 2, end).trim();
    rest = rest.substring(end + 2);
    const rendered: string = resolveToken(token, inputJson, configJson, secretValues, !urlMode);
    const hasFormatter: boolean = token.indexOf('|') >= 0;
    if (urlMode) {
      // URL 中只编码用户输入值，不编码模板结构；带格式化后缀（site: 语法）与 secret 都不编码
      if (!hasFormatter && (token.startsWith('input.') || token.startsWith('config.'))) {
        out = out + encodeURIComponent(rendered);
      } else {
        out = out + rendered;
      }
    } else {
      out = out + rendered;
    }
  }
  return out;
}

/** 按点路径抽取响应 JSON 的字段；空路径返回原文。 */
export function extractByResponsePath(rawJson: string, responsePath: string): string {
  if (responsePath === null || responsePath === undefined || responsePath.trim().length === 0) {
    return rawJson === null || rawJson === undefined ? '' : rawJson;
  }
  const root = parseRecord(rawJson);
  if (root === null) {
    // 顶层可能是数组：包一层再按路径取
    try {
      const parsed = JSON.parse(rawJson) as Object;
      if (Array.isArray(parsed)) {
        return valueToText(parsed as Object[]);
      }
    } catch (e) {
      return '';
    }
    return '';
  }
  const value: string = readPathValue(root, responsePath);
  return value;
}

/** 判断模板中是否包含某个占位符。 */
export function containsPlaceholder(template: string, placeholder: string): boolean {
  if (template === null || template === undefined) {
    return false;
  }
  return (template as string).indexOf(`{{${placeholder}}}`) >= 0;
}

/** 从请求头 JSON 文本构造头 Map（非法返回空 Map）。 */
export function parseHeaderText(headersJson: string): Map<string, string> {
  const out: Map<string, string> = new Map<string, string>();
  const record = parseRecord(headersJson);
  if (record === null) {
    return out;
  }
  const keys: string[] = Object.keys(record);
  for (const key of keys) {
    const value: Object = record[key];
    if (typeof value === 'string') {
      out.set(key, value as string);
    } else if (value !== undefined && value !== null) {
      out.set(key, valueToText(value));
    }
  }
  return out;
}

/** 取 config 中字符串列表（用于域名等场景）。 */
export function readConfigStringList(configJson: string, key: string): string[] {
  const record = parseRecord(configJson);
  if (record === null) {
    return [];
  }
  return getStringList(record, key);
}

/** 取 config 中子对象。 */
export function readConfigObject(configJson: string, key: string): Record<string, Object> | null {
  const record = parseRecord(configJson);
  if (record === null) {
    return null;
  }
  return getObject(record, key);
}

/** 生成给模型看的简短结果（截断并标注来源）。 */
export function compactResultText(text: string, maxLen: number): string {
  if (text === null || text === undefined) {
    return '';
  }
  const value = (text as string).trim();
  if (value.length <= maxLen) {
    return value;
  }
  return value.substring(0, maxLen) + '…（结果较长，已截断）';
}
