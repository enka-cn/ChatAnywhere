/**
 * 密钥保管契约：所有 API Key / MCP Token 只能进 HarmonyOS Asset Store Kit。
 * 明文禁止写入 Preferences / RDB / 日志。
 */
export interface SecretApi {
  /** 保存（存在则先删除再新增，保证幂等）。alias 必须稳定，如 'deepseek.apiKey'。 */
  put(alias: string, secret: string): Promise<void>;

  /** 读取；不存在返回 null（禁止抛错污染调用方）。 */
  get(alias: string): Promise<string | null>;

  remove(alias: string): Promise<void>;

  has(alias: string): Promise<boolean>;

  /** 列出已保存的别名（不含明文），用于设置页展示"已配置"。 */
  listAliases(): Promise<string[]>;
}
