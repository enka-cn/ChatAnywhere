/**
 * SKILL.md ↔ SkillManifest 双向编解码（纯逻辑，零平台依赖，可被 Node 逻辑测试覆盖）。
 *
 * 目的：v3 的「技能创造室」改成 SKILL.md 编辑器（左列表 + 右 Markdown 编辑/预览），
 * 由本模块统一负责 frontmatter/正文与 `SkillManifest` JSON 的互转，避免 UI 手拼 JSON。
 *
 * ## frontmatter 映射（`---` 包裹，`key: value`）
 * 已知键：
 * - `id` / `name` / `version` / `description`
 * - `tier`：输出中文别名「声明式 / 远程 MCP / 端侧脚本」；输入同时接受
 *   `L1/L2/L3`、`L1_DECLARATIVE/L2_REMOTE_MCP/L3_QUICKJS_SANDBOX`
 * - `endpoint`：L1 → `httpTemplate.urlTemplate`；L2 → `mcpEndpoint`
 * - `method` / `request_body` / `request_headers` / `response_path` / `timeout_ms`：L1 模板细节
 * - `transport` / `auth_secret`：L2 MCP 传输方式与鉴权密钥别名（不含明文密钥）
 * - `quick_js`：L3 脚本源码
 * - `tool` / `tool_description` / `tool_parameters`：Function Calling 声明
 * - `allowed_domains`：逗号/空白分隔的域名列表（也接受 JSON 数组写法）
 * 其余标量键 → 配置项（命中 base 的 configSchema 则更新默认值，否则按值类型新建字段）。
 *
 * 正文 → `promptSnippet`；正文为空时保留 base 的提示词片段。
 *
 * 约定：写出的 Markdown 一定能被 `toManifestJson` 读回（`toManifestJson(toMarkdown(m), m).ok === true`，
 * 且 id/name/tier/请求模板/工具/配置等关键字段不丢）。
 */
import {
  asRecord, emptyRecord, getObject, getObjectList, getString, getStringList, hasValue,
  parseJsonValueText, parseRecord, putString, putValue, toJsonText, truncateText, valueToText
} from './util/JsonLite';
import { normalizeConfigJson, normalizeManifestJson, validateManifestJson } from './SkillSchema';

/** 编解码结果。 */
export interface SkillMarkdownResult {
  ok: boolean;
  /** 失败原因（直白中文）。 */
  error?: string;
  /** 成功时输出的 SkillManifest JSON 文本（失败时可能为空串或已规范化的部分结果）。 */
  manifestJson: string;
  /** 非致命告警（未知 frontmatter 键、缺参数结构、地址无法静态校验等）。 */
  warnings: string[];
}

/** 一行 frontmatter（key 已规范化为已知键或保留原始配置键）。 */
interface FrontmatterEntry {
  key: string;
  rawKey: string;
  value: Object | null;
}

/** Markdown 切分结果。 */
interface MarkdownSplit {
  hasFrontmatter: boolean;
  malformed: boolean;
  lines: string[];
  body: string;
}

/** 允许的分级中文别名。 */
const TIER_ALIAS_L1: string = '声明式';
const TIER_ALIAS_L2: string = '远程 MCP';
const TIER_ALIAS_L3: string = '端侧脚本';

/** 是否是「数字 token」（用于 frontmatter 标量推断，避免把 1.0.0 当数字）。 */
function isPlainNumberToken(text: string): boolean {
  const pattern: RegExp = new RegExp('^-?[0-9]+(\\.[0-9]+)?$');
  return pattern.test(text);
}

