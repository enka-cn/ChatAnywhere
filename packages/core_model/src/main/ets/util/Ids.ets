/**
 * ID 生成（纯函数，零平台依赖）。
 */

let counter: number = 0;

/** 生成带前缀的短 id：`<prefix>_<base36 time>_<counter><rand>`。 */
export function newId(prefix: string): string {
  counter = (counter + 1) % 100000;
  const t = Date.now().toString(36);
  const rand = Math.floor(Math.random() * 100000).toString(36);
  return `${prefix}_${t}_${counter.toString(36)}${rand}`;
}

/** 会话 id。 */
export function newSessionId(): string {
  return newId('ses');
}

/** 节点 id。 */
export function newNodeId(): string {
  return newId('nd');
}

/** item id。 */
export function newItemId(): string {
  return newId('it');
}

/** 幂等键（一次发送内）。 */
export function newRunId(): string {
  return newId('run');
}
