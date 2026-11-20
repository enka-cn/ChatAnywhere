/**
 * 轻量动态 JSON 工具（纯逻辑，零平台依赖，便于 QA 用 Node 直接跑）。
 *
 * 为什么不直接复用 core_model 的 JsonUtil：
 * 本模块被 SseParser / 各厂商事件解析器引用，这些解析器要求"零依赖"，
 * 不能 import `@app/core_model`（Node 逻辑测试不会解析跨包别名）。
 *
 * ArkTS 约束：禁止 Record 对象字面量，动态 map 一律先 `JSON.parse('{}') as Record<...>` 再逐项赋值。
 */

/** 空 object map（可安全 set 后交给 JSON.stringify）。 */
export function newObjectRecord(): Record<string, Object> {
  return JSON.parse('{}') as Record<string, Object>;
}

/** 判断一个 Object 是否为"普通对象"（非 null、非数组）。 */
export function isPlainObject(value: Object): boolean {
  if (value === null || value === undefined) {
    return false;
  }
  if (typeof value !== 'object') {
    return false;
  }
  return !Array.isArray(value);
}

/** 把任意 Object 安全转成 Record（失败返回 null）。 */
export function asRecord(value: Object): Record<string, Object> | null {
  if (!isPlainObject(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

/** 安全读取 string 字段。 */
export function getStr(rec: Record<string, Object> | null, key: string, defaultValue: string): string {
  if (rec === null) {
    return defaultValue;
  }
  const v: Object = rec[key];
  if (typeof v === 'string') {
    return v as string;
  }
  return defaultValue;
}

/** 安全读取 number 字段（兼容数字字符串）。 */
export function getNum(rec: Record<string, Object> | null, key: string, defaultValue: number): number {
  if (rec === null) {
    return defaultValue;
  }
  const v: Object = rec[key];
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    const parsed: number = Number.parseFloat(v as string);
    if (!Number.isNaN(parsed)) {
      return parsed;
    }
  }
  return defaultValue;
}

/** 安全读取 boolean 字段。 */
export function getBool(rec: Record<string, Object> | null, key: string, defaultValue: boolean): boolean {
  if (rec === null) {
    return defaultValue;
  }
  const v: Object = rec[key];
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  return defaultValue;
}

/** 安全读取子对象。 */
export function getObj(rec: Record<string, Object> | null, key: string): Record<string, Object> | null {
  if (rec === null) {
    return null;
  }
  return asRecord(rec[key]);
}

/** 安全读取子对象数组。 */
export function getObjList(rec: Record<string, Object> | null, key: string): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  if (rec === null) {
    return out;
  }
  const v: Object = rec[key];
  if (!Array.isArray(v)) {
    return out;
  }
  const arr: Object[] = v as Object[];
  for (const one of arr) {
    const item: Record<string, Object> | null = asRecord(one);
    if (item !== null) {
      out.push(item);
    }
  }
  return out;
}

/** 安全读取字符串数组。 */
export function getStrList(rec: Record<string, Object> | null, key: string): string[] {
  const out: string[] = [];
  if (rec === null) {
    return out;
  }
  const v: Object = rec[key];
  if (!Array.isArray(v)) {
    return out;
  }
  const arr: Object[] = v as Object[];
  for (const one of arr) {
    if (typeof one === 'string') {
      out.push(one as string);
    }
  }
  return out;
}

/** 字段存在且非 null（用于区分"未提供"与"空字符串"）。 */
export function hasField(rec: Record<string, Object> | null, key: string): boolean {
  if (rec === null) {
    return false;
  }
  return rec[key] !== undefined && rec[key] !== null;
}

/** 把 JSON 文本解析为 Record（失败返回 null，绝不抛错）。 */
export function parseRecord(json: string): Record<string, Object> | null {
  if (json === undefined || json === null) {
    return null;
  }
  const text: string = json.trim();
  if (text.length === 0) {
    return null;
  }
  try {
    const parsed: Object = JSON.parse(text) as Object;
    return asRecord(parsed);
  } catch (e) {
    return null;
  }
}

/** 把 Record 序列化为紧凑 JSON；失败返回空串。 */
export function stringifyRecord(rec: Record<string, Object>): string {
  try {
    return JSON.stringify(rec);
  } catch (e) {
    return '';
  }
}
