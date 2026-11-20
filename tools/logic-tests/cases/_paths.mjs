/**
 * 用例侧的路径/加载辅助：所有被测模块都从 prepare.ps1 生成的 build/ 里加载。
 *
 * 被测源码每次由 prepare.ps1 重新生成，用例文件本身不 import .ets（Node 不认 .ets，
 * 且 .ets 里未改写过的类型 import 会在运行时炸）。
 */
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

/** tools/logic-tests/build */
export const BUILD_DIR = path.resolve(here, '..', 'build');
/** 仓库根 */
export const REPO_DIR = path.resolve(here, '..', '..', '..');

/**
 * 尝试加载 build/ 下的 .ts 产物。
 * @param {string} relPath 相对 build/ 的路径，如 'packages/core_model/src/main/ets/util/Tokens.ts'
 * @returns {Promise<any|null>} 文件不存在返回 null（用例据此 skip 并记录原因）
 */
export async function tryImport(relPath) {
  const full = path.join(BUILD_DIR, relPath);
  if (!existsSync(full)) {
    return null;
  }
  return import(pathToFileURL(full).href);
}

/** 构建产物缺失时的统一跳过原因文案。 */
export function missingReason(relPath) {
  const shown = relPath.split(path.sep).join('/');
  return `构建产物缺失 build/${shown}（源码尚未实现，或 prepare.ps1 判定依赖平台已跳过）`;
}

/** 断言「值在范围内」的常用小工具（保持用例可读）。 */
export function assertBetween(actual, min, max, label) {
  if (!(actual >= min && actual <= max)) {
    throw new Error(`${label || '值'} 应在 [${min}, ${max}] 内，实际 ${actual}`);
  }
}