/** 规范化 frontmatter key：小写、空白/连字符转下划线，再做已知键别名映射。 */
function canonicalKnownKey(rawKey: string): string {
  const key: string = rawKey.trim().toLowerCase().split(' ').join('_').split('-').join('_');
  switch (key) {
    case 'id':
    case 'name':
    case 'version':
    case 'tier':
    case 'description':
    case 'endpoint':
    case 'method':
    case 'tool':
      return key;
    case 'allowed_domains':
    case 'alloweddomains':
    case 'allowed_domain':
      return 'allowed_domains';
    case 'tool_description':
    case 'tooldescription':
      return 'tool_description';
    case 'tool_parameters':
    case 'toolparameters':
      return 'tool_parameters';
    case 'request_body':
    case 'requestbody':
      return 'request_body';
    case 'request_headers':
    case 'requestheaders':
      return 'request_headers';
    case 'response_path':
    case 'responsepath':
      return 'response_path';
    case 'timeout_ms':
    case 'timeoutms':
      return 'timeout_ms';
    case 'transport':
    case 'mcp_transport':
    case 'mcptransport':
      return 'transport';
    case 'auth_secret':
    case 'authsecret':
    case 'auth_secret_alias':
    case 'authsecretalias':
      return 'auth_secret';
    case 'quick_js':
    case 'quickjs':
    case 'quick_js_code':
    case 'quickjscode':
      return 'quick_js';
    default:
      return '';
  }
}

/** 去掉一层引号。 */
function stripQuotes(text: string): string {
  const value: string = text.trim();
  if (value.length >= 2) {
    const first: string = value.substring(0, 1);
    const last: string = value.substring(value.length - 1);
    if ((first === '"' && last === '"') || (first === '\'' && last === '\'')) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}

/** 逗号 / 空白分隔列表解析（域名等）。 */
function splitListText(raw: string): string[] {
  const out: string[] = [];
  if (raw === null || raw === undefined || raw.trim().length === 0) {
    return out;
  }
  const commaParts: string[] = (raw as string).split(',');
  for (const part of commaParts) {
    const tokens: string[] = part.trim().split(new RegExp('\\s+'));
    for (const token of tokens) {
      const value: string = stripQuotes(token);
      if (value.length > 0 && out.indexOf(value) < 0) {
        out.push(value);
      }
    }
  }
  return out;
}

/** 解析 frontmatter 的一个值：双引号 JSON 串 / 单引号串 / 布尔 / 数字 / JSON 数组 / 裸文本。 */
function parseFrontmatterValue(rawValue: string): Object | null {
  const text: string = rawValue.trim();
  if (text.length === 0) {
    return null;
  }
  if (text.startsWith('"')) {
    const parsed: Object | null = parseJsonValueText(text);
    if (parsed !== null) {
      return parsed;
    }
    return stripQuotes(text);
  }
  if (text.startsWith('\'')) {
    return stripQuotes(text);
  }
  if (text === 'true') {
    return true;
  }
  if (text === 'false') {
    return false;
  }
  if (text === 'null') {
    return null;
  }
  if (text.startsWith('[') && text.endsWith(']')) {
    const parsed: Object | null = parseJsonValueText(text);
    if (parsed !== null && Array.isArray(parsed)) {
      return parsed;
    }
    return splitListText(text.substring(1, text.length - 1));
  }
  if (isPlainNumberToken(text)) {
    return Number.parseFloat(text);
  }
  return text;
}

/** 把字符串写成 frontmatter 标量（必要时 JSON 转义，避免冒号/引号/井号破坏结构）。 */
function formatScalar(text: string): string {
  const value: string = text === null || text === undefined ? '' : text;
  if (value.length === 0) {
    return '""';
  }
  if (value !== value.trim()) {
    return JSON.stringify(value);
  }
  const badChars: string[] = [':', '#', '"', '\'', '[', ']', '{', '}', ',', '\n', '\r', '\\'];
  for (const ch of badChars) {
    if (value.indexOf(ch) >= 0) {
      return JSON.stringify(value);
    }
  }
  const lower: string = value.toLowerCase();
  if (lower === 'true' || lower === 'false' || lower === 'null') {
    return JSON.stringify(value);
  }
  if (!Number.isNaN(Number(value))) {
    return JSON.stringify(value);
  }
  return value;
}

/** 把值格式化为 frontmatter 值（配置项用：数组用 JSON，标量沿用 formatScalar）。 */
function formatConfigValue(value: Object): string {
  if (Array.isArray(value)) {
    return JSON.stringify(value);
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return `${value}`;
  }
  return formatScalar(valueToText(value));
}

/** 分级 → 中文别名。 */
function tierToAlias(tier: string): string {
  switch (tier) {
    case 'L2_REMOTE_MCP':
      return TIER_ALIAS_L2;
    case 'L3_QUICKJS_SANDBOX':
      return TIER_ALIAS_L3;
    default:
      return TIER_ALIAS_L1;
  }
}

/** 中文别名 / L1-L3 / 全称 → 规范分级（无法识别返回空串）。 */
function parseTierAlias(text: string): string {
  const value: string = text.trim().toLowerCase().split(' ').join(' ');
  if (value === 'l1' || value === 'l1_declarative' || value === 'declarative' ||
    value === '声明式' || value === 'l1声明式' || value === 'l1 声明式') {
    return 'L1_DECLARATIVE';
  }
  if (value === 'l2' || value === 'l2_remote_mcp' || value === 'mcp' || value === '远程mcp' ||
    value === '远程 mcp' || value === '远程服务') {
    return 'L2_REMOTE_MCP';
  }
  if (value === 'l3' || value === 'l3_quickjs_sandbox' || value === 'quickjs' ||
    value === '端侧脚本' || value === '脚本') {
    return 'L3_QUICKJS_SANDBOX';
  }
  return '';
}

/** 切分 markdown 为 frontmatter 行与正文。 */
function splitMarkdown(markdown: string): MarkdownSplit {
  const text: string = markdown === null || markdown === undefined ? '' : markdown;
  const normalized: string = text.split('\r\n').join('\n').split('\r').join('\n');
  const lines: string[] = normalized.split('\n');
  let firstNonEmpty: number = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim().length > 0) {
      firstNonEmpty = i;
      break;
    }
  }
  if (firstNonEmpty < 0) {
    return { hasFrontmatter: false, malformed: false, lines: [], body: '' };
  }
  if (lines[firstNonEmpty].trim() !== '---') {
    return { hasFrontmatter: false, malformed: false, lines: [], body: normalized.trim() };
  }
  let end: number = -1;
  for (let i = firstNonEmpty + 1; i < lines.length; i++) {
    if (lines[i].trim() === '---') {
      end = i;
      break;
    }
  }
  if (end < 0) {
    return { hasFrontmatter: false, malformed: true, lines: [], body: normalized.trim() };
  }
  const frontmatterLines: string[] = [];
  for (let i = firstNonEmpty + 1; i < end; i++) {
    frontmatterLines.push(lines[i]);
  }
  const bodyLines: string[] = [];
  for (let i = end + 1; i < lines.length; i++) {
    bodyLines.push(lines[i]);
  }
  return {
    hasFrontmatter: true,
    malformed: false,
    lines: frontmatterLines,
    body: bodyLines.join('\n').trim()
  };
}

