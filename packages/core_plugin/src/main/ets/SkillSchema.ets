/**
 * 技能清单 Schema：解析 / 规范化 / 校验 / 配置默认值与范围校验。
 *
 * 纯逻辑，零平台依赖（只 import 同目录纯工具），便于 QA 用 Node 做逻辑测试。
 * 所有函数以 **JSON 文本**作为出入口，避免跨模块结构类型耦合：
 * 内核/UI 拿到结果后再 `JSON.parse(...) as SkillManifest`。
 *
 * 对应 Blueprint §3.5 的 `SkillManifest` + `configSchema` 规范。
 */
import {
  asRecord, clampInt, emptyRecord, getBool, getNumber, getObject, getObjectList, getString,
  getStringList, hasValue, isValidJsonText, parseRecord, toJsonText, truncateText
} from './util/JsonLite';
import {
  extractHost, findInvalidDomain, hostFromUrlTemplate, isDomainAllowed, isSecureOrLocalUrl,
  normalizeHost
} from './util/DomainUtil';

/** 校验结果（失败原因用直白中文）。 */
export interface SkillValidateResult {
  ok: boolean;
  error: string;
  warnings: string[];
}

/** 规范化结果（manifestJson 是补全默认值后的清单）。 */
export interface SkillNormalizeResult {
  ok: boolean;
  error: string;
  warnings: string[];
  manifestJson: string;
}

/** 配置校验结果（configJson 是合并默认值后的规范配置）。 */
export interface SkillConfigResult {
  ok: boolean;
  error: string;
  configJson: string;
}

/** 构造 configSchema 用的字段描述（与契约 SkillConfigField 结构一致，但保持纯逻辑零依赖）。 */
export interface ConfigFieldInput {
  key: string;
  label: string;
  type: string;
  defaultValueJson: string;
  min?: number;
  max?: number;
  options?: string[];
  hint?: string;
}

/** 允许的分级。 */
export const SKILL_TIERS: string[] = ['L1_DECLARATIVE', 'L2_REMOTE_MCP', 'L3_QUICKJS_SANDBOX'];

/** 允许的配置字段类型。 */
export const CONFIG_FIELD_TYPES: string[] = ['boolean', 'number', 'string', 'string_list', 'enum'];

/** 允许的 HTTP 方法。 */
export const HTTP_METHODS: string[] = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'];

/** L3 脚本里禁止出现的能力（沙箱后端未启用，禁止访问宿主机能力）。 */
export const L3_FORBIDDEN_TOKENS: string[] = [
  'require(', 'import ', 'import(', 'eval(', 'new Function', 'process.', 'fs.', 'os.',
  'setInterval', 'while(true)', 'while (true)'
];

const SKILL_ID_PATTERN: RegExp = new RegExp('^[a-z][a-z0-9_]{1,47}$');
const VERSION_PATTERN: RegExp = new RegExp('^[0-9]+\\.[0-9]+\\.[0-9]+$');
const CONFIG_KEY_PATTERN: RegExp = new RegExp('^[A-Za-z][A-Za-z0-9_]{0,47}$');
const TOOL_NAME_PATTERN: RegExp = new RegExp('^[A-Za-z0-9_-]{1,64}$');
const SECRET_PATTERN: RegExp = new RegExp('(sk-[A-Za-z0-9_-]{16,})|(Bearer[ ]+[A-Za-z0-9._-]{24,})');

/** 分级中文名（UI 展示用）。 */
export function tierLabel(tier: string): string {
  switch (tier) {
    case 'L1_DECLARATIVE':
      return 'L1 声明式';
    case 'L2_REMOTE_MCP':
      return 'L2 远程服务';
    case 'L3_QUICKJS_SANDBOX':
      return 'L3 端侧脚本';
    default:
      return '未知分级';
  }
}

/** 是否为已知分级。 */
export function isKnownTier(tier: string): boolean {
  return SKILL_TIERS.indexOf(tier) >= 0;
}

/** 技能 id 是否合法（小写字母开头，字母数字下划线，2-48 位）。 */
export function isValidSkillId(id: string): boolean {
  if (id === null || id === undefined) {
    return false;
  }
  return SKILL_ID_PATTERN.test((id as string).trim());
}

/** 版本号是否合法（形如 1.0.0）。 */
export function isValidVersion(version: string): boolean {
  if (version === null || version === undefined) {
    return false;
  }
  return VERSION_PATTERN.test((version as string).trim());
}

