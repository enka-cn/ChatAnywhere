/**
 * MCP（Model Context Protocol）JSON-RPC 2.0 与 SSE 响应的纯逻辑部分。
 *
 * 纯函数，零平台依赖，可被 Node 逻辑测试覆盖。
 * 平台 HTTP 传输在 `runners/L2McpClient.ets` 中完成。
 *
 * 支持的 MCP 交互：initialize → notifications/initialized → tools/list → tools/call。
 */
import {
  emptyRecord, getBool, getNumber, getObject, getObjectList, getString, hasValue, parseObjectArray,
  parseRecord, toJsonText, truncateText
} from './JsonLite';

/** 解析出来的 MCP 工具描述。 */
export interface McpToolInfo {
  name: string;
  description: string;
  parametersJson: string;
}

/** JSON-RPC 响应结果。 */
export interface McpRpcResult {
  ok: boolean;
  error: string;
  resultJson: string;
  id: number;
}

/** tools/call 结果。 */
export interface McpCallOutcome {
  ok: boolean;
  text: string;
  error: string;
}

/** 构造 JSON-RPC 请求文本。 */
export function buildJsonRpcRequest(id: number, method: string, paramsJson: string): string {
  const request: Record<string, Object> = emptyRecord();
  request['jsonrpc'] = '2.0';
  request['id'] = id;
  request['method'] = method;
  if (paramsJson !== null && paramsJson !== undefined && paramsJson.trim().length > 0) {
    const params = parseRecord(paramsJson);
    if (params !== null) {
      request['params'] = params;
    }
  }
  return JSON.stringify(request);
}

/** 构造 JSON-RPC 通知（无 id）。 */
export function buildJsonRpcNotification(method: string, paramsJson: string): string {
  const request: Record<string, Object> = emptyRecord();
  request['jsonrpc'] = '2.0';
  request['method'] = method;
  if (paramsJson !== null && paramsJson !== undefined && paramsJson.trim().length > 0) {
    const params = parseRecord(paramsJson);
    if (params !== null) {
      request['params'] = params;
    }
  }
  return JSON.stringify(request);
}

/** initialize 参数。 */
export function buildInitializeParams(protocolVersion: string, clientName: string,
  clientVersion: string): string {
  const params: Record<string, Object> = emptyRecord();
  params['protocolVersion'] = protocolVersion;
  const capabilities: Record<string, Object> = emptyRecord();
  params['capabilities'] = capabilities;
  const clientInfo: Record<string, Object> = emptyRecord();
  clientInfo['name'] = clientName;
  clientInfo['version'] = clientVersion;
  params['clientInfo'] = clientInfo;
  return JSON.stringify(params);
}

/** tools/list 参数（空对象）。 */
export function buildToolsListParams(): string {
  return '{}';
}

/** tools/call 参数。 */
export function buildToolCallParams(toolName: string, argumentsJson: string): string {
  const params: Record<string, Object> = emptyRecord();
  params['name'] = toolName;
  let args: Record<string, Object> = emptyRecord();
  const parsedArgs = parseRecord(argumentsJson);
  if (parsedArgs !== null) {
    args = parsedArgs;
  }
  params['arguments'] = args;
  return JSON.stringify(params);
}

/** 收集 SSE 响应里的 `data:` 载荷（按空行分帧）。 */
export function collectSseData(rawBody: string): string[] {
  const out: string[] = [];
  if (rawBody === null || rawBody === undefined || rawBody.length === 0) {
    return out;
  }
  const lines: string[] = (rawBody as string).split('\n');
  let dataLines: string[] = [];
  for (const rawLine of lines) {
    let line: string = rawLine;
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    if (line.length === 0) {
      if (dataLines.length > 0) {
        out.push(dataLines.join('\n'));
        dataLines = [];
      }
      continue;
    }
    if (line.startsWith(':')) {
      continue;
    }
    if (line.startsWith('data:')) {
      let value: string = line.substring('data:'.length);
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
      dataLines.push(value);
    }
  }
  if (dataLines.length > 0) {
    out.push(dataLines.join('\n'));
  }
  return out;
}

/** 解释单条 JSON-RPC 响应文本。 */
function interpretRpcText(text: string): McpRpcResult {
  const record = parseRecord(text);
  if (record === null) {
    // 可能是批量数组
    const list: Object[] = parseObjectArray(text);
    for (const one of list) {
      const sub = parseRecord(toJsonText(one));
      if (sub === null) {
        continue;
      }
      const result: McpRpcResult = interpretRpcRecord(sub);
      if (result.ok) {
        return result;
      }
    }
    return { ok: false, error: 'MCP 响应不是合法的 JSON-RPC 对象', resultJson: '', id: 0 };
  }
  return interpretRpcRecord(record);
}

