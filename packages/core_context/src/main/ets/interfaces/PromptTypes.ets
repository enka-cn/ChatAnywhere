/**
 * 四层提示词装配契约（Blueprint §3.3；顺序固定 → KV Cache 前缀字节稳定）。
 *
 * 装配顺序（严禁运行时随机排序）：
 *   1) base     基础规则 / 当前日期 / 输出格式 / 联网状态
 *   2) persona  当前角色提示词
 *   3) skill    已装技能的提示词片段（按 skillId 字典序）
 *   4) memory   记忆摘要 + FTS5 回捞片段（按相关度降序）
 */

/** 技能提示词片段（由 core_plugin 提供，已按 skillId 排序）。 */
export interface PromptSkillSnippet {
  skillId: string;
  name: string;
  snippet: string;
}

/** 装配输入。 */
export interface PromptAssemblyInput {
  /** 基础规则覆盖（为空用内置中文基座）。 */
  systemBase?: string;
  personaPrompt?: string;
  skillSnippets: PromptSkillSnippet[];
  /** 压缩产生的记忆摘要。 */
  memorySummary?: string;
  /** FTS5 回捞的早期细节片段。 */
  retrievedMemories?: string[];
  /** 当前模型中文名。 */
  modelLabel?: string;
  userName?: string;
  /** 剪贴板内容（仅当用户显式开启模板变量时注入）。 */
  clipboard?: string;
  /** 当前时间戳 ms（便于测试传固定值）。 */
  now?: number;
  /** 本轮是否开启联网（影响基座中的联网行为约定）。 */
  webEnabled?: boolean;
  /** 本轮是否开启深度思考。 */
  deepThinking?: boolean;
}

/** 装配片段（便于调试与「提示词工坊」展示）。 */
export interface PromptSegment {
  layer: 'base' | 'persona' | 'skill' | 'memory';
  /** skill 层为 skillId，其余为固定标识。 */
  id: string;
  content: string;
}

/** 装配结果。 */
export interface PromptAssemblyResult {
  /** 最终 system prompt（四层用分隔线拼接）。 */
  systemPrompt: string;
  segments: PromptSegment[];
}

/** 内置角色。 */
export interface PersonaPreset {
  id: string;
  /** 直白中文名，如「严谨研究员」。 */
  name: string;
  /** 一句话说明。 */
  description: string;
  prompt: string;
}
