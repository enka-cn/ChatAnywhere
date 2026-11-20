/**
 * 数据层装配：打开 RDB、建表、构造仓库 / 轨迹 / 密钥 / 导出器。
 *
 * 初始化顺序（任一必需步骤失败都抛带中文信息的 Error，由 AppServices 转成提示条，
 * 绝不让应用白屏崩溃）：
 * 1. RdbRepository.init()：getRdbStore → 幂等建表 → 探测 FTS5（失败降级 LIKE）→ Preferences；
 * 2. TrajectoryStore：内存索引 + 分支逻辑，复用同一个仓库实例；
 * 3. AssetSecretStore：密钥读写全部走 Asset Store Kit，构造期无平台副作用；
 * 4. SessionExporter：ZIP 导入导出，导出目录默认 context.filesDir/exports。
 *
 * 注意：AssetStoreKit 不在启动时强制探测 —— 无权限/无锁屏密码时不应阻塞对话主流程，
 * 只有在真正保存/读取密钥时才给出中文提示。
 */
import { Context } from '@kit.AbilityKit';
import { CreateModelLayer, ModelLayer, ModelLayerOptions } from './interfaces/ModelLayer';
import { RdbRepository } from './impl/RdbRepository';
import { AssetSecretStore } from './impl/AssetSecretStore';
import { SessionExporter } from './impl/SessionExporter';
import { TrajectoryStore } from './TrajectoryStore';

/** 默认数据库文件名。 */
const DEFAULT_DB_NAME: string = 'chatanywhere.db';

export const createModelLayer: CreateModelLayer = async (
  context: Context,
  options?: ModelLayerOptions
): Promise<ModelLayer> => {
  if (context === null || context === undefined) {
    throw new Error('数据层初始化失败：缺少应用上下文');
  }
  const dbName = options !== undefined && options.dbName !== undefined && options.dbName.length > 0
    ? options.dbName
    : DEFAULT_DB_NAME;
  const repo = new RdbRepository(context, dbName);
  try {
    await repo.init();
  } catch (e) {
    const reason = (e as Error).message;
    throw new Error(`本地数据库初始化失败：${reason}`);
  }

  const trajectory = new TrajectoryStore(repo, repo);
  const secrets = new AssetSecretStore();
  const exporter = new SessionExporter(
    context,
    repo,
    repo,
    options === undefined ? undefined : options.exportDir
  );

  const layer: ModelLayer = {
    repo: repo,
    trajectory: trajectory,
    secrets: secrets,
    exporter: exporter
  };
  return layer;
};
