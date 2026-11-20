/**
 * 独立联网清洗（轨道 B）：先检索 + 清洗，再把结果作为提示词的检索层注入，避免模型瞎编。
 *
 * 插件模块未启动时只写一条「联网清洗暂不可用」的时间轴并降级为不联网，
 * 会话继续可用；网络/清洗失败同样降级为「按模型自己的知识回答」。
 */
import { ConversationNode, SourceRef } from '@app/core_model';
import { CleanedWebDoc, CleanedWebPolicyLike } from '@app/core_plugin';
import { RuntimeHost } from './RuntimeTypes';
import { SearchTraceStore } from './SearchTraceStore';
import { collectNodeText } from './RuntimeUtils';

export class StandaloneCleaner {
  private host: RuntimeHost;
  private trace: SearchTraceStore;

  constructor(host: RuntimeHost, trace: SearchTraceStore) {
    this.host = host;
    this.trace = trace;
  }

  /** 返回塞进提示词检索层的文本块（非独立清洗模式返回空数组）。 */
  async run(path: ConversationNode[]): Promise<string[]> {
    const blocks: string[] = [];
    if (this.host.webMode() !== 'standalone_clean') {
      return blocks;
    }
    const services = this.host.appServices();
    if (!services.hasPlugin()) {
      this.trace.upsert('clean_unavailable', 'clean', '联网清洗暂不可用',
        '技能模块没有启动，这一轮先不联网', 'failed');
      return blocks;
    }
    let query: string = '';
    for (let i = path.length - 1; i >= 0; i--) {
      if (path[i].role === 'user') {
        query = collectNodeText(path[i]);
        break;
      }
    }
    if (query.length === 0) {
      return blocks;
    }
    const traceId: string = 'clean_turn';
    this.trace.upsert(traceId, 'clean', '正在联网检索并清洗资料', '只保留高质量来源', 'running');
    this.host.notifyNow();
    try {
      const web = services.requirePlugin().web;
      // ArkTS 不支持结构化类型：WebCleanerApi 要的是 CleanedWebPolicyLike，这里显式构造。
      const policy: CleanedWebPolicyLike = {
        mode: 'standalone_clean',
        includeDomains: [],
        excludeDomains: [],
        minRerankScore: 1.5,
        minAuthority: 0,
        fetchTopK: 0,
        fetchTimeoutMs: 8000
      };
      const docs: CleanedWebDoc[] = await web.search(query, policy);
      const enriched: CleanedWebDoc[] = await web.enrichWithFetch(docs, policy);
      if (enriched.length === 0) {
        this.trace.upsert(traceId, 'clean', '没有找到可用的联网资料', '这一轮按模型自己的知识回答', 'done');
        return blocks;
      }
      blocks.push(web.toPromptBlock(enriched));
      for (const one of enriched) {
        const snippet: string = one.contentForModel.length > 120
          ? `${one.contentForModel.substring(0, 120)}…` : one.contentForModel;
        const ref: SourceRef = {
          title: one.title,
          url: one.url,
          snippet: snippet,
          rerankScore: one.rerankScore,
          authority: one.authority
        };
        if (one.siteName !== undefined) {
          ref.siteName = one.siteName;
        }
        this.trace.addSource(ref);
      }
      this.trace.upsert(traceId, 'clean', '联网清洗完成',
        `清洗后保留 ${enriched.length} 条资料，已回答里会带来源`, 'done');
      this.host.notifyNow();
    } catch (e) {
      this.trace.upsert(traceId, 'clean', '联网清洗没成功',
        `这一轮按模型自己的知识回答：${(e as Error).message}`, 'failed');
    }
    return blocks;
  }
}