/** 取数字（frontmatter 值可能是 number 或数字字符串）。 */
function toNumberValue(value: Object | null, fallback: number): number {
  if (value === null) {
    return fallback;
  }
  if (typeof value === 'number') {
    return value as number;
  }
  const parsed: number = Number.parseFloat(valueToText(value));
  return Number.isNaN(parsed) ? fallback : parsed;
}

/** 域名列表解析（数组或逗号/空白分隔字符串）。 */
function parseDomainList(value: Object | null): string[] {
  const out: string[] = [];
  if (value === null || value === undefined) {
    return out;
  }
  if (Array.isArray(value)) {
    const arr = value as Object[];
    for (const one of arr) {
      const text: string = stripQuotes(valueToText(one));
      if (text.length > 0 && out.indexOf(text) < 0) {
        out.push(text);
      }
    }
    return out;
  }
  return splitListText(valueToText(value));
}

/** 移除 Record 的一个键（ArkTS 不支持 delete 运算符）。 */
function removeRecordKey(record: Record<string, Object>, key: string): Record<string, Object> {
  const out: Record<string, Object> = emptyRecord();
  Object.keys(record).forEach((one: string) => {
    if (one !== key) {
      out[one] = record[one];
    }
  });
  return out;
}

/** 配置项类型的中文名（告警文案用）。 */
function configTypeLabel(type: string): string {
  switch (type) {
    case 'boolean':
      return '开关';
    case 'number':
      return '数字';
    case 'string_list':
      return '列表';
    case 'enum':
      return '枚举';
    default:
      return '文本';
  }
}

