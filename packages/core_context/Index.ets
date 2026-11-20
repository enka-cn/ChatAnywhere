/**
 * core_context 公开 API（冻结契约）。
 *
 * - 契约：interfaces/*.ets 中的类型与接口（跨模块只能从这里 import）
 * - 实现：CacheAwareCompactor（缓存感知压缩）、PromptAssembler（四层提示词装配）
 * - 预设：PromptPresets（内置中文基座与角色）
 */
export {
  CompactionTrigger, CompactionPolicy, CompactorInput, CompactionDecision, CompactionOutcome, TextSummarizer
} from './src/main/ets/interfaces/CompactionTypes';

export {
  PromptSkillSnippet, PromptAssemblyInput, PromptSegment, PromptAssemblyResult, PersonaPreset
} from './src/main/ets/interfaces/PromptTypes';

export {
  CompactorApi, PromptAssemblerApi, ContextLayer, CreateContextLayer, SkillSnippetSorter
} from './src/main/ets/interfaces/ContextLayer';

export { createContextLayer } from './src/main/ets/ContextLayerFactory';

export { CacheAwareCompactor } from './src/main/ets/CacheAwareCompactor';

export { PromptAssembler, sortSkillSnippets } from './src/main/ets/PromptAssembler';

export {
  BASE_PROMPT, CLIPBOARD_RULE, DEEP_THINKING_RULE, DEFAULT_PERSONA_ID, MEMORY_SUMMARY_PREFIX, PERSONAS,
  USER_NAME_RULE, WEB_ENABLED_RULE
} from './src/main/ets/PromptPresets';
