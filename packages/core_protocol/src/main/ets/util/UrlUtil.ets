/**
 * URL 拼接与请求体小工具（纯逻辑，零平台依赖）。
 */

/**
 * 拼接 baseUrl 与协议路径。
 * - 去掉 baseUrl 末尾多余的 `/`；
 * - baseUrl 已经以目标路径结尾时不再重复追加（用户可能直接填完整端点）；
 * - 允许 baseUrl 带子路径（如 `https://example.com/openai/v1`）。
 *
 * @param baseUrl 形如 `https://api.deepseek.com` 或 `https://host/openai/v1`
 * @param path 形如 `/responses`、`/v1/messages`、`/chat/completions`
 */
export function joinUrl(baseUrl: string, path: string): string {
  let base: string = baseUrl === undefined || baseUrl === null ? '' : baseUrl.trim();
  while (base.length > 1 && base.charAt(base.length - 1) === '/') {
    base = base.substring(0, base.length - 1);
  }
  const suffix: string = path.charAt(0) === '/' ? path : `/${path}`;
  if (base.length === 0) {
    return suffix;
  }
  if (base.length >= suffix.length && base.substring(base.length - suffix.length) === suffix) {
    return base;
  }
  return base + suffix;
}

/**
 * 判断地址是否为 https（rcp 在 6.1.0(23)+ 禁止明文 HTTP：错误码 1007900201）。
 */
export function isHttpsUrl(url: string): boolean {
  if (url === undefined || url === null) {
    return false;
  }
  return url.trim().substring(0, 8).toLowerCase() === 'https://';
}

/**
 * 从 HTTP 响应体里截取一段用于错误提示的文本（去掉换行、限制长度）。
 */
export function bodySnippet(body: string, maxLen: number): string {
  if (body === undefined || body === null || body.length === 0) {
    return '';
  }
  let text: string = body;
  text = text.split('\n').join(' ');
  text = text.split('\r').join(' ');
  text = text.trim();
  if (text.length <= maxLen) {
    return text;
  }
  return text.substring(0, maxLen) + '…';
}
