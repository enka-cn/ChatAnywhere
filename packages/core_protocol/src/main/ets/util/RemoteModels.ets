/**
 * 上游 `/models` 探测：URL 组装 + 响应解析（纯逻辑，零平台依赖）。
 *
 * 供 v3.2「真实模型目录」使用：模型列表只能来自真实端点探测，禁止内置占位模型。
 * 三家差异：
 * - DeepSeek（Responses API）：`GET {baseUrl}/models`
 *   （baseUrl 默认 https://api.deepseek.com，注意 DeepSeek 的模型列表不在 /v1 下）
 * - Anthropic（Messages API）：`GET {baseUrl}/v1/models`
 *   header 需 `x-api-key` + `anthropic-version: 2023-06-01`
 * - OpenAI 兼容：`GET {baseUrl}/models`；baseUrl 已含 `/v1` 时不重复拼接，否则补 `/v1/models`
 *
 * 响应解析对 OpenAI / DeepSeek / Anthropic / 各类中转站都容错：
 * - 标准：`{ "object": "list", "data": [{ "id": "..." , "display_name"?: "...", "name"?: "..." }] }`
 * - 变体：`{ "models": [...] }`、裸数组 `[...]`、数组元素为字符串
 * - displayName 优先 `display_name` → `name` → `id`
 * - 非法 JSON / 空 body / 缺字段一律返回空数组，绝不抛错。
 */
import { RemoteModelInfo } from '../interfaces/ProtocolTypes';
import { asRecord, getObjList, getStr, parseRecord, stringifyRecord } from './JsonLite';
import { joinUrl } from './UrlUtil';

/** 按协议拼出 /models 探测地址。 */
export function modelsUrl(protocol: string, baseUrl: string): string {
  if (protocol === 'deepseek_responses') {
    return joinUrl(baseUrl, '/models');
  }
  if (protocol === 'anthropic_messages') {
    return joinUrl(baseUrl, '/v1/models');
  }
  return openAiCompatModelsUrl(baseUrl);
}

/**
 * OpenAI 兼容端点的 /models 地址。
 * baseUrl 已含 `/v1`（如 https://api.openai.com/v1）→ 直接 + `/models`；
 * 否则补 `/v1/models`；已以 `/models` 结尾时原样返回。
 */
export function openAiCompatModelsUrl(baseUrl: string): string {
  let base: string = baseUrl === undefined || baseUrl === null ? '' : baseUrl.trim();
  while (base.length > 1 && base.charAt(base.length - 1) === '/') {
    base = base.substring(0, base.length - 1);
  }
  if (base.length === 0) {
    return '/v1/models';
  }
  if (base.length >= 7 && base.substring(base.length - 7) === '/models') {
    return base;
  }
  if (base.length >= 3 && base.substring(base.length - 3) === '/v1') {
    return `${base}/models`;
  }
  return `${base}/v1/models`;
}

/** 从模型对象里挑出模型 id（兼容 id / model / name 三种写法）。 */
function pickModelId(item: Record<string, Object>): string {
  const id: string = getStr(item, 'id', '');
  if (id.length > 0) {
    return id.trim();
  }
  const model: string = getStr(item, 'model', '');
  if (model.length > 0) {
    return model.trim();
  }
  const name: string = getStr(item, 'name', '');
  return name.trim();
}

/** 从模型对象里挑出展示名（优先 display_name，其次 name，最后回退 id）。 */
function pickDisplayName(item: Record<string, Object>, modelId: string): string {
  const displayName: string = getStr(item, 'display_name', '');
  if (displayName.length > 0) {
    return displayName.trim();
  }
  const name: string = getStr(item, 'name', '');
  if (name.length > 0) {
    return name.trim();
  }
  return modelId;
}

/** 去重追加（同一 modelId 只保留第一次出现的记录）。 */
function appendModel(out: RemoteModelInfo[], seen: Set<string>, modelId: string,
  displayName: string, metaJson: string): void {
  const id: string = modelId.trim();
  if (id.length === 0 || seen.has(id)) {
    return;
  }
  seen.add(id);
  const info: RemoteModelInfo = {
    modelId: id,
    displayName: displayName.trim().length > 0 ? displayName.trim() : id,
    metaJson: metaJson
  };
  out.push(info);
}

/**
 * 解析 `/models` 响应体。
 * @param body HTTP 响应体文本（非法 JSON / 空串返回空数组）
 */
export function parseModelsResponse(body: string): RemoteModelInfo[] {
  const out: RemoteModelInfo[] = [];
  const seen: Set<string> = new Set<string>();
  if (body === undefined || body === null) {
    return out;
  }
  const text: string = body.trim();
  if (text.length === 0) {
    return out;
  }

  const rec: Record<string, Object> | null = parseRecord(text);
  if (rec !== null) {
    let items: Record<string, Object>[] = getObjList(rec, 'data');
    if (items.length === 0) {
      items = getObjList(rec, 'models');
    }
    for (const item of items) {
      const modelId: string = pickModelId(item);
      if (modelId.length === 0) {
        continue;
      }
      appendModel(out, seen, modelId, pickDisplayName(item, modelId), stringifyRecord(item));
    }
    return out;
  }

  // 裸数组：["model-a", {"id":"model-b"}] 都接受
  try {
    const arr: Object[] = JSON.parse(text) as Object[];
    if (!Array.isArray(arr)) {
      return out;
    }
    for (const one of arr) {
      if (typeof one === 'string') {
        const id: string = one as string;
        appendModel(out, seen, id, id, '');
        continue;
      }
      const item: Record<string, Object> | null = asRecord(one);
      if (item === null) {
        continue;
      }
      const modelId: string = pickModelId(item);
      if (modelId.length === 0) {
        continue;
      }
      appendModel(out, seen, modelId, pickDisplayName(item, modelId), stringifyRecord(item));
    }
  } catch (e) {
    return out;
  }
  return out;
}

/** 只取 modelId 列表（连接测试回显用）。 */
export function modelIdsOf(models: RemoteModelInfo[]): string[] {
  const out: string[] = [];
  for (const one of models) {
    out.push(one.modelId);
  }
  return out;
}
