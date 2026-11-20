/**
 * 消息列表数据源（供 LazyForEach 使用）。
 *
 * 为什么需要：主对话可能很长，ForEach 会把全部消息一次性挂到组件树上；
 * LazyForEach 只构建可视区域（配合 List.cachedCount），历史再长首屏也不变慢。
 *
 * 变更通知尽量精确：
 * - 追加一条（正常发消息）→ onDataAdd(index)，不动已有节点；
 * - 同位置内容变化（重新生成占位节点被填充）→ onDataChange(index)；
 * - 结构变化（分支切换 / 换会话 / 压缩）→ onDataReloaded()。
 */
import { ConversationNode } from '@app/core_model';

/** 节点内容签名：id + item 数 + 文本总长（足以区分流式填充与分支切换）。 */
function nodeSignature(node: ConversationNode): string {
  let textLength: number = 0;
  for (const item of node.items) {
    if (item.text !== undefined) {
      textLength += item.text.length;
    }
  }
  return `${node.nodeId}|${node.items.length}|${textLength}`;
}

/** List + LazyForEach 的消息数据源。 */
export class MessageDataSource implements IDataSource {
  private nodes: ConversationNode[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.nodes.length;
  }

  getData(index: number): ConversationNode {
    return this.nodes[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 用最新的节点数组刷新数据源，并按差异发通知。 */
  update(next: ConversationNode[]): void {
    const prev: ConversationNode[] = this.nodes;
    let reload: boolean = false;
    let append: boolean = false;
    const changed: number[] = [];

    if (next.length === prev.length) {
      for (let i = 0; i < next.length; i++) {
        if (next[i].nodeId !== prev[i].nodeId) {
          reload = true;
          break;
        }
        if (nodeSignature(next[i]) !== nodeSignature(prev[i])) {
          changed.push(i);
        }
      }
    } else if (next.length > prev.length) {
      append = true;
      for (let i = 0; i < prev.length; i++) {
        if (next[i].nodeId !== prev[i].nodeId) {
          append = false;
          reload = true;
          break;
        }
      }
    } else {
      reload = true;
    }

    this.nodes = next;

    if (reload) {
      for (const listener of this.listeners) {
        listener.onDataReloaded();
      }
      return;
    }
    if (append) {
      for (let i = prev.length; i < next.length; i++) {
        for (const listener of this.listeners) {
          listener.onDataAdd(i);
        }
      }
      return;
    }
    for (const index of changed) {
      for (const listener of this.listeners) {
        listener.onDataChange(index);
      }
    }
  }
}
