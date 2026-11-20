/**
 * 单轮对话的累加器与结果类型（纯数据，不依赖平台与门面）。
 *
 * 流式事件先写进 `RoundAccumulator`，在 onDone / onError / stop 三者任一到达时
 * 转成只读的 `RoundResult`，供落盘、工具循环与快照更新使用。
 */
import { VendorRaw } from '@app/core_model';
import { UsageInfo } from '@app/core_protocol';

/** 单个工具调用的累加器（tool_call 的 delta / end 事件合并到同一条）。 */
export class ToolCallAcc {
  callId: string = '';
  itemId: string = '';
  toolName: string = '';
  argumentsJson: string = '';
  ended: boolean = false;
}

/** 一次联网检索块的累加器（added / 进度 / done 事件合并到同一条）。 */
export class WebCallAcc {
  itemId: string = '';
  status: string = '';
  vendorRaw: VendorRaw | null = null;
}

/** 一轮协议请求的累计结果（只读，结束后的稳定形态）。 */
export interface RoundResult {
  text: string;
  reasoning: string;
  toolCalls: ToolCallAcc[];
  webCalls: WebCallAcc[];
  usage: UsageInfo | null;
  title: string;
  errorMessage: string;
  errorCode: string;
  retriable: boolean;
  stopped: boolean;
}

/** 流式过程中的可变累加器（结束后 toResult 转只读）。 */
export class RoundAccumulator {
  text: string = '';
  reasoning: string = '';
  toolCalls: ToolCallAcc[] = [];
  webCalls: WebCallAcc[] = [];
  usage: UsageInfo | null = null;
  title: string = '';
  errorMessage: string = '';
  errorCode: string = '';
  retriable: boolean = false;
  stopped: boolean = false;
  settled: boolean = false;

  /** 转成只读结果（数组引用复用，避免逐帧拷贝大对象）。 */
  toResult(): RoundResult {
    const result: RoundResult = {
      text: this.text,
      reasoning: this.reasoning,
      toolCalls: this.toolCalls,
      webCalls: this.webCalls,
      usage: this.usage,
      title: this.title,
      errorMessage: this.errorMessage,
      errorCode: this.errorCode,
      retriable: this.retriable,
      stopped: this.stopped
    };
    return result;
  }
}
