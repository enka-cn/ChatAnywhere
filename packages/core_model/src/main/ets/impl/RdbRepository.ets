/**
 * RDB 数据仓库实现：SQLite 建表 + 会话/节点轨迹 + FTS5 检索（不可用时自动降级 LIKE）
 * + 技能与版本快照 + 非敏感设置（Preferences）。
 *
 * 设计红线（Blueprint §1 / DEV_GUIDE §5）：
 * - 所有写操作先落盘再返回；
 * - 历史只增不删：压缩只写 archived 标记，检索仍可回捞；
 * - FTS5 是否可用无法从 SDK 确认 → 建表/查询失败必须静默降级，绝不能让 App 启动崩溃；
 * - 密钥不经过这里（见 AssetSecretStore）。
 *
 * 平台 API 事实来源：`sdk/default/openharmony/ets/api/@ohos.data.relationalStore.d.ts`、
 * `@ohos.data.preferences.d.ts`（详见 docs/API_REFERENCE.md §6、§9.1）。
 */
import { Context } from '@kit.AbilityKit';
import { relationalStore, preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConversationNode, NodeBrief, SessionMeta } from '../interfaces/ModelTypes';
import {
  RdbRepositoryApi,
  SearchHit,
  SkillRecord,
  SkillSnapshot
} from '../interfaces/RepositoryApi';
import { ModelRegistryApi, ProviderModelRecord } from '../interfaces/ModelRegistryApi';
import {
  buildFtsQuery,
  likePattern,
  makeSnippet,
  nodeFromJson,
  nodePreview,
  nodeSearchText,
  nodeToJson,
  toNodeRole
} from '../util/NodeCodec';
import { resolveActiveLeafId } from '../util/TrajectoryLogic';
import { newSessionId } from '../util/Ids';
import { RootBranchStore, SessionArchiveStore } from './InternalStoreInterfaces';

const DOMAIN: number = 0x1A2B;
const TAG: string = 'RdbRepository';

/** Preferences 文件名（非敏感设置，密钥禁止进这里）。 */
const SETTINGS_FILE: string = 'chatanywhere_settings';

/** 单条 SQL 的绑定参数上限保护（SQLite 变量上限 999）。 */
const IN_CHUNK: number = 200;

const SQL_CREATE_SESSIONS: string = `CREATE TABLE IF NOT EXISTS sessions (
  session_id TEXT PRIMARY KEY NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  model_id TEXT NOT NULL DEFAULT '',
  provider_id TEXT NOT NULL DEFAULT '',
  pinned INTEGER NOT NULL DEFAULT 0,
  node_count INTEGER NOT NULL DEFAULT 0,
  total_tokens INTEGER NOT NULL DEFAULT 0,
  active_root_id TEXT
)`;

const SQL_CREATE_NODES: string = `CREATE TABLE IF NOT EXISTS nodes (
  node_id TEXT PRIMARY KEY NOT NULL,
  session_id TEXT NOT NULL,
  parent_id TEXT,
  role TEXT NOT NULL DEFAULT '',
  node_json TEXT NOT NULL DEFAULT '{}',
  content_text TEXT NOT NULL DEFAULT '',
  model_id TEXT NOT NULL DEFAULT '',
  provider_id TEXT NOT NULL DEFAULT '',
  token_estimate INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  active_child_id TEXT,
  archived INTEGER NOT NULL DEFAULT 0,
  cached_tokens INTEGER,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  cache_hit_ratio REAL
)`;

const SQL_CREATE_NODES_INDEXES: string = `CREATE INDEX IF NOT EXISTS idx_nodes_session ON nodes (session_id, created_at)`;

const SQL_CREATE_NODES_PARENT_INDEX: string =
  `CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes (session_id, parent_id)`;

const SQL_CREATE_SKILLS: string = `CREATE TABLE IF NOT EXISTS skills (
  skill_id TEXT PRIMARY KEY NOT NULL,
  version TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 1,
  manifest_json TEXT NOT NULL DEFAULT '{}',
  updated_at INTEGER NOT NULL DEFAULT 0
)`;

const SQL_CREATE_SKILL_SNAPSHOTS: string = `CREATE TABLE IF NOT EXISTS skill_snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  skill_id TEXT NOT NULL,
  version TEXT NOT NULL DEFAULT '',
  manifest_json TEXT NOT NULL DEFAULT '{}',
  saved_at INTEGER NOT NULL DEFAULT 0
)`;

const SQL_CREATE_SKILL_SNAPSHOT_INDEX: string =
  `CREATE INDEX IF NOT EXISTS idx_skill_snapshots_skill ON skill_snapshots (skill_id, saved_at)`;

/** 真实模型注册表（v3.2）：模型只来自用户对真实端点的「测试连接/拉取模型」，不内置占位模型。 */
const SQL_CREATE_PROVIDER_MODELS: string = `CREATE TABLE IF NOT EXISTS provider_models (
  provider_id TEXT NOT NULL,
  model_id TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  meta_json TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 0,
  discovered_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (provider_id, model_id)
)`;

const SQL_CREATE_PROVIDER_MODELS_INDEX: string =
  `CREATE INDEX IF NOT EXISTS idx_provider_models_provider ON provider_models (provider_id)`;

/** FTS5 首选项：trigram 支持任意位置子串匹配（含中文短词以外场景）。 */
const SQL_CREATE_FTS_TRIGRAM: string = `CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
  node_id UNINDEXED,
  session_id UNINDEXED,
  content_text,
  tokenize = 'trigram'
)`;

/** FTS5 兜底建表：不带 tokenizer 参数（部分 SQLite 构建不接受 trigram）。 */
const SQL_CREATE_FTS_DEFAULT: string = `CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
  node_id UNINDEXED,
  session_id UNINDEXED,
  content_text
)`;

/**
 * 节点 upsert：二次保存（流式最终化）时只更新已知字段；
 * `archived` 用 MAX(旧值, 新值) 保留归档标记，避免最终化把已归档节点改回未归档。
 * 旧版 SQLite 不支持 ON CONFLICT DO UPDATE 时由 SQL_REPLACE_NODE 兜底。
 */
