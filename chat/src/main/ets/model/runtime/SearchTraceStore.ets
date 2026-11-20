/**
 * 本轮「检索与清洗过程」时间轴 + 引用来源的持有者。
 *
 * 时间轴按 id 合并（同一条检索只出现一条记录），来源按 url 去重后最多 12 条。
 * 检索事件（web_search_status）在这里解析成累加器状态并同步时间轴，
 * 使 StreamTurnExecutor 的流式事件处理保持轻薄。
 */
import { SourceRef, VendorRaw } from '@app/core_model';
import { StreamPayload } from '@app/core_protocol';
import { SearchTraceStep } from '../ChatRuntimeApi';
import { RoundAccumulator, WebCallAcc } from './RoundTypes';
import { mergeVendorRaw, parseSourcesJson, readVendorRaw } from './RuntimeUtils';

/** 引用来源最多展示条数。 */
const MAX_SOURCES: number = 12;

export class SearchTraceStore {
  /** 本轮时间轴（就地更新，外部只拿拷贝）。 */
  private trace: SearchTraceStep[] = [];
  /** 本轮累计来源（独立清洗 + 工具结果 + 协议联网事件）。 */
  private sources: SourceRef[] = [];

  /** 开新的一轮 / 切换会话时清空。 */
  reset(): void {
    this.trace = [];
    this.sources = [];
  }

  /** 时间轴的深拷贝（快照外发用）。 */
  copy(): SearchTraceStep[] {
    const out: SearchTraceStep[] = [];
    for (const step of this.trace) {
      const copy: SearchTraceStep = {
        id: step.id,
        kind: step.kind,
        title: step.title,
        detail: step.detail,
        status: step.status,
        at: step.at
      };
      out.push(copy);
    }
    return out;
  }

  /** 追加一条本轮来源（独立清洗 / 工具结果用）。 */
  addSource(one: SourceRef): void {
    this.sources.push(one);
  }

  /** 写入 / 更新一条时间轴（同 id 就地更新）。 */
  upsert(id: string, kind: string, title: string, detail: string, status: string): void {
    for (const step of this.trace) {
      if (step.id === id) {
        step.kind = kind;
        step.title = title;
        step.detail = detail;
        step.status = status;
        step.at = Date.now();
        return;
      }
    }
    const step: SearchTraceStep = {
      id: id,
      kind: kind,
      title: title,
      detail: detail,
      status: status,
      at: Date.now()
    };
    this.trace.push(step);
  }

  /** 汇总本轮来源（去重，最多 MAX_SOURCES 条）。 */
  collect(webCalls: WebCallAcc[]): SourceRef[] {
    const out: SourceRef[] = [];
    const seen: Set<string> = new Set<string>();
    const push = (one: SourceRef): void => {
      if (one.url.length === 0 || seen.has(one.url) || out.length >= MAX_SOURCES) {
        return;
      }
      seen.add(one.url);
      out.push(one);
    };
    for (const one of this.sources) {
      push(one);
    }
    for (const call of webCalls) {
      if (call.vendorRaw !== null && call.vendorRaw.sources !== undefined) {
        for (const one of call.vendorRaw.sources) {
          push(one);
        }
      }
    }
    return out;
  }

  /**
   * 消费一条 web_search_status 事件：合并到同一 itemId 的累加器，
   * 并把直白中文的进度写进时间轴（正在检索 / 完成 / 失败 / 未完成）。
   */
  applyWebStatus(acc: RoundAccumulator, payload: StreamPayload): void {
    const status: string = payload.searchStatus === undefined ? '' : payload.searchStatus;
    const itemId: string = payload.itemId === undefined ? '' : payload.itemId;
    const rawJson: string = payload.vendorRawJson === undefined ? '' : payload.vendorRawJson;
    const sourcesJson: string = payload.sourcesJson === undefined ? '' : payload.sourcesJson;
    let call: WebCallAcc | null = null;
    for (const one of acc.webCalls) {
      if (itemId.length > 0 && one.itemId === itemId) {
        call = one;
        break;
      }
    }
    if (call === null) {
      call = new WebCallAcc();
      call.itemId = itemId;
      acc.webCalls.push(call);
    }
    if (status.length > 0) {
      call.status = status;
    }
    if (rawJson.length > 0) {
      const parsed: VendorRaw | null = readVendorRaw(rawJson);
      if (parsed !== null) {
        call.vendorRaw = mergeVendorRaw(call.vendorRaw, parsed);
        if (parsed.status !== undefined && parsed.status.length > 0) {
          call.status = parsed.status;
        }
      }
    }
    if (sourcesJson.length > 0) {
      const sources: SourceRef[] = parseSourcesJson(sourcesJson);
      if (sources.length > 0) {
        if (call.vendorRaw === null) {
          const raw: VendorRaw = { provider: 'deepseek', sources: sources };
          call.vendorRaw = raw;
        } else {
          call.vendorRaw.sources = sources;
        }
      }
    }
    // 时间轴：同一条检索按 itemId 合并，避免一条搜索出现三条记录。
    const traceId: string = itemId.length > 0 ? itemId : `web_${acc.webCalls.length}`;
    const sourceCount: number = call.vendorRaw !== null && call.vendorRaw.sources !== undefined
      ? call.vendorRaw.sources.length : 0;
    const statusText: string = payload.text === undefined ? '' : payload.text;
    let title: string = '正在联网检索';
    let stepStatus: string = 'running';
    let detail: string = '';
    if (call.status === 'completed') {
      title = '联网检索完成';
      stepStatus = 'done';
      detail = sourceCount > 0 ? `找到 ${sourceCount} 条资料` : '没有找到可用资料';
    } else if (call.status === 'failed') {
      title = '联网检索失败';
      stepStatus = 'failed';
    } else if (call.status === 'incomplete') {
      title = '联网检索未完成';
      stepStatus = 'failed';
    } else if (call.status === 'searching') {
      title = '正在联网搜索';
    } else if (statusText.length > 0) {
      title = statusText;
    }
    this.upsert(traceId, 'search', title, detail, stepStatus);
  }
}