/** 版本号补丁位 +1（草稿升级用）。 */
export function bumpPatchVersion(version: string): string {
  const parts: string[] = (version === null || version === undefined ? '1.0.0' : version).split('.');
  if (parts.length < 3) {
    return '1.0.1';
  }
  const major: number = Number.parseInt(parts[0], 10);
  const minor: number = Number.parseInt(parts[1], 10);
  const patch: number = Number.parseInt(parts[2], 10);
  if (Number.isNaN(major) || Number.isNaN(minor) || Number.isNaN(patch)) {
    return '1.0.1';
  }
  return `${major}.${minor}.${patch + 1}`;
}

/** 追加去重告警。 */
function pushWarning(warnings: string[], message: string): void {
  if (message.length === 0) {
    return;
  }
  if (warnings.indexOf(message) < 0) {
    warnings.push(message);
  }
}

/** JSON.parse 失败返回 null（不看异常文本）。 */
function parseJsonValue(text: string): Object | null {
  if (text === null || text === undefined) {
    return null;
  }
  const trimmed: string = (text as string).trim();
  if (trimmed.length === 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(trimmed) as Object;
    return parsed === undefined ? null : parsed;
  } catch (e) {
    return null;
  }
}

/** 某类型的默认值 JSON 文本。 */
export function defaultJsonForType(type: string, options: string[]): string {
  switch (type) {
    case 'boolean':
      return 'false';
    case 'number':
      return '0';
    case 'string_list':
      return '[]';
    case 'enum':
      if (options.length > 0) {
        return JSON.stringify(options[0]);
      }
      return '""';
    default:
      return '""';
  }
}

/** 校验一个配置值的类型与范围（返回中文错误，空串表示通过）。 */
export function validateConfigValue(type: string, valueJson: string, options: string[],
  min: number, max: number, hasMin: boolean, hasMax: boolean, displayName: string): string {
  const parsed: Object | null = parseJsonValue(valueJson);
  if (parsed === null) {
    return `配置项「${displayName}」的值不是合法 JSON`;
  }
  if (type === 'boolean') {
    if (typeof parsed !== 'boolean') {
      return `配置项「${displayName}」需要是开关（true/false）`;
    }
    return '';
  }
  if (type === 'number') {
    if (typeof parsed !== 'number') {
      return `配置项「${displayName}」需要是数字`;
    }
    const numberValue: number = parsed as number;
    if (!Number.isFinite(numberValue)) {
      return `配置项「${displayName}」的数字无效`;
    }
    if (hasMin && numberValue < min) {
      return `配置项「${displayName}」不能小于 ${min}`;
    }
    if (hasMax && numberValue > max) {
      return `配置项「${displayName}」不能大于 ${max}`;
    }
    return '';
  }
  if (type === 'string') {
    if (typeof parsed !== 'string') {
      return `配置项「${displayName}」需要是文本`;
    }
    return '';
  }
  if (type === 'string_list') {
    if (!Array.isArray(parsed)) {
      return `配置项「${displayName}」需要是文本列表`;
    }
    const list = parsed as Object[];
    for (const one of list) {
      if (typeof one !== 'string') {
        return `配置项「${displayName}」的列表里只能放文本`;
      }
    }
    return '';
  }
  if (type === 'enum') {
    if (typeof parsed !== 'string') {
      return `配置项「${displayName}」只能从预设选项中选一个`;
    }
    const selected: string = parsed as string;
    if (options.indexOf(selected) < 0) {
      return `配置项「${displayName}」的取值「${selected}」不在可选项里`;
    }
    return '';
  }
  return `配置项「${displayName}」的类型「${type}」不受支持`;
}

/** 规范化单个 configSchema 字段。 */
function normalizeConfigField(raw: Record<string, Object>, warnings: string[]): Record<string, Object> {
  const out: Record<string, Object> = emptyRecord();
  const key: string = getString(raw, 'key', '').trim();
  const type: string = getString(raw, 'type', 'string').trim();
  const options: string[] = getStringList(raw, 'options');
  const label: string = getString(raw, 'label', key).trim();
  out['key'] = key;
  out['label'] = label.length === 0 ? key : label;
  out['type'] = CONFIG_FIELD_TYPES.indexOf(type) >= 0 ? type : 'string';
  if (type !== 'string' && CONFIG_FIELD_TYPES.indexOf(type) < 0) {
    pushWarning(warnings, `配置项「${key}」的类型不受支持，已按文本处理`);
  }
  let defaultText: string = getString(raw, 'defaultValueJson', '').trim();
  const hasMin: boolean = hasValue(raw, 'min');
  const min: number = getNumber(raw, 'min', 0);
  const hasMax: boolean = hasValue(raw, 'max');
  const max: number = getNumber(raw, 'max', 0);
  if (defaultText.length === 0) {
    defaultText = defaultJsonForType(out['type'] as string, options);
  }
  const defaultError: string = validateConfigValue(out['type'] as string, defaultText, options,
    min, max, hasMin, hasMax, key);
  if (defaultError.length > 0) {
    pushWarning(warnings, `配置项「${key}」的默认值不可用，已重置：${defaultError}`);
    defaultText = defaultJsonForType(out['type'] as string, options);
  }
  out['defaultValueJson'] = defaultText;
  if (hasMin) {
    out['min'] = min;
  }
  if (hasMax) {
    out['max'] = max;
  }
  if (options.length > 0) {
    out['options'] = options;
  }
  const hint: string = getString(raw, 'hint', '');
  if (hint.trim().length > 0) {
    out['hint'] = hint.trim();
  }
  return out;
}