/** 推导配置项类型。 */
function inferConfigType(value: Object): string {
  if (typeof value === 'boolean') {
    return 'boolean';
  }
  if (typeof value === 'number') {
    return 'number';
  }
  if (Array.isArray(value)) {
    return 'string_list';
  }
  return 'string';
}

/** 按已有字段类型收敛值（尽量让草稿能通过配置校验）。 */
function coerceConfigValue(type: string, value: Object, key: string, warnings: string[]): Object {
  if (type === 'number') {
    if (typeof value === 'number') {
      return value as number;
    }
    const parsed: number = Number.parseFloat(valueToText(value));
    if (!Number.isNaN(parsed)) {
      return parsed;
    }
    warnings.push(`配置项「${key}」需要数字，但读到「${truncateText(valueToText(value), 20)}」，已忽略该值`);
    return 0;
  }
  if (type === 'boolean') {
    if (typeof value === 'boolean') {
      return value as boolean;
    }
    const text: string = valueToText(value).trim().toLowerCase();
    if (text === 'true') {
      return true;
    }
    if (text === 'false') {
      return false;
    }
    warnings.push(`配置项「${key}」需要开关（true/false），但读到「${truncateText(text, 20)}」，已忽略该值`);
    return false;
  }
  if (type === 'string') {
    return valueToText(value);
  }
  if (type === 'string_list') {
    return parseDomainList(value);
  }
  if (type === 'enum') {
    return valueToText(value);
  }
  return value;
}

/** 查找 configSchema 中某 key 的下标（-1 表示没有）。 */
function findConfigSpecIndex(schema: Object[], key: string): number {
  for (let i = 0; i < schema.length; i++) {
    const record = asRecord(schema[i]);
    if (record === null) {
      continue;
    }
    if (getString(record, 'key', '') === key) {
      return i;
    }
  }
  return -1;
}

/** 解析工具参数 Schema（支持 JSON 字符串或对象两种写法）。 */
function parseToolParameters(value: Object, warnings: string[]): Record<string, Object> | null {
  let parsed: Object | null = null;
  if (typeof value === 'string') {
    parsed = parseJsonValueText(value as string);
  } else if (typeof value === 'object' && !Array.isArray(value)) {
    parsed = value;
  }
  const record = asRecord(parsed);
  if (record === null) {
    warnings.push('tool_parameters 不是合法的 JSON 对象，已使用空参数 Schema');
    return null;
  }
  return record;
}

/** `_` 前缀：避免误报未使用。 */
function isBlank(text: string): boolean {
  return text === null || text === undefined || text.trim().length === 0;
}

/**
 * SKILL.md 编解码器。
 */
