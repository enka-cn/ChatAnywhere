/**
 * L2 远程 MCP 客户端（Streamable HTTP / SSE 传输）。
 *
 * 流程：initialize → notifications/initialized → tools/list（自动发现工具）→ tools/call。
 * 证书/令牌只从 Asset 密钥托管读取（`runtimePayload.authSecretAlias`），
 * 端点域名必须在 `allowedDomains` 白名单中（默认拒绝）。
 */
import { SecretApi } from '@app/core_model';
import { SkillManifest } from '../interfaces/SkillManifest';
import { extractHost, isDomainAllowed } from '../util/DomainUtil';
import { truncateText } from '../util/JsonLite';
import {
  buildInitializeParams, buildJsonRpcNotification, buildJsonRpcRequest, buildToolCallParams,
  buildToolsListParams, extractCallOutcome, extractProtocolVersion, extractTools, McpCallOutcome,
  McpRpcResult, McpToolInfo, parseRpcBody
} from '../util/McpProtocol';
import { HttpOutcome, NetHttp } from './NetHttp';

/** 本客户端声明的 MCP 协议版本（服务端可回退到它支持的其他版本）。 */
const MCP_PROTOCOL_VERSION: string = '2025-06-18';

/** MCP 单次请求超时（毫秒）。 */
const MCP_TIMEOUT_MS: number = 20000;

/** MCP 工具调用超时（可能包含远端长任务）。 */
const MCP_CALL_TIMEOUT_MS: number = 45000;

/** 一个已配置的 MCP 连接（每次挂载创建一个实例，卸载时 dispose）。 */
export class L2McpClient {
  private readonly manifest: SkillManifest;
  private readonly secrets: SecretApi;
  private readonly endpoint: string;
  private readonly allowedDomains: string[];
  private nextId: number = 1;
  private sessionId: string = '';
  private initialized: boolean = false;
  private disposed: boolean = false;

  constructor(manifest: SkillManifest, secrets: SecretApi) {
    this.manifest = manifest;
    this.secrets = secrets;
    const endpoint: string = manifest.runtimePayload.mcpEndpoint === undefined
      ? '' : (manifest.runtimePayload.mcpEndpoint as string);
    this.endpoint = endpoint.trim();
    this.allowedDomains = manifest.runtimePayload.allowedDomains;
  }

  /** 校验端点与白名单（挂载前调用，失败抛中文错误）。 */
  validateEndpoint(): void {
    if (this.endpoint.length === 0) {
      throw new Error('该远程服务技能没有填写 MCP 地址。');
    }
    if (!this.endpoint.startsWith('https://')) {
      throw new Error('MCP 地址必须使用 https://（禁止明文 HTTP）。');
    }
    const host: string = extractHost(this.endpoint);
    if (host.length === 0) {
      throw new Error('MCP 地址里识别不到域名，请检查地址。');
    }
    if (!isDomainAllowed(host, this.allowedDomains)) {
      throw new Error(`MCP 地址的域名「${host}」不在允许访问的白名单里（默认拒绝），请先补充白名单。`);
    }
  }

  /** 构造请求头（含令牌与 MCP 会话 id）。 */
  private async buildHeaders(): Promise<Map<string, string>> {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Content-Type', 'application/json');
    headers.set('Accept', 'application/json, text/event-stream');
    if (this.sessionId.length > 0) {
      headers.set('Mcp-Session-Id', this.sessionId);
    }
    const alias: string = this.manifest.runtimePayload.authSecretAlias === undefined
      ? '' : (this.manifest.runtimePayload.authSecretAlias as string).trim();
    if (alias.length > 0) {
      let token: string | null = null;
      try {
        token = await this.secrets.get(alias);
      } catch (e) {
        token = null;
      }
      if (token === null || token.length === 0) {
        throw new Error('该远程服务技能需要访问令牌：请到「设置」里保存对应令牌后再试。');
      }
      headers.set('Authorization', `Bearer ${token}`);
    }
    return headers;
  }

