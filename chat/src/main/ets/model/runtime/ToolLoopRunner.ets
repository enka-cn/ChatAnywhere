/**
 * 工具循环（本轮最多 4 轮，轮次上限由 StreamTurnExecutor 控制）：
 * 对每个 tool_call 调 `plugin.kernel.executeTool`，把结果落盘成 tool_result 节点。
 *
 * 插件模块初始化失败（AppServices 已降级）时：每个技能调用都返回可读中文错误，
 * 绝不让工具失败打断整轮对话。
 */
import { CanonicalItem, SourceRef, newItemId } from '@app/core_model';
import { ToolExecutionResult } from '@app/core_plugin';
import { RuntimeHost } from './RuntimeTypes';
import { RoundResult } from './RoundTypes';
import { SearchTraceStore } from './SearchTraceStore';
import { buildToolNode } from './NodeFactory';
import { toolKey } from './RuntimeUtils';

export class ToolLoopRunner {
  private host: RuntimeHost;
  private trace: SearchTraceStore;

  constructor(host: RuntimeHost, trace: SearchTraceStore) {
    this.host = host;
    this.trace = trace;
  }

  /** 执行本轮所有工具调用，落盘 tool_result 节点，返回其节点 id（无调用返回 null）。 */
  async execute(result: RoundResult, parentNodeId: string): Promise<string | null> {
    const services = this.host.appServices();
    const items: CanonicalItem[] = [];
    for (const call of result.toolCalls) {
      const callId: string = toolKey(call);
      const name: string = call.toolName.length > 0 ? call.toolName : '未知技能';
      const args: string = call.argumentsJson.length > 0 ? call.argumentsJson : '{}';
      this.trace.upsert(`tool_${callId}`, 'tool', `正在执行技能「${name}」`, args.length > 80
        ? `${args.substring(0, 80)}…` : args, 'running');
      this.host.notifyNow();
      let content: string = '';
      let isError: boolean = false;
      let sources: SourceRef[] = [];
      if (!services.hasPlugin()) {
        content = '技能模块暂时不可用，这次没法执行这个技能。';
        isError = true;
      } else {
        try {
          const executed: ToolExecutionResult = await services.requirePlugin().kernel.executeTool(name, args);
          content = executed.ok ? executed.content : (executed.error !== undefined ? executed.error : executed.content);
          if (content.length === 0) {
            content = executed.ok ? '（技能没有返回内容）' : '（技能执行失败，没有错误详情）';
          }
          isError = !executed.ok;
          if (executed.sources !== undefined) {
            sources = executed.sources;
          }
        } catch (e) {
          content = `技能执行失败：${(e as Error).message}`;
          isError = true;
        }
      }
      this.trace.upsert(`tool_${callId}`, 'tool',
        isError ? `技能「${name}」没有成功` : `技能「${name}」已返回结果`,
        isError ? content.substring(0, 80) : '', isError ? 'failed' : 'done');
      for (const one of sources) {
        this.trace.addSource(one);
      }
      const item: CanonicalItem = {
        id: newItemId(),
        kind: 'tool_result',
        callId: callId,
        toolName: name,
        text: content,
        isError: isError,
        createdAt: Date.now()
      };
      items.push(item);
    }
    if (items.length === 0) {
      return null;
    }
    const node = buildToolNode(this.host.sessionId(), parentNodeId, items);
    await this.host.appendNode(node);
    return node.nodeId;
  }
}
