/**
 * 非敏感设置键常量（Preferences key）。密钥一律走 SecretApi。
 */
export class SettingsKeys {
  static readonly ACTIVE_PROVIDER: string = 'chat.activeProvider';
  static readonly ACTIVE_MODEL: string = 'chat.activeModel';
  /** 'quick' | 'deep' | 'off'：快速 / 深度思考 / 关闭思考 */
  static readonly THINKING_LEVEL: string = 'chat.thinkingLevel';
  /** 'off' | 'server_managed' | 'standalone_clean' */
  static readonly WEB_MODE: string = 'chat.webMode';
  static readonly PERSONA_ID: string = 'chat.personaId';
  static readonly PERSONA_PROMPT: string = 'chat.personaPrompt';
  /** 用户自定义厂商端点（OpenAI 兼容）。 */
  static readonly CUSTOM_BASE_URL: string = 'provider.custom.baseUrl';
  static readonly CUSTOM_MODEL_ID: string = 'provider.custom.modelId';
  static readonly ANTHROPIC_BASE_URL: string = 'provider.anthropic.baseUrl';
  /** 记忆压缩策略：'auto' | 'aggressive' | 'off' */
  static readonly COMPACTION_POLICY: string = 'chat.compactionPolicy';
  static readonly LAN_EDITOR_LAST_PORT: string = 'lan.lastPort';
  static readonly LAST_SESSION_ID: string = 'chat.lastSessionId';
  static readonly USER_NAME: string = 'chat.userName';
}

/** Secret alias 常量。 */
export class SecretAliases {
  static readonly DEEPSEEK: string = 'deepseek.apiKey';
  static readonly ANTHROPIC: string = 'anthropic.apiKey';
  static readonly OPENAI_COMPAT: string = 'openaiCompat.apiKey';
  static readonly MCP_DEFAULT_TOKEN: string = 'mcp.defaultToken';
}