/** 规范化 HTTP 模板。 */
function normalizeHttpTemplate(raw: Record<string, Object>): Record<string, Object> {
  const out: Record<string, Object> = emptyRecord();
  const method: string = getString(raw, 'method', 'GET').trim().toUpperCase();
  out['method'] = method.length === 0 ? 'GET' : method;
  out['urlTemplate'] = getString(raw, 'urlTemplate', '').trim();
  const headersJson: string = getString(raw, 'headersJson', '').trim();
  if (headersJson.length > 0) {
    out['headersJson'] = headersJson;
  }
  const bodyTemplate: string = getString(raw, 'bodyTemplate', '');
  if (bodyTemplate.trim().length > 0) {
    out['bodyTemplate'] = bodyTemplate;
  }
  const responsePath: string = getString(raw, 'responsePath', '').trim();
  if (responsePath.length > 0) {
    out['responsePath'] = responsePath;
  }
  out['timeoutMs'] = clampInt(getNumber(raw, 'timeoutMs', 15000), 1000, 120000);
  return out;
}

/** 规范化 runtimePayload。 */
function normalizeRuntimePayload(raw: Record<string, Object>, warnings: string[]): Record<string, Object> {
  const out: Record<string, Object> = emptyRecord();
  const domains: string[] = [];
  const rawDomains: string[] = getStringList(raw, 'allowedDomains');
  for (const one of rawDomains) {
    const normalized: string = normalizeHost(one);
    if (normalized.length > 0 && domains.indexOf(normalized) < 0) {
      domains.push(normalized);
    } else if (normalized.length === 0) {
      pushWarning(warnings, `白名单里存在空的域名项，已忽略`);
    }
  }
  out['allowedDomains'] = domains;
  const httpRaw: Record<string, Object> | null = getObject(raw, 'httpTemplate');
  if (httpRaw !== null) {
    out['httpTemplate'] = normalizeHttpTemplate(httpRaw);
  }
  const mcpEndpoint: string = getString(raw, 'mcpEndpoint', '').trim();
  if (mcpEndpoint.length > 0) {
    out['mcpEndpoint'] = mcpEndpoint;
  }
  const mcpTransport: string = getString(raw, 'mcpTransport', '').trim();
  if (mcpTransport.length > 0) {
    out['mcpTransport'] = mcpTransport;
  }
  const quickJsCode: string = getString(raw, 'quickJsCode', '');
  if (quickJsCode.trim().length > 0) {
    out['quickJsCode'] = quickJsCode;
  }
  const authAlias: string = getString(raw, 'authSecretAlias', '').trim();
  if (authAlias.length > 0) {
    out['authSecretAlias'] = authAlias;
  }
  return out;
}

/** 规范化工具声明（补全缺失的 name/parameters）。 */
function normalizeToolSchema(toolSchemaJson: string, skillId: string, warnings: string[]): string {
  const record = parseRecord(toolSchemaJson);
  if (record === null) {
    pushWarning(warnings, '工具声明不是合法的 JSON 对象，已忽略');
    return '';
  }
  if (getString(record, 'name', '').trim().length === 0) {
    record['name'] = skillId.length > 0 ? skillId : 'skill';
    pushWarning(warnings, '工具声明缺少 name，已使用技能 id 兜底');
  }
  if (getString(record, 'description', '').trim().length === 0) {
    record['description'] = '由技能提供的工具';
  }
  if (getObject(record, 'parameters') === null) {
    const parameters: Record<string, Object> = emptyRecord();
    parameters['type'] = 'object';
    parameters['properties'] = emptyRecord();
    record['parameters'] = parameters;
    pushWarning(warnings, '工具声明缺少参数 Schema，已补为空对象');
  }
  return toJsonText(record);
}

/**
 * 解析并规范化技能清单：缺失字段补默认值、非法嵌套结构降级并给出告警。
 * 不拒绝"暂时不合法"的清单（校验交给 validateManifestJson），便于创造室展示草稿。
 */
