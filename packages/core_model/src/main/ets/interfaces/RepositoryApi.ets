/**
 * 数据层契约：会话 / 节点轨迹 / FTS5 检索 / 技能与快照 / 设置。
 *
 * 所有写操作必须"先落盘再返回"，UI 不得依赖内存态。
 * 实现方：core_model/RdbRepository.ets（SQLite + FTS5）。
 */
import { ConversationNode, NodeBrief, SessionMeta } from './ModelTypes';

/** 会话级操作。 */
export interface SessionRepositoryApi {
  createSession(title: string, modelId: string, providerId: string): Promise<SessionMeta>;

  listSessions(limit?: number): Promise<SessionMeta[]>;

  getSession(sessionId: string): Promise<SessionMeta | null>;

  renameSession(sessionId: string, title: string): Promise<void>;

  deleteSession(sessionId: string): Promise<void>;

  /** 更新 updatedAt 并可选刷新累计 token。 */
  touchSession(sessionId: string, totalTokens?: number): Promise<void>;
}

/** 节点轨迹的原子存取（append-only）。 */
export interface NodeRepositoryApi {
  /** 追加一个节点。nodeId 已存在时视为更新（用于流式完成后的最终化）。 */
  saveNode(node: ConversationNode): Promise<void>;

  loadNode(nodeId: string): Promise<ConversationNode | null>;

  /** 会话全部节点（含 archived），按 createdAt 升序。 */
  loadSessionNodes(sessionId: string): Promise<ConversationNode[]>;

  /** 读取某节点下的子节点（分支菜单）。 */
  loadChildren(sessionId: string, parentId: string | null): Promise<NodeBrief[]>;

  /** 记录 parent 的激活子节点（分支切换）。 */
  setActiveChild(sessionId: string, parentId: string | null, childId: string): Promise<void>;

  /** 归档（压缩后保留原文）。 */
  archiveNodes(nodeIds: string[]): Promise<void>;

  /** 仅在入库前裁剪大载荷标记。 */
  markPayloadPruned(nodeId: string): Promise<void>;

  /** 会话的活动叶子节点（沿 activeChildId 走到末端）。 */
  getActiveLeafId(sessionId: string): Promise<string | null>;
}

/** FTS5 全文检索命中。 */
export interface SearchHit {
  nodeId: string;
  sessionId: string;
  /** 命中片段（高亮标记由 UI 处理）。 */
  snippet: string;
  /** BM25 相关度，越大越相关。 */
  score: number;
  createdAt: number;
}

/** 历史原文检索（FTS5 + LIKE 兜底）。 */
export interface SearchApi {
  search(query: string, limit?: number, sessionId?: string): Promise<SearchHit[]>;
  /** 重建索引（导入后调用）。 */
  reindexSession(sessionId: string): Promise<void>;
}

/** 落盘的技能记录（manifest 以 JSON 字符串保存，避免 core_model 反向依赖 core_plugin）。 */
export interface SkillRecord {
  skillId: string;
  version: string;
  enabled: boolean;
  manifestJson: string;
  updatedAt: number;
}

/** 技能版本快照（回滚使用）。 */
export interface SkillSnapshot {
  skillId: string;
  version: string;
  manifestJson: string;
  savedAt: number;
}

/** 技能持久化（含版本快照，强制"落盘 + 可回滚"）。 */
export interface SkillRepositoryApi {
  saveSkill(record: SkillRecord): Promise<void>;
  loadSkills(): Promise<SkillRecord[]>;
  loadSkill(skillId: string): Promise<SkillRecord | null>;
  removeSkill(skillId: string): Promise<void>;

  saveSkillSnapshot(snapshot: SkillSnapshot): Promise<void>;
  listSkillSnapshots(skillId: string): Promise<SkillSnapshot[]>;
  /** 取与该技能当前版本不同的最近一个快照（回滚目标）。 */
  loadPreviousSnapshot(skillId: string): Promise<SkillSnapshot | null>;
  clearSkillSnapshots(skillId: string): Promise<void>;
}

/** 非敏感配置（Preferences 后端）；密钥禁止走这里。 */
export interface SettingsApi {
  getString(key: string, defaultValue: string): Promise<string>;
  putString(key: string, value: string): Promise<void>;
  getNumber(key: string, defaultValue: number): Promise<number>;
  putNumber(key: string, value: number): Promise<void>;
  getBool(key: string, defaultValue: boolean): Promise<boolean>;
  putBool(key: string, value: boolean): Promise<void>;
  remove(key: string): Promise<void>;
}

/** RDB 汇总能力（实现类同时具备上述接口）。 */
export interface RdbRepositoryApi extends SessionRepositoryApi, NodeRepositoryApi, SearchApi,
  SkillRepositoryApi, SettingsApi {
  /** 最近一次打开数据库失败的原因（用于设置页诊断，空串表示正常）。 */
  readonly lastError: string;
  /** 关闭数据库（页面退出/测试用）。 */
  close(): Promise<void>;
}
