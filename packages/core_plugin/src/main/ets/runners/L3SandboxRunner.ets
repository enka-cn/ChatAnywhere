/**
 * L3 端侧脚本沙箱执行器（接口 / 权限白名单 / 校验完整，执行后端按能力降级）。
 *
 * 取舍（已登记 docs/DEV_GUIDE.md §7）：当前构建未集成 QuickJS-NG NAPI 运行时，
 * 因此执行时返回**明确的中文错误**，绝不静默失败或假装成功。
 * 校验与权限模型保持完整，后续接入 native_core 时只需替换 `execute` 后端。
 */
import { DryRunReport, SkillManifest, ToolExecutionResult } from '../interfaces/SkillManifest';
import { validateQuickJsCode } from '../SkillSchema';
import { findInvalidDomain } from '../util/DomainUtil';
import { parseRecord, truncateText } from '../util/JsonLite';
import { ToolRunner } from './ToolRunner';

/** L3 脚本执行器（每个挂载实例对应一个技能）。 */
export class L3SandboxRunner implements ToolRunner {
  /** 当前构建的统一降级文案（UI 直接展示，禁止静默失败）。 */
  static readonly NOT_ENABLED_MESSAGE: string =
    '当前构建未启用端侧脚本沙箱（QuickJS-NG 未集成），该脚本技能暂时无法运行。请改用 L1 声明式或 L2 远程服务技能。';

  private readonly manifest: SkillManifest;

  constructor(manifest: SkillManifest) {
    this.manifest = manifest;
  }

  /** 静态校验脚本与权限白名单（返回中文错误，空串表示通过）。 */
  validate(): string {
    const code: string = this.manifest.runtimePayload.quickJsCode === undefined
      ? '' : (this.manifest.runtimePayload.quickJsCode as string);
    const codeError: string = validateQuickJsCode(code);
    if (codeError.length > 0) {
      return codeError;
    }
    const domains: string[] = this.manifest.runtimePayload.allowedDomains;
    const invalidDomain: string = findInvalidDomain(domains);
    if (invalidDomain.length > 0) {
      return `脚本技能的域名白名单「${invalidDomain}」不合法。`;
    }
    return '';
  }

  /** 生成安全告警（给管理页/创造的 Diff 卡片展示）。 */
  static buildSecurityWarnings(manifest: SkillManifest): string[] {
    const warnings: string[] = [];
    warnings.push('当前构建未启用端侧脚本沙箱，该技能可以保存但暂时不能运行。');
    const domains: string[] = manifest.runtimePayload.allowedDomains;
    if (domains.length > 0) {
      warnings.push(`脚本声明的网络白名单：${domains.join('、')}（沙箱未启用时不会真正发起网络请求）。`);
    }
    const code: string = manifest.runtimePayload.quickJsCode === undefined
      ? '' : (manifest.runtimePayload.quickJsCode as string);
    if (code.length > 0) {
      warnings.push(`脚本长度 ${code.length} 字，执行前会再做一次静态权限校验。`);
    }
    return warnings;
  }

  /** 执行（当前一律返回明确降级文案）。 */
  async execute(argumentsJson: string): Promise<ToolExecutionResult> {
    const startedAt: number = Date.now();
    let input: string = argumentsJson === null || argumentsJson === undefined ? '{}' : argumentsJson.trim();
    if (input.length === 0) {
      input = '{}';
    }
    if (parseRecord(input) === null) {
      return {
        ok: false,
        content: '',
        elapsedMs: Date.now() - startedAt,
        error: '脚本工具的参数不是合法的 JSON 对象。'
      };
    }
    const validationError: string = this.validate();
    if (validationError.length > 0) {
      return { ok: false, content: '', elapsedMs: Date.now() - startedAt, error: validationError };
    }
    return {
      ok: false,
      content: '',
      elapsedMs: Date.now() - startedAt,
      error: L3SandboxRunner.NOT_ENABLED_MESSAGE
    };
  }

  /** 试跑：返回明确不可用报告（不伪造通过）。 */
  async dryRun(sampleInput: string): Promise<DryRunReport> {
    const startedAt: number = Date.now();
    const warnings: string[] = L3SandboxRunner.buildSecurityWarnings(this.manifest);
    const validationError: string = this.validate();
    const error: string = validationError.length > 0 ? validationError : L3SandboxRunner.NOT_ENABLED_MESSAGE;
    return {
      passed: false,
      latencyMs: Date.now() - startedAt,
      sampleOutput: '',
      securityWarnings: warnings,
      error
    };
  }

  /** 结果统一截断（供未来接入沙箱后端时复用）。 */
  static compactOutput(text: string): string {
    return truncateText(text, 4000);
  }
}