export function normalizeManifestJson(json: string): SkillNormalizeResult {
  const warnings: string[] = [];
  if (json === null || json === undefined || (json as string).trim().length === 0) {
    return { ok: false, error: '技能清单内容为空', warnings, manifestJson: '' };
  }
  let raw: Record<string, Object> | null = null;
  try {
    const parsed = JSON.parse((json as string).trim()) as Object;
    raw = asRecord(parsed);
  } catch (e) {
    const err = e as Error;
    return { ok: false, error: `技能清单不是合法的 JSON：${err.message}`, warnings, manifestJson: '' };
  }
  if (raw === null) {
    return { ok: false, error: '技能清单必须是一个 JSON 对象（不能是数组或数字）', warnings, manifestJson: '' };
  }
  const out: Record<string, Object> = emptyRecord();
  const id: string = getString(raw, 'id', '').trim();
  out['id'] = id;
  const version: string = getString(raw, 'version', '1.0.0').trim();
  out['version'] = version.length === 0 ? '1.0.0' : version;
  const name: string = getString(raw, 'name', '').trim();
  out['name'] = name.length === 0 ? (id.length === 0 ? '未命名技能' : id) : name;
  out['description'] = getString(raw, 'description', '').trim();
  let tier: string = getString(raw, 'tier', '').trim();
  if (tier.length === 0) {
    tier = 'L1_DECLARATIVE';
    pushWarning(warnings, '技能清单缺少分级，已按 L1 声明式处理');
  }
  out['tier'] = tier;
  out['enabled'] = getBool(raw, 'enabled', true);
  const author: string = getString(raw, 'author', 'user').trim();
  out['author'] = author.length === 0 ? 'user' : author;
  const updatedAt: number = getNumber(raw, 'updatedAt', 0);
  out['updatedAt'] = updatedAt > 0 ? updatedAt : Date.now();
  const runtimeRaw: Record<string, Object> | null = getObject(raw, 'runtimePayload');
  out['runtimePayload'] = normalizeRuntimePayload(runtimeRaw === null ? emptyRecord() : runtimeRaw, warnings);
  // configSchema
  const schemaList: Record<string, Object>[] = getObjectList(raw, 'configSchema');
  const schemaArr: Object[] = [];
  for (const one of schemaList) {
    schemaArr.push(normalizeConfigField(one, warnings));
  }
  out['configSchema'] = schemaArr;
  const toolSchemaJson: string = getString(raw, 'toolSchemaJson', '').trim();
  if (toolSchemaJson.length > 0) {
    const normalizedTool: string = normalizeToolSchema(toolSchemaJson, id, warnings);
    if (normalizedTool.length > 0) {
      out['toolSchemaJson'] = normalizedTool;
    }
  }
  const promptSnippet: string = getString(raw, 'promptSnippet', '').trim();
  if (promptSnippet.length > 0) {
    out['promptSnippet'] = promptSnippet;
  }
  const savedConfigJson: string = getString(raw, 'savedConfigJson', '').trim();
  const configCheck: SkillConfigResult = normalizeConfigJson(toJsonText(out), savedConfigJson);
  if (!configCheck.ok) {
    pushWarning(warnings, '已保存的配置无法识别，已重置为默认配置');
    out['savedConfigJson'] = buildDefaultConfigJson(toJsonText(out));
  } else {
    out['savedConfigJson'] = configCheck.configJson;
  }
  return { ok: true, error: '', warnings, manifestJson: toJsonText(out) };
}

/** 校验工具声明 JSON（返回中文错误，空串表示通过）。 */
function validateToolSchemaText(toolSchemaJson: string): string {
  const record = parseRecord(toolSchemaJson);
  if (record === null) {
    return '工具声明不是合法的 JSON 对象';
  }
  const toolName: string = getString(record, 'name', '').trim();
  if (toolName.length === 0) {
    return '工具声明缺少 name';
  }
  if (!TOOL_NAME_PATTERN.test(toolName)) {
    return `工具名「${toolName}」不合法：只允许字母、数字、下划线和连字符，长度 1-64`;
  }
  if (getString(record, 'description', '').trim().length === 0) {
    return '工具声明缺少 description（模型需要靠它判断何时调用）';
  }
  if (getObject(record, 'parameters') === null) {
    return '工具声明缺少 parameters（JSON Schema）';
  }
  return '';
}

/** 在文本中查找明显的明文密钥（返回命中片段，空串表示没有）。 */
export function findSecretLiteral(text: string): string {
  if (text === null || text === undefined || text.length === 0) {
    return '';
  }
  const match = SECRET_PATTERN.exec(text);
  if (match === null) {
    return '';
  }
  const value: string = match[0];
  return truncateText(value, 12);
}

