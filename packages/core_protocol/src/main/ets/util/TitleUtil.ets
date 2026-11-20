/**
 * 会话标题的本地兜底生成（纯逻辑，零平台依赖）。
 *
 * 优先使用 DeepSeek 服务端下发的 `response.title`（通过 title_generated 事件），
 * 没有时由本函数从首条用户提问里截取，保证 UI 永远有可读标题。
 */

/** 标题最大长度（字符数，中文 16 字已能表达完整意图）。 */
const MAX_TITLE_LENGTH: number = 16;

/** 去掉 Markdown 标记、代码围栏与多余空白。 */
export function sanitizeTitleText(text: string): string {
  if (text === undefined || text === null) {
    return '';
  }
  let out: string = text;
  // 代码围栏整体丢弃（避免标题里出现三反引号与代码）
  out = out.split('```').join(' ');
  out = out.split('\r').join('\n');
  const lines: string[] = out.split('\n');
  let cleaned: string = '';
  for (const line of lines) {
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      continue;
    }
    cleaned = cleaned.length === 0 ? trimmed : `${cleaned} ${trimmed}`;
    if (cleaned.length >= MAX_TITLE_LENGTH * 2) {
      break;
    }
  }
  // 常见 Markdown 符号与无意义前缀
  const symbols: string[] = ['#', '>', '*', '`', '~', '-', '|', '[', ']', '(', ')'];
  for (const symbol of symbols) {
    cleaned = cleaned.split(symbol).join(' ');
  }
  // 压缩连续空白
  while (cleaned.indexOf('  ') >= 0) {
    cleaned = cleaned.split('  ').join(' ');
  }
  cleaned = cleaned.trim();
  // 去掉开头的标点
  while (cleaned.length > 0 && isLeadingPunctuation(cleaned.charAt(0))) {
    cleaned = cleaned.substring(1).trim();
  }
  return cleaned;
}

/** 是否为无意义的开头标点。 */
function isLeadingPunctuation(ch: string): boolean {
  return ch === '，' || ch === '。' || ch === '、' || ch === '：' || ch === '；' || ch === ','
    || ch === '.' || ch === ':' || ch === ';' || ch === '!' || ch === '?' || ch === '！' || ch === '？';
}

/** 截断到指定字符数，超出补省略号。 */
export function truncateTitle(text: string, maxLength: number): string {
  if (text === undefined || text === null) {
    return '';
  }
  const trimmed: string = text.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return trimmed.substring(0, maxLength) + '…';
}

/**
 * 本地标题：先取首条用户提问的第一句，取不到再用助手回答开头。
 * 极端情况下返回「新的对话」。
 */
export function buildLocalTitle(firstUserText: string, assistantText: string): string {
  const userPart: string = sanitizeTitleText(firstUserText);
  if (userPart.length > 0) {
    // 只在第一句足够长时才按句号截断，否则保留整句
    const sentence: string = firstSentence(userPart);
    return truncateTitle(sentence, MAX_TITLE_LENGTH);
  }
  const assistantPart: string = sanitizeTitleText(assistantText);
  if (assistantPart.length > 0) {
    return truncateTitle(assistantPart, MAX_TITLE_LENGTH);
  }
  return '新的对话';
}

/** 取第一个句子（句末标点后即停）。 */
function firstSentence(text: string): string {
  const stops: string[] = ['。', '！', '？', '!', '?', '\n'];
  let end: number = text.length;
  for (const stop of stops) {
    const index: number = text.indexOf(stop);
    if (index > 0 && index < end) {
      end = index;
    }
  }
  const sentence: string = text.substring(0, end).trim();
  return sentence.length > 0 ? sentence : text;
}