const SQL_UPSERT_NODE: string = `INSERT INTO nodes (
  node_id, session_id, parent_id, role, node_json, content_text, model_id, provider_id,
  token_estimate, created_at, active_child_id, archived, cached_tokens, prompt_tokens,
  completion_tokens, cache_hit_ratio
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(node_id) DO UPDATE SET
  session_id = excluded.session_id,
  parent_id = excluded.parent_id,
  role = excluded.role,
  node_json = excluded.node_json,
  content_text = excluded.content_text,
  model_id = excluded.model_id,
  provider_id = excluded.provider_id,
  token_estimate = excluded.token_estimate,
  created_at = excluded.created_at,
  active_child_id = excluded.active_child_id,
  archived = MAX(nodes.archived, excluded.archived),
  cached_tokens = excluded.cached_tokens,
  prompt_tokens = excluded.prompt_tokens,
  completion_tokens = excluded.completion_tokens,
  cache_hit_ratio = excluded.cache_hit_ratio`;

/** 兜底写法（SQLite < 3.24 无 upsert 语法时使用；会重置 archived，仅作最后退路）。 */
const SQL_REPLACE_NODE: string = `INSERT OR REPLACE INTO nodes (
  node_id, session_id, parent_id, role, node_json, content_text, model_id, provider_id,
  token_estimate, created_at, active_child_id, archived, cached_tokens, prompt_tokens,
  completion_tokens, cache_hit_ratio
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`;

const SQL_INSERT_SESSION_IF_ABSENT: string = `INSERT OR IGNORE INTO sessions (
  session_id, title, created_at, updated_at, model_id, provider_id, pinned, node_count, total_tokens
) VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0)`;

const SQL_REFRESH_SESSION_AGGR: string = `UPDATE sessions SET
  updated_at = ?,
  node_count = (SELECT COUNT(*) FROM nodes WHERE session_id = ?),
  total_tokens = (SELECT COALESCE(SUM(token_estimate), 0) FROM nodes WHERE session_id = ?)
WHERE session_id = ?`;

const COL_SESSION: string =
  'session_id, title, created_at, updated_at, model_id, provider_id, pinned, node_count, total_tokens';

const COL_NODE_JSON: string = 'node_json';

const COL_SKILL: string = 'skill_id, version, enabled, manifest_json, updated_at';

const COL_SNAPSHOT: string = 'skill_id, version, manifest_json, saved_at';

const COL_PROVIDER_MODEL: string =
  'provider_id, model_id, display_name, meta_json, enabled, discovered_at';

/** 构造空的 ValuesBucket（ArkTS 禁止 Record 对象字面量）。 */
function newValuesBucket(): relationalStore.ValuesBucket {
  return JSON.parse('{}') as relationalStore.ValuesBucket;
}

export class RdbRepository implements RdbRepositoryApi, ModelRegistryApi, RootBranchStore, SessionArchiveStore {
  private readonly context: Context;
  private readonly dbName: string;
  private store: relationalStore.RdbStore | null = null;
  private prefs: preferences.Preferences | null = null;
  private prefsInit: Promise<preferences.Preferences> | null = null;
  private ftsEnabled: boolean = false;
  private opened: boolean = false;

  /** 最近一次打开/查询失败的原因（空串表示正常）。 */
  lastError: string = '';

