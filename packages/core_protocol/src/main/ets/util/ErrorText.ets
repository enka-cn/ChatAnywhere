/**
 * 网络/HTTP 错误的中文化映射（纯逻辑，零平台依赖）。
 *
 * 错误码来源：docs/API_REFERENCE.md §5.7（逐字摘自 rcp `fetch` docblock）。
 * 原则：面向用户的文案必须直白中文，不暴露 HTTP/curl 术语；同时给出可重试标记。
 */

/** 一次错误的统一描述。 */
export class NetErrorInfo {
  /** 直白中文提示（可直接上屏）。 */
  message: string = '';
  /** 机器可读错误码，如 `rcp_1007900007` / `http_429` / `timeout`。 */
  errorCode: string = 'unknown';
  /** 是否值得让用户点"重试"。 */
  retriable: boolean = false;
}

function createInfo(message: string, errorCode: string, retriable: boolean): NetErrorInfo {
  const info: NetErrorInfo = new NetErrorInfo();
  info.message = message;
  info.errorCode = errorCode;
  info.retriable = retriable;
  return info;
}

/** rcp 业务错误码 → 中文。 */
export function mapRcpError(businessCode: number, rawMessage: string): NetErrorInfo {
  const code: string = `rcp_${businessCode}`;
  if (businessCode === 1007900006) {
    return createInfo('无法解析服务器地址，请检查网络或接口地址是否写对', code, true);
  }
  if (businessCode === 1007900007) {
    return createInfo('连不上服务器，请检查网络连接', code, true);
  }
  if (businessCode === 1007900009) {
    return createInfo('服务器拒绝访问，请检查密钥或权限', code, false);
  }
  if (businessCode === 1007900027 || businessCode === 1007900990) {
    return createInfo('手机内存不足，请稍后重试', code, true);
  }
  if (businessCode === 1007900028) {
    return createInfo('网络请求超时，服务端长时间没有回应，请重试', code, true);
  }
  if (businessCode === 1007900035 || businessCode === 1007900058 || businessCode === 1007900077) {
    return createInfo('安全连接失败，请检查系统时间或网络代理设置', code, false);
  }
  if (businessCode === 1007900052) {
    return createInfo('服务器没有返回任何数据，请稍后重试', code, true);
  }
  if (businessCode === 1007900056) {
    return createInfo('接收数据中断，请重试', code, true);
  }
  if (businessCode === 1007900089) {
    return createInfo('网络连接数已达上限，请稍后重试', code, true);
  }
  if (businessCode === 1007900992) {
    return createInfo('请求已停止', code, false);
  }
  if (businessCode === 1007900993) {
    return createInfo('网络会话已关闭，请重试', code, true);
  }
  if (businessCode === 1007900201) {
    return createInfo('系统禁止明文 HTTP 传输，请把接口地址改成 https:// 开头', code, false);
  }
  if (businessCode === 1007900994) {
    return createInfo('网络会话数量已达上限，请重启应用后再试', code, true);
  }
  if (businessCode === 1007900001) {
    return createInfo('接口协议不受支持，请检查接口地址', code, false);
  }
  if (businessCode === 1007900003) {
    return createInfo('接口地址格式不正确，请检查设置里的接口地址', code, false);
  }
  if (businessCode === 1007900991) {
    return createInfo('服务端响应格式异常，请稍后重试', code, true);
  }
  const detail: string = rawMessage === undefined ? '' : rawMessage.trim();
  if (detail.length > 0) {
    return createInfo(`网络请求失败（${detail}）`, code, true);
  }
  return createInfo('网络请求失败，请检查网络后重试', code, true);
}

/** HTTP 状态码 → 中文。 */
export function mapHttpStatus(status: number, body: string): NetErrorInfo {
  const code: string = `http_${status}`;
  if (status === 400) {
    return createInfo('请求参数不被接受，请检查模型设置或先整理对话记忆', code, false);
  }
  if (status === 401) {
    return createInfo('密钥无效或未填写，请到设置里重新保存密钥', code, false);
  }
  if (status === 402) {
    return createInfo('账户余额不足，请充值后再试', code, false);
  }
  if (status === 403) {
    return createInfo('没有访问权限，请检查密钥权限或地区限制', code, false);
  }
  if (status === 404) {
    return createInfo('接口地址不存在，请检查设置里的接口地址', code, false);
  }
  if (status === 408) {
    return createInfo('请求超时，请重试', code, true);
  }
  if (status === 413) {
    return createInfo('发送内容太长，请先整理对话记忆再试', code, false);
  }
  if (status === 422) {
    return createInfo('服务端无法处理这次请求，请检查内容后重试', code, false);
  }
  if (status === 429) {
    return createInfo('请求太频繁，请稍等片刻再试', code, true);
  }
  if (status === 500 || status === 502 || status === 503 || status === 504 || status === 529) {
    return createInfo('服务端暂时不可用，请稍后重试', code, true);
  }
  const detail: string = body === undefined ? '' : body.trim();
  if (detail.length > 0 && detail.length <= 120) {
    return createInfo(`请求失败（HTTP ${status}）：${detail}`, code, status >= 500);
  }
  return createInfo(`请求失败（HTTP ${status}）`, code, status >= 500);
}

/** 任意被抛出的异常 → 中文（catch 里只能拿到 Object）。 */
export function mapThrownError(rawMessage: string): NetErrorInfo {
  const text: string = rawMessage === undefined || rawMessage === null ? '' : rawMessage.trim();
  if (text.length === 0) {
    return createInfo('网络请求失败，请检查网络后重试', 'unknown', true);
  }
  // rcp 抛出的 BusinessError 常带 `rcp error 1007900007: ...` 形式，尝试提取数字码。
  const marker: number = text.indexOf('1007900');
  if (marker >= 0) {
    const candidate: string = text.substring(marker, marker + 11);
    const parsed: number = Number.parseInt(candidate, 10);
    if (!Number.isNaN(parsed)) {
      return mapRcpError(parsed, text);
    }
  }
  return createInfo('网络请求失败，请检查网络后重试', 'unknown', true);
}
