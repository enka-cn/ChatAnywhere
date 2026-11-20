/**
 * 轻量 JSON 读取/构造工具（纯函数，零平台依赖，可直接用于 Node 逻辑测试）。
 *
 * ArkTS 限制（docs/DEV_GUIDE.md §2）：
 * - 禁止 `Record` 对象字面量 → 动态 map 统一 `JSON.parse('{}') as Record<string, Object>` 后逐项赋值；
 * - 禁止 `for...in` → 遍历用 `Object.keys`。
 */

/** 空 string map。 */
export function emptyRecord(): Record<string, Object> {
  return JSON.parse('{}') as Record<string, Object>;
}

/** 判断是否普通 JSON 对象（排除 null 与数组）。 */
export function isRecordValue(value: Object | null | undefined): boolean {
  if (value === null || value === undefined) {
    return false;
  }
  return typeof value === 'object' && !Array.isArray(value);
}

/** 把任意值收敛为 Record（不是对象时返回 null）。 */
export function asRecord(value: Object | null | undefined): Record<string, Object> | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, Object>;
  }
  return null;
}

/** 解析 JSON 文本为 Record；空串/非法/非对象一律返回 null。 */
export function parseRecord(json: string): Record<string, Object> | null {
  if (json === null || json === undefined) {
    return null;
  }
  const text: string = json.trim();
  if (text.length === 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(text) as Object;
    return asRecord(parsed);
  } catch (e) {
    return null;
  }
}

/** 解析 JSON 文本为数组；失败返回空数组。 */
export function parseObjectArray(json: string): Object[] {
  if (json === null || json === undefined) {
    return [];
  }
  const text: string = json.trim();
  if (text.length === 0) {
    return [];
  }
  try {
    const parsed = JSON.parse(text) as Object;
    if (Array.isArray(parsed)) {
      return parsed as Object[];
    }
    return [];
  } catch (e) {
    return [];
  }
}

/** 解析 JSON 文本为字符串数组；失败返回空数组。 */
export function parseStringArray(json: string): string[] {
  const out: string[] = [];
  if (json === null || json === undefined) {
    return out;
  }
  const text: string = json.trim();
  if (text.length === 0) {
    return out;
  }
  try {
    const parsed = JSON.parse(text) as Object;
    if (Array.isArray(parsed)) {
      const arr = parsed as Object[];
      for (const one of arr) {
        if (typeof one === 'string') {
          out.push(one as string);
        }
      }
    }
  } catch (e) {
    return out;
  }
  return out;
}

/** 安全读取字符串。 */
export function getString(rec: Record<string, Object>, key: string, defaultValue: string): string {
  if (rec === null || rec === undefined) {
    return defaultValue;
  }
  const value: Object = rec[key];
  if (typeof value === 'string') {
    return value as string;
  }
  return defaultValue;
}

/** 安全读取数字（兼容字符串数字）。 */
export function getNumber(rec: Record<string, Object>, key: string, defaultValue: number): number {
  if (rec === null || rec === undefined) {
    return defaultValue;
  }
  const value: Object = rec[key];
  if (typeof value === 'number') {
    return value as number;
  }
  if (typeof value === 'string') {
    const parsed: number = Number.parseFloat(value as string);
    return Number.isNaN(parsed) ? defaultValue : parsed;
  }
  return defaultValue;
}

/** 安全读取布尔值。 */
export function getBool(rec: Record<string, Object>, key: string, defaultValue: boolean): boolean {
  if (rec === null || rec === undefined) {
    return defaultValue;
  }
  const value: Object = rec[key];
  if (typeof value === 'boolean') {
    return value as boolean;
  }
  return defaultValue;
}

/** 安全读取字符串数组。 */
export function getStringList(rec: Record<string, Object>, key: string): string[] {
  const out: string[] = [];
  if (rec === null || rec === undefined) {
    return out;
  }
  const value: Object = rec[key];
  if (Array.isArray(value)) {
    const arr = value as Object[];
    for (const one of arr) {
      if (typeof one === 'string') {
        out.push(one as string);
      }
    }
  }
  return out;
}

