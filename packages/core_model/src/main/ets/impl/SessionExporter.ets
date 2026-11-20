/**
 * 会话导入导出实现（ZIP）。
 *
 * 归档结构（对齐 Blueprint Milestone 5 与 chat-demo 的「manifest + 分会话文件」思路）：
 * ```
 * manifest.json                              # { format, version, export_format_version, exportedAt, sessions }
 * sessions/<sessionId>/nodes.jsonl           # 每行一个 ConversationNode（JSON）—— 本项目导入的主格式
 * chat_session_index.json                    # chat-demo v3 兼容索引（额外写出）
 * chat_sessions/<sessionId>.json             # chat-demo v3 兼容会话文件（额外写出）
 * ```
 * 导入规则：
 * - 包内有 nodes.jsonl → 走本项目格式（最高保真）；
 * - 否则若含 chat_session_index.json / chat_sessions/*.json → 走 chat-demo v3 兼容映射（只读，生成本地新会话）；
 * - 不覆盖已有会话；坏行/坏片段跳过并写入 warnings，绝不因一条数据损坏整包失败；
 * - ZIP 解压失败抛带中文原因的 Error（UI 提示用户换文件）。
 *
 * 平台 API：`@ohos.zlib`（compressFile / decompressFile）、`@ohos.file.fs`
 * （见 docs/API_REFERENCE.md；zlib 目录压缩默认 keepTopLevelFolder=false）。
 */
import { Context } from '@kit.AbilityKit';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConversationNode, SessionMeta } from '../interfaces/ModelTypes';
import { ExportResult, ImportResult, SessionExporterApi } from '../interfaces/ExportApi';
import { RdbRepositoryApi } from '../interfaces/RepositoryApi';
import {
  nodeFromJson,
  nodePreview,
  nodeToJson,
  RawSessionMeta,
  sessionMetaFromRaw,
  splitJsonLines
} from '../util/NodeCodec';
import {
  ChatDemoIndexEntry,
  ChatDemoSession,
  chatDemoSessionToNodes,
  nodesToChatDemoIndexEntry,
  nodesToChatDemoSession
} from '../util/ChatDemoCodec';
import { newNodeId, newSessionId } from '../util/Ids';
import { SessionArchiveStore } from './InternalStoreInterfaces';

const DOMAIN: number = 0x1A2B;
const TAG: string = 'SessionExporter';

const MANIFEST_FILE: string = 'manifest.json';
const SESSIONS_DIR: string = 'sessions';
const NODES_FILE: string = 'nodes.jsonl';
const ARCHIVE_FORMAT: string = 'chatanywhere-session-archive';
const ARCHIVE_VERSION: number = 1;
/** chat-demo v3 兼容结构的目录/文件名与版本号。 */
const CHAT_DEMO_SESSIONS_DIR: string = 'chat_sessions';
const CHAT_DEMO_INDEX_FILE: string = 'chat_session_index.json';
const CHAT_DEMO_FORMAT_VERSION: number = 3;

/** 扫描目录的最大深度（防止异常压缩包造成无限递归）。 */
const MAX_SCAN_DEPTH: number = 6;

/** 导入时单个会话最多导入的节点数（保护内存）。 */
const MAX_NODES_PER_SESSION: number = 50000;

/** 归档清单（写）。 */
interface ArchiveManifest {
  format: string;
  version: number;
  /** 同时满足 chat-demo v3 清单要求（官方客户端只读取 export_format_version）。 */
  export_format_version: number;
  exportedAt: number;
  sessions: SessionMeta[];
}

/** 归档清单（读，全部可选以便容错）。 */
interface RawArchiveManifest {
  format?: string;
  version?: number;
  exportedAt?: number;
  sessions?: RawSessionMeta[];
}

