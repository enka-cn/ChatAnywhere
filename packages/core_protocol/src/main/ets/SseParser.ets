/**
 * SSE（Server-Sent Events）增量解析器：只负责"字节流 → 帧"，与厂商语义无关。
 *
 * 纯逻辑、零平台 import（可由 QA 在 Node 端直接跑）。
 *
 * 支持：
 * - 增量输入：任意分片（可能是半个 UTF-8 字符由上游 TextDecoder 处理、半个行、半个帧）；
 * - 行结束符：`\n`、`\r\n`、以及单独 `\r`（若 `\r` 位于分片末尾则等待下一片，避免把 CRLF 拆成两行）；
 * - 字段：`event:` / `data:`（多行 data 用 `\n` 拼接）/ `id:` / `retry:`；
 * - 以 `:` 开头的注释行（如 `: keep-alive`）与未知字段一律忽略；
 * - 空行闭合当前帧；`flush()` 冲出流结束前的残留帧；`reset()` 清空全部状态。
 *
 * 注意：DeepSeek Responses API 没有 `data: [DONE]` 终止帧，终止由 `response.completed` 等事件表达。
 */
import { SseFrame, SseParserApi } from './interfaces/ProviderAdapter';

export class SseParser implements SseParserApi {
  /** 尚未构成完整行的残留文本。 */
  private buffer: string = '';
  /** 当前帧的 `event:` 值。 */
  private eventName: string = '';
  /** 当前帧的 `data:` 行（多行按出现顺序保存）。 */
  private dataLines: string[] = [];
  /** 最近一次 `id:`（按 SSE 规范跨帧粘滞）。 */
  private lastId: string = '';
  /** 最近一次 `retry:`（毫秒，-1 表示未设置）。 */
  private retryMs: number = -1;

  /**
   * 输入任意文本分片，返回本次输入中已闭合的帧。
   * @param chunk 已解码的文本分片（空串/undefined 安全返回空数组）。
   */
  feed(chunk: string): SseFrame[] {
    const out: SseFrame[] = [];
    if (chunk === undefined || chunk === null || chunk.length === 0) {
      return out;
    }
    this.buffer = this.buffer + chunk;
    let line: string | null = this.takeLine();
    while (line !== null) {
      this.consumeLine(line, out);
      line = this.takeLine();
    }
    return out;
  }

  /** 流结束时调用：把残留的半行当作完整行处理，并冲出未闭合的帧。 */
  flush(): SseFrame[] {
    const out: SseFrame[] = [];
    if (this.buffer.length > 0) {
      let rest: string = this.buffer;
      this.buffer = '';
      if (rest.charAt(rest.length - 1) === '\r') {
        rest = rest.substring(0, rest.length - 1);
      }
      if (rest.length > 0) {
        this.consumeLine(rest, out);
      }
    }
    this.dispatch(out);
    return out;
  }

  /** 清空全部状态（新一次请求复用一个解析器实例时调用）。 */
  reset(): void {
    this.buffer = '';
    this.eventName = '';
    this.dataLines = [];
    this.lastId = '';
    this.retryMs = -1;
  }

  /** 从缓冲区头部取出一整行；不足一行返回 null。 */
  private takeLine(): string | null {
    const lf: number = this.buffer.indexOf('\n');
    if (lf >= 0) {
      let line: string = this.buffer.substring(0, lf);
      if (line.length > 0 && line.charAt(line.length - 1) === '\r') {
        line = line.substring(0, line.length - 1);
      }
      this.buffer = this.buffer.substring(lf + 1);
      return line;
    }
    // 没有 \n：仅在 \r 后面确实还有字符时才按"单独的 CR"切行；
    // 若 \r 正好在分片末尾，则等待下一片（可能是被拆开的 CRLF）。
    const cr: number = this.buffer.indexOf('\r');
    if (cr >= 0 && cr + 1 < this.buffer.length) {
      const line: string = this.buffer.substring(0, cr);
      this.buffer = this.buffer.substring(cr + 1);
      return line;
    }
    return null;
  }

  /** 处理一行 SSE 文本。 */
  private consumeLine(line: string, out: SseFrame[]): void {
    if (line.length === 0) {
      this.dispatch(out);
      return;
    }
    if (line.charAt(0) === ':') {
      // 注释行（keep-alive 心跳），忽略。
      return;
    }
    const colon: number = line.indexOf(':');
    const field: string = colon < 0 ? line : line.substring(0, colon);
    let value: string = colon < 0 ? '' : line.substring(colon + 1);
    if (value.length > 0 && value.charAt(0) === ' ') {
      value = value.substring(1);
    }
    if (field === 'event') {
      this.eventName = value;
    } else if (field === 'data') {
      this.dataLines.push(value);
    } else if (field === 'id') {
      if (value.indexOf('\u0000') < 0) {
        this.lastId = value;
      }
    } else if (field === 'retry') {
      const parsed: number = Number.parseInt(value, 10);
      if (!Number.isNaN(parsed) && parsed >= 0) {
        this.retryMs = parsed;
      }
    }
    // 其他字段按规范忽略。
  }

  /** 用当前累积的字段产出一个帧（无 event 且无 data 时不产出）。 */
  private dispatch(out: SseFrame[]): void {
    const data: string = this.dataLines.join('\n');
    const eventName: string = this.eventName;
    this.eventName = '';
    this.dataLines = [];
    if (data.length === 0 && eventName.length === 0) {
      return;
    }
    const frame: SseFrame = { event: eventName, data: data };
    if (this.lastId.length > 0) {
      frame.id = this.lastId;
    }
    if (this.retryMs >= 0) {
      frame.retry = this.retryMs;
    }
    out.push(frame);
  }
}