  constructor(context: Context, dbName: string) {
    this.context = context;
    this.dbName = dbName.length > 0 ? dbName : 'chatanywhere.db';
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /**
   * 打开数据库、建表（幂等）、探测 FTS5、初始化 Preferences。
   * 失败抛带中文信息的 Error（由 AppServices 展示引导，不直接崩溃）。
   */
  async init(): Promise<void> {
    if (this.opened) {
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: this.dbName,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    try {
      this.store = await relationalStore.getRdbStore(this.context, config);
    } catch (e) {
      this.lastError = `本地数据库打开失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'getRdbStore failed: %{public}s', (e as Error).message);
      throw new Error(this.lastError);
    }
    await this.createSchema();
    try {
      const opts: preferences.Options = { name: SETTINGS_FILE };
      this.prefs = await preferences.getPreferences(this.context, opts);
    } catch (e) {
      // 设置读写失败不应阻塞主流程：get 给默认值，put 时再报中文错误。
      this.prefs = null;
      hilog.warn(DOMAIN, TAG, 'getPreferences failed: %{public}s', (e as Error).message);
    }
    this.opened = true;
  }

  /** 关闭数据库（设置页/测试用）。 */
  async close(): Promise<void> {
    const store = this.store;
    this.store = null;
    this.opened = false;
    if (store !== null) {
      try {
        await store.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close failed: %{public}s', (e as Error).message);
      }
    }
  }

  private requireStore(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('本地数据库尚未打开，请返回首页重试');
    }
    return this.store;
  }

  private async createSchema(): Promise<void> {
    const store = this.requireStore();
    try {
      await store.executeSql(SQL_CREATE_SESSIONS);
      await store.executeSql(SQL_CREATE_NODES);
      await store.executeSql(SQL_CREATE_NODES_INDEXES);
      await store.executeSql(SQL_CREATE_NODES_PARENT_INDEX);
      await store.executeSql(SQL_CREATE_SKILLS);
      await store.executeSql(SQL_CREATE_SKILL_SNAPSHOTS);
      await store.executeSql(SQL_CREATE_SKILL_SNAPSHOT_INDEX);
    } catch (e) {
      this.lastError = `初始化数据表失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
    // 模型注册表建表失败只降级（模型列表暂时为空），绝不阻断 App 启动。
    try {
      await store.executeSql(SQL_CREATE_PROVIDER_MODELS);
      await store.executeSql(SQL_CREATE_PROVIDER_MODELS_INDEX);
    } catch (e) {
      this.lastError = `模型清单表初始化失败，模型列表将暂时为空：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'create provider_models failed: %{public}s', (e as Error).message);
    }
    await this.initFts();
  }

  /** 探测 FTS5：建表 + 试查询；任何失败都降级 LIKE，不影响启动。 */
  private async initFts(): Promise<void> {
    const store = this.requireStore();
    let created: boolean = false;
    try {
      await store.executeSql(SQL_CREATE_FTS_TRIGRAM);
      created = true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'fts5 trigram unavailable: %{public}s', (e as Error).message);
    }
    if (!created) {
      try {
        await store.executeSql(SQL_CREATE_FTS_DEFAULT);
        created = true;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'fts5 unavailable: %{public}s', (e as Error).message);
      }
    }
    if (!created) {
      this.ftsEnabled = false;
      this.lastError = '本机不支持增强全文索引，已自动改用关键词匹配（功能正常，速度略慢）';
      return;
    }
    try {
      const rs = await store.querySql('SELECT node_id FROM nodes_fts LIMIT 1');
      rs.close();
      this.ftsEnabled = true;
    } catch (e) {
      this.ftsEnabled = false;
      this.lastError = '全文索引不可用，已自动改用关键词匹配（功能正常，速度略慢）';
      hilog.warn(DOMAIN, TAG, 'fts5 probe failed: %{public}s', (e as Error).message);
    }
  }

  // ---------------------------------------------------------------------------
  // 结果集读取小工具
  // ---------------------------------------------------------------------------

  private colIndex(rs: relationalStore.ResultSet, name: string): number {
    return rs.getColumnIndex(name);
  }

  private readString(rs: relationalStore.ResultSet, name: string): string {
    const idx = this.colIndex(rs, name);
    if (idx < 0 || rs.isColumnNull(idx)) {
      return '';
    }
    return rs.getString(idx);
  }

  private readNumber(rs: relationalStore.ResultSet, name: string, defaultValue: number): number {
    const idx = this.colIndex(rs, name);
    if (idx < 0 || rs.isColumnNull(idx)) {
      return defaultValue;
    }
    return rs.getLong(idx);
  }

  private readOptionalNumber(rs: relationalStore.ResultSet, name: string): number | null {
    const idx = this.colIndex(rs, name);
    if (idx < 0 || rs.isColumnNull(idx)) {
      return null;
    }
    return rs.getLong(idx);
  }

  private readOptionalReal(rs: relationalStore.ResultSet, name: string): number | null {
    const idx = this.colIndex(rs, name);
    if (idx < 0 || rs.isColumnNull(idx)) {
      return null;
    }
    return rs.getDouble(idx);
  }

  private sessionFromRow(rs: relationalStore.ResultSet): SessionMeta {
    const meta: SessionMeta = {
      sessionId: this.readString(rs, 'session_id'),
      title: this.readString(rs, 'title'),
      createdAt: this.readNumber(rs, 'created_at', 0),
      updatedAt: this.readNumber(rs, 'updated_at', 0),
      pinned: this.readNumber(rs, 'pinned', 0) === 1,
      nodeCount: this.readNumber(rs, 'node_count', 0),
      totalTokens: this.readNumber(rs, 'total_tokens', 0)
    };
    const modelId = this.readString(rs, 'model_id');
    if (modelId.length > 0) {
      meta.modelId = modelId;
    }
    const providerId = this.readString(rs, 'provider_id');
    if (providerId.length > 0) {
      meta.providerId = providerId;
    }
    return meta;
  }

  private skillFromRow(rs: relationalStore.ResultSet): SkillRecord {
    const record: SkillRecord = {
      skillId: this.readString(rs, 'skill_id'),
      version: this.readString(rs, 'version'),
      enabled: this.readNumber(rs, 'enabled', 1) === 1,
      manifestJson: this.readString(rs, 'manifest_json'),
      updatedAt: this.readNumber(rs, 'updated_at', 0)
    };
    return record;
  }

  private snapshotFromRow(rs: relationalStore.ResultSet): SkillSnapshot {
    const snapshot: SkillSnapshot = {
      skillId: this.readString(rs, 'skill_id'),
      version: this.readString(rs, 'version'),
      manifestJson: this.readString(rs, 'manifest_json'),
      savedAt: this.readNumber(rs, 'saved_at', 0)
    };
    return snapshot;
  }

  private providerModelFromRow(rs: relationalStore.ResultSet): ProviderModelRecord {
    const record: ProviderModelRecord = {
      providerId: this.readString(rs, 'provider_id'),
      modelId: this.readString(rs, 'model_id'),
      displayName: this.readString(rs, 'display_name'),
      metaJson: this.readString(rs, 'meta_json'),
      enabled: this.readNumber(rs, 'enabled', 0) === 1,
      discoveredAt: this.readNumber(rs, 'discovered_at', 0)
    };
    return record;
  }

  // ---------------------------------------------------------------------------
  // 会话
  // ---------------------------------------------------------------------------

  async createSession(title: string, modelId: string, providerId: string): Promise<SessionMeta> {
    const store = this.requireStore();
    const now = Date.now();
    const sessionId = newSessionId();
    const safeTitle = title.trim().length > 0 ? title.trim() : '新对话';
    const meta: SessionMeta = {
      sessionId: sessionId,
      title: safeTitle,
      createdAt: now,
      updatedAt: now,
      pinned: false,
      nodeCount: 0,
      totalTokens: 0
    };
    if (modelId.length > 0) {
      meta.modelId = modelId;
    }
    if (providerId.length > 0) {
      meta.providerId = providerId;
    }
    const bucket = newValuesBucket();
    bucket['session_id'] = sessionId;
    bucket['title'] = safeTitle;
    bucket['created_at'] = now;
    bucket['updated_at'] = now;
    bucket['model_id'] = modelId;
    bucket['provider_id'] = providerId;
    bucket['pinned'] = 0;
    bucket['node_count'] = 0;
    bucket['total_tokens'] = 0;
    try {
      await store.insert('sessions', bucket);
    } catch (e) {
      this.lastError = `新建会话失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
    return meta;
  }

  async listSessions(limit?: number): Promise<SessionMeta[]> {
    const store = this.requireStore();
    const max = limit !== undefined && limit > 0 ? limit : 200;
    const out: SessionMeta[] = [];
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT ${COL_SESSION} FROM sessions ORDER BY pinned DESC, updated_at DESC LIMIT ?`,
        [max]
      );
      while (rs.goToNextRow()) {
        out.push(this.sessionFromRow(rs));
      }
    } catch (e) {
      this.lastError = `读取会话列表失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'listSessions failed: %{public}s', (e as Error).message);
      return [];
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
    return out;
  }

  async getSession(sessionId: string): Promise<SessionMeta | null> {
    const store = this.requireStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(`SELECT ${COL_SESSION} FROM sessions WHERE session_id = ?`, [sessionId]);
      if (!rs.goToNextRow()) {
        return null;
      }
      return this.sessionFromRow(rs);
    } catch (e) {
      this.lastError = `读取会话失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'getSession failed: %{public}s', (e as Error).message);
      return null;
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
  }

  async renameSession(sessionId: string, title: string): Promise<void> {
    const store = this.requireStore();
    const safeTitle = title.trim().length > 0 ? title.trim() : '未命名对话';
    const bucket = newValuesBucket();
    bucket['title'] = safeTitle;
    bucket['updated_at'] = Date.now();
    const predicates = new relationalStore.RdbPredicates('sessions');
    predicates.equalTo('session_id', sessionId);
    try {
      await store.update(bucket, predicates);
    } catch (e) {
      this.lastError = `重命名会话失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async deleteSession(sessionId: string): Promise<void> {
    const store = this.requireStore();
    const nodePredicates = new relationalStore.RdbPredicates('nodes');
    nodePredicates.equalTo('session_id', sessionId);
    const sessionPredicates = new relationalStore.RdbPredicates('sessions');
    sessionPredicates.equalTo('session_id', sessionId);
    const tx: relationalStore.Transaction = await store.createTransaction();
    try {
      await tx.delete(nodePredicates);
      await tx.delete(sessionPredicates);
      await tx.commit();
    } catch (e) {
      try {
        await tx.rollback();
      } catch (e2) {
        // 忽略回滚失败：原始错误更重要
      }
      this.lastError = `删除会话失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
    await this.deleteFtsSession(sessionId);
  }

  async touchSession(sessionId: string, totalTokens?: number): Promise<void> {
    const store = this.requireStore();
    try {
      if (totalTokens !== undefined && totalTokens >= 0) {
        await store.executeSql('UPDATE sessions SET updated_at = ?, total_tokens = ? WHERE session_id = ?', [
          Date.now(), totalTokens, sessionId
        ]);
      } else {
        await store.executeSql('UPDATE sessions SET updated_at = ? WHERE session_id = ?', [
          Date.now(), sessionId
        ]);
      }
    } catch (e) {
      this.lastError = `更新会话时间失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  // ---------------------------------------------------------------------------
  // 节点轨迹
  // ---------------------------------------------------------------------------

  async saveNode(node: ConversationNode): Promise<void> {
    if (node === null || node === undefined) {
      throw new Error('保存消息失败：消息内容为空');
    }
    if (node.nodeId.length === 0 || node.sessionId.length === 0) {
      throw new Error('保存消息失败：消息缺少必要编号');
    }
    const store = this.requireStore();
    const now = Date.now();
    const createdAt = node.createdAt > 0 ? node.createdAt : now;
    const json = nodeToJson(node);
    const searchText = nodeSearchText(node);
    const modelId = node.modelId ?? '';
    const providerId = node.providerId ?? '';
    const activeChildId: string | null = node.activeChildId === undefined ? null : node.activeChildId;
    const archived: number = node.archived === true ? 1 : 0;
    const cachedTokens: number | null = node.cachedTokens === undefined ? null : node.cachedTokens;
    const promptTokens: number | null = node.promptTokens === undefined ? null : node.promptTokens;
    const completionTokens: number | null = node.completionTokens === undefined ? null : node.completionTokens;
    const cacheHitRatio: number | null = node.cacheHitRatio === undefined ? null : node.cacheHitRatio;

    const nodeArgs: relationalStore.ValueType[] = [
      node.nodeId, node.sessionId, node.parentId, node.role, json, searchText, modelId, providerId,
      node.tokenEstimate, createdAt, activeChildId, archived, cachedTokens, promptTokens,
      completionTokens, cacheHitRatio
    ];
    const tx: relationalStore.Transaction = await store.createTransaction();
    try {
      await tx.execute(SQL_INSERT_SESSION_IF_ABSENT, [
        node.sessionId, '新对话', createdAt, now, modelId, providerId
      ]);
      try {
        await tx.execute(SQL_UPSERT_NODE, nodeArgs);
      } catch (upsertError) {
        // 极老版本 SQLite 不支持 upsert 语法：退回 INSERT OR REPLACE（仍保证写入成功）
        hilog.warn(DOMAIN, TAG, 'upsert unsupported, fallback replace: %{public}s',
          (upsertError as Error).message);
        await tx.execute(SQL_REPLACE_NODE, nodeArgs);
      }
      await tx.execute(SQL_REFRESH_SESSION_AGGR, [now, node.sessionId, node.sessionId, node.sessionId]);
      await tx.commit();
    } catch (e) {
      try {
        await tx.rollback();
      } catch (e2) {
        // 忽略回滚失败
      }
      this.lastError = `保存消息失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
    await this.syncNodeFts(node.nodeId, node.sessionId, searchText);
  }

  async loadNode(nodeId: string): Promise<ConversationNode | null> {
    const store = this.requireStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(`SELECT ${COL_NODE_JSON} FROM nodes WHERE node_id = ?`, [nodeId]);
      if (!rs.goToNextRow()) {
        return null;
      }
      return nodeFromJson(this.readString(rs, COL_NODE_JSON));
    } catch (e) {
      this.lastError = `读取消息失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'loadNode failed: %{public}s', (e as Error).message);
      return null;
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
  }

  async loadSessionNodes(sessionId: string): Promise<ConversationNode[]> {
    const store = this.requireStore();
    const out: ConversationNode[] = [];
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT ${COL_NODE_JSON} FROM nodes WHERE session_id = ? ORDER BY created_at ASC, node_id ASC`,
        [sessionId]
      );
      while (rs.goToNextRow()) {
        const node = nodeFromJson(this.readString(rs, COL_NODE_JSON));
        if (node === null) {
          this.lastError = '有 1 条历史消息已损坏，已跳过显示（原文仍保留在本地数据库）';
          continue;
        }
        out.push(node);
      }
    } catch (e) {
      this.lastError = `读取会话消息失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'loadSessionNodes failed: %{public}s', (e as Error).message);
      return out;
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
    return out;
  }

  async loadChildren(sessionId: string, parentId: string | null): Promise<NodeBrief[]> {
    const store = this.requireStore();
    const out: NodeBrief[] = [];
    const counts: Map<string, number> = new Map<string, number>();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const countRs = await store.querySql(
        'SELECT parent_id, COUNT(*) AS child_count FROM nodes WHERE session_id = ? GROUP BY parent_id',
        [sessionId]
      );
      try {
        while (countRs.goToNextRow()) {
          const key = this.readString(countRs, 'parent_id');
          counts.set(key, this.readNumber(countRs, 'child_count', 0));
        }
      } finally {
        countRs.close();
      }
      if (parentId === null) {
        rs = await store.querySql(
          `SELECT node_id, parent_id, role, created_at, active_child_id, archived, node_json, content_text
           FROM nodes WHERE session_id = ? AND parent_id IS NULL ORDER BY created_at ASC, node_id ASC`,
          [sessionId]
        );
      } else {
        rs = await store.querySql(
          `SELECT node_id, parent_id, role, created_at, active_child_id, archived, node_json, content_text
           FROM nodes WHERE session_id = ? AND parent_id = ? ORDER BY created_at ASC, node_id ASC`,
          [sessionId, parentId]
        );
      }
      while (rs.goToNextRow()) {
        const nodeJson = this.readString(rs, 'node_json');
        const parsed = nodeFromJson(nodeJson);
        const nodeId = this.readString(rs, 'node_id');
        const role = this.readString(rs, 'role');
        const previewText = parsed !== null ? nodePreview(parsed) : makeSnippet(this.readString(rs, 'content_text'), '', 40);
        const brief: NodeBrief = {
          nodeId: nodeId,
          parentId: parentId,
          role: toNodeRole(role),
          createdAt: this.readNumber(rs, 'created_at', 0),
          preview: previewText,
          childCount: counts.get(nodeId) ?? 0
        };
        const activeChildId = this.readString(rs, 'active_child_id');
        if (activeChildId.length > 0) {
          brief.activeChildId = activeChildId;
        }
        brief.archived = this.readNumber(rs, 'archived', 0) === 1;
        out.push(brief);
      }
    } catch (e) {
      this.lastError = `读取分支失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'loadChildren failed: %{public}s', (e as Error).message);
      return out;
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
    return out;
  }

  async setActiveChild(sessionId: string, parentId: string | null, childId: string): Promise<void> {
    const store = this.requireStore();
    try {
      if (parentId === null) {
        await store.executeSql(SQL_INSERT_SESSION_IF_ABSENT, [
          sessionId, '新对话', Date.now(), Date.now(), '', ''
        ]);
        await store.executeSql('UPDATE sessions SET active_root_id = ?, updated_at = ? WHERE session_id = ?', [
          childId, Date.now(), sessionId
        ]);
        return;
      }
      await store.executeSql(
        'UPDATE nodes SET active_child_id = ? WHERE node_id = ? AND session_id = ?',
        [childId, parentId, sessionId]
      );
    } catch (e) {
      this.lastError = `切换分支失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async archiveNodes(nodeIds: string[]): Promise<void> {
    if (nodeIds === undefined || nodeIds === null || nodeIds.length === 0) {
      return;
    }
    const store = this.requireStore();
    let chunk: relationalStore.ValueType[] = [];
    let marks: string = '';
    try {
      for (const id of nodeIds) {
        if (id.length === 0) {
          continue;
        }
        chunk.push(id);
        marks += marks.length === 0 ? '?' : ',?';
        if (chunk.length >= IN_CHUNK) {
          await store.executeSql(`UPDATE nodes SET archived = 1 WHERE node_id IN (${marks})`, chunk);
          chunk = [];
          marks = '';
        }
      }
      if (chunk.length > 0) {
        await store.executeSql(`UPDATE nodes SET archived = 1 WHERE node_id IN (${marks})`, chunk);
      }
    } catch (e) {
      this.lastError = `归档旧消息失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async markPayloadPruned(nodeId: string): Promise<void> {
    const node = await this.loadNode(nodeId);
    if (node === null) {
      return;
    }
    let changed: boolean = false;
    for (const item of node.items) {
      if (item.payloadPruned === true) {
        continue;
      }
      if (item.kind === 'tool_call' || item.kind === 'tool_result' || item.kind === 'web_search_call') {
        item.payloadPruned = true;
        changed = true;
        continue;
      }
      const text = item.text ?? '';
      if (text.length > 4000) {
        item.payloadPruned = true;
        changed = true;
      }
    }
    if (!changed) {
      return;
    }
    const store = this.requireStore();
    try {
      await store.executeSql('UPDATE nodes SET node_json = ? WHERE node_id = ?', [nodeToJson(node), nodeId]);
    } catch (e) {
      this.lastError = `标记消息精简失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async getActiveLeafId(sessionId: string): Promise<string | null> {
    const nodes = await this.loadSessionNodes(sessionId);
    const rootActiveId = await this.getActiveRootChildId(sessionId);
    return resolveActiveLeafId(nodes, rootActiveId);
  }

  /** 会话根分支选择（根节点没有父节点可挂 activeChildId，单独存 sessions 表）。 */
  async getActiveRootChildId(sessionId: string): Promise<string | null> {
    const store = this.requireStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql('SELECT active_root_id FROM sessions WHERE session_id = ?', [sessionId]);
      if (!rs.goToNextRow()) {
        return null;
      }
      const value = this.readString(rs, 'active_root_id');
      return value.length > 0 ? value : null;
    } catch (e) {
      return null;
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
  }

  /** 持久化会话根分支选择。 */
  async setActiveRootChildId(sessionId: string, childId: string): Promise<void> {
    await this.setActiveChild(sessionId, null, childId);
  }

  /** 导入时按原 sessionId 写入会话（已存在则覆盖元信息，不覆盖节点）。 */
  async upsertSession(meta: SessionMeta): Promise<void> {
    const store = this.requireStore();
    const bucket = newValuesBucket();
    bucket['session_id'] = meta.sessionId;
    bucket['title'] = meta.title;
    bucket['created_at'] = meta.createdAt;
    bucket['updated_at'] = meta.updatedAt;
    bucket['model_id'] = meta.modelId ?? '';
    bucket['provider_id'] = meta.providerId ?? '';
    bucket['pinned'] = meta.pinned === true ? 1 : 0;
    bucket['node_count'] = meta.nodeCount ?? 0;
    bucket['total_tokens'] = meta.totalTokens ?? 0;
    try {
      await store.insert('sessions', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      this.lastError = `写入会话失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  // ---------------------------------------------------------------------------
  // 检索
  // ---------------------------------------------------------------------------

  async search(query: string, limit?: number, sessionId?: string): Promise<SearchHit[]> {
    const keyword = query.trim();
    if (keyword.length === 0) {
      return [];
    }
    const max = limit !== undefined && limit > 0 ? limit : 30;
    const hits: SearchHit[] = [];
    const seen: Set<string> = new Set<string>();
    const ftsQuery = buildFtsQuery(keyword);
    if (this.ftsEnabled && ftsQuery.length > 0) {
      await this.searchFts(ftsQuery, max, sessionId, hits, seen);
    }
    if (hits.length < max) {
      await this.searchLike(keyword, max, sessionId, hits, seen);
    }
    return hits;
  }

  private async searchFts(
    ftsQuery: string, max: number, sessionId: string | undefined,
    hits: SearchHit[], seen: Set<string>
  ): Promise<void> {
    const store = this.requireStore();
    const args: relationalStore.ValueType[] = [ftsQuery];
    let sql = `SELECT node_id, session_id, created_at,
      snippet(nodes_fts, 2, '[', ']', '…', 12) AS snip, bm25(nodes_fts) AS rank_score
      FROM nodes_fts WHERE nodes_fts MATCH ?`;
    if (sessionId !== undefined && sessionId !== null && sessionId.length > 0) {
      sql += ' AND session_id = ?';
      args.push(sessionId);
    }
    sql += ' ORDER BY rank_score ASC LIMIT ?';
    args.push(max);
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(sql, args);
      while (rs.goToNextRow()) {
        const nodeId = this.readString(rs, 'node_id');
        if (nodeId.length === 0 || seen.has(nodeId)) {
          continue;
        }
        seen.add(nodeId);
        const rankScore = this.readOptionalReal(rs, 'rank_score');
        const hit: SearchHit = {
          nodeId: nodeId,
          sessionId: this.readString(rs, 'session_id'),
          snippet: this.readString(rs, 'snip'),
          score: rankScore === null ? 0 : -rankScore,
          createdAt: this.readNumber(rs, 'created_at', 0)
        };
        hits.push(hit);
      }
    } catch (e) {
      // 查询失败（分词器不支持/索引损坏）→ 永久降级 LIKE，避免每次都失败。
      this.ftsEnabled = false;
      this.lastError = '全文索引查询失败，已自动改用关键词匹配（功能正常，速度略慢）';
      hilog.warn(DOMAIN, TAG, 'fts search failed: %{public}s', (e as Error).message);
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
  }

  private async searchLike(
    keyword: string, max: number, sessionId: string | undefined,
    hits: SearchHit[], seen: Set<string>
  ): Promise<void> {
    const store = this.requireStore();
    const args: relationalStore.ValueType[] = [likePattern(keyword)];
    let sql = `SELECT node_id, session_id, created_at, content_text FROM nodes
      WHERE content_text LIKE ? ESCAPE '\\'`;
    if (sessionId !== undefined && sessionId !== null && sessionId.length > 0) {
      sql += ' AND session_id = ?';
      args.push(sessionId);
    }
    sql += ' ORDER BY created_at DESC LIMIT ?';
    args.push(max);
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(sql, args);
      while (rs.goToNextRow()) {
        const nodeId = this.readString(rs, 'node_id');
        if (nodeId.length === 0 || seen.has(nodeId)) {
          continue;
        }
        seen.add(nodeId);
        const hit: SearchHit = {
          nodeId: nodeId,
          sessionId: this.readString(rs, 'session_id'),
          snippet: makeSnippet(this.readString(rs, 'content_text'), keyword, 24),
          score: 1,
          createdAt: this.readNumber(rs, 'created_at', 0)
        };
        hits.push(hit);
      }
    } catch (e) {
      this.lastError = `检索历史消息失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'like search failed: %{public}s', (e as Error).message);
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
  }

  async reindexSession(sessionId: string): Promise<void> {
    if (!this.ftsEnabled) {
      // 没有 FTS 时 LIKE 天然可查，无需建索引。
      return;
    }
    const store = this.requireStore();
    const nodes = await this.loadSessionNodes(sessionId);
    const tx: relationalStore.Transaction = await store.createTransaction();
    try {
      await tx.execute('DELETE FROM nodes_fts WHERE session_id = ?', [sessionId]);
      for (const node of nodes) {
        await tx.execute('INSERT INTO nodes_fts (node_id, session_id, content_text) VALUES (?, ?, ?)', [
          node.nodeId, node.sessionId, nodeSearchText(node)
        ]);
      }
      await tx.commit();
    } catch (e) {
      try {
        await tx.rollback();
      } catch (e2) {
        // 忽略回滚失败
      }
      this.ftsEnabled = false;
      this.lastError = '重建全文索引失败，已自动改用关键词匹配（功能正常，速度略慢）';
      hilog.warn(DOMAIN, TAG, 'reindex failed: %{public}s', (e as Error).message);
    }
  }

  private async syncNodeFts(nodeId: string, sessionId: string, contentText: string): Promise<void> {
    if (!this.ftsEnabled) {
      return;
    }
    const store = this.requireStore();
    try {
      await store.executeSql('DELETE FROM nodes_fts WHERE node_id = ?', [nodeId]);
      await store.executeSql('INSERT INTO nodes_fts (node_id, session_id, content_text) VALUES (?, ?, ?)', [
        nodeId, sessionId, contentText
      ]);
    } catch (e) {
      this.ftsEnabled = false;
      this.lastError = '全文索引更新失败，已自动改用关键词匹配（功能正常，速度略慢）';
      hilog.warn(DOMAIN, TAG, 'fts sync failed: %{public}s', (e as Error).message);
    }
  }

  private async deleteFtsSession(sessionId: string): Promise<void> {
    if (!this.ftsEnabled) {
      return;
    }
    try {
      await this.requireStore().executeSql('DELETE FROM nodes_fts WHERE session_id = ?', [sessionId]);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'fts delete failed: %{public}s', (e as Error).message);
    }
  }

  // ---------------------------------------------------------------------------
  // 技能与版本快照
  // ---------------------------------------------------------------------------

  async saveSkill(record: SkillRecord): Promise<void> {
    if (record.skillId.length === 0) {
      throw new Error('保存技能失败：技能编号为空');
    }
    const store = this.requireStore();
    const bucket = newValuesBucket();
    bucket['skill_id'] = record.skillId;
    bucket['version'] = record.version;
    bucket['enabled'] = record.enabled ? 1 : 0;
    bucket['manifest_json'] = record.manifestJson;
    bucket['updated_at'] = record.updatedAt > 0 ? record.updatedAt : Date.now();
    try {
      await store.insert('skills', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      this.lastError = `保存技能失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async loadSkills(): Promise<SkillRecord[]> {
    const store = this.requireStore();
    const out: SkillRecord[] = [];
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(`SELECT ${COL_SKILL} FROM skills ORDER BY skill_id ASC`);
      while (rs.goToNextRow()) {
        out.push(this.skillFromRow(rs));
      }
    } catch (e) {
      this.lastError = `读取技能列表失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'loadSkills failed: %{public}s', (e as Error).message);
      return [];
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
    return out;
  }

  async loadSkill(skillId: string): Promise<SkillRecord | null> {
    const store = this.requireStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(`SELECT ${COL_SKILL} FROM skills WHERE skill_id = ?`, [skillId]);
      if (!rs.goToNextRow()) {
        return null;
      }
      return this.skillFromRow(rs);
    } catch (e) {
      this.lastError = `读取技能失败：${(e as Error).message}`;
      return null;
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
  }

  async removeSkill(skillId: string): Promise<void> {
    const store = this.requireStore();
    const predicates = new relationalStore.RdbPredicates('skills');
    predicates.equalTo('skill_id', skillId);
    try {
      await store.delete(predicates);
    } catch (e) {
      this.lastError = `删除技能失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async saveSkillSnapshot(snapshot: SkillSnapshot): Promise<void> {
    if (snapshot.skillId.length === 0) {
      throw new Error('保存技能版本失败：技能编号为空');
    }
    const store = this.requireStore();
    const bucket = newValuesBucket();
    bucket['skill_id'] = snapshot.skillId;
    bucket['version'] = snapshot.version;
    bucket['manifest_json'] = snapshot.manifestJson;
    bucket['saved_at'] = snapshot.savedAt > 0 ? snapshot.savedAt : Date.now();
    try {
      await store.insert('skill_snapshots', bucket);
    } catch (e) {
      this.lastError = `保存技能旧版本失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async listSkillSnapshots(skillId: string): Promise<SkillSnapshot[]> {
    const store = this.requireStore();
    const out: SkillSnapshot[] = [];
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT ${COL_SNAPSHOT} FROM skill_snapshots WHERE skill_id = ? ORDER BY saved_at DESC, id DESC`,
        [skillId]
      );
      while (rs.goToNextRow()) {
        out.push(this.snapshotFromRow(rs));
      }
    } catch (e) {
      this.lastError = `读取技能版本失败：${(e as Error).message}`;
      return out;
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
    return out;
  }

  async loadPreviousSnapshot(skillId: string): Promise<SkillSnapshot | null> {
    const current = await this.loadSkill(skillId);
    const snapshots = await this.listSkillSnapshots(skillId);
    if (snapshots.length === 0) {
      return null;
    }
    if (current === null) {
      return snapshots[0];
    }
    for (const snapshot of snapshots) {
      if (snapshot.version !== current.version) {
        return snapshot;
      }
    }
    return null;
  }

  async clearSkillSnapshots(skillId: string): Promise<void> {
    const store = this.requireStore();
    try {
      await store.executeSql('DELETE FROM skill_snapshots WHERE skill_id = ?', [skillId]);
    } catch (e) {
      this.lastError = `清理技能旧版本失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  // ---------------------------------------------------------------------------
  // 真实模型注册表（provider_models，v3.2）
  // ---------------------------------------------------------------------------

  /**
   * 用一次真实探测结果整体替换某厂商的模型清单。
   * 事务内：先读旧 enabled 状态 → 全量重写本厂商行（同 provider+model 保留旧 enabled，
   * 新模型用传入 enabled）→ 旧清单里已消失的模型随之被删除。
   * 空 providerId 视为调用错误；写入失败抛中文 Error。
   */
  async saveDiscoveredModels(providerId: string, records: ProviderModelRecord[]): Promise<void> {
    if (providerId === undefined || providerId === null || providerId.trim().length === 0) {
      throw new Error('保存模型清单失败：厂商标识为空');
    }
    const store = this.requireStore();
    const safeRecords: ProviderModelRecord[] = [];
    const seen: Set<string> = new Set<string>();
    if (records !== undefined && records !== null) {
      for (const record of records) {
        if (record === null || record === undefined) {
          continue;
        }
        const rawModelId = record.modelId === undefined || record.modelId === null ? '' : record.modelId;
        const modelId = rawModelId.trim();
        if (modelId.length === 0) {
          hilog.warn(DOMAIN, TAG, 'skip discovered model with empty id');
          continue;
        }
        if (seen.has(modelId)) {
          continue;
        }
        seen.add(modelId);
        const rawDisplayName = record.displayName === undefined || record.displayName === null
          ? '' : record.displayName;
        const rawMetaJson = record.metaJson === undefined || record.metaJson === null
          ? '' : record.metaJson;
        const discoveredAt = record.discoveredAt > 0 ? record.discoveredAt : Date.now();
        const normalized: ProviderModelRecord = {
          providerId: providerId,
          modelId: modelId,
          displayName: rawDisplayName.trim().length > 0 ? rawDisplayName.trim() : modelId,
          metaJson: rawMetaJson,
          enabled: record.enabled === true,
          discoveredAt: discoveredAt
        };
        safeRecords.push(normalized);
      }
    }
    const tx: relationalStore.Transaction = await store.createTransaction();
    try {
      const oldEnabled: Map<string, boolean> = new Map<string, boolean>();
      const rs = await tx.querySql(
        'SELECT model_id, enabled FROM provider_models WHERE provider_id = ?',
        [providerId]
      );
      try {
        while (rs.goToNextRow()) {
          oldEnabled.set(this.readString(rs, 'model_id'), this.readNumber(rs, 'enabled', 0) === 1);
        }
      } finally {
        rs.close();
      }
      await tx.execute('DELETE FROM provider_models WHERE provider_id = ?', [providerId]);
      for (const record of safeRecords) {
        const previous = oldEnabled.get(record.modelId);
        const enabled = previous === undefined ? record.enabled : previous;
        await tx.execute(
          `INSERT INTO provider_models (provider_id, model_id, display_name, meta_json, enabled, discovered_at)
           VALUES (?, ?, ?, ?, ?, ?)`,
          [
            providerId, record.modelId, record.displayName, record.metaJson,
            enabled ? 1 : 0, record.discoveredAt
          ]
        );
      }
      await tx.commit();
    } catch (e) {
      try {
        await tx.rollback();
      } catch (e2) {
        // 忽略回滚失败：原始错误更重要
      }
      this.lastError = `保存模型清单失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'saveDiscoveredModels failed: %{public}s', (e as Error).message);
      throw new Error(this.lastError);
    }
  }

  /** 全量读取模型清单（含未启用），按厂商 + 模型 id 排序；读失败返回空列表并记 lastError。 */
  async loadModels(): Promise<ProviderModelRecord[]> {
    const store = this.requireStore();
    const out: ProviderModelRecord[] = [];
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT ${COL_PROVIDER_MODEL} FROM provider_models ORDER BY provider_id ASC, model_id ASC`
      );
      while (rs.goToNextRow()) {
        out.push(this.providerModelFromRow(rs));
      }
    } catch (e) {
      this.lastError = `读取模型清单失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'loadModels failed: %{public}s', (e as Error).message);
      return [];
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
    return out;
  }

  /** 勾选/取消勾选某个模型；模型不存在时抛中文 Error（提示重新拉取清单）。 */
  async setModelEnabled(providerId: string, modelId: string, enabled: boolean): Promise<void> {
    if (providerId === undefined || providerId === null || providerId.trim().length === 0 ||
      modelId === undefined || modelId === null || modelId.trim().length === 0) {
      throw new Error('切换模型失败：缺少厂商或模型标识');
    }
    const store = this.requireStore();
    let exists: boolean = false;
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        'SELECT model_id FROM provider_models WHERE provider_id = ? AND model_id = ?',
        [providerId, modelId]
      );
      exists = rs.goToNextRow();
    } catch (e) {
      this.lastError = `切换模型失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    } finally {
      if (rs !== null) {
        rs.close();
      }
    }
    if (!exists) {
      throw new Error('切换模型失败：没有找到这个模型，请先在设置页重新拉取模型清单');
    }
    try {
      await store.executeSql(
        'UPDATE provider_models SET enabled = ? WHERE provider_id = ? AND model_id = ?',
        [enabled ? 1 : 0, providerId, modelId]
      );
    } catch (e) {
      this.lastError = `切换模型失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  /** 清空某厂商的全部模型（切换端点 / 重置时用）。 */
  async removeProviderModels(providerId: string): Promise<void> {
    if (providerId === undefined || providerId === null || providerId.trim().length === 0) {
      throw new Error('清空模型清单失败：厂商标识为空');
    }
    const store = this.requireStore();
    try {
      await store.executeSql('DELETE FROM provider_models WHERE provider_id = ?', [providerId]);
    } catch (e) {
      this.lastError = `清空模型清单失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  // ---------------------------------------------------------------------------
  // 非敏感设置（Preferences；密钥禁止走这里）
  // ---------------------------------------------------------------------------

  private async prefsInstance(): Promise<preferences.Preferences> {
    if (this.prefs !== null) {
      return this.prefs;
    }
    if (this.prefsInit === null) {
      const opts: preferences.Options = { name: SETTINGS_FILE };
      this.prefsInit = preferences.getPreferences(this.context, opts);
    }
    this.prefs = await this.prefsInit;
    return this.prefs;
  }

  async getString(key: string, defaultValue: string): Promise<string> {
    try {
      const p = await this.prefsInstance();
      const value = await p.get(key, defaultValue);
      if (typeof value === 'string') {
        return value as string;
      }
      return defaultValue;
    } catch (e) {
      return defaultValue;
    }
  }

  async putString(key: string, value: string): Promise<void> {
    try {
      const p = await this.prefsInstance();
      await p.put(key, value);
      await p.flush();
    } catch (e) {
      this.lastError = `保存设置失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async getNumber(key: string, defaultValue: number): Promise<number> {
    try {
      const p = await this.prefsInstance();
      const value = await p.get(key, defaultValue);
      if (typeof value === 'number') {
        return value as number;
      }
      if (typeof value === 'string') {
        const parsed = Number.parseFloat(value as string);
        return Number.isNaN(parsed) ? defaultValue : parsed;
      }
      return defaultValue;
    } catch (e) {
      return defaultValue;
    }
  }

  async putNumber(key: string, value: number): Promise<void> {
    try {
      const p = await this.prefsInstance();
      await p.put(key, value);
      await p.flush();
    } catch (e) {
      this.lastError = `保存设置失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async getBool(key: string, defaultValue: boolean): Promise<boolean> {
    try {
      const p = await this.prefsInstance();
      const value = await p.get(key, defaultValue);
      if (typeof value === 'boolean') {
        return value as boolean;
      }
      if (typeof value === 'string') {
        const text = (value as string).toLowerCase();
        if (text === 'true' || text === '1') {
          return true;
        }
        if (text === 'false' || text === '0') {
          return false;
        }
      }
      if (typeof value === 'number') {
        return (value as number) !== 0;
      }
      return defaultValue;
    } catch (e) {
      return defaultValue;
    }
  }

  async putBool(key: string, value: boolean): Promise<void> {
    try {
      const p = await this.prefsInstance();
      await p.put(key, value);
      await p.flush();
    } catch (e) {
      this.lastError = `保存设置失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }

  async remove(key: string): Promise<void> {
    try {
      const p = await this.prefsInstance();
      await p.delete(key);
      await p.flush();
    } catch (e) {
      this.lastError = `删除设置失败：${(e as Error).message}`;
      throw new Error(this.lastError);
    }
  }
}
