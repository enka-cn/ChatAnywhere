/**
 * 四层提示词装配器（Blueprint §3.3）。
 *
 * 装配顺序固定，严禁运行时随机排序（前缀字节稳定才能真正命中 KV Cache）：
 *   1) base     基础规则 / 当前日期 / 联网与思考状态
 *   2) persona  当前角色提示词
 *   3) skill    已装技能的提示词片段（按 skillId 字典序）
 *   4) memory   记忆摘要 + FTS5 回捞片段（按传入顺序）
 *
 * 本文件不允许 import 任何 @kit.*，可被 Node 逻辑测试直接运行。
 */
import { PersonaPreset, PromptAssemblyInput, PromptAssemblyResult, PromptSegment, PromptSkillSnippet } from './interfaces/PromptTypes';
import { PromptAssemblerApi } from './interfaces/ContextLayer';
import {
  BASE_PROMPT, CLIPBOARD_RULE, DEEP_THINKING_RULE, MEMORY_SUMMARY_PREFIX, PERSONAS, USER_NAME_RULE, WEB_ENABLED_RULE
} from './PromptPresets';

/** 四层之间的固定分隔线（改动它等于让所有缓存失效，别动）。 */
const LAYER_SEPARATOR: string = '\n\n---\n\n';

/** 两位补零。 */
function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 本地日期 `YYYY-MM-DD`。 */
function formatDate(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

/** 本地时间 `HH:mm`。 */
function formatTime(date: Date): string {
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

/** 中文星期。 */
function formatWeekday(date: Date): string {
  const weekdays: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
  return weekdays[date.getDay()];
}

/** 把一个模板变量替换成值（不用正则与 replaceAll，保证 ArkTS 与 Node 行为一致）。 */
function replaceToken(text: string, token: string, value: string): string {
  if (text.indexOf(token) < 0) {
    return text;
  }
  return text.split(token).join(value);
}

/**
 * 技能片段排序：只按 skillId 字典序，同 id 保持传入顺序（排序稳定）。
 * 单独导出，方便 UI 与协议层复用同一套规则。
 */
export function sortSkillSnippets(snippets: PromptSkillSnippet[]): PromptSkillSnippet[] {
  const sorted: PromptSkillSnippet[] = snippets.slice();
  sorted.sort((a: PromptSkillSnippet, b: PromptSkillSnippet): number => {
    if (a.skillId < b.skillId) {
      return -1;
    }
    if (a.skillId > b.skillId) {
      return 1;
    }
    return 0;
  });
  return sorted;
}

/**
 * 提示词装配器。
 * 无状态、无平台依赖；同样输入必然得到逐字节一致的结果。
 */
export class PromptAssembler implements PromptAssemblerApi {
  /**
   * 按 base → persona → skill（字典序）→ memory 的固定顺序装配最终 system prompt。
   *
   * @param input 装配输入；未传 systemBase 时使用内置中文基座
   */
  assemble(input: PromptAssemblyInput): PromptAssemblyResult {
    const segments: PromptSegment[] = [];

    // 1) base：内置基座（或调用方覆盖），再叠加本轮联网 / 深度思考的行为约定。
    const customBase: string = input.systemBase ?? '';
    const baseTemplate: string = customBase.trim().length > 0 ? customBase : BASE_PROMPT;
    let baseContent: string = this.renderTemplate(baseTemplate, input);
    if (input.webEnabled === true) {
      baseContent = `${baseContent}\n${WEB_ENABLED_RULE}`;
    }
    if (input.deepThinking === true) {
      baseContent = `${baseContent}\n${DEEP_THINKING_RULE}`;
    }
    const baseSegment: PromptSegment = {
      layer: 'base',
      id: 'base',
      content: baseContent
    };
    segments.push(baseSegment);

    const userName: string = input.userName ?? '';
    if (userName.trim().length > 0) {
      const userNameSegment: PromptSegment = {
        layer: 'base',
        id: 'user_name',
        content: this.renderTemplate(USER_NAME_RULE, input)
      };
      segments.push(userNameSegment);
    }

    // 剪贴板只在用户显式传入且非空时注入，避免平时把无关内容塞给模型。
    const clipboard: string = input.clipboard ?? '';
    if (clipboard.trim().length > 0) {
      const clipboardSegment: PromptSegment = {
        layer: 'base',
        id: 'clipboard',
        content: `${CLIPBOARD_RULE}\n${clipboard}`
      };
      segments.push(clipboardSegment);
    }

    // 2) persona：当前角色提示词。
    const personaPrompt: string = input.personaPrompt ?? '';
    if (personaPrompt.trim().length > 0) {
      const personaSegment: PromptSegment = {
        layer: 'persona',
        id: 'persona',
        content: this.renderTemplate(personaPrompt, input)
      };
      segments.push(personaSegment);
    }

    // 3) skill：按 skillId 字典序固定排列，顺序变了缓存就废了。
    const sortedSkills: PromptSkillSnippet[] = sortSkillSnippets(input.skillSnippets);
    for (const snippet of sortedSkills) {
      if (snippet.snippet.trim().length === 0) {
        continue;
      }
      const skillSegment: PromptSegment = {
        layer: 'skill',
        id: snippet.skillId,
        content: `技能「${snippet.name}」的使用要点：\n${this.renderTemplate(snippet.snippet, input)}`
      };
      segments.push(skillSegment);
    }

    // 4) memory：先放压缩摘要，再按传入顺序放 FTS5 回捞片段。
    const memorySummary: string = input.memorySummary ?? '';
    if (memorySummary.trim().length > 0) {
      const memorySegment: PromptSegment = {
        layer: 'memory',
        id: 'memory_summary',
        content: `${MEMORY_SUMMARY_PREFIX}\n${this.renderTemplate(memorySummary, input)}`
      };
      segments.push(memorySegment);
    }
    const retrievedMemories: string[] = input.retrievedMemories ?? [];
    let recallIndex: number = 0;
    for (const memory of retrievedMemories) {
      if (memory.trim().length === 0) {
        continue;
      }
      recallIndex += 1;
      const recallSegment: PromptSegment = {
        layer: 'memory',
        id: `memory_${recallIndex}`,
        content: `更早聊到的第 ${recallIndex} 段（可能相关）：\n${this.renderTemplate(memory, input)}`
      };
      segments.push(recallSegment);
    }

    const parts: string[] = [];
    for (const segment of segments) {
      parts.push(segment.content);
    }
    const result: PromptAssemblyResult = {
      systemPrompt: parts.join(LAYER_SEPARATOR),
      segments: segments
    };
    return result;
  }

  /**
   * 替换模板变量：`{{date}}` `{{time}}` `{{weekday}}` `{{model}}` `{{user}}` `{{clipboard}}`。
   * 未知变量原样保留（不抛错），方便技能片段里保留自己的占位写法。
   *
   * @param template 含变量的模板文本
   * @param input 变量取值来源；now 不传时用当前时间
   */
  renderTemplate(template: string, input: PromptAssemblyInput): string {
    const nowMs: number = input.now ?? Date.now();
    const date: Date = new Date(nowMs);
    const modelRaw: string = input.modelLabel ?? '';
    const modelLabel: string = modelRaw.trim().length > 0 ? modelRaw : '当前模型';
    const userRaw: string = input.userName ?? '';
    const clipboardRaw: string = input.clipboard ?? '';
    let text: string = template;
    text = replaceToken(text, '{{date}}', formatDate(date));
    text = replaceToken(text, '{{time}}', formatTime(date));
    text = replaceToken(text, '{{weekday}}', formatWeekday(date));
    text = replaceToken(text, '{{model}}', modelLabel);
    text = replaceToken(text, '{{user}}', userRaw);
    text = replaceToken(text, '{{clipboard}}', clipboardRaw);
    return text;
  }

  /** 内置角色列表（返回副本，避免调用方改到内置常量）。 */
  personas(): PersonaPreset[] {
    return PERSONAS.slice();
  }

  /** 按 id 取角色，找不到返回 null。 */
  persona(id: string): PersonaPreset | null {
    for (const preset of PERSONAS) {
      if (preset.id === id) {
        return preset;
      }
    }
    return null;
  }
}
