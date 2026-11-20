/**
 * 域名与 URL 工具（纯函数，零平台依赖，可 Node 逻辑测试）。
 *
 * 安全红线：技能只能访问 `runtimePayload.allowedDomains` 中的域名，默认拒绝；
 * 不允许通配符（`*`），子域名按后缀匹配（`api.example.com` 命中 `example.com`）。
 */

const DOMAIN_PATTERN: RegExp = new RegExp('^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$');
const IPV4_PATTERN: RegExp = new RegExp('^[0-9]{1,3}(\\.[0-9]{1,3}){3}$');

/** 提取 URL 的 host（小写、去端口/路径/用户信息；非法返回空串）。 */
export function extractHost(url: string): string {
  if (url === null || url === undefined) {
    return '';
  }
  let rest: string = (url as string).trim();
  if (rest.length === 0) {
    return '';
  }
  const schemeIndex: number = rest.indexOf('://');
  if (schemeIndex >= 0) {
    rest = rest.substring(schemeIndex + 3);
  }
  // 去掉路径/查询/锚点
  let cut: number = rest.length;
  const separators: string[] = ['/', '?', '#'];
  for (const sep of separators) {
    const index: number = rest.indexOf(sep);
    if (index >= 0 && index < cut) {
      cut = index;
    }
  }
  rest = rest.substring(0, cut);
  // 去掉用户信息
  const atIndex: number = rest.lastIndexOf('@');
  if (atIndex >= 0) {
    rest = rest.substring(atIndex + 1);
  }
  // IPv6 字面量
  if (rest.startsWith('[')) {
    const endIndex: number = rest.indexOf(']');
    if (endIndex > 0) {
      return rest.substring(0, endIndex + 1).toLowerCase();
    }
  }
  // 去掉端口
  const colonIndex: number = rest.indexOf(':');
  if (colonIndex >= 0) {
    rest = rest.substring(0, colonIndex);
  }
  return rest.toLowerCase();
}

/** 规范化域名（去 scheme/路径/端口/尾部点，小写）。 */
export function normalizeHost(value: string): string {
  if (value === null || value === undefined) {
    return '';
  }
  let host: string = (value as string).trim().toLowerCase();
  if (host.length === 0) {
    return '';
  }
  const schemeIndex: number = host.indexOf('://');
  if (schemeIndex >= 0) {
    host = host.substring(schemeIndex + 3);
  }
  const slashIndex: number = host.indexOf('/');
  if (slashIndex >= 0) {
    host = host.substring(0, slashIndex);
  }
  const colonIndex: number = host.indexOf(':');
  if (colonIndex >= 0 && !host.startsWith('[')) {
    host = host.substring(0, colonIndex);
  }
  while (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  return host;
}

/** 是否是合法域名（纯 host 写法；含 localhost 与 IPv4；拒绝协议/路径/通配符）。 */
export function isValidDomainPattern(host: string): boolean {
  if (host === null || host === undefined) {
    return false;
  }
  const raw: string = (host as string).trim().toLowerCase();
  if (raw.length === 0) {
    return false;
  }
  if (raw.indexOf('://') >= 0 || raw.indexOf('/') >= 0 || raw.indexOf('*') >= 0 || raw.indexOf(' ') >= 0) {
    return false;
  }
  const value: string = normalizeHost(raw);
  if (value.length === 0) {
    return false;
  }
  if (value === 'localhost') {
    return true;
  }
  if (IPV4_PATTERN.test(value)) {
    return true;
  }
  return DOMAIN_PATTERN.test(value);
}

/** host 是否命中白名单（精确或子域名后缀）。 */
export function isDomainAllowed(host: string, allowedDomains: string[]): boolean {
  const target: string = normalizeHost(host);
  if (target.length === 0) {
    return false;
  }
  for (const raw of allowedDomains) {
    const domain: string = normalizeHost(raw);
    if (domain.length === 0) {
      continue;
    }
    if (target === domain) {
      return true;
    }
    if (target.endsWith('.' + domain)) {
      return true;
    }
  }
  return false;
}

/** 是否 HTTPS（本地回环允许 http，便于局域网调试）。 */
export function isSecureOrLocalUrl(url: string): boolean {
  const text: string = url === null || url === undefined ? '' : (url as string).trim().toLowerCase();
  if (text.startsWith('https://')) {
    return true;
  }
  if (text.startsWith('http://localhost') || text.startsWith('http://127.0.0.1') ||
    text.startsWith('http://[::1]')) {
    return true;
  }
  return false;
}

/**
 * URL 模板里的主机名。
 * 只有当主机名能静态确定时才返回域名；scheme 段或 host 段出现 `{{...}}` 占位符时返回空串
 * （由调用方按「无法静态校验」处理，校验阶段提示用户把域名写死）。
 */
export function hostFromUrlTemplate(template: string): string {
  if (template === null || template === undefined) {
    return '';
  }
  const text: string = (template as string).trim();
  const schemeIndex: number = text.indexOf('://');
  if (schemeIndex < 0) {
    const directHost: string = extractHost(text);
    return directHost.indexOf('{{') >= 0 || directHost.indexOf('}}') >= 0 ? '' : directHost;
  }
  // scheme 段出现占位符 → 协议不可静态确定
  const schemePart: string = text.substring(0, schemeIndex);
  if (schemePart.indexOf('{{') >= 0 || schemePart.indexOf('}}') >= 0) {
    return '';
  }
  // host 段 = scheme 之后到第一个 / ? # 之前；出现占位符则无法静态校验
  const rest: string = text.substring(schemeIndex + 3);
  let cut: number = rest.length;
  const separators: string[] = ['/', '?', '#'];
  for (const sep of separators) {
    const index: number = rest.indexOf(sep);
    if (index >= 0 && index < cut) {
      cut = index;
    }
  }
  const hostSegment: string = rest.substring(0, cut);
  if (hostSegment.indexOf('{{') >= 0 || hostSegment.indexOf('}}') >= 0) {
    return '';
  }
  const host: string = extractHost(text);
  if (host.indexOf('{{') >= 0 || host.indexOf('}}') >= 0) {
    return '';
  }
  return host;
}

/** 判断 allowedDomains 列表中是否存在非法项（返回第一个非法项，空串表示都合法）。 */
export function findInvalidDomain(allowedDomains: string[]): string {
  for (const raw of allowedDomains) {
    const domain: string = normalizeHost(raw);
    if (!isValidDomainPattern(domain)) {
      return raw;
    }
  }
  return '';
}

/** 把检索结果域名转换为 `site:` 语法的补充片段（供查询组装使用）。 */
export function toIncludeSiteSyntax(domains: string[]): string {
  const parts: string[] = [];
  for (const raw of domains) {
    const domain: string = normalizeHost(raw);
    if (domain.length > 0) {
      parts.push(`site:${domain}`);
    }
  }
  return parts.length === 0 ? '' : ' ' + parts.join(' OR ');
}

/** 把排除域名转换为 `-site:` 语法片段。 */
export function toExcludeSiteSyntax(domains: string[]): string {
  const parts: string[] = [];
  for (const raw of domains) {
    const domain: string = normalizeHost(raw);
    if (domain.length > 0) {
      parts.push(`-site:${domain}`);
    }
  }
  return parts.length === 0 ? '' : ' ' + parts.join(' ');
}
