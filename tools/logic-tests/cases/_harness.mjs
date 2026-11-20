/**
 * 极简测试 harness（只用 Node 内置 node:assert）。
 *
 * 约定：
 *  - 每个 *.test.mjs 末尾调用 summarize()；
 *  - 输出 `PASS <中文测试名>` / `FAIL <中文测试名>` / `SKIP <中文测试名> :: 原因`；
 *  - 最后输出一行机器可读的 `SUMMARY passed=N failed=M skipped=K`，
 *    由 run.ps1 汇总（所以即使某用例文件在 import 阶段就崩，run.ps1 也能识别为文件级失败）。
 */
import assert from 'node:assert/strict';

const state = { passed: 0, failed: 0, skipped: 0, failures: [] };

export { assert };

function indent(text) {
  return String(text).split('\n').map((line) => '  ' + line).join('\n');
}

function formatError(err) {
  if (!err) return '未知错误';
  const message = err.message ? String(err.message) : String(err);
  const stack = err.stack ? String(err.stack).split('\n').slice(1, 4).join('\n') : '';
  return stack ? message + '\n' + stack : message;
}

/** 同步用例。 */
export function test(name, fn) {
  try {
    const ret = fn();
    if (ret && typeof ret.then === 'function') {
      throw new Error('异步用例请使用 testAsync()');
    }
    state.passed += 1;
    console.log(`PASS ${name}`);
  } catch (err) {
    state.failed += 1;
    state.failures.push({ name, err });
    console.log(`FAIL ${name}`);
    console.log(indent(formatError(err)));
  }
}

/** 异步用例。 */
export async function testAsync(name, fn) {
  try {
    await fn();
    state.passed += 1;
    console.log(`PASS ${name}`);
  } catch (err) {
    state.failed += 1;
    state.failures.push({ name, err });
    console.log(`FAIL ${name}`);
    console.log(indent(formatError(err)));
  }
}

/** 跳过一条用例（被测文件尚未实现 / 依赖平台，记录原因，不隐藏）。 */
export function skip(name, reason) {
  state.skipped += 1;
  console.log(`SKIP ${name}${reason ? ' :: ' + reason : ''}`);
}

/** 文件级跳过：整份构建产物缺失时使用，然后 summarize。 */
export function skipFile(reason) {
  state.skipped += 1;
  console.log(`SKIP (整份用例) :: ${reason}`);
}

/** 输出汇总行；失败时让进程退出码非 0（run.ps1 仍以 SUMMARY 为准）。 */
export function summarize() {
  console.log(`SUMMARY passed=${state.passed} failed=${state.failed} skipped=${state.skipped}`);
  if (state.failed > 0) {
    process.exitCode = 1;
  }
}
