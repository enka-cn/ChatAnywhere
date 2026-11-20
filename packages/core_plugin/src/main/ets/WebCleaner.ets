/**
 * 双轨联网清洗引擎的实现（轨道 B：独立 Search / Fetch）。
 *
 * 轨道 A（DeepSeek 原厂托管 `deepseek_web_search` / `deepseek_read_url`）由协议层 Adapter 声明，
 * 本类只负责轨道 B：`POST /v1/tools/search` 与 `POST /v1/tools/fetch` 的调用、质量过滤、8 秒超时降级。
 *
 * 纯逻辑（查询组装 / 响应清洗 / 提示词拼接）在 `util/WebClean.ets`，本文件只做网络与密钥接线。
 */
import { SecretAliases, SecretApi, SettingsApi } from '@app/core_model';
import { CleanedWebDoc, WebCleanerApi, CleanedWebPolicyLike } from './interfaces/WebCleanerApi';
import { HttpOutcome, NetHttp } from './runners/NetHttp';
import {
  buildFetchRequestBody, buildPromptBlock, buildQueryText, buildSearchRequestBody, cleanFetchDoc,
  cleanSearchDocs, describeApiError, sortDocsByQuality
} from './util/WebClean';
import { truncateText } from './util/JsonLite';

/** 默认 DeepSeek API 根地址（可在设置里覆盖，便于代理/自建网关）。 */
const DEFAULT_BASE_URL: string = 'https://api.deepseek.com';

/** 设置键：API 根地址。 */
const SETTINGS_BASE_URL: string = 'plugin.deepseek.baseUrl';

/** 设置键：单次检索条数（1-50）。 */
const SETTINGS_SEARCH_COUNT: string = 'plugin.webSearch.count';

/** Fetch 默认超时（Blueprint：8000ms 超时降级回 summary）。 */
const DEFAULT_FETCH_TIMEOUT_MS: number = 8000;

/** Search 请求超时（独立 Search 通常 1-3 秒返回）。 */
const SEARCH_TIMEOUT_MS: number = 20000;

/** 并发 Fetch 上限（避免触发目标域名级 QPS 限制）。 */
const MAX_ENRICH_FETCH: number = 5;

/** 清洗器依赖（由插件层工厂注入数据层能力）。 */
export interface WebCleanerDeps {
  secrets: SecretApi;
  settings: SettingsApi;
}

/** 联网清洗实现。 */
export class WebCleanerImpl implements WebCleanerApi {
  private readonly deps: WebCleanerDeps;
  private lastErrorMessage: string = '';

  constructor(deps: WebCleanerDeps) {
    this.deps = deps;
  }

  /** 最近一次失败原因（直白中文，供 UI 提示；成功时为空串）。 */
  get lastError(): string {
    return this.lastErrorMessage;
  }

  /** 读取 DeepSeek 密钥（不存在返回空串，禁止抛错污染调用方）。 */
  private async apiKey(): Promise<string> {
    try {
      const key: string | null = await this.deps.secrets.get(SecretAliases.DEEPSEEK);
      return key === null ? '' : key;
    } catch (e) {
      return '';
    }
  }

  /** API 根地址。 */
  private async baseUrl(): Promise<string> {
    let value: string = DEFAULT_BASE_URL;
    try {
      value = await this.deps.settings.getString(SETTINGS_BASE_URL, DEFAULT_BASE_URL);
    } catch (e) {
      value = DEFAULT_BASE_URL;
    }
    const trimmed: string = value.trim();
    if (trimmed.length === 0) {
      return DEFAULT_BASE_URL;
    }
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  /** 单次检索条数。 */
  private async searchCount(): Promise<number> {
    let count: number = 10;
    try {
      count = await this.deps.settings.getNumber(SETTINGS_SEARCH_COUNT, 10);
    } catch (e) {
      count = 10;
    }
    if (Number.isNaN(count) || count < 1) {
      return 1;
    }
    if (count > 50) {
      return 50;
    }
    return Math.floor(count);
  }

  /** 鉴权请求头。 */
  private authHeaders(apiKey: string): Map<string, string> {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Content-Type', 'application/json');
    headers.set('Authorization', `Bearer ${apiKey}`);
    return headers;
  }

  /** 组装带 site:/after:/lang: 语法的查询串。 */
  buildQuery(query: string, policy: CleanedWebPolicyLike): string {
    return buildQueryText(query, policy);
  }

  /** 独立 Search：返回按质量分排序、已过滤清洗的结果。 */
  async search(query: string, policy: CleanedWebPolicyLike): Promise<CleanedWebDoc[]> {
    this.lastErrorMessage = '';
    const trimmedQuery: string = query === null || query === undefined ? '' : query.trim();
    if (trimmedQuery.length === 0) {
      this.lastErrorMessage = '检索内容不能为空。';
      return [];
    }
    const apiKey: string = await this.apiKey();
    if (apiKey.length === 0) {
      this.lastErrorMessage = '尚未配置 DeepSeek 密钥，无法使用联网清洗。请到「设置」里填写密钥。';
      return [];
    }
    const baseUrl: string = await this.baseUrl();
    const count: number = await this.searchCount();
    const queryText: string = buildQueryText(trimmedQuery, policy);
    const body: string = buildSearchRequestBody(queryText, policy, count, false);
    const outcome: HttpOutcome = await NetHttp.request(`${baseUrl}/v1/tools/search`, 'POST',
      this.authHeaders(apiKey), body, SEARCH_TIMEOUT_MS);
    if (!outcome.ok) {
      this.lastErrorMessage = describeApiError(outcome.status, outcome.body);
      return [];
    }
    const docs: CleanedWebDoc[] = cleanSearchDocs(outcome.body, policy);
    if (docs.length === 0) {
      this.lastErrorMessage = '没有检索到符合质量阈值的结果，可以试试降低「最低相关度」或放宽站点限制。';
    }
    return docs;
  }

  /** 独立 Fetch：抓取网页 Markdown 正文；失败/超时返回 null 由调用方降级回 summary。 */
  async fetchDoc(url: string, policy: CleanedWebPolicyLike): Promise<CleanedWebDoc | null> {
    this.lastErrorMessage = '';
    const target: string = url === null || url === undefined ? '' : url.trim();
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      this.lastErrorMessage = '抓取地址必须是 http(s) 链接。';
      return null;
    }
    const apiKey: string = await this.apiKey();
    if (apiKey.length === 0) {
      this.lastErrorMessage = '尚未配置 DeepSeek 密钥，无法抓取网页正文。';
      return null;
    }
    let timeoutMs: number = policy.fetchTimeoutMs;
    if (Number.isNaN(timeoutMs) || timeoutMs < 2000) {
      timeoutMs = DEFAULT_FETCH_TIMEOUT_MS;
    }
    if (timeoutMs > 20000) {
      timeoutMs = 20000;
    }
    const baseUrl: string = await this.baseUrl();
    const body: string = buildFetchRequestBody(target);
    const outcome: HttpOutcome = await NetHttp.request(`${baseUrl}/v1/tools/fetch`, 'POST',
      this.authHeaders(apiKey), body, timeoutMs);
    if (!outcome.ok) {
      const isTimeoutLike: boolean = outcome.status === 408 || outcome.status === 504 || outcome.status === 0;
      this.lastErrorMessage = isTimeoutLike
        ? '抓取网页超时，已自动降级为摘要。'
        : describeApiError(outcome.status, outcome.body);
      return null;
    }
    const doc: CleanedWebDoc | null = cleanFetchDoc(outcome.body, target);
    if (doc === null) {
      this.lastErrorMessage = '没能从该网页提取到可读正文，已降级为摘要。';
    }
    return doc;
  }

