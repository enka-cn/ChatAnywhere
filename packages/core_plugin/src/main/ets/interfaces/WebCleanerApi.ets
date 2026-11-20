/**
 * 双轨联网清洗契约（Blueprint §3.3）。
 *
 * 轨道 A（原厂托管）：deepseek_web_search / deepseek_read_url —— 由协议层 Adapter 声明，本模块只负责策略翻译。
 * 轨道 B（独立清洗）：POST /v1/tools/search + /v1/tools/fetch，本模块负责查询组装 / 质量过滤 / 超时降级。
 */
import { CleanedWebDoc } from './WebTypes';

export { CleanedWebDoc, WebCleanPolicy } from './WebTypes';

/** 清洗引擎接口。 */
export interface WebCleanerApi {
  /** 组装带 site:/after:/lang: 语法的查询串。 */
  buildQuery(query: string, policy: CleanedWebPolicyLike): string;

  /** 独立 Search（轨道 B），返回按质量分排序的清洗结果。 */
  search(query: string, policy: CleanedWebPolicyLike): Promise<CleanedWebDoc[]>;

  /** 独立 Fetch（轨道 B），超时/失败返回 null 由调用方降级回 summary。 */
  fetchDoc(url: string, policy: CleanedWebPolicyLike): Promise<CleanedWebDoc | null>;

  /** 把 Search 原始响应 JSON 清洗为 CleanedWebDoc[]（纯函数，可单测）。 */
  cleanSearchResponse(rawJson: string, policy: CleanedWebPolicyLike): CleanedWebDoc[];

  /** 把 Fetch 原始响应 JSON 清洗为 CleanedWebDoc（纯函数，可单测）。 */
  cleanFetchResponse(rawJson: string, url: string): CleanedWebDoc | null;

  /** 拼接为注入模型的「检索结果」文本块（带来源编号）。 */
  toPromptBlock(docs: CleanedWebDoc[]): string;

  /** 并发 Fetch TopK 并把内容并入文档（失败自动降级 summary）。 */
  enrichWithFetch(docs: CleanedWebDoc[], policy: CleanedWebPolicyLike): Promise<CleanedWebDoc[]>;
}

/** 避免循环 import 的宽化类型别名（等价于 WebCleanPolicy）。 */
export interface CleanedWebPolicyLike {
  mode: string;
  includeDomains: string[];
  excludeDomains: string[];
  afterDate?: string;
  languages?: string[];
  minRerankScore: number;
  minAuthority: number;
  fetchTopK: number;
  fetchTimeoutMs: number;
}
