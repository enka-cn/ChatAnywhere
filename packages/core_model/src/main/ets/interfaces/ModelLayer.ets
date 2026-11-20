/**
 * 数据层装配契约：入口 HAP 通过 createModelLayer(context) 一次性拿到全部数据能力。
 */
import { Context } from '@kit.AbilityKit';
import { RdbRepositoryApi } from './RepositoryApi';
import { SecretApi } from './SecretApi';
import { SessionExporterApi } from './ExportApi';
import { TrajectoryApi } from './TrajectoryApi';

/** 初始化选项。 */
export interface ModelLayerOptions {
  dbName?: string;
  /** 导出目录（默认 context.filesDir + '/exports'）。 */
  exportDir?: string;
}

/** 数据层门面。 */
export interface ModelLayer {
  /** RDB 仓库：会话 / 节点 / 检索 / 技能 / 设置。 */
  repo: RdbRepositoryApi;
  /** 轨迹树（分支切换 + 活动路径 + 最终化）。 */
  trajectory: TrajectoryApi;
  /** 密钥保管（Asset Store Kit）。 */
  secrets: SecretApi;
  /** 导入导出。 */
  exporter: SessionExporterApi;
}

/** 初始化数据库并返回数据层。失败时抛错（由 AppServices 展示中文引导）。 */
export type CreateModelLayer = (context: Context, options?: ModelLayerOptions) => Promise<ModelLayer>;
