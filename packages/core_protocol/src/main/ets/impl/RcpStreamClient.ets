/**
 * 基于 HarmonyOS Remote Communication Kit（rcp）的流式 HTTP 客户端。
 *
 * 平台强绑定实现（不做 Node 逻辑测试，靠编译期类型检查 + 真机联调）。
 * 本文件所有 API 均已对照本地 SDK 声明核实：
 * `C:\Application\DevEco Studio\sdk\default\hms\ets\api\@hms.collaboration.rcp.d.ts`
 *
 * 关键事实（见 docs/API_REFERENCE.md §5）：
 * - 流式回调挂在 `Configuration.tracing.httpEventsHandler`，**不是** Request 顶层字段；
 * - `transfer.timeout.transferMs` 默认仅 60000ms，长回答会被腰斩 → 流式放大到 1800000ms，
 *   并设 `inactivityMs=300000`（5 分钟没有数据才判定卡死）；
 * - 一旦使用 `onDataReceive`，`response.body` 不再带数据 → 只用 `statusCode` 判断成败；
 * - Session 上限 1024，用完必须 `close()`；
 * - 明文 HTTP 会被系统拒绝（1007900201）→ 接口地址必须是 https。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { HttpRequestSpec } from '../interfaces/ProtocolTypes';
import { NetErrorInfo, mapHttpStatus, mapRcpError, mapThrownError } from '../util/ErrorText';

/** 流式回调（数据用回调推送，Promise 只表示生命周期）。 */
export interface RcpStreamSink {
  /** 收到一段已解码的 UTF-8 文本（可能半行/半个帧）。 */
  onText: (text: string) => void;
  /** 服务端正常结束。 */
  onEnd: () => void;
  /** 失败（网络/HTTP 状态码/超时），message 已中文化。 */
  onError: (message: string, errorCode: string, retriable: boolean) => void;
  /** 用户主动取消。 */
  onCancel: () => void;
}

/** 一次非流式请求的结果。 */
export interface RcpSimpleResponse {
  statusCode: number;
  body: string;
  latencyMs: number;
}

/** 可取消的流句柄。 */
export interface RcpStreamConn {
  cancel(): void;
  /** 流结束后 resolve（不会 reject）。 */
  readonly finished: Promise<void>;
}

const CONNECT_TIMEOUT_MS: number = 20000;
/** 流式传输窗口：30 分钟（默认 60s 会把长回答截断）。 */
const STREAM_TRANSFER_MS: number = 1800000;
/** 无数据判定卡死的窗口：5 分钟。 */
const STREAM_INACTIVITY_MS: number = 300000;
/** 非流式请求的传输窗口：60 秒。 */
const ONCE_TRANSFER_MS: number = 60000;

export class RcpStreamClient {
  /**
   * 发起一次流式请求（SSE）。
   * @param spec Adapter 产出的请求描述（headers 不含密钥，密钥由 ProtocolLayer 注入）
   * @param sink 数据回调
   */
  start(spec: HttpRequestSpec, sink: RcpStreamSink): RcpStreamConn {
    const conn: RcpStreamConnection = new RcpStreamConnection(sink, spec.timeoutMs);
    conn.begin(spec);
    return conn;
  }

  /**
   * 发起一次非流式请求（连接测试 / 模型列表）。
   * 失败时抛中文 Error（调用方转成可读诊断）。
   */
  async fetchOnce(spec: HttpRequestSpec): Promise<RcpSimpleResponse> {
    let session: rcp.Session | null = null;
    const startAt: number = Date.now();
    try {
      const timeout: rcp.Timeout = {
        connectMs: CONNECT_TIMEOUT_MS,
        transferMs: spec.timeoutMs > 0 ? spec.timeoutMs : ONCE_TRANSFER_MS,
        inactivityMs: spec.timeoutMs > 0 ? spec.timeoutMs : ONCE_TRANSFER_MS
      };
      const transfer: rcp.TransferConfiguration = { autoRedirect: true, timeout: timeout };
      const configuration: rcp.Configuration = { transfer: transfer };
      const sessionConfig: rcp.SessionConfiguration = { requestConfiguration: configuration };
      session = rcp.createSession(sessionConfig);
      const headers: rcp.RequestHeaders = RcpStreamClient.toRcpHeaders(spec.headers);
      const method: rcp.HttpMethod = RcpStreamClient.toRcpMethod(spec.method);
      let request: rcp.Request;
      if (spec.bodyJson !== undefined && spec.bodyJson.length > 0) {
        request = new rcp.Request(spec.url, method, headers, spec.bodyJson);
      } else {
        request = new rcp.Request(spec.url, method, headers);
      }
      const response: rcp.Response = await session.fetch(request);
      let body: string = '';
      if (response.body !== undefined) {
        body = RcpStreamClient.decodeAll(response.body);
      }
      const result: RcpSimpleResponse = {
        statusCode: response.statusCode,
        body: body,
        latencyMs: Date.now() - startAt
      };
      return result;
    } catch (e) {
      const err: Object = e as Object;
      const info: NetErrorInfo = RcpStreamClient.errorInfoOf(err);
      throw new Error(info.message);
    } finally {
      if (session !== null) {
        try {
          session.close();
        } catch (e2) {
          // 关闭失败不影响结果
        }
      }
    }
  }