/** L3 脚本的安全校验（返回中文错误，空串表示通过）。 */
export function validateQuickJsCode(code: string): string {
  const source: string = code === null || code === undefined ? '' : (code as string);
  if (source.trim().length === 0) {
    return 'L3 脚本技能必须提供脚本代码';
  }
  for (const token of L3_FORBIDDEN_TOKENS) {
    if (source.indexOf(token) >= 0) {
      return `脚本里使用了被禁止的能力「${token}」，端侧沙箱不会提供文件/进程/网络直连能力`;
    }
  }
  if (source.length > 20000) {
    return '脚本代码过长（超过 20000 字），请拆分或改用 L1 声明式技能';
  }
  return '';
}

/** 校验规范化后的清单主体。 */
function validateNormalized(rec: Record<string, Object>, warnings: string[]): SkillValidateResult {
  const id: string = getString(rec, 'id', '').trim();
  if (id.length === 0) {
    return { ok: false, error: '缺少技能 id', warnings };
  }
  if (!isValidSkillId(id)) {
    return {
      ok: false,
      error: `技能 id「${id}」不合法：需以小写字母开头，只含小写字母/数字/下划线，长度 2-48`,
      warnings
    };
  }
  const version: string = getString(rec, 'version', '').trim();
  if (!isValidVersion(version)) {
    return { ok: false, error: `版本号「${version}」不合法，需形如 1.0.0`, warnings };
  }
  const tier: string = getString(rec, 'tier', '').trim();
  if (!isKnownTier(tier)) {
    return { ok: false, error: `技能分级「${tier}」不合法，只能是 L1 声明式 / L2 远程服务 / L3 端侧脚本`, warnings };
  }
  const name: string = getString(rec, 'name', '').trim();
  if (name.length === 0) {
    return { ok: false, error: '缺少技能名称（name）', warnings };
  }
  if (name.length > 24) {
    pushWarning(warnings, '技能名称较长，建议不超过 12 个字，便于在能力抽屉中展示');
  }
  const description: string = getString(rec, 'description', '').trim();
  if (description.length === 0) {
    pushWarning(warnings, '技能说明为空，建议补一句直白的中文说明');
  }
  const payload: Record<string, Object> | null = getObject(rec, 'runtimePayload');
  if (payload === null) {
    return { ok: false, error: '缺少 runtimePayload（运行时载荷）', warnings };
  }
  const domains: string[] = getStringList(payload, 'allowedDomains');
  const invalidDomain: string = findInvalidDomain(domains);
  if (invalidDomain.length > 0) {
    return {
      ok: false,
      error: `域名白名单「${invalidDomain}」不合法：只能填域名（如 api.example.com），不能带协议、路径或通配符`,
      warnings
    };
  }
  if (domains.length > 8) {
    pushWarning(warnings, `该技能可访问 ${domains.length} 个外部域名，建议收敛到必要范围`);
  }
  const httpTemplate: Record<string, Object> | null = getObject(payload, 'httpTemplate');
  const mcpEndpoint: string = getString(payload, 'mcpEndpoint', '').trim();
  const quickJsCode: string = getString(payload, 'quickJsCode', '');
  const toolSchemaJson: string = getString(rec, 'toolSchemaJson', '').trim();
  const promptSnippet: string = getString(rec, 'promptSnippet', '').trim();
  const bodyTemplate: string = httpTemplate === null ? '' : getString(httpTemplate, 'bodyTemplate', '');
  const headersJson: string = httpTemplate === null ? '' : getString(httpTemplate, 'headersJson', '');
  const secretHit: string = findSecretLiteral(`${headersJson}\n${bodyTemplate}\n${quickJsCode}`);
  if (secretHit.length > 0) {
    return {
      ok: false,
      error: `技能内容里出现了明文密钥（${secretHit}），请改用 {{secret:别名}} 占位符，并在「设置」里保存密钥`,
      warnings
    };
  }
  if (tier === 'L1_DECLARATIVE') {
    if (httpTemplate === null && promptSnippet.length === 0) {
      return { ok: false, error: 'L1 技能至少要提供 HTTP 模板或提示词片段之一', warnings };
    }
    if (httpTemplate !== null) {
      const method: string = getString(httpTemplate, 'method', 'GET').trim().toUpperCase();
      if (HTTP_METHODS.indexOf(method) < 0) {
        return { ok: false, error: `HTTP 方法「${method}」不受支持，只能是 ${HTTP_METHODS.join(' / ')}`, warnings };
      }
      const urlTemplate: string = getString(httpTemplate, 'urlTemplate', '').trim();
      if (urlTemplate.length === 0) {
        return { ok: false, error: 'HTTP 模板缺少请求地址（urlTemplate）', warnings };
      }
      if (!isSecureOrLocalUrl(urlTemplate)) {
        return { ok: false, error: '请求地址必须使用 https://（仅本机调试允许 http://localhost）', warnings };
      }
      const host: string = hostFromUrlTemplate(urlTemplate);
      if (host.length === 0) {
        return { ok: false, error: '请求地址里识别不到域名，请确认 urlTemplate 是完整 URL', warnings };
      }
      if (!isDomainAllowed(host, domains)) {
        return {
          ok: false,
          error: `请求地址的域名「${host}」不在 allowedDomains 白名单中（默认拒绝访问），请先补充白名单`,
          warnings
        };
      }
      if (domains.length === 0) {
        return { ok: false, error: '该技能需要访问网络，必须显式填写 allowedDomains 白名单', warnings };
      }
      if (promptSnippet.length === 0) {
        pushWarning(warnings, '该技能没有提示词片段，模型可能不知道什么时候该调用它');
      }
      const timeoutMs: number = getNumber(httpTemplate, 'timeoutMs', 15000);
      if (timeoutMs < 1000 || timeoutMs > 120000) {
        pushWarning(warnings, '请求超时建议设置在 1000-120000 毫秒之间');
      }
      if (toolSchemaJson.length === 0) {
        pushWarning(warnings, '该技能没有声明可调用工具，模型不会在对话中调用它');
      } else {
        const toolError: string = validateToolSchemaText(toolSchemaJson);
        if (toolError.length > 0) {
          return { ok: false, error: toolError, warnings };
        }
      }
    } else if (toolSchemaJson.length > 0) {
      return { ok: false, error: '声明了可调用工具却没有 HTTP 模板，无法执行', warnings };
    }
    if (promptSnippet.length > 8000) {
      return { ok: false, error: '提示词片段超过 8000 字，会破坏上下文与缓存，请精简', warnings };
    }
    if (promptSnippet.length > 2000) {
      pushWarning(warnings, '提示词片段偏长（超过 2000 字），可能影响 KV 缓存前缀稳定性');
    }
  } else if (tier === 'L2_REMOTE_MCP') {
    if (mcpEndpoint.length === 0) {
      return { ok: false, error: 'L2 远程服务技能必须填写 MCP 地址（mcpEndpoint）', warnings };
    }
    if (!mcpEndpoint.startsWith('https://')) {
      return { ok: false, error: 'MCP 地址必须使用 https://（禁止明文 HTTP）', warnings };
    }
    const mcpHost: string = extractHost(mcpEndpoint);
    if (mcpHost.length === 0) {
      return { ok: false, error: 'MCP 地址里识别不到域名，请检查 URL', warnings };
    }
    if (!isDomainAllowed(mcpHost, domains)) {
      return {
        ok: false,
        error: `MCP 地址的域名「${mcpHost}」不在 allowedDomains 白名单中（默认拒绝访问）`,
        warnings
      };
    }
    if (toolSchemaJson.length > 0) {
      pushWarning(warnings, 'L2 远程技能的可用工具以服务端 tools/list 返回为准，本地工具声明会被忽略');
    }
  } else {
    const codeError: string = validateQuickJsCode(quickJsCode);
    if (codeError.length > 0) {
      return { ok: false, error: codeError, warnings };
    }
    pushWarning(warnings, '当前构建未启用端侧脚本沙箱，该技能可以保存但暂时无法运行');
  }
  // configSchema
  const specs: Record<string, Object>[] = getObjectList(rec, 'configSchema');
  const seenKeys: string[] = [];
  for (const spec of specs) {
    const key: string = getString(spec, 'key', '').trim();
    if (key.length === 0) {
      return { ok: false, error: '配置项缺少 key（英文标识）', warnings };
    }
    if (!CONFIG_KEY_PATTERN.test(key)) {
      return { ok: false, error: `配置项 key「${key}」不合法：只允许字母、数字、下划线`, warnings };
    }
    if (seenKeys.indexOf(key) >= 0) {
      return { ok: false, error: `配置项 key「${key}」重复`, warnings };
    }
    seenKeys.push(key);
    const label: string = getString(spec, 'label', '').trim();
    if (label.length === 0) {
      pushWarning(warnings, `配置项「${key}」缺少中文标签，手机端表单会显示英文 key`);
    }
    const type: string = getString(spec, 'type', '').trim();
    if (CONFIG_FIELD_TYPES.indexOf(type) < 0) {
      return { ok: false, error: `配置项「${key}」的类型「${type}」不受支持`, warnings };
    }
    const options: string[] = getStringList(spec, 'options');
    if (type === 'enum' && options.length === 0) {
      return { ok: false, error: `配置项「${key}」是枚举类型，但缺少 options 选项`, warnings };
    }
    const defaultJson: string = getString(spec, 'defaultValueJson', '');
    if (!isValidJsonText(defaultJson)) {
      return { ok: false, error: `配置项「${key}」的默认值不是合法 JSON`, warnings };
    }
    const hasMin: boolean = hasValue(spec, 'min');
    const hasMax: boolean = hasValue(spec, 'max');
    const min: number = getNumber(spec, 'min', 0);
    const max: number = getNumber(spec, 'max', 0);
    if (hasMin && hasMax && min > max) {
      return { ok: false, error: `配置项「${key}」的最小值大于最大值`, warnings };
    }
    const valueError: string = validateConfigValue(type, defaultJson, options, min, max, hasMin, hasMax, key);
    if (valueError.length > 0) {
      return { ok: false, error: `默认值有误：${valueError}`, warnings };
    }
  }
  // 已保存配置必须能通过范围校验
  const savedJson: string = getString(rec, 'savedConfigJson', '').trim();
  if (savedJson.length > 0) {
    const configCheck: SkillConfigResult = normalizeConfigJson(toJsonText(rec), savedJson);
    if (!configCheck.ok) {
      return { ok: false, error: `已保存的配置不合法：${configCheck.error}`, warnings };
    }
  }
  return { ok: true, error: '', warnings };
}

