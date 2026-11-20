/**
 * 包内扩展能力接口（不在冻结契约内，仅供 core_model 内部装配使用）。
 *
 * ArkTS 不支持结构化类型（arkts-no-structural-typing），实现类必须显式 `implements`，
 * 因此把「RdbRepository 额外提供的两项落盘能力」单独声明，避免在工厂里做鸭子类型传参。
 */
import { SessionMeta } from '../interfaces/ModelTypes';

/**
 * 会话根分支的持久化。
 * 根节点没有父节点可挂 activeChildId，所以根的选择单独存 sessions.active_root_id；
 * TrajectoryStore 冷启动时用它恢复「用户上次选的是哪一条开头」。
 */
export interface RootBranchStore {
  getActiveRootChildId(sessionId: string): Promise<string | null>;
  setActiveRootChildId(sessionId: string, childId: string): Promise<void>;
}

/**
 * 会话元信息按归档原 id 落盘（导入用）。
 * SessionRepositoryApi 只有 createSession（总是生成新 id），而导入需要保留原 id。
 */
export interface SessionArchiveStore {
  upsertSession(meta: SessionMeta): Promise<void>;
}