  // ------------------------------------------------------------- 小工具

  /** headers( Map ) → rcp.RequestHeaders（ArkTS 禁止 Record 字面量，走 JSON 中转）。 */
  static toRcpHeaders(headers: Map<string, string>): rcp.RequestHeaders {
    const rec: Record<string, string> = JSON.parse('{}') as Record<string, string>;
    headers.forEach((value: string, key: string) => {
      rec[key] = value;
    });
    return JSON.parse(JSON.stringify(rec)) as rcp.RequestHeaders;
  }

  /** 字符串方法 → rcp.HttpMethod 字面量（避免泛 string 赋值报错）。 */
  static toRcpMethod(method: string): rcp.HttpMethod {
    if (method === 'GET') {
      return 'GET';
    }
    if (method === 'PUT') {
      return 'PUT';
    }
    if (method === 'DELETE') {
      return 'DELETE';
    }
    if (method === 'PATCH') {
      return 'PATCH';
    }
    if (method === 'HEAD') {
      return 'HEAD';
    }
    return 'POST';
  }

  /** 一次性解码整个 ArrayBuffer。 */
  static decodeAll(buffer: ArrayBuffer): string {
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const options: util.DecodeToStringOptions = { stream: false };
      return decoder.decodeToString(new Uint8Array(buffer), options);
    } catch (e) {
      return '';
    }
  }

  /** 任意异常 → 中文错误信息。 */
  static errorInfoOf(err: Object): NetErrorInfo {
    const be: BusinessError = err as BusinessError;
    const code: number = be.code === undefined || be.code === null ? -1 : be.code;
    if (code > 0) {
      const rawMessage: string = be.message === undefined ? '' : be.message;
      return mapRcpError(code, rawMessage);
    }
    const plain: Error = err as Error;
    const message: string = plain.message === undefined ? '' : plain.message;
    return mapThrownError(message);
  }
}

/** 单次流式连接的生命周期管理。 */
class RcpStreamConnection implements RcpStreamConn {
  readonly finished: Promise<void>;
  private readonly sink: RcpStreamSink;
  private readonly timeoutMs: number;
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private resolveFinish: () => void = () => {
  };
  private session: rcp.Session | null = null;
  private request: rcp.Request | null = null;
  private statusCode: number = 0;
  private errorBody: string = '';
  private contentType: string = '';
  private finishedOnce: boolean = false;
  private timerId: number = -1;

  constructor(sink: RcpStreamSink, timeoutMs: number) {
    this.sink = sink;
    this.timeoutMs = timeoutMs;
    this.finished = new Promise<void>((resolve) => {
      this.resolveFinish = () => {
        resolve();
      };
    });
  }

  /** 建立会话并发出请求。 */
  begin(spec: HttpRequestSpec): void {
    try {
      const configuration: rcp.Configuration = this.buildConfiguration();
      const sessionConfig: rcp.SessionConfiguration = { requestConfiguration: configuration };
      this.session = rcp.createSession(sessionConfig);
      const headers: rcp.RequestHeaders = RcpStreamClient.toRcpHeaders(spec.headers);
      const method: rcp.HttpMethod = RcpStreamClient.toRcpMethod(spec.method);
      let request: rcp.Request;
      if (spec.bodyJson !== undefined && spec.bodyJson.length > 0) {
        request = new rcp.Request(spec.url, method, headers, spec.bodyJson);
      } else {
        request = new rcp.Request(spec.url, method, headers);
      }
      this.request = request;
      this.armTimeout();
      const session: rcp.Session = this.session;
      session.fetch(request).then((response: rcp.Response) => {
        this.handleFetchResponse(response);
      }).catch((reason: Object) => {
        this.handleFetchFailure(reason);
      });
    } catch (e) {
      const err: Object = e as Object;
      this.fail(RcpStreamClient.errorInfoOf(err));
    }
  }

  cancel(): void {
    if (this.finishedOnce) {
      return;
    }
    try {
      if (this.session !== null) {
        this.session.cancel(this.request === null ? undefined : this.request);
      }
    } catch (e) {
      // 取消失败也要走完收尾流程
    }
    if (!this.finishedOnce) {
      this.sink.onCancel();
      this.complete();
    }
  }

  // ------------------------------------------------------------- 内部实现