/** 把清单序列化为紧凑 JSON（非法输入返回空串），供导出/落盘前统一格式。 */
export function serializeManifestJson(json: string): string {
  const record = parseRecord(json);
  if (record === null) {
    return '';
  }
  return toJsonText(record);
}

/** 校验清单（先规范化再校验），返回中文错误与安全告警。 */
export function validateManifestJson(json: string): SkillValidateResult {
  const normalized: SkillNormalizeResult = normalizeManifestJson(json);
  if (!normalized.ok) {
    return { ok: false, error: normalized.error, warnings: normalized.warnings };
  }
  const record = parseRecord(normalized.manifestJson);
  if (record === null) {
    return { ok: false, error: '技能清单解析失败', warnings: normalized.warnings };
  }
  const warnings: string[] = normalized.warnings.slice(0);
  return validateNormalized(record, warnings);
}

/** 汇总安全告警（即使清单不合法也尽量给出，供 UI 提前提示）。 */
export function collectSecurityWarnings(json: string): string[] {
  const normalized: SkillNormalizeResult = normalizeManifestJson(json);
  if (!normalized.ok) {
    return normalized.warnings;
  }
  const record = parseRecord(normalized.manifestJson);
  if (record === null) {
    return normalized.warnings;
  }
  const warnings: string[] = normalized.warnings.slice(0);
  const result: SkillValidateResult = validateNormalized(record, warnings);
  return result.warnings;
}