export class SkillMarkdownCodec {
  /**
   * SkillManifest JSON → SKILL.md（YAML frontmatter + 正文提示词）。
   * 清单无法解析时返回空串（UI 侧显示空编辑器即可）。
   */
  static toMarkdown(manifestJson: string): string {
    if (isBlank(manifestJson)) {
      return '';
    }
    const normalized = normalizeManifestJson(manifestJson);
    let record = parseRecord(normalized.ok ? normalized.manifestJson : manifestJson);
    if (record === null) {
      return '';
    }
    const lines: string[] = [];
    lines.push('---');
    lines.push(`id: ${formatScalar(getString(record, 'id', ''))}`);
    lines.push(`name: ${formatScalar(getString(record, 'name', ''))}`);
    lines.push(`version: ${formatScalar(getString(record, 'version', '1.0.0'))}`);
    const tier: string = getString(record, 'tier', 'L1_DECLARATIVE');
    lines.push(`tier: ${tierToAlias(tier)}`);
    const description: string = getString(record, 'description', '');
    if (description.length > 0) {
      lines.push(`description: ${formatScalar(description)}`);
    }
    const payload = getObject(record, 'runtimePayload');
    if (payload !== null) {
      const domains: string[] = getStringList(payload, 'allowedDomains');
      if (tier === 'L2_REMOTE_MCP') {
        const endpoint: string = getString(payload, 'mcpEndpoint', '');
        if (endpoint.length > 0) {
          lines.push(`endpoint: ${formatScalar(endpoint)}`);
        }
        const transport: string = getString(payload, 'mcpTransport', '');
        if (transport.length > 0) {
          lines.push(`transport: ${formatScalar(transport)}`);
        }
        const authAlias: string = getString(payload, 'authSecretAlias', '');
        if (authAlias.length > 0) {
          lines.push(`auth_secret: ${formatScalar(authAlias)}`);
        }
      } else if (tier === 'L3_QUICKJS_SANDBOX') {
        const code: string = getString(payload, 'quickJsCode', '');
        if (code.length > 0) {
          lines.push(`quick_js: ${formatScalar(code)}`);
        }
      } else {
        const template = getObject(payload, 'httpTemplate');
        if (template !== null) {
          lines.push(`endpoint: ${formatScalar(getString(template, 'urlTemplate', ''))}`);
          lines.push(`method: ${formatScalar(getString(template, 'method', 'GET').toUpperCase())}`);
          const headersJson: string = getString(template, 'headersJson', '');
          if (headersJson.length > 0) {
            lines.push(`request_headers: ${formatScalar(headersJson)}`);
          }
          const bodyTemplate: string = getString(template, 'bodyTemplate', '');
          if (bodyTemplate.length > 0) {
            lines.push(`request_body: ${formatScalar(bodyTemplate)}`);
          }
          const responsePath: string = getString(template, 'responsePath', '');
          if (responsePath.length > 0) {
            lines.push(`response_path: ${formatScalar(responsePath)}`);
          }
          lines.push(`timeout_ms: ${toNumberValue(template['timeoutMs'], 15000)}`);
        }
      }
      lines.push(`allowed_domains: ${domains.join(', ')}`);
    }
    const tool = parseRecord(getString(record, 'toolSchemaJson', ''));
    if (tool !== null) {
      const toolName: string = getString(tool, 'name', '');
      if (toolName.length > 0) {
        lines.push(`tool: ${formatScalar(toolName)}`);
        const toolDescription: string = getString(tool, 'description', '');
        if (toolDescription.length > 0) {
          lines.push(`tool_description: ${formatScalar(toolDescription)}`);
        }
        const parameters = getObject(tool, 'parameters');
        if (parameters !== null) {
          lines.push(`tool_parameters: ${formatScalar(toJsonText(parameters))}`);
        }
      }
    }
    const schema: Record<string, Object>[] = getObjectList(record, 'configSchema');
    const saved = parseRecord(getString(record, 'savedConfigJson', ''));
    for (const spec of schema) {
      const key: string = getString(spec, 'key', '');
      if (key.length === 0 || canonicalKnownKey(key).length > 0) {
        // 与已知 frontmatter 键冲突的配置项无法无损表达，跳过（合法清单里不会出现）
        continue;
      }
      let value: Object | null = null;
      if (saved !== null && hasValue(saved, key)) {
        value = saved[key];
      } else {
        value = parseJsonValueText(getString(spec, 'defaultValueJson', ''));
      }
      if (value === null) {
        continue;
      }
      lines.push(`${key}: ${formatConfigValue(value)}`);
    }
    lines.push('---');
    const prompt: string = getString(record, 'promptSnippet', '').trim();
    if (prompt.length > 0) {
      lines.push('');
      lines.push(prompt);
    }
    lines.push('');
    return lines.join('\n');
  }