/** 把任意 id 变成安全的单层目录名。 */
function safeSegment(value: string): string {
  const cleaned = value.replace(/[\\/:*?"<>|\s]+/g, '_');
  if (cleaned.length === 0) {
    return 'session';
  }
  return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
}

/** 两位补零。 */
function twoDigits(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

export class SessionExporter implements SessionExporterApi {
  private readonly context: Context;
  private readonly repo: RdbRepositoryApi;
  private readonly archive: SessionArchiveStore;
  private readonly exportPath: string;
  private seq: number = 0;

  constructor(
    context: Context,
    repo: RdbRepositoryApi,
    archive: SessionArchiveStore,
    exportDirPath?: string
  ) {
    this.context = context;
    this.repo = repo;
    this.archive = archive;
    this.exportPath = exportDirPath !== undefined && exportDirPath.length > 0
      ? exportDirPath
      : `${context.filesDir}/exports`;
  }

  /** 导出目录（应用沙箱内的 exports/）。 */
  exportDir(): string {
    return this.exportPath;
  }

  // ---------------------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------------------

  async exportSession(sessionId: string): Promise<ExportResult> {
    const meta = await this.repo.getSession(sessionId);
    if (meta === null) {
      throw new Error('导出失败：找不到这个会话，可能已被删除');
    }
    const nodes = await this.repo.loadSessionNodes(sessionId);
    const sessions: SessionMeta[] = [meta];
    const nodeLists: ConversationNode[][] = [nodes];
    return this.writeArchive(sessions, nodeLists);
  }

  async exportAll(): Promise<ExportResult> {
    const sessions = await this.repo.listSessions(10000);
    if (sessions.length === 0) {
      throw new Error('导出失败：本地还没有任何会话');
    }
    const nodeLists: ConversationNode[][] = [];
    for (const meta of sessions) {
      nodeLists.push(await this.repo.loadSessionNodes(meta.sessionId));
    }
    return this.writeArchive(sessions, nodeLists);
  }

  /** 写临时目录 → zlib 打包 → 统计大小；临时目录在 finally 中清理。 */
  private async writeArchive(
    sessions: SessionMeta[],
    nodeLists: ConversationNode[][]
  ): Promise<ExportResult> {
    this.ensureDir(this.exportPath);
    const stage = `${this.context.cacheDir}/ca_export_${Date.now()}_${this.nextSeq()}`;
    this.ensureDir(stage);
    try {
      const manifest: ArchiveManifest = {
        format: ARCHIVE_FORMAT,
        version: ARCHIVE_VERSION,
        export_format_version: CHAT_DEMO_FORMAT_VERSION,
        exportedAt: Date.now(),
        sessions: sessions
      };
      this.writeTextFile(`${stage}/${MANIFEST_FILE}`, JSON.stringify(manifest));
      for (let i = 0; i < sessions.length; i++) {
        const dir = `${stage}/${SESSIONS_DIR}/${safeSegment(sessions[i].sessionId)}`;
        this.ensureDir(dir);
        const lines: string[] = [];
        for (const node of nodeLists[i]) {
          lines.push(nodeToJson(node));
        }
        this.writeTextFile(`${dir}/${NODES_FILE}`, lines.join('\n'));
      }
      // ---- chat-demo v3 兼容结构（额外写出，官方 chat-demo 可直接读取；本项目导入仍以 nodes.jsonl 为主） ----
      const chatSessionsDir = `${stage}/${CHAT_DEMO_SESSIONS_DIR}`;
      this.ensureDir(chatSessionsDir);
      const indexEntries: ChatDemoIndexEntry[] = [];
      for (let i = 0; i < sessions.length; i++) {
        const meta = sessions[i];
        let activeLeafId: string | null = null;
        try {
          activeLeafId = await this.repo.getActiveLeafId(meta.sessionId);
        } catch (e) {
          activeLeafId = null;
          hilog.warn(DOMAIN, TAG, 'getActiveLeafId failed for export: %{public}s', (e as Error).message);
        }
        const chatSession = nodesToChatDemoSession(meta, nodeLists[i], activeLeafId);
        this.writeTextFile(
          `${chatSessionsDir}/${safeSegment(meta.sessionId)}.json`,
          JSON.stringify(chatSession)
        );
        indexEntries.push(nodesToChatDemoIndexEntry(meta, nodeLists[i].length));
      }
      this.writeTextFile(`${stage}/${CHAT_DEMO_INDEX_FILE}`, JSON.stringify(indexEntries));
      const fileName = this.buildFileName();
      const zipPath = `${this.exportPath}/${fileName}`;
      const options: zlib.Options = {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
      };
      await zlib.compressFile(stage, zipPath, options);
      const bytes = this.fileSize(zipPath);
      hilog.info(DOMAIN, TAG, 'export ok sessions=%{public}d bytes=%{public}d', sessions.length, bytes);
      const result: ExportResult = {
        fileName: fileName,
        filePath: zipPath,
        bytes: bytes,
        sessionCount: sessions.length
      };
      return result;
    } catch (e) {
      this.lastExportError = `导出失败：${(e as Error).message}。请确认手机存储空间充足后重试。`;
      throw new Error(this.lastExportError);
    } finally {
      this.removeDirQuietly(stage);
    }
  }

  /** 最近一次导出失败原因（诊断用，空串表示正常）。 */
  lastExportError: string = '';

  // ---------------------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------------------

  async importZip(zipPath: string): Promise<ImportResult> {
    if (zipPath === undefined || zipPath === null || zipPath.trim().length === 0) {
      throw new Error('导入失败：没有选择文件');
    }
    if (!this.exists(zipPath)) {
      throw new Error('导入失败：找不到这个压缩包，请重新选择文件');
    }
    const stage = `${this.context.cacheDir}/ca_import_${Date.now()}_${this.nextSeq()}`;
    this.ensureDir(stage);
    const warnings: string[] = [];
    let skipped: number = 0;
    const imported: SessionMeta[] = [];
    try {
      const options: zlib.Options = {};
      try {
        await zlib.decompressFile(zipPath, stage, options);
      } catch (e) {
        throw new Error(
          `导入失败：压缩包无法解析（${(e as Error).message}）。请确认是 ChatAnyWhere 导出的 ZIP 文件。`
        );
      }
      const manifestMap = this.loadManifest(stage, warnings);
      const nodeFiles = this.collectFiles(stage, NODES_FILE, 0);
      if (nodeFiles.length === 0) {
        // 没有本应用格式的会话文件 → 尝试 chat-demo v3 兼容导入（只读、生成本地新会话）
        const chatDemo = await this.importChatDemoArchive(stage, warnings);
        if (chatDemo !== null) {
          return chatDemo;
        }
        warnings.push('压缩包内没有找到可识别的会话数据（既没有 nodes.jsonl，也没有 chat-demo 会话文件）');
        const empty: ImportResult = { sessions: imported, skipped: skipped, warnings: warnings };
        return empty;
      }
      for (const file of nodeFiles) {
        const fileName = file;
        try {
          const outcome = await this.importOneFile(fileName, manifestMap, warnings);
          skipped += outcome.skipped;
          if (outcome.meta !== null) {
            imported.push(outcome.meta);
          }
        } catch (e) {
          skipped += 1;
          warnings.push(`有一个会话导入失败：${(e as Error).message}`);
          hilog.error(DOMAIN, TAG, 'import file failed: %{public}s', (e as Error).message);
        }
      }
      hilog.info(DOMAIN, TAG, 'import ok sessions=%{public}d skipped=%{public}d', imported.length, skipped);
      const result: ImportResult = {
        sessions: imported,
        skipped: skipped,
        warnings: warnings
      };
      return result;
    } finally {
      this.removeDirQuietly(stage);
    }
  }

  // ---------------------------------------------------------------------------
  // chat-demo v3 兼容导入
  // ---------------------------------------------------------------------------

  /**
   * chat-demo v3 归档导入：`chat_sessions/<id>.json` → 本地新会话。
   * 始终生成新 sessionId（不覆盖本地数据），标题追加「（导入）」。
   * 返回 null 表示压缩包里没有 chat-demo 会话文件。
   */
  private async importChatDemoArchive(
    stage: string,
    warnings: string[]
  ): Promise<ImportResult | null> {
    const sessionFiles = this.collectChatDemoSessionFiles(stage);
    if (sessionFiles.length === 0) {
      return null;
    }
    warnings.push('检测到 chat-demo 归档格式，已按兼容规则导入：对话文本/思考/联网来源尽量保留，'
      + '图片原件、思考签名细节与部分状态字段不保留');
    const indexMap = this.loadChatDemoIndex(stage, warnings);
    const imported: SessionMeta[] = [];
    let skipped: number = 0;
    for (const file of sessionFiles) {
      try {
        const text = fileIo.readTextSync(file);
        const raw = JSON.parse(text) as ChatDemoSession;
        if (raw === null || raw === undefined) {
          skipped += 1;
          warnings.push('有一个 chat-demo 会话文件内容为空，已跳过');
          continue;
        }
        const targetSessionId = newSessionId();
        const nodes = chatDemoSessionToNodes(raw, targetSessionId, warnings);
        if (nodes.length === 0) {
          skipped += 1;
          warnings.push('有一个 chat-demo 会话没有任何消息，已跳过');
          continue;
        }
        const title = `${this.chatDemoTitle(raw, indexMap, nodes)}（导入）`;
        const createdAt = this.chatDemoCreatedAt(raw, nodes);
        const totalTokens = this.sumTokens(nodes);
        const meta: SessionMeta = {
          sessionId: targetSessionId,
          title: title,
          createdAt: createdAt,
          updatedAt: Date.now(),
          pinned: false,
          nodeCount: nodes.length,
          totalTokens: totalTokens
        };
        await this.archive.upsertSession(meta);
        for (const node of nodes) {
          await this.repo.saveNode(node);
        }
        await this.repo.touchSession(targetSessionId);
        imported.push(meta);
        hilog.info(DOMAIN, TAG, 'chat-demo session imported nodes=%{public}d', nodes.length);
      } catch (e) {
        skipped += 1;
        warnings.push(`有一个 chat-demo 会话导入失败：${(e as Error).message}`);
        hilog.error(DOMAIN, TAG, 'chat-demo import failed: %{public}s', (e as Error).message);
      }
    }
    const result: ImportResult = {
      sessions: imported,
      skipped: skipped,
      warnings: warnings
    };
    return result;
  }

  /** chat-demo 会话标题：会话字段 → 索引字段 → 首条用户消息预览。 */
  private chatDemoTitle(
    raw: ChatDemoSession,
    indexMap: Map<string, ChatDemoIndexEntry>,
    nodes: ConversationNode[]
  ): string {
    const rawTitle = raw.title ?? '';
    if (rawTitle.trim().length > 0) {
      return rawTitle.trim();
    }
    const id = raw.id;
    if (id !== undefined && id !== null && id.length > 0) {
      const entry = indexMap.get(id);
      if (entry !== undefined) {
        const indexTitle = entry.title ?? '';
        if (indexTitle.trim().length > 0) {
          return indexTitle.trim();
        }
      }
    }
    for (const node of nodes) {
      if (node.role === 'user') {
        const preview = nodePreview(node);
        if (preview.length > 0) {
          return preview.length > 24 ? preview.substring(0, 24) : preview;
        }
      }
    }
    return '导入的会话';
  }

  /** chat-demo 会话创建时间：取最早消息时间，缺失用当前时间。 */
  private chatDemoCreatedAt(raw: ChatDemoSession, nodes: ConversationNode[]): number {
    let created: number = 0;
    for (const node of nodes) {
      if (node.createdAt > 0 && (created === 0 || node.createdAt < created)) {
        created = node.createdAt;
      }
    }
    return created > 0 ? created : Date.now();
  }

  /** 读取 chat_session_index.json（缺失/损坏都不影响导入）。 */
  private loadChatDemoIndex(stage: string, warnings: string[]): Map<string, ChatDemoIndexEntry> {
    const map: Map<string, ChatDemoIndexEntry> = new Map<string, ChatDemoIndexEntry>();
    const files = this.collectFiles(stage, CHAT_DEMO_INDEX_FILE, 0);
    if (files.length === 0) {
      return map;
    }
    try {
      const text = fileIo.readTextSync(files[0]);
      const list = JSON.parse(text) as ChatDemoIndexEntry[];
      if (Array.isArray(list)) {
        for (const entry of list) {
          const id = entry.id;
          if (id !== undefined && id !== null && id.length > 0) {
            map.set(id, entry);
          }
        }
      }
    } catch (e) {
      warnings.push(`chat-demo 会话索引解析失败，已按会话文件本身导入（${(e as Error).message}）`);
    }
    return map;
  }

  /** 收集 chat_sessions/ 目录下的 .json 会话文件（兼容 zip 顶层带目录的情况）。 */
  private collectChatDemoSessionFiles(root: string): string[] {
    const allJson = this.collectFilesBySuffix(root, '.json', 0);
    const out: string[] = [];
    for (const file of allJson) {
      const normalized = file.replace(/\\/g, '/');
      const marker = `/${CHAT_DEMO_SESSIONS_DIR}/`;
      if (normalized.indexOf(marker) >= 0) {
        out.push(file);
      }
    }
    return out;
  }

  /** 单个 nodes.jsonl 的导入结果。 */
  private async importOneFile(
    filePath: string,
    manifestMap: Map<string, SessionMeta>,
    warnings: string[]
  ): Promise<ImportFileOutcome> {
    let text: string = '';
    try {
      text = fileIo.readTextSync(filePath);
    } catch (e) {
      throw new Error(`读取会话文件失败（${(e as Error).message}）`);
    }
    const lines = splitJsonLines(text);
    const parsed: ConversationNode[] = [];
    let badLines: number = 0;
    for (const line of lines) {
      const node = nodeFromJson(line);
      if (node === null) {
        badLines += 1;
        continue;
      }
      parsed.push(node);
      if (parsed.length >= MAX_NODES_PER_SESSION) {
        warnings.push('单个会话消息过多，只导入了前 5 万条');
        break;
      }
    }
    const outcome: ImportFileOutcome = { meta: null, skipped: badLines };
    if (parsed.length === 0) {
      if (badLines > 0) {
        warnings.push('有一段会话数据全部损坏，已跳过（原文件未改动）');
      }
      return outcome;
    }
    // 归档里的 sessionId：优先用节点自带的，其次用目录名。
    const originalSessionId = parsed[0].sessionId.length > 0
      ? parsed[0].sessionId
      : this.guessSessionIdFromPath(filePath);
    let manifestMeta = manifestMap.get(originalSessionId);
    if (manifestMeta === undefined && parsed[0].sessionId.length > 0) {
      manifestMeta = manifestMap.get(parsed[0].sessionId);
    }
    const derived = this.deriveMeta(originalSessionId, manifestMeta, parsed);

    const existing = await this.repo.getSession(derived.sessionId);
    const conflict = existing !== null;
    const targetSessionId = conflict ? newSessionId() : derived.sessionId;
    const title = conflict ? `${derived.title}（导入）` : derived.title;
    this.repairParents(parsed, warnings);
    this.remapNodes(parsed, targetSessionId, conflict);

    const totalTokens = this.sumTokens(parsed);
    const finalMeta: SessionMeta = {
      sessionId: targetSessionId,
      title: title,
      createdAt: derived.createdAt,
      updatedAt: Date.now(),
      pinned: false,
      nodeCount: parsed.length,
      totalTokens: totalTokens
    };
    if (derived.modelId !== undefined) {
      finalMeta.modelId = derived.modelId;
    }
    if (derived.providerId !== undefined) {
      finalMeta.providerId = derived.providerId;
    }
    await this.archive.upsertSession(finalMeta);
    for (const node of parsed) {
      await this.repo.saveNode(node);
    }
    await this.repo.touchSession(targetSessionId);
    outcome.meta = finalMeta;
    return outcome;
  }

  /** 会话元信息：manifest 优先，缺失则从节点推断。 */
  private deriveMeta(
    sessionId: string,
    manifestMeta: SessionMeta | undefined,
    nodes: ConversationNode[]
  ): SessionMeta {
    if (manifestMeta !== undefined) {
      return manifestMeta;
    }
    let createdAt = nodes[0].createdAt;
    let title = '';
    for (const node of nodes) {
      if (node.createdAt > 0 && (createdAt <= 0 || node.createdAt < createdAt)) {
        createdAt = node.createdAt;
      }
      if (title.length === 0 && node.role === 'user') {
        const preview = nodePreview(node);
        if (preview.length > 0) {
          title = preview.length > 24 ? preview.substring(0, 24) : preview;
        }
      }
    }
    const meta: SessionMeta = {
      sessionId: sessionId,
      title: title.length > 0 ? title : '导入的会话',
      createdAt: createdAt > 0 ? createdAt : Date.now(),
      updatedAt: Date.now(),
      pinned: false
    };
    if (nodes[0].modelId !== undefined) {
      meta.modelId = nodes[0].modelId;
    }
    if (nodes[0].providerId !== undefined) {
      meta.providerId = nodes[0].providerId;
    }
    return meta;
  }

  /**
   * 修复孤立父引用：父节点不在本文件里的节点提升为根，避免树断链导致整段不可见。
   */
  private repairParents(nodes: ConversationNode[], warnings: string[]): void {
    const ids: Set<string> = new Set<string>();
    for (const node of nodes) {
      ids.add(node.nodeId);
    }
    let repaired: number = 0;
    for (const node of nodes) {
      if (node.parentId !== null && node.parentId.length > 0 && !ids.has(node.parentId)) {
        node.parentId = null;
        repaired += 1;
      }
      if (node.parentId !== null && node.parentId === node.nodeId) {
        node.parentId = null;
        repaired += 1;
      }
    }
    if (repaired > 0) {
      warnings.push(`有 ${repaired} 条消息的上级已缺失，已提升为独立开头（内容不受影响）`);
    }
  }

  /** 冲突导入时重映射节点 id 与父引用；非冲突只统一 sessionId。 */
  private remapNodes(nodes: ConversationNode[], targetSessionId: string, regenerateIds: boolean): void {
    if (!regenerateIds) {
      for (const node of nodes) {
        node.sessionId = targetSessionId;
      }
      return;
    }
    const idMap: Map<string, string> = new Map<string, string>();
    for (const node of nodes) {
      idMap.set(node.nodeId, newNodeId());
    }
    for (const node of nodes) {
      const oldParent = node.parentId;
      const oldActiveChild = node.activeChildId;
      const mappedId = idMap.get(node.nodeId);
      node.nodeId = mappedId === undefined ? node.nodeId : mappedId;
      node.sessionId = targetSessionId;
      if (oldParent === null) {
        node.parentId = null;
      } else {
        const mappedParent = idMap.get(oldParent);
        node.parentId = mappedParent === undefined ? null : mappedParent;
      }
      if (oldActiveChild !== undefined) {
        const mappedChild = idMap.get(oldActiveChild);
        if (mappedChild !== undefined) {
          node.activeChildId = mappedChild;
        }
      }
    }
  }

  private sumTokens(nodes: ConversationNode[]): number {
    let total: number = 0;
    for (const node of nodes) {
      total += node.tokenEstimate > 0 ? node.tokenEstimate : 0;
    }
    return total;
  }

  private guessSessionIdFromPath(filePath: string): string {
    const normalized = filePath.replace(/\\/g, '/');
    const segments = normalized.split('/');
    for (let i = segments.length - 1; i >= 0; i--) {
      const seg = segments[i];
      if (seg.length > 0 && seg !== NODES_FILE) {
        return seg;
      }
    }
    return newSessionId();
  }

  /** 读取 manifest.json（可能因 keepTopLevelFolder 而在子目录里）。 */
  private loadManifest(stage: string, warnings: string[]): Map<string, SessionMeta> {
    const result: Map<string, SessionMeta> = new Map<string, SessionMeta>();
    const files = this.collectFiles(stage, MANIFEST_FILE, 0);
    if (files.length === 0) {
      warnings.push('压缩包缺少 manifest.json，已按目录结构推断会话信息');
      return result;
    }
    try {
      const text = fileIo.readTextSync(files[0]);
      const raw = JSON.parse(text) as RawArchiveManifest;
      const list: RawSessionMeta[] = raw.sessions === undefined || raw.sessions === null ? [] : raw.sessions;
      for (const item of list) {
        const meta = sessionMetaFromRaw(item);
        if (meta !== null) {
          result.set(meta.sessionId, meta);
        }
      }
    } catch (e) {
      warnings.push(`manifest.json 解析失败，已按目录结构推断会话信息（${(e as Error).message}）`);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 文件系统小工具
  // ---------------------------------------------------------------------------

  private nextSeq(): number {
    this.seq = (this.seq + 1) % 100000;
    return this.seq;
  }

  private buildFileName(): string {
    const now = new Date();
    const stamp = `${now.getFullYear()}${twoDigits(now.getMonth() + 1)}${twoDigits(now.getDate())}-`
      + `${twoDigits(now.getHours())}${twoDigits(now.getMinutes())}${twoDigits(now.getSeconds())}`;
    return `chatanywhere-${stamp}-${this.nextSeq()}.zip`;
  }

  private exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  private ensureDir(path: string): void {
    if (this.exists(path)) {
      return;
    }
    try {
      fileIo.mkdirSync(path, true);
    } catch (e) {
      throw new Error(`创建目录失败（${(e as Error).message}）`);
    }
  }

  private writeTextFile(path: string, text: string): void {
    const file = fileIo.openSync(
      path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private fileSize(path: string): number {
    try {
      return fileIo.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }

  private removeDirQuietly(path: string): void {
    try {
      if (this.exists(path)) {
        fileIo.rmdirSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cleanup failed: %{public}s', (e as Error).message);
    }
  }

  /** 递归收集文件名匹配的文件（深度受限）。 */
  private collectFiles(root: string, fileName: string, depth: number): string[] {
    const out: string[] = [];
    if (depth > MAX_SCAN_DEPTH) {
      return out;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(root);
    } catch (e) {
      return out;
    }
    for (const name of names) {
      const full = `${root}/${name}`;
      let isDir: boolean = false;
      try {
        isDir = fileIo.statSync(full).isDirectory();
      } catch (e) {
        continue;
      }
      if (isDir) {
        const nested = this.collectFiles(full, fileName, depth + 1);
        for (const item of nested) {
          out.push(item);
        }
      } else if (name === fileName) {
        out.push(full);
      }
    }
    return out;
  }

  /** 递归收集指定后缀的文件（深度受限；用于 chat-demo 的 chat_sessions/*.json）。 */
  private collectFilesBySuffix(root: string, suffix: string, depth: number): string[] {
    const out: string[] = [];
    if (depth > MAX_SCAN_DEPTH) {
      return out;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(root);
    } catch (e) {
      return out;
    }
    for (const name of names) {
      const full = `${root}/${name}`;
      let isDir: boolean = false;
      try {
        isDir = fileIo.statSync(full).isDirectory();
      } catch (e) {
        continue;
      }
      if (isDir) {
        const nested = this.collectFilesBySuffix(full, suffix, depth + 1);
        for (const item of nested) {
          out.push(item);
        }
      } else if (suffix.length > 0 && name.length >= suffix.length &&
        name.substring(name.length - suffix.length) === suffix) {
        out.push(full);
      }
    }
    return out;
  }
}

/** 单个文件导入结果（内部使用）。 */
interface ImportFileOutcome {
  meta: SessionMeta | null;
  skipped: number;
}
