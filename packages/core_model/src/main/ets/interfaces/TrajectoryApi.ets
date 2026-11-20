/**
 * 轨迹树契约（只增不改 + 分支切换）。
 */
import { ConversationNode, NodeBrief } from './ModelTypes';

export interface TrajectoryApi {
  /** 追加节点（内存索引 + RDB 落盘）。 */
  append(node: ConversationNode): Promise<void>;

  getNode(nodeId: string): Promise<ConversationNode | null>;

  /** 根到活动叶子的节点链（发给模型的上下文）。 */
  activePath(sessionId: string): Promise<ConversationNode[]>;

  getActiveLeafId(sessionId: string): Promise<string | null>;

  /** 某节点的分支概要。 */
  children(sessionId: string, parentId: string | null): Promise<NodeBrief[]>;

  /** 切换某 parent 的激活子节点。 */
  switchBranch(sessionId: string, parentId: string | null, childId: string): Promise<void>;

  /** 在历史节点上 fork 出新分支（编辑/重试）。返回新节点 id。 */
  forkFrom(sourceNodeId: string, newRole: string, text: string): Promise<string>;

  /** 压缩后归档。 */
  archive(nodeIds: string[]): Promise<void>;

  /** 会话已加载节点（内存缓存命中则直接返回）。 */
  sessionNodes(sessionId: string): Promise<ConversationNode[]>;
}