  /**
   * SKILL.md → SkillManifest JSON。
   * @param markdown SKILL.md 文本
   * @param baseManifestJson 旧版清单（保留 UI 未编辑的运行时载荷/字段/配置 schema）
   */
  static toManifestJson(markdown: string, baseManifestJson?: string): SkillMarkdownResult {
    const warnings: string[] = [];
    const markdownText: string = isBlank(markdown) ? '' : markdown;
    if (markdownText.trim().length === 0) {
      return { ok: false, error: 'SKILL.md 内容不能为空', manifestJson: '', warnings };
    }
    const split: MarkdownSplit = splitMarkdown(markdownText);
    if (split.malformed) {
      warnings.push('frontmatter 缺少结束的 ---，已按纯正文处理');
    } else if (!split.hasFrontmatter) {
      warnings.push('没有找到 frontmatter（--- 包裹），已按「正文提示词」处理');
    }
    const entries: Map<string, FrontmatterEntry> = new Map<string, FrontmatterEntry>();
    for (const rawLine of split.lines) {
      const trimmed: string = rawLine.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      const colonIndex: number = rawLine.indexOf(':');
      if (colonIndex < 0) {
        warnings.push(`忽略无法解析的 frontmatter 行：${truncateText(trimmed, 40)}`);
        continue;
      }
      const rawKey: string = rawLine.substring(0, colonIndex).trim();
      if (rawKey.length === 0) {
        continue;
      }
      const canonical: string = canonicalKnownKey(rawKey);
      const key: string = canonical.length > 0 ? canonical : rawKey;
      if (entries.has(key)) {
        warnings.push(`frontmatter 键「${rawKey}」重复，后者生效`);
      }
      entries.set(key, {
        key,
        rawKey,
        value: parseFrontmatterValue(rawLine.substring(colonIndex + 1))
      });
    }
    // 旧版清单作为合并基底
    let base: Record<string, Object> | null = null;
    if (!isBlank(baseManifestJson === undefined ? '' : (baseManifestJson as string))) {
      base = parseRecord(baseManifestJson as string);
      if (base === null) {
        warnings.push('旧版技能清单无法解析，已按新技能处理');
      }
    }
    let work: Record<string, Object> = emptyRecord();
    if (base !== null) {
      const copied = parseRecord(toJsonText(base));
      if (copied !== null) {
        work = copied;
      }
    }
    // 分级
    const tierEntry: FrontmatterEntry | undefined = entries.get('tier');
    let tier: string = getString(work, 'tier', '');
    if (tierEntry !== undefined && tierEntry.value !== null) {
      const tierText: string = valueToText(tierEntry.value).trim();
      const parsedTier: string = parseTierAlias(tierText);
      if (parsedTier.length === 0) {
        return {
          ok: false,
          error: `无法识别技能分级「${tierText}」：请填写 声明式 / 远程 MCP / 端侧脚本（也接受 L1 / L2 / L3）`,
          manifestJson: '',
          warnings
        };
      }
      tier = parsedTier;
    }
    if (tier.length === 0) {
      tier = 'L1_DECLARATIVE';
    }
    putString(work, 'tier', tier);
    // 基础文本字段（Markdown 未出现的键保留 base 值）
    const textKeys: string[] = ['id', 'name', 'version', 'description'];
    for (const key of textKeys) {
      const entry: FrontmatterEntry | undefined = entries.get(key);
      if (entry !== undefined && entry.value !== null) {
        putString(work, key, valueToText(entry.value).trim());
      }
    }
    // 运行时载荷
    let payload = getObject(work, 'runtimePayload');
    if (payload === null) {
      payload = emptyRecord();
      putValue(work, 'runtimePayload', payload);
    }
    const domainsEntry: FrontmatterEntry | undefined = entries.get('allowed_domains');
    if (domainsEntry !== undefined) {
      putValue(payload, 'allowedDomains', parseDomainList(domainsEntry.value));
    } else if (!hasValue(payload, 'allowedDomains')) {
      putValue(payload, 'allowedDomains', [] as string[]);
    }
    const endpointEntry: FrontmatterEntry | undefined = entries.get('endpoint');
    if (tier === 'L1_DECLARATIVE') {
      if (endpointEntry !== undefined && endpointEntry.value !== null) {
        const endpoint: string = valueToText(endpointEntry.value).trim();
        const template: Record<string, Object> = emptyRecord();
        const methodEntry: FrontmatterEntry | undefined = entries.get('method');
        const methodText: string = methodEntry === undefined || methodEntry.value === null
          ? 'GET' : valueToText(methodEntry.value).trim().toUpperCase();
        putString(template, 'method', methodText.length === 0 ? 'GET' : methodText);
        putString(template, 'urlTemplate', endpoint);
        const headersEntry: FrontmatterEntry | undefined = entries.get('request_headers');
        if (headersEntry !== undefined && headersEntry.value !== null) {
          putString(template, 'headersJson', valueToText(headersEntry.value));
        }
        const bodyEntry: FrontmatterEntry | undefined = entries.get('request_body');
        if (bodyEntry !== undefined && bodyEntry.value !== null) {
          putString(template, 'bodyTemplate', valueToText(bodyEntry.value));
        }
        const responsePathEntry: FrontmatterEntry | undefined = entries.get('response_path');
        if (responsePathEntry !== undefined && responsePathEntry.value !== null) {
          putString(template, 'responsePath', valueToText(responsePathEntry.value).trim());
        }
        const timeoutEntry: FrontmatterEntry | undefined = entries.get('timeout_ms');
        putValue(template, 'timeoutMs', timeoutEntry === undefined ? 15000 : toNumberValue(timeoutEntry.value, 15000));
        putValue(payload, 'httpTemplate', template);
      } else if (split.hasFrontmatter && hasValue(payload, 'httpTemplate')) {
        // frontmatter 里删掉了 endpoint：同步移除请求模板（删除语义）
        payload = removeRecordKey(payload, 'httpTemplate');
        putValue(work, 'runtimePayload', payload);
      }
    } else if (tier === 'L2_REMOTE_MCP') {
      if (endpointEntry !== undefined && endpointEntry.value !== null) {
        putString(payload, 'mcpEndpoint', valueToText(endpointEntry.value).trim());
      }
      const transportEntry: FrontmatterEntry | undefined = entries.get('transport');
      if (transportEntry !== undefined && transportEntry.value !== null) {
        putString(payload, 'mcpTransport', valueToText(transportEntry.value).trim());
      }
      const authEntry: FrontmatterEntry | undefined = entries.get('auth_secret');
      if (authEntry !== undefined && authEntry.value !== null) {
        putString(payload, 'authSecretAlias', valueToText(authEntry.value).trim());
      }
    } else {
      const quickJsEntry: FrontmatterEntry | undefined = entries.get('quick_js');
      if (quickJsEntry !== undefined && quickJsEntry.value !== null) {
        putString(payload, 'quickJsCode', valueToText(quickJsEntry.value));
      }
    }
    // 工具声明
    const toolEntry: FrontmatterEntry | undefined = entries.get('tool');
    if (toolEntry !== undefined && toolEntry.value !== null) {
      const toolName: string = valueToText(toolEntry.value).trim();
      if (toolName.length > 0) {
        const toolRecord: Record<string, Object> = emptyRecord();
        putString(toolRecord, 'name', toolName);
        const toolDescriptionEntry: FrontmatterEntry | undefined = entries.get('tool_description');
        const toolDescription: string = toolDescriptionEntry === undefined || toolDescriptionEntry.value === null
          ? getString(work, 'description', '') : valueToText(toolDescriptionEntry.value).trim();
        putString(toolRecord, 'description', toolDescription.length > 0 ? toolDescription : '由技能提供的工具');
        let parameters: Record<string, Object> | null = null;
        const parametersEntry: FrontmatterEntry | undefined = entries.get('tool_parameters');
        if (parametersEntry !== undefined && parametersEntry.value !== null) {
          parameters = parseToolParameters(parametersEntry.value, warnings);
        }
        if (parameters === null) {
          parameters = emptyRecord();
          putString(parameters, 'type', 'object');
          putValue(parameters, 'properties', emptyRecord());
          warnings.push(`工具「${toolName}」没有可解析的参数结构，已使用空参数 Schema（模型仍可调用但无参数约束）`);
        }
        putValue(toolRecord, 'parameters', parameters);
        putString(work, 'toolSchemaJson', toJsonText(toolRecord));
      }
    } else if (split.hasFrontmatter && base !== null && hasValue(work, 'toolSchemaJson')) {
      work = removeRecordKey(work, 'toolSchemaJson');
    }
    // 配置项：base 已保存值先铺底，再用 frontmatter 覆盖
    const configValues: Record<string, Object> = emptyRecord();
    const baseSaved = parseRecord(getString(work, 'savedConfigJson', ''));
    if (baseSaved !== null) {
      Object.keys(baseSaved).forEach((key: string) => {
        configValues[key] = baseSaved[key];
      });
    }
    const schema: Object[] = [];
    const schemaRecords: Record<string, Object>[] = getObjectList(work, 'configSchema');
    for (const spec of schemaRecords) {
      schema.push(spec);
    }
    entries.forEach((entry: FrontmatterEntry, key: string) => {
      if (canonicalKnownKey(key).length > 0) {
        return;
      }
      if (entry.value === null) {
        return;
      }
      const specIndex: number = findConfigSpecIndex(schema, key);
      if (specIndex >= 0) {
        const spec = asRecord(schema[specIndex]);
        if (spec === null) {
          return;
        }
        const type: string = getString(spec, 'type', 'string');
        const coerced: Object = coerceConfigValue(type, entry.value, key, warnings);
        putString(spec, 'defaultValueJson', toJsonText(coerced));
        configValues[key] = coerced;
        return;
      }
      const inferredType: string = inferConfigType(entry.value);
      const newSpec: Record<string, Object> = emptyRecord();
      putString(newSpec, 'key', key);
      putString(newSpec, 'label', entry.rawKey);
      putString(newSpec, 'type', inferredType);
      putString(newSpec, 'defaultValueJson', toJsonText(entry.value));
      schema.push(newSpec);
      configValues[key] = entry.value;
      warnings.push(`未知键「${entry.rawKey}」已作为配置项处理（类型：${configTypeLabel(inferredType)}）`);
    });
    if (schema.length > 0) {
      putValue(work, 'configSchema', schema);
    }
    const provisionalJson: string = toJsonText(work);
    const configCheck = normalizeConfigJson(provisionalJson, toJsonText(configValues));
    if (!configCheck.ok) {
      return { ok: false, error: `配置项校验失败：${configCheck.error}`, manifestJson: '', warnings };
    }
    putString(work, 'savedConfigJson', configCheck.configJson);
    // 正文 → 提示词片段（空正文保留 base 的提示词）
    const body: string = split.body.trim();
    if (body.length > 0) {
      putString(work, 'promptSnippet', body);
    }
    putValue(work, 'updatedAt', Date.now());
    const manifestJson: string = toJsonText(work);
    const normalized = normalizeManifestJson(manifestJson);
    if (!normalized.ok) {
      return { ok: false, error: normalized.error, manifestJson: '', warnings };
    }
    const validation = validateManifestJson(normalized.manifestJson);
    mergeWarnings(warnings, validation.warnings);
    if (!validation.ok) {
      return { ok: false, error: validation.error, manifestJson: normalized.manifestJson, warnings };
    }
    return { ok: true, manifestJson: normalized.manifestJson, warnings };
  }

