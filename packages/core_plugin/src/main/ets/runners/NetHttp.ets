/**
 * 插件层统一的 HTTP 客户端（基于 `@ohos.net.http`）。
 *
 * 每个请求独立创建 HttpRequest 并在结束时 destroy()，避免复用状态与内存泄漏；
 * 网络能力只由插件层内部使用，L1/L2 的访问边界由白名单在调用前强制校验。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { emptyRecord, truncateText } from '../util/JsonLite';

/** HTTP 结果（body 统一为字符串，错误为直白中文）。 */
export interface HttpOutcome {
  ok: boolean;
  status: number;
  body: string;
  headers: Map<string, string>;
  error: string;
}

/** 网络客户端（无状态，方法可并发调用）。 */
export class NetHttp {
  /** 字符串方法 → net.http 枚举。 */
  static toMethod(method: string): http.RequestMethod {
    const upper: string = method === null || method === undefined ? 'GET' : (method as string).toUpperCase();
    switch (upper) {
      case 'POST':
        return http.RequestMethod.POST;
      case 'PUT':
        return http.RequestMethod.PUT;
      case 'DELETE':
        return http.RequestMethod.DELETE;
      case 'PATCH':
        return http.RequestMethod.PATCH;
      case 'HEAD':
        return http.RequestMethod.HEAD;
      default:
        return http.RequestMethod.GET;
    }
  }

  /** 状态码 → 直白中文提示。 */
  static describeStatus(status: number): string {
    switch (status) {
      case 400:
        return '请求参数不合法（400）';
      case 401:
        return '密钥缺失或无效（401），请到「设置」检查';
      case 402:
        return '账户余额不足（402）';
      case 403:
        return '请求被拒绝（403）';
      case 404:
        return '找不到可用的网页内容（404）';
      case 408:
        return '请求超时（408），稍后重试即可';
      case 413:
        return '请求体过大（413）';
      case 429:
        return '请求太频繁（429），稍后重试即可';
      case 500:
        return '服务端错误（500），稍后重试即可';
      case 504:
        return '下游超时（504），稍后重试即可';
      default:
        return `请求失败（HTTP ${status}）`;
    }
  }

  /**
   * 发起一次 HTTP 请求。
   * @param url 完整地址（调用方已做白名单校验）
   * @param method GET/POST/...
   * @param headers 请求头
   * @param body 请求体（空串表示无请求体）
   * @param timeoutMs 连接与读取超时（毫秒）
   */
  static async request(url: string, method: string, headers: Map<string, string>,
    body: string, timeoutMs: number): Promise<HttpOutcome> {
    const request = http.createHttp();
    const headerRecord: Record<string, Object> = emptyRecord();
    headers.forEach((value: string, key: string) => {
      headerRecord[key] = value;
    });
    const options: http.HttpRequestOptions = {
      method: NetHttp.toMethod(method),
      header: headerRecord,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      usingCache: false
    };
    if (body !== null && body !== undefined && (body as string).length > 0) {
      options.extraData = body;
    }
    try {
      const response = await request.request(url, options);
      const raw: Object = response.result;
      let text: string = '';
      if (typeof raw === 'string') {
        text = raw as string;
      } else if (raw !== undefined && raw !== null) {
        try {
          text = JSON.stringify(raw);
        } catch (e) {
          text = '';
        }
      }
      const headersOut: Map<string, string> = new Map<string, string>();
      try {
        const headerJson: string = JSON.stringify(response.header);
        const headerRec = JSON.parse(headerJson) as Record<string, Object>;
        Object.keys(headerRec).forEach((key: string) => {
          const value: Object = headerRec[key];
          if (typeof value === 'string') {
            headersOut.set(key.toLowerCase(), value as string);
          } else if (value !== undefined && value !== null) {
            headersOut.set(key.toLowerCase(), `${value}`);
          }
        });
      } catch (e) {
        // 响应头解析失败不影响主体结果
      }
      const status: number = response.responseCode;
      const ok: boolean = status >= 200 && status < 300;
      return {
        ok,
        status,
        body: text,
        headers: headersOut,
        error: ok ? '' : `${NetHttp.describeStatus(status)}：${truncateText(text, 200)}`
      };
    } catch (e) {
      const err = e as BusinessError;
      const code: number = err === null || err === undefined ? 0 : err.code;
      const message: string = err === null || err === undefined ? '未知错误' : err.message;
      return {
        ok: false,
        status: 0,
        body: '',
        headers: new Map<string, string>(),
        error: `网络请求失败（${code}）：${message}`
      };
    } finally {
      request.destroy();
    }
  }
}