/** 解释单个 JSON-RPC 响应对象。 */
function interpretRpcRecord(record: Record<string, Object>): McpRpcResult {
  const id: number = getNumber(record, 'id', 0);
  const errorObj: Record<string, Object> | null = getObject(record, 'error');
  if (errorObj !== null) {
    const message: string = getString(errorObj, 'message', 'MCP 服务返回错误');
    const code: number = getNumber(errorObj, 'code', 0);
    return {
      ok: false,
      error: `MCP 服务错误（${code}）：${truncateText(message, 160)}`,
      resultJson: '',
      id
    };
  }
  if (!hasValue(record, 'result')) {
    return { ok: false, error: 'MCP 响应缺少 result 字段', resultJson: '', id };
  }
  const resultValue: Object = record['result'];
  return { ok: true, error: '', resultJson: toJsonText(resultValue), id };
}

/**
 * 解析 MCP HTTP 响应体：既支持 `application/json`，也支持 `text/event-stream`（SSE）。
 * 返回第一条带 result/error 的 JSON-RPC 响应。
 */
export function parseRpcBody(rawBody: string, contentType: string): McpRpcResult {
  if (rawBody === null || rawBody === undefined) {
    return { ok: false, error: 'MCP 服务返回了空响应', resultJson: '', id: 0 };
  }
  const body: string = (rawBody as string).trim();
  if (body.length === 0) {
    return { ok: false, error: 'MCP 服务返回了空响应', resultJson: '', id: 0 };
  }
  const lowerType: string = contentType === null || contentType === undefined
    ? '' : (contentType as string).toLowerCase();
  const looksLikeSse: boolean = body.startsWith('data:') || body.indexOf('\ndata:') >= 0 ||
    lowerType.indexOf('text/event-stream') >= 0;
  if (looksLikeSse) {
    const payloads: string[] = collectSseData(body);
    let lastResult: McpRpcResult = { ok: false, error: 'MCP 流式响应里没有找到有效结果', resultJson: '', id: 0 };
    for (const payload of payloads) {
      const record = parseRecord(payload);
      if (record === null) {
        continue;
      }
      if (hasValue(record, 'result') || hasValue(record, 'error')) {
        lastResult = interpretRpcRecord(record);
        if (lastResult.ok) {
          return lastResult;
        }
      }
    }
    return lastResult;
  }
  return interpretRpcText(body);
}

/** 从 tools/list 的 result JSON 中提取工具列表。 */
export function extractTools(resultJson: string): McpToolInfo[] {
  const out: McpToolInfo[] = [];
  const result = parseRecord(resultJson);
  if (result === null) {
    return out;
  }
  const tools: Record<string, Object>[] = getObjectList(result, 'tools');
  for (const tool of tools) {
    const name: string = getString(tool, 'name', '').trim();
    if (name.length === 0) {
      continue;
    }
    const description: string = getString(tool, 'description', '').trim();
    const inputSchema: Record<string, Object> | null = getObject(tool, 'inputSchema');
    let parametersJson: string = '{"type":"object","properties":{}}';
    if (inputSchema !== null) {
      parametersJson = toJsonText(inputSchema);
    }
    out.push({ name, description, parametersJson });
  }
  return out;
}

/** 从 initialize 的 result JSON 里读协议版本（缺省返回空串）。 */
export function extractProtocolVersion(resultJson: string): string {
  const result = parseRecord(resultJson);
  if (result === null) {
    return '';
  }
  return getString(result, 'protocolVersion', '');
}

/** 从 tools/call 的 result JSON 中提取文本结果。 */
export function extractCallOutcome(resultJson: string): McpCallOutcome {
  const result = parseRecord(resultJson);
  if (result === null) {
    return { ok: false, text: '', error: 'MCP 工具结果不是合法的 JSON 对象' };
  }
  const isError: boolean = getBool(result, 'isError', false);
  const parts: string[] = [];
  const contentValue: Object = result['content'];
  if (contentValue !== undefined && contentValue !== null && Array.isArray(contentValue)) {
    const items = contentValue as Object[];
    for (const one of items) {
      const item = parseRecord(toJsonText(one));
      if (item === null) {
        continue;
      }
      const type: string = getString(item, 'type', '');
      const text: string = getString(item, 'text', '');
      if (type === 'text' && text.length > 0) {
        parts.push(text);
      } else if (type === 'resource' || type === 'image') {
        parts.push(`[${type === 'image' ? '图片结果' : '资源结果'}]`);
      }
    }
  }
  if (parts.length === 0) {
    const textValue: Object = result['content'];
    if (typeof textValue === 'string') {
      parts.push(textValue as string);
    }
  }
  if (parts.length === 0 && hasValue(result, 'structuredContent')) {
    parts.push(toJsonText(result['structuredContent']));
  }
  const text: string = parts.join('\n').trim();
  if (isError) {
    return { ok: false, text, error: text.length > 0 ? text : 'MCP 工具返回了错误' };
  }
  if (text.length === 0) {
    return { ok: false, text: '', error: 'MCP 工具没有返回可读内容' };
  }
  return { ok: true, text, error: '' };
}

/** 安全截断（导出给上层拼提示用）。 */
export function limitText(text: string, maxLen: number): string {
  return truncateText(text, maxLen);
}
