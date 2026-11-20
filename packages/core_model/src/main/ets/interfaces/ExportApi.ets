/**
 * 会话导入导出契约（兼容 chat-demo 的 ZIP 结构，Blueprint Milestone 5）。
 */
import { SessionMeta } from './ModelTypes';

/** 导出结果：文件位于应用沙箱，fileName 供分享使用。 */
export interface ExportResult {
  fileName: string;
  filePath: string;
  bytes: number;
  sessionCount: number;
}

/** 导入结果。 */
export interface ImportResult {
  sessions: SessionMeta[];
  skipped: number;
  warnings: string[];
}

export interface SessionExporterApi {
  /** 导出单会话为 ZIP（含 manifest.json + nodes.jsonl）。 */
  exportSession(sessionId: string): Promise<ExportResult>;

  /** 导出全部会话。 */
  exportAll(): Promise<ExportResult>;

  /** 导入 ZIP（不覆盖已有会话，冲突时改标题追加）。 */
  importZip(zipPath: string): Promise<ImportResult>;

  /** 导出目录（应用沙箱内的 exports/），供 UI 展示与分享。 */
  exportDir(): string;
}