/** 安全读取子对象。 */
export function getObject(rec: Record<string, Object>, key: string): Record<string, Object> | null {
  if (rec === null || rec === undefined) {
    return null;
  }
  return asRecord(rec[key]);
}

/** 安全读取子对象数组。 */
export function getObjectList(rec: Record<string, Object>, key: string): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  if (rec === null || rec === undefined) {
    return out;
  }
  const value: Object = rec[key];
  if (Array.isArray(value)) {
    const arr = value as Object[];
    for (const one of arr) {
      const sub = asRecord(one);
      if (sub !== null) {
        out.push(sub);
      }
    }
  }
  return out;
}

/** 键是否存在且非 null/undefined。 */
export function hasValue(rec: Record<string, Object>, key: string): boolean {
  if (rec === null || rec === undefined) {
    return false;
  }
  return rec[key] !== undefined && rec[key] !== null;
}

/** 写入字符串。 */
export function putString(rec: Record<string, Object>, key: string, value: string): void {
  rec[key] = value;
}

/** 写入数字。 */
export function putNumber(rec: Record<string, Object>, key: string, value: number): void {
  rec[key] = value;
}

/** 写入布尔。 */
export function putBool(rec: Record<string, Object>, key: string, value: boolean): void {
  rec[key] = value;
}

/** 写入任意 JSON 值（数组/对象/原始值）。 */
export function putValue(rec: Record<string, Object>, key: string, value: Object): void {
  rec[key] = value;
}

/** 把 JSON 值序列化（失败返回空串）。 */
export function toJsonText(value: Object): string {
  try {
    return JSON.stringify(value);
  } catch (e) {
    return '';
  }
}

/** 把 JSON 值序列化为紧凑字符串（null 返回 'null'）。 */
export function valueToText(value: Object | null | undefined): string {
  if (value === null || value === undefined) {
    return '';
  }
  if (typeof value === 'string') {
    return value as string;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return `${value}`;
  }
  const text = toJsonText(value);
  return text;
}

/** 值的显示文本（用于 Diff / 日志）：字符串原样、数组逗号连接、对象截断 JSON。 */
export function displayValue(value: Object | null | undefined, maxLen: number): string {
  if (value === null || value === undefined) {
    return '（空）';
  }
  if (typeof value === 'string') {
    return truncateText(value as string, maxLen);
  }
  if (typeof value === 'boolean' || typeof value === 'number') {
    return `${value}`;
  }
  if (Array.isArray(value)) {
    const arr = value as Object[];
    const parts: string[] = [];
    for (const one of arr) {
      parts.push(displayValue(one, maxLen));
    }
    return parts.length === 0 ? '（空列表）' : parts.join('、');
  }
  return truncateText(toJsonText(value), maxLen);
}

/** 截断文本并追加省略提示。 */
export function truncateText(text: string, maxLen: number): string {
  if (text === null || text === undefined) {
    return '';
  }
  const value = text as string;
  if (maxLen <= 0 || value.length <= maxLen) {
    return value;
  }
  return value.substring(0, maxLen) + '…（已截断）';
}

/** 判断文本是否是合法 JSON。 */
export function isValidJsonText(text: string): boolean {
  if (text === null || text === undefined) {
    return false;
  }
  const trimmed = (text as string).trim();
  if (trimmed.length === 0) {
    return false;
  }
  try {
    JSON.parse(trimmed);
    return true;
  } catch (e) {
    return false;
  }
}

/** 解析任意 JSON 值为 Object（空串/非法返回 null）。 */
export function parseJsonValueText(text: string): Object | null {
  if (text === null || text === undefined) {
    return null;
  }
  const trimmed: string = (text as string).trim();
  if (trimmed.length === 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(trimmed) as Object;
    return parsed === undefined ? null : parsed;
  } catch (e) {
    return null;
  }
}

/** 数值范围收敛。 */
export function clampNumber(value: number, min: number, max: number): number {
  if (Number.isNaN(value)) {
    return min;
  }
  if (value < min) {
    return min;
  }
  if (value > max) {
    return max;
  }
  return value;
}

/** 精确到整数的范围收敛。 */
export function clampInt(value: number, min: number, max: number): number {
  return Math.floor(clampNumber(value, min, max));
}
