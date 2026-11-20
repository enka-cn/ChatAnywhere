/**
 * 双轨联网清洗的数据类型（Blueprint §3.3）。
 */

/** 清洗策略。 */
export interface WebCleanPolicy {
  mode: string;
  /** 转为 site:a OR site:b */
  includeDomains: string[];
  /** 转为 -site:x */
  excludeDomains: string[];
  /** 转为 after:YYYY-MM-DD */
  afterDate?: string;
  /** 转为 lang:zh,en */
  languages?: string[];
  /** 默认 1.5（DeepSeek 官方优质结果阈值）。 */
  minRerankScore: number;
  /** 默认 2 或 3（>=3 为极权威）。 */
  minAuthority: number;
  /** 0=仅用 600-800 字 summary 省 Token；>0 并发 Fetch Markdown。 */
  fetchTopK: number;
  /** 默认 8000ms，超时自动降级回 summary。 */
  fetchTimeoutMs: number;
}

/** 清洗后的网页文档。 */
export interface CleanedWebDoc {
  title: string;
  url: string;
  siteName?: string;
  publishedAt?: string;
  rerankScore: number;
  authority: number;
  /** 清洗裁剪后的 summary 或 Markdown 正文。 */
  contentForModel: string;
  /** 是否降级使用了 summary。 */
  usedFallbackSummary: boolean;
}

/** 缺省策略。 */
export function defaultWebCleanPolicy(): WebCleanPolicy {
  return {
    mode: 'auto',
    includeDomains: [],
    excludeDomains: [],
    minRerankScore: 1.5,
    minAuthority: 0,
    fetchTopK: 0,
    fetchTimeoutMs: 8000
  };
}
