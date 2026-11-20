/**
 * L1 声明式技能执行器：按 manifest 里的 HTTP 模板发请求，并做域名白名单强制校验。
 *
 * 安全红线（docs/DEV_GUIDE.md §5）：
 * - 只允许访问 `runtimePayload.allowedDomains` 中的域名，默认拒绝；
 * - 密钥只通过 `{{secret:别名}}` 占位符注入，清单里绝不出现明文；
 * - 不在白名单、鉴权缺失、HTTP 失败都必须返回可读中文错误（不静默失败）。
 */
import { SecretApi } from '@app/core_model';
import { HttpTemplate, SkillManifest, ToolExecutionResult } from '../interfaces/SkillManifest';
import { extractHost, isDomainAllowed } from '../util/DomainUtil';
import {
  compactResultText, extractByResponsePath, extractSecretAliases, parseHeaderText, renderTemplate
} from '../util/L1Template';
import { parseRecord } from '../util/JsonLite';
import { HttpOutcome, NetHttp } from './NetHttp';
import { ToolRunner } from './ToolRunner';

/** L1 声明式 HTTP 执行器（每个挂载实例对应一个技能）。 */
export class L1DeclarativeRunner implements ToolRunner {
  private readonly manifest: SkillManifest;
  private readonly secrets: SecretApi;
  private configJson: string = '{}';

  constructor(manifest: SkillManifest, secrets: SecretApi, configJson: string) {
    this.manifest = manifest;
    this.secrets = secrets;
    this.configJson = configJson;
  }

  /** 用户改配置后热更新（无需重新挂载）。 */
  setConfig(configJson: string): void {
    this.configJson = configJson;
  }

  /** 收集模板里用到的密钥别名并取回明文值（只存在内存 Map 中，不落盘不打印）。 */
  private async loadSecrets(templateText: string): Promise<Map<string, string>> {
    const values: Map<string, string> = new Map<string, string>();
    const aliases: string[] = extractSecretAliases(templateText);
    for (const alias of aliases) {
      let value: string = '';
      try {
        const fetched: string | null = await this.secrets.get(alias);
        if (fetched !== null) {
          value = fetched;
        }
      } catch (e) {
        value = '';
      }
      values.set(alias, value);
    }
    return values;
  }

  /** 渲染并解析请求头。 */
  private buildHeaders(template: HttpTemplate, inputJson: string, secretValues: Map<string, string>): Map<string, string> {
    const headersJson: string = template.headersJson === undefined ? '' : (template.headersJson as string);
    const rendered: string = renderTemplate(headersJson, inputJson, this.configJson, secretValues, false);
    const headers: Map<string, string> = parseHeaderText(rendered);
    let hasContentType: boolean = false;
    headers.forEach((value: string, key: string) => {
      if (key.toLowerCase() === 'content-type') {
        hasContentType = true;
      }
    });
    if (!hasContentType) {
      headers.set('Content-Type', 'application/json');
    }
    return headers;
  }

  /** 鉴权头为空时提前给出直白提示，避免把空 Bearer 发到服务端。 */
  private checkAuth(headers: Map<string, string>): string {
    let authError: string = '';
    headers.forEach((value: string, key: string) => {
      if (key.toLowerCase() !== 'authorization') {
        return;
      }
      const trimmed: string = value.trim();
      if (trimmed.length === 0 || trimmed === 'Bearer' || trimmed.endsWith('Bearer ')) {
        authError = '该技能需要先配置密钥：请到「设置」里保存对应密钥后再试。';
      }
    });
    return authError;
  }

  /** 失败结果。 */
  private fail(startedAt: number, message: string): ToolExecutionResult {
    return { ok: false, content: '', elapsedMs: Date.now() - startedAt, error: message };
  }

  /** 根据 HTTP 状态补一句可操作提示。 */
  private hintForStatus(outcome: HttpOutcome): string {
    if (outcome.status === 401) {
      return '（提示：需要先在「设置」里保存 DeepSeek 密钥）';
    }
    if (outcome.status === 429) {
      return '（提示：请求太频繁，稍后重试即可）';
    }
    if (outcome.status === 402) {
      return '（提示：账户余额不足，充值后再试）';
    }
    return '';
  }

  /** 执行一次工具调用。 */
  async execute(argumentsJson: string): Promise<ToolExecutionResult> {
    const startedAt: number = Date.now();
    const template: HttpTemplate | undefined = this.manifest.runtimePayload.httpTemplate;
    if (template === undefined || template === null) {
      return this.fail(startedAt, '该技能没有配置 HTTP 请求模板，无法执行。');
    }
    let inputJson: string = argumentsJson === null || argumentsJson === undefined ? '' : argumentsJson.trim();
    if (inputJson.length === 0) {
      inputJson = '{}';
    }
    if (parseRecord(inputJson) === null) {
      return this.fail(startedAt, '工具参数不是合法的 JSON 对象，请检查模型给出的参数。');
    }
    const allowedDomains: string[] = this.manifest.runtimePayload.allowedDomains;
    if (allowedDomains.length === 0) {
      return this.fail(startedAt, '该技能没有配置允许访问的域名（默认拒绝），请先在「技能管理」里补充白名单。');
    }
    const secretText: string = `${template.urlTemplate}
${template.headersJson === undefined ? '' : template.headersJson}
${template.bodyTemplate === undefined ? '' : template.bodyTemplate}`;
    const secretValues: Map<string, string> = await this.loadSecrets(secretText);
    const url: string = renderTemplate(template.urlTemplate, inputJson, this.configJson, secretValues, true);
    const host: string = extractHost(url);
    if (host.length === 0) {
      return this.fail(startedAt, '请求地址里识别不到域名，请检查技能的 HTTP 模板。');
    }
    if (!isDomainAllowed(host, allowedDomains)) {
      return this.fail(startedAt,
        `不允许访问域名「${host}」：该技能只允许访问 ${allowedDomains.join('、')}，请到「技能管理」补充白名单后再试。`);
    }
    const headers: Map<string, string> = this.buildHeaders(template, inputJson, secretValues);
    const authError: string = this.checkAuth(headers);
    if (authError.length > 0) {
      return this.fail(startedAt, authError);
    }
    const method: string = template.method === undefined ? 'GET' : template.method.toUpperCase();
    let body: string = '';
    if (method !== 'GET' && method !== 'HEAD' && template.bodyTemplate !== undefined) {
      body = renderTemplate(template.bodyTemplate, inputJson, this.configJson, secretValues, false);
    }
    const timeoutMs: number = template.timeoutMs === undefined ? 15000 : template.timeoutMs;
    const outcome: HttpOutcome = await NetHttp.request(url, method, headers, body, timeoutMs);
    if (!outcome.ok) {
      const message: string = outcome.status === 0
        ? outcome.error
        : `${outcome.error}${this.hintForStatus(outcome)}`;
      return this.fail(startedAt, message);
    }
    const responsePath: string = template.responsePath === undefined ? '' : template.responsePath;
    const extracted: string = extractByResponsePath(outcome.body, responsePath);
    const content: string = extracted.trim().length === 0
      ? compactResultText(outcome.body, 4000)
      : compactResultText(extracted, 6000);
    if (content.length === 0) {
      return this.fail(startedAt, '接口返回了空内容。');
    }
    return { ok: true, content, elapsedMs: Date.now() - startedAt };
  }

  /** 试跑（与真实执行同一路径，供内核 dryRun 使用）。 */
  async dryRun(sampleInput: string): Promise<ToolExecutionResult> {
    return this.execute(sampleInput);
  }
}