/** 由 configSchema 生成默认配置 JSON（Record<string, 默认值>）。 */
export function buildDefaultConfigJson(manifestJson: string): string {
  const record = parseRecord(manifestJson);
  if (record === null) {
    return '{}';
  }
  const specs: Record<string, Object>[] = getObjectList(record, 'configSchema');
  const config: Record<string, Object> = emptyRecord();
  for (const spec of specs) {
    const key: string = getString(spec, 'key', '').trim();
    if (key.length === 0) {
      continue;
    }
    const type: string = getString(spec, 'type', 'string');
    const options: string[] = getStringList(spec, 'options');
    const defaultText: string = getString(spec, 'defaultValueJson', '').trim();
    const candidates: string = defaultText.length > 0 ? defaultText : defaultJsonForType(type, options);
    const parsed: Object | null = parseJsonValue(candidates);
    if (parsed !== null) {
      config[key] = parsed;
    } else {
      const fallback: Object | null = parseJsonValue(defaultJsonForType(type, options));
      config[key] = fallback === null ? '' : fallback;
    }
  }
  return toJsonText(config);
}

/**
 * 校验并规范化用户配置：缺项用默认值补齐、多余额外键丢弃、类型/范围/枚举逐项校验。
 * 返回合并后的规范配置 JSON。
 */
