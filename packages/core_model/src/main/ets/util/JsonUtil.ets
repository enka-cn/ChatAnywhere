/**
 * 动态 JSON 工具（纯函数，零平台依赖）。
 *
 * ArkTS 禁止 Record 对象字面量（arkts-no-untyped-obj-literals），
 * 因此动态 map 统一从这里构造，再逐项赋值。
 */

/** 空 string map（可安全 set 后交给 JSON.stringify）。 */
export function newStringRecord(): Record<string, string> {
  return JSON.parse('{}') as Record<string, string>;
}

/** 空 Object map。 */
export function newObjectRecord(): Record<string, Object> {
  return JSON.parse('{}') as Record<string, Object>;
}

/** 空 number map。 */
export function newNumberRecord(): Record<string, number> {
  return JSON.parse('{}') as Record<string, number>;
}

/** 安全读取 string。 */
export function getString(rec: Record<string, Object>, key: string, defaultValue: string): string {
  if (rec === undefined || rec === null) {
    return defaultValue;
  }
  const v: Object = rec[key];
  if (typeof v === 'string') {
    return v as string;
  }
  return defaultValue;
}

/** 安全读取 number（兼容 JSON 里的数字/字符串数字）。 */
export function getNumber(rec: Record<string, Object>, key: string, defaultValue: number): number {
  if (rec === undefined || rec === null) {
    return defaultValue;
  }
  const v: Object = rec[key];
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    const parsed = Number.parseFloat(v as string);
    return Number.isNaN(parsed) ? defaultValue : parsed;
  }
  return defaultValue;
}

/** 安全读取 boolean。 */
export function getBool(rec: Record<string, Object>, key: string, defaultValue: boolean): boolean {
  if (rec === undefined || rec === null) {
    return defaultValue;
  }
  const v: Object = rec[key];
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  return defaultValue;
}

/** 安全读取字符串数组。 */
export function getStringList(rec: Record<string, Object>, key: string): string[] {
  const out: string[] = [];
  if (rec === undefined || rec === null) {
    return out;
  }
  const v: Object = rec[key];
  if (Array.isArray(v)) {
    const arr = v as Object[];
    for (const one of arr) {
      if (typeof one === 'string') {
        out.push(one as string);
      }
    }
  }
  return out;
}

/** 安全读取子对象。 */
export function getRecord(rec: Record<string, Object>, key: string): Record<string, Object> | null {
  if (rec === undefined || rec === null) {
    return null;
  }
  const v: Object = rec[key];
  if (typeof v === 'object' && v !== null && !Array.isArray(v)) {
    return v as Record<string, Object>;
  }
  return null;
}

/** 安全读取子对象数组。 */
export function getRecordList(rec: Record<string, Object>, key: string): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  if (rec === undefined || rec === null) {
    return out;
  }
  const v: Object = rec[key];
  if (Array.isArray(v)) {
    const arr = v as Object[];
    for (const one of arr) {
      if (typeof one === 'object' && one !== null && !Array.isArray(one)) {
        out.push(one as Record<string, Object>);
      }
    }
  }
  return out;
}

/** 从 Record 中挑出存在的键（用于构造请求体时跳过 undefined）。 */
export function hasKey(rec: Record<string, Object>, key: string): boolean {
  return rec !== undefined && rec !== null && rec[key] !== undefined && rec[key] !== null;
}