  private buildConfiguration(): rcp.Configuration {
    const timeout: rcp.Timeout = {
      connectMs: CONNECT_TIMEOUT_MS,
      transferMs: STREAM_TRANSFER_MS,
      inactivityMs: STREAM_INACTIVITY_MS
    };
    const transfer: rcp.TransferConfiguration = { autoRedirect: true, timeout: timeout };
    const handler: rcp.HttpEventsHandler = {
      onDataReceive: (incomingData: ArrayBuffer): void => {
        this.handleData(incomingData);
      },
      onHeaderReceive: (headers: rcp.ResponseHeaders): void => {
        this.handleHeaders(headers);
      },
      onStatusCodeReceive: (statusCode: number): void => {
        this.handleStatus(statusCode);
      },
      onDataEnd: (): void => {
        this.handleDataEnd();
      },
      onCanceled: (): void => {
        this.handleCanceled();
      }
    };
    const tracing: rcp.TracingConfiguration = { collectTimeInfo: true, httpEventsHandler: handler };
    const configuration: rcp.Configuration = { transfer: transfer, tracing: tracing };
    return configuration;
  }

  private armTimeout(): void {
    if (this.timeoutMs <= 0) {
      return;
    }
    this.timerId = setTimeout(() => {
      this.handleTimeout();
    }, this.timeoutMs);
  }

  private clearTimer(): void {
    if (this.timerId >= 0) {
      try {
        clearTimeout(this.timerId);
      } catch (e) {
        // 忽略
      }
      this.timerId = -1;
    }
  }

  private handleTimeout(): void {
    if (this.finishedOnce) {
      return;
    }
    try {
      if (this.session !== null) {
        this.session.cancel(this.request === null ? undefined : this.request);
      }
    } catch (e) {
      // 忽略
    }
    const info: NetErrorInfo = new NetErrorInfo();
    info.message = '等待服务端响应超时，已自动停止，请重试';
    info.errorCode = 'timeout';
    info.retriable = true;
    this.fail(info);
  }

  private handleData(incomingData: ArrayBuffer): void {
    if (this.finishedOnce) {
      return;
    }
    let text: string = '';
    try {
      const options: util.DecodeToStringOptions = { stream: true };
      text = this.decoder.decodeToString(new Uint8Array(incomingData), options);
    } catch (e) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    // 已经拿到错误状态码：把后续字节当作错误说明收集起来，不再喂给 SSE 解析器。
    if (this.statusCode >= 400) {
      if (this.errorBody.length < 4000) {
        this.errorBody = this.errorBody + text;
      }
      return;
    }
    this.sink.onText(text);
  }

  private handleHeaders(headers: rcp.ResponseHeaders): void {
    const raw: string | string[] | undefined = headers['content-type'];
    if (typeof raw === 'string') {
      this.contentType = raw as string;
    } else if (Array.isArray(raw)) {
      const arr: string[] = raw as string[];
      this.contentType = arr.length > 0 ? arr[0] : '';
    }
  }

  private handleStatus(statusCode: number): void {
    if (statusCode > 0) {
      this.statusCode = statusCode;
    }
  }

  private handleDataEnd(): void {
    if (this.finishedOnce) {
      return;
    }
    if (this.statusCode >= 400) {
      this.fail(mapHttpStatus(this.statusCode, this.errorBody));
      return;
    }
    this.sink.onEnd();
    this.complete();
  }

  private handleCanceled(): void {
    if (this.finishedOnce) {
      return;
    }
    this.sink.onCancel();
    this.complete();
  }

  private handleFetchResponse(response: rcp.Response): void {
    if (this.finishedOnce) {
      return;
    }
    const code: number = response.statusCode;
    this.statusCode = code;
    if (code >= 400) {
      let body: string = this.errorBody;
      if (body.length === 0 && response.body !== undefined) {
        body = RcpStreamClient.decodeAll(response.body);
      }
      this.fail(mapHttpStatus(code, body));
      return;
    }
    // 200：数据仍在回调里流动（onDataReceive 时 response.body 为空），等待 onDataEnd。
  }

  private handleFetchFailure(reason: Object): void {
    if (this.finishedOnce) {
      return;
    }
    this.fail(RcpStreamClient.errorInfoOf(reason));
  }

  private fail(info: NetErrorInfo): void {
    if (this.finishedOnce) {
      return;
    }
    this.sink.onError(info.message, info.errorCode, info.retriable);
    this.complete();
  }

  /** 收尾：清定时器、释放 session、resolve finished（幂等）。 */
  private complete(): void {
    if (this.finishedOnce) {
      return;
    }
    this.finishedOnce = true;
    this.clearTimer();
    // 避免在 rcp 回调栈内同步关闭 session
    const session: rcp.Session | null = this.session;
    this.session = null;
    this.request = null;
    setTimeout(() => {
      if (session !== null) {
        try {
          session.close();
        } catch (e) {
          // 忽略
        }
      }
    }, 0);
    this.resolveFinish();
  }
}
