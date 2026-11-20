/**
 * 页面路由契约（Lead 维护；UI 队友按此跳转，避免字符串写错）。
 */
export class RouteUrls {
  static readonly CHAT: string = 'pages/ChatPage';
  static readonly SKILL_CREATOR: string = 'pages/SkillCreatorPage';
  static readonly SKILL_MANAGER: string = 'pages/SkillManagerPage';
  static readonly SETTINGS: string = 'pages/SettingsPage';
}

/** 打开对话页参数。 */
export interface ChatPageParams {
  sessionId: string;
  /** 可选的初始输入（如从分享链接进入时预填）。 */
  draftText?: string;
}

/** 技能创造室参数。 */
export interface SkillCreatorParams {
  /** 空串表示新建技能。 */
  targetSkillId: string;
  /** 非空表示从某条对话「沉淀为技能」。 */
  nodeId: string;
}

/** 技能管理参数。 */
export interface SkillManagerParams {
  /** 可选：直接展开某技能详情。 */
  openSkillId: string;
}

/** 设置页参数。 */
export interface SettingsPageParams {
  /** 'first_run' 表示首次引导进入。 */
  from: string;
  /** v3：直接打开某个设置分类（personas / models / memory / sync）。 */
  category?: string;
}

/** 从 router.getParams() 安全提取。 */
export function asChatParams(raw: Object | undefined): ChatPageParams {
  if (raw === undefined || raw === null) {
    return { sessionId: '' };
  }
  const rec = raw as Record<string, Object>;
  const sessionId = rec['sessionId'];
  const draftText = rec['draftText'];
  return {
    sessionId: typeof sessionId === 'string' ? sessionId as string : '',
    draftText: typeof draftText === 'string' ? draftText as string : undefined
  };
}
