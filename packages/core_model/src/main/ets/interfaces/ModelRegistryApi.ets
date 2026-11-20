/**
 * 真实厂商模型注册表（RDB 落盘，v3.2）。
 *
 * 设计原则：**不再内置占位模型**。模型只能由用户在设置页对真实端点执行
 * 「测试连接 / 拉取模型」后写入本表；只有 `enabled = true` 的模型会出现在
 * 对话页顶栏与角色默认模型选择器中。
 */
export interface ProviderModelRecord {
  providerId: string;
  modelId: string;
  /** 展示名（优先用上游返回的 display_name / id）。 */
  displayName: string;
  /** 上游原始信息 JSON（可选，便于诊断）。 */
  metaJson: string;
  /** 用户是否勾选启用。 */
  enabled: boolean;
  /** 发现时间（ms）。 */
  discoveredAt: number;
}

export interface ModelRegistryApi {
  /** 用一次探测结果整体替换某厂商的模型清单（保留已有启用状态）。 */
  saveDiscoveredModels(providerId: string, records: ProviderModelRecord[]): Promise<void>;

  /** 全量读取（含未启用）。 */
  loadModels(): Promise<ProviderModelRecord[]>;

  /** 勾选/取消勾选某个模型。 */
  setModelEnabled(providerId: string, modelId: string, enabled: boolean): Promise<void>;

  /** 清空某厂商的模型（切换端点 / 重置时用）。 */
  removeProviderModels(providerId: string): Promise<void>;
}