  /** 新技能模板：一份可直接保存、且能通过 Schema 校验的 SKILL.md（纯提示词技能）。 */
  static newTemplate(): string {
    const lines: string[] = [];
    lines.push('---');
    lines.push('id: my_new_skill');
    lines.push('name: 我的新技能');
    lines.push('version: 1.0.0');
    lines.push('tier: 声明式');
    lines.push('description: 用一句话说明这个技能解决什么问题');
    lines.push('');
    lines.push('# ── 需要调用外部接口时，取消下面几行的注释并改成自己的地址 ──');
    lines.push('# endpoint: https://api.example.com/v1/search');
    lines.push('# method: POST');
    lines.push('# tool: my_tool');
    lines.push('# allowed_domains: api.example.com');
    lines.push('# request_headers: {"Content-Type":"application/json"}');
    lines.push('# request_body: {"query":"{{input.query}}"}');
    lines.push('# response_path: data.results');
    lines.push('---');
    lines.push('');
    lines.push('当用户需要 …… 时，请使用这个技能，按下面的要求处理：');
    lines.push('1. 先确认……');
    lines.push('2. 再……');
    return lines.join('\n');
  }
}

/** 合并告警（去重）。 */
function mergeWarnings(target: string[], source: string[]): void {
  for (const warning of source) {
    if (target.indexOf(warning) < 0) {
      target.push(warning);
    }
  }
}