export function normalizeConfigJson(manifestJson: string, configJson: string): SkillConfigResult {
  const record = parseRecord(manifestJson);
  if (record === null) {
    return { ok: false, error: '技能清单无法解析', configJson: '' };
  }
  let provided: Record<string, Object> | null = null;
  if (configJson !== null && configJson !== undefined && (configJson as string).trim().length > 0) {
    provided = parseRecord(configJson);
    if (provided === null) {
      return { ok: false, error: '配置内容不是合法的 JSON 对象', configJson: '' };
    }
  }
  const specs: Record<string, Object>[] = getObjectList(record, 'configSchema');
  const out: Record<string, Object> = emptyRecord();
  for (const spec of specs) {
    const key: string = getString(spec, 'key', '').trim();
    if (key.length === 0) {
      continue;
    }
    const type: string = getString(spec, 'type', 'string');
    const options: string[] = getStringList(spec, 'options');
    const hasMin: boolean = hasValue(spec, 'min');
    const hasMax: boolean = hasValue(spec, 'max');
    const min: number = getNumber(spec, 'min', 0);
    const max: number = getNumber(spec, 'max', 0);
    const defaultText: string = getString(spec, 'defaultValueJson', '').trim();
    if (provided === null || !hasValue(provided, key)) {
      const fallbackText: string = defaultText.length > 0 ? defaultText : defaultJsonForType(type, options);
      const parsedDefault: Object | null = parseJsonValue(fallbackText);
      if (parsedDefault !== null) {
        out[key] = parsedDefault;
      }
      continue;
    }
    const rawValue: Object = provided[key];
    const valueJson: string = toJsonText(rawValue);
    const error: string = validateConfigValue(type, valueJson, options, min, max, hasMin, hasMax, key);
    if (error.length > 0) {
      return { ok: false, error, configJson: '' };
    }
    out[key] = rawValue;
  }
  return { ok: true, error: '', configJson: toJsonText(out) };
}

/** 校验用户配置（与 normalizeConfigJson 同语义，语义化别名）。 */
export function validateConfigJson(manifestJson: string, configJson: string): SkillConfigResult {
  return normalizeConfigJson(manifestJson, configJson);
}

/** 把配置写回清单的 savedConfigJson 字段。 */
export function withConfigJson(manifestJson: string, configJson: string): string {
  const record = parseRecord(manifestJson);
  if (record === null) {
    return '';
  }
  record['savedConfigJson'] = configJson;
  return toJsonText(record);
}

/** 从 ConfigFieldInput[] 构造 configSchema JSON 文本。 */
export function buildConfigSchema(entries: ConfigFieldInput[]): string {
  const list: Object[] = [];
  for (const entry of entries) {
    const record: Record<string, Object> = emptyRecord();
    record['key'] = entry.key;
    record['label'] = entry.label;
    record['type'] = entry.type;
    record['defaultValueJson'] = entry.defaultValueJson;
    if (entry.min !== undefined) {
      record['min'] = entry.min as number;
    }
    if (entry.max !== undefined) {
      record['max'] = entry.max as number;
    }
    if (entry.options !== undefined) {
      record['options'] = entry.options as string[];
    }
    if (entry.hint !== undefined) {
      record['hint'] = entry.hint as string;
    }
    list.push(record);
  }
  return toJsonText(list);
}

/** 读取清单的 configSchema 为可编辑字段数组（UI/创造室用）。 */
export function configEntries(manifestJson: string): ConfigFieldInput[] {
  const out: ConfigFieldInput[] = [];
  const record = parseRecord(manifestJson);
  if (record === null) {
    return out;
  }
  const specs: Record<string, Object>[] = getObjectList(record, 'configSchema');
  for (const spec of specs) {
    const entry: ConfigFieldInput = {
      key: getString(spec, 'key', ''),
      label: getString(spec, 'label', getString(spec, 'key', '')),
      type: getString(spec, 'type', 'string'),
      defaultValueJson: getString(spec, 'defaultValueJson', '""')
    };
    if (hasValue(spec, 'min')) {
      entry.min = getNumber(spec, 'min', 0);
    }
    if (hasValue(spec, 'max')) {
      entry.max = getNumber(spec, 'max', 0);
    }
    const options: string[] = getStringList(spec, 'options');
    if (options.length > 0) {
      entry.options = options;
    }
    const hint: string = getString(spec, 'hint', '').trim();
    if (hint.length > 0) {
      entry.hint = hint;
    }
    out.push(entry);
  }
  return out;
}

/** 读取清单里的 allowedDomains。 */
export function manifestDomains(manifestJson: string): string[] {
  const record = parseRecord(manifestJson);
  if (record === null) {
    return [];
  }
  const payload: Record<string, Object> | null = getObject(record, 'runtimePayload');
  if (payload === null) {
    return [];
  }
  return getStringList(payload, 'allowedDomains');
}

/** 生成清单的一句话中文摘要（列表/创造室用）。 */
export function describeManifest(manifestJson: string): string {
  const record = parseRecord(manifestJson);
  if (record === null) {
    return '无法识别的技能清单';
  }
  const name: string = getString(record, 'name', getString(record, 'id', '未命名技能'));
  const tier: string = tierLabel(getString(record, 'tier', ''));
  const domains: string[] = manifestDomains(manifestJson);
  const tools: number = getString(record, 'toolSchemaJson', '').trim().length > 0 ? 1 : 0;
  const domainText: string = domains.length === 0 ? '不访问网络' : `可访问 ${domains.length} 个域名`;
  return `${name}｜${tier}｜${tools > 0 ? '含可调用工具' : '仅提示词'}｜${domainText}`;
}