  /** 发送一次 JSON-RPC 请求。 */
  private async post(bodyJson: string, timeoutMs: number): Promise<HttpOutcome> {
    if (this.disposed) {
      throw new Error('MCP 客户端已关闭。');
    }
    const headers: Map<string, string> = await this.buildHeaders();
    const outcome: HttpOutcome = await NetHttp.request(this.endpoint, 'POST', headers, bodyJson, timeoutMs);
    const sessionValue: string | undefined = outcome.headers.get('mcp-session-id');
    if (sessionValue !== undefined && sessionValue.length > 0) {
      this.sessionId = sessionValue;
    }
    return outcome;
  }

  /** 初始化握手（幂等）。 */
  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.validateEndpoint();
    const id: number = this.nextId;
    this.nextId = this.nextId + 1;
    const body: string = buildJsonRpcRequest(id, 'initialize',
      buildInitializeParams(MCP_PROTOCOL_VERSION, 'ChatAnyWhere', '1.0.0'));
    const outcome: HttpOutcome = await this.post(body, MCP_TIMEOUT_MS);
    if (!outcome.ok) {
      throw new Error(`连接远程服务失败：${outcome.error}`);
    }
    const contentType: string = outcome.headers.get('content-type') === undefined
      ? '' : (outcome.headers.get('content-type') as string);
    const parsed: McpRpcResult = parseRpcBody(outcome.body, contentType);
    if (!parsed.ok) {
      throw new Error(`远程服务初始化失败：${parsed.error}`);
    }
    const remoteVersion: string = extractProtocolVersion(parsed.resultJson);
    if (remoteVersion.length === 0) {
      throw new Error('远程服务没有返回可用的协议版本，可能不是标准 MCP 服务。');
    }
    this.initialized = true;
    try {
      const notifyBody: string = buildJsonRpcNotification('notifications/initialized', '{}');
      await this.post(notifyBody, 10000);
    } catch (e) {
      // 通知失败不影响后续 tools/list（多数服务端容忍）
    }
  }

  /** 拉取工具列表（自动发现）。 */
  async listTools(): Promise<McpToolInfo[]> {
    await this.initialize();
    const id: number = this.nextId;
    this.nextId = this.nextId + 1;
    const body: string = buildJsonRpcRequest(id, 'tools/list', buildToolsListParams());
    const outcome: HttpOutcome = await this.post(body, MCP_TIMEOUT_MS);
    if (!outcome.ok) {
      throw new Error(`获取远程工具列表失败：${outcome.error}`);
    }
    const contentType: string = outcome.headers.get('content-type') === undefined
      ? '' : (outcome.headers.get('content-type') as string);
    const parsed: McpRpcResult = parseRpcBody(outcome.body, contentType);
    if (!parsed.ok) {
      throw new Error(`获取远程工具列表失败：${parsed.error}`);
    }
    return extractTools(parsed.resultJson);
  }

  /** 调用远端工具。 */
  async callTool(toolName: string, argumentsJson: string): Promise<McpCallOutcome> {
    try {
      await this.initialize();
    } catch (e) {
      const err = e as Error;
      return { ok: false, text: '', error: err.message };
    }
    const id: number = this.nextId;
    this.nextId = this.nextId + 1;
    const body: string = buildJsonRpcRequest(id, 'tools/call', buildToolCallParams(toolName, argumentsJson));
    let outcome: HttpOutcome;
    try {
      outcome = await this.post(body, MCP_CALL_TIMEOUT_MS);
    } catch (e) {
      const err = e as Error;
      return { ok: false, text: '', error: `调用远程工具失败：${err.message}` };
    }
    if (!outcome.ok) {
      return { ok: false, text: '', error: `调用远程工具失败：${truncateText(outcome.error, 200)}` };
    }
    const contentType: string = outcome.headers.get('content-type') === undefined
      ? '' : (outcome.headers.get('content-type') as string);
    const parsed: McpRpcResult = parseRpcBody(outcome.body, contentType);
    if (!parsed.ok) {
      return { ok: false, text: '', error: `调用远程工具失败：${parsed.error}` };
    }
    return extractCallOutcome(parsed.resultJson);
  }

  /** 释放（当前为无长连接实现，仅标记状态，防止继续使用）。 */
  dispose(): void {
    this.disposed = true;
    this.initialized = false;
    this.sessionId = '';
  }

  /** 是否已完成握手。 */
  get ready(): boolean {
    return this.initialized && !this.disposed;
  }
}