  /** 把 Search 原始响应 JSON 清洗为文档数组（纯函数，可单测）。 */
  cleanSearchResponse(rawJson: string, policy: CleanedWebPolicyLike): CleanedWebDoc[] {
    return cleanSearchDocs(rawJson, policy);
  }

  /** 把 Fetch 原始响应 JSON 清洗为文档（纯函数，可单测）。 */
  cleanFetchResponse(rawJson: string, url: string): CleanedWebDoc | null {
    return cleanFetchDoc(rawJson, url);
  }

  /** 拼接注入模型的「联网检索结果」文本块（带来源编号）。 */
  toPromptBlock(docs: CleanedWebDoc[]): string {
    return buildPromptBlock(docs);
  }

  /**
   * 并发抓取质量最高的前 `fetchTopK` 篇正文；单条失败/超时自动降级回 summary。
   * 返回顺序与入参一致，保证引用编号稳定。
   */
  async enrichWithFetch(docs: CleanedWebDoc[], policy: CleanedWebPolicyLike): Promise<CleanedWebDoc[]> {
    if (docs === null || docs === undefined || docs.length === 0) {
      return [];
    }
    const fetchTopK: number = policy.fetchTopK;
    if (Number.isNaN(fetchTopK) || fetchTopK <= 0) {
      return docs.slice(0);
    }
    const sorted: CleanedWebDoc[] = sortDocsByQuality(docs);
    const limit: number = Math.min(fetchTopK, sorted.length, MAX_ENRICH_FETCH);
    const tasks: Promise<CleanedWebDoc | null>[] = [];
    for (let i = 0; i < limit; i++) {
      tasks.push(this.fetchDoc(sorted[i].url, policy));
    }
    const fetched: (CleanedWebDoc | null)[] = await Promise.all(tasks);
    const replacements: Map<string, CleanedWebDoc> = new Map<string, CleanedWebDoc>();
    for (let i = 0; i < limit; i++) {
      const one = fetched[i];
      if (one !== null) {
        replacements.set(sorted[i].url, one);
      }
    }
    const out: CleanedWebDoc[] = [];
    for (const doc of docs) {
      const replacement: CleanedWebDoc | undefined = replacements.get(doc.url);
      if (replacement !== undefined) {
        // 保留 Search 阶段的质量分/权威度，只替换正文（避免排序信息丢失）
        const merged: CleanedWebDoc = {
          title: replacement.title.length > 0 ? replacement.title : doc.title,
          url: doc.url,
          rerankScore: doc.rerankScore,
          authority: doc.authority,
          contentForModel: replacement.contentForModel,
          usedFallbackSummary: false
        };
        if (doc.siteName !== undefined) {
          merged.siteName = doc.siteName;
        }
        if (doc.publishedAt !== undefined) {
          merged.publishedAt = doc.publishedAt;
        }
        out.push(merged);
        continue;
      }
      const fallback: CleanedWebDoc = {
        title: doc.title,
        url: doc.url,
        rerankScore: doc.rerankScore,
        authority: doc.authority,
        contentForModel: truncateText(doc.contentForModel, 1000),
        usedFallbackSummary: true
      };
      if (doc.siteName !== undefined) {
        fallback.siteName = doc.siteName;
      }
      if (doc.publishedAt !== undefined) {
        fallback.publishedAt = doc.publishedAt;
      }
      out.push(fallback);
    }
    return out;
  }
}
