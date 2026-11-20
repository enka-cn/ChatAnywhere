/**
 * 节点编解码与检索文本（packages/core_model/util/NodeCodec.ets）
 *
 * 覆盖：无损 JSON 往返、坏数据容错、FTS5/LIKE 查询串构造、命中片段、JSONL 切分、
 * 会话元信息宽松解析；以及节点预览/NodeBrief 等列表页展示逻辑。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_model/src/main/ets/util/NodeCodec.ts';
const m = await tryImport(P);

if (!m) {
  skip('节点编解码（全部用例）', missingReason(P));
  summarize();
} else {
  const fullNode = {
    nodeId: 'nd1', parentId: 'nd0', sessionId: 's1', role: 'assistant',
    items: [
      { id: 'i1', kind: 'text', text: '这是回答正文', createdAt: 11 },
      { id: 'i2', kind: 'web_search_call', vendorRaw: { provider: 'deepseek', signature: 'SIG', sources: [{ title: 't', url: 'u', snippet: 'sn' }] } }
    ],
    modelId: 'deepseek-flash', providerId: 'deepseek', tokenEstimate: 88, createdAt: 1000,
    activeChildId: 'nd2', archived: true, cachedTokens: 512, promptTokens: 3475,
    completionTokens: 54, cacheHitRatio: 0.147
  };

  test('nodeToJson → nodeFromJson 字段无损往返（含 vendorRaw/usage/archived）', () => {
    const back = m.nodeFromJson(m.nodeToJson(fullNode));
    assert.deepEqual(back, fullNode);
  });

  test('nodeFromJson：非法 JSON / 空串 / null 返回 null，不抛错', () => {
    assert.equal(m.nodeFromJson('{broken'), null);
    assert.equal(m.nodeFromJson(''), null);
    assert.equal(m.nodeFromJson(null), null);
    assert.equal(m.nodeFromJson('null'), null);
    assert.equal(m.nodeFromJson('123'), null);
  });

  test('nodeFromJson：缺 nodeId / sessionId 视为坏数据返回 null', () => {
    assert.equal(m.nodeFromJson('{"sessionId":"s1"}'), null);
    assert.equal(m.nodeFromJson('{"nodeId":"n1"}'), null);
  });

  test('nodeFromJson：缺 items/tokenEstimate/createdAt 时补默认值（不崩）', () => {
    const n = m.nodeFromJson('{"nodeId":"n1","sessionId":"s1","role":"weird"}');
    assert.deepEqual(n.items, []);
    assert.equal(n.tokenEstimate, 0);
    assert.equal(n.createdAt, 0);
    assert.equal(n.parentId, null);
    assert.equal(n.role, 'user'); // 非法角色降级
  });

  test('isNodeRole / toNodeRole', () => {
    assert.equal(m.isNodeRole('user'), true);
    assert.equal(m.isNodeRole('tool'), true);
    assert.equal(m.isNodeRole('nope'), false);
    assert.equal(m.toNodeRole('system'), 'system');
    assert.equal(m.toNodeRole('assistant'), 'assistant');
    assert.equal(m.toNodeRole('bad'), 'user');
  });

  test('nodeSearchText：text / tool_call / tool_result 抽取检索正文', () => {
    const textNode = { ...fullNode, items: [{ id: 'i', kind: 'text', text: '你好世界' }] };
    assert.equal(m.nodeSearchText(textNode), '你好世界');

    const toolNode = { ...fullNode, items: [{ id: 'i', kind: 'tool_call', toolName: 'get_weather', argumentsJson: '{"city":"北京"}' }] };
    assert.ok(m.nodeSearchText(toolNode).includes('get_weather'));
    assert.ok(m.nodeSearchText(toolNode).includes('北京'));

    const resultNode = { ...fullNode, items: [{ id: 'i', kind: 'tool_result', text: '工具返回结果' }] };
    assert.equal(m.nodeSearchText(resultNode), '工具返回结果');
  });

  test('nodeSearchText：web_search_call 抽取来源标题/摘要/URL 与 fallbackSummary', () => {
    const n = {
      ...fullNode,
      items: [{
        id: 'i', kind: 'web_search_call',
        vendorRaw: {
          provider: 'deepseek',
          pageMeta: { url: 'https://p.example', title: '页面标题' },
          sources: [{ title: '来源标题', url: 'https://s.example', snippet: '来源摘要' }]
        },
        fallbackSummary: '降级摘要'
      }]
    };
    const text = m.nodeSearchText(n);
    for (const part of ['页面标题', 'https://p.example', '来源标题', '来源摘要', '降级摘要']) {
      assert.ok(text.includes(part), `应包含 ${part}，实际：${text}`);
    }
  });

  test('nodeSearchText：file_ref / image 抽取 fileId 与 mimeType', () => {
    const n = { ...fullNode, items: [{ id: 'i', kind: 'file_ref', fileId: 'file_1', mimeType: 'application/pdf' }] };
    assert.ok(m.nodeSearchText(n).includes('file_1'));
    assert.ok(m.nodeSearchText(n).includes('application/pdf'));
  });

  test('nodeSearchText：检索文本上限 20000 字符', () => {
    const big = '汉'.repeat(30000);
    const n = { ...fullNode, items: [{ id: 'i', kind: 'text', text: big }] };
    assert.ok(m.nodeSearchText(n).length <= 20000);
  });

  test('nodePreview：优先 text/checkpoint_summary，超长截断到 160 字并加省略号', () => {
    const short = { ...fullNode, items: [{ id: 'i', kind: 'text', text: '  一句话   预览  ' }] };
    assert.equal(m.nodePreview(short), '一句话 预览'); // 连续空白折叠 + trim

    const long = { ...fullNode, items: [{ id: 'i', kind: 'text', text: '长'.repeat(300) }] };
    const preview = m.nodePreview(long);
    assert.equal(preview.length, 161); // 160 + '…'
    assert.ok(preview.endsWith('…'));
  });

  test('nodePreview：无正文时回退其它 item 的 text；完全为空返回空串', () => {
    const reasoning = { ...fullNode, items: [{ id: 'i', kind: 'reasoning', text: '思考内容' }] };
    assert.ok(m.nodePreview(reasoning).includes('思考内容'));
    const empty = { ...fullNode, items: [{ id: 'i', kind: 'tool_call', toolName: 'f' }] };
    assert.equal(m.nodePreview(empty), '');
  });

  test('briefFromNode：携带 childCount、preview 与可选字段', () => {
    const brief = m.briefFromNode(fullNode, 3);
    assert.equal(brief.nodeId, 'nd1');
    assert.equal(brief.childCount, 3);
    assert.equal(brief.activeChildId, 'nd2');
    assert.equal(brief.archived, true);
    assert.equal(brief.parentId, 'nd0');
    assert.ok(brief.preview.length > 0);
  });

  test('buildFtsQuery：按空白切词、双引号包裹、OR 连接（trigram 分词器要求 ≥3 字）', () => {
    // 实现阈值：短于 3 字的词丢弃（FTS5 trigram 分词器要求），交给 LIKE 兜底
    assert.equal(m.buildFtsQuery('DeepSeek 缓存'), '"DeepSeek"');
    assert.equal(m.buildFtsQuery('DeepSeek 缓存机制'), '"DeepSeek" OR "缓存机制"');
  });

  test('buildFtsQuery：丢弃短于 3 字的词与空串；无有效词返回空串', () => {
    assert.equal(m.buildFtsQuery('我想 查 天气'), '');
    assert.equal(m.buildFtsQuery('缓存机制 天气预报'), '"缓存机制" OR "天气预报"');
    assert.equal(m.buildFtsQuery(''), '');
    assert.equal(m.buildFtsQuery('a b c'), '');
    assert.equal(m.buildFtsQuery(null), '');
  });

  test('buildFtsQuery：剔除破坏 FTS5 语法的字符（引号/括号/星号/冒号等）', () => {
    const q = m.buildFtsQuery('破坏语*法括(测试)号 正常词');
    assert.ok(!q.includes('(') && !q.includes(')') && !q.includes('*') && !q.includes(':'));
    assert.ok(q.includes('"破坏语"'), q);
    assert.ok(q.includes('"法括"') || q.includes('"号"') || q.includes('"正常词"'), q);
    assert.ok(q.includes('"正常词"'), q);
  });

  test('buildFtsQuery：最多 8 个词（防止恶意超长查询）', () => {
    const terms = Array.from({ length: 20 }, (_, i) => `关键词${i}`).join(' ');
    const q = m.buildFtsQuery(terms);
    assert.equal(q.split(' OR ').length, 8);
  });

  test('likePattern：转义 LIKE 通配符 % _ 与反斜杠', () => {
    assert.equal(m.likePattern('100%'), '%100\\%%');
    assert.equal(m.likePattern('a_b'), '%a\\_b%');
    assert.equal(m.likePattern('c\\d'), '%c\\\\d%');
  });

  test('makeSnippet：命中位置前后截取并加省略号', () => {
    const text = '前'.repeat(50) + '目标关键词' + '后'.repeat(50);
    const snip = m.makeSnippet(text, '目标关键词', 5);
    assert.ok(snip.includes('目标关键词'));
    assert.ok(snip.startsWith('…'));
    assert.ok(snip.endsWith('…'));
  });

  test('makeSnippet：未命中时取开头；空文本返回空串；window<=0 用默认 24', () => {
    const long = 'x'.repeat(100);
    assert.equal(m.makeSnippet(long, 'zzz', 2), 'xxxx…');
    assert.equal(m.makeSnippet('', 'q', 5), '');
    assert.equal(m.makeSnippet(long, '', -1), 'x'.repeat(48) + '…');
  });

  test('makeSnippet：英文大小写不敏感命中', () => {
    const snip = m.makeSnippet('Hello DeepSeek World', 'deepseek', 3);
    assert.ok(snip.includes('DeepSeek'));
  });

  test('splitJsonLines：过滤空行与 CRLF 残留', () => {
    assert.deepEqual(m.splitJsonLines('{"a":1}\r\n\r\n  \n{"b":2}\n'), ['{"a":1}', '{"b":2}']);
    assert.deepEqual(m.splitJsonLines(''), []);
    assert.deepEqual(m.splitJsonLines(null), []);
  });

  test('sessionMetaFromRaw：缺 sessionId 返回 null；缺省字段补默认值', () => {
    assert.equal(m.sessionMetaFromRaw({ title: 'x' }), null);
    const meta = m.sessionMetaFromRaw({ sessionId: 's1' });
    assert.equal(meta.sessionId, 's1');
    assert.equal(meta.title, '导入的会话');
    assert.ok(meta.createdAt > 0);
    assert.ok(meta.updatedAt > 0);
  });

  test('sessionMetaFromRaw：保留已知可选字段', () => {
    const meta = m.sessionMetaFromRaw({
      sessionId: 's1', title: '会话', createdAt: 100, updatedAt: 200, modelId: 'm', providerId: 'p',
      pinned: true, nodeCount: 5, totalTokens: 900
    });
    assert.equal(meta.title, '会话');
    assert.equal(meta.createdAt, 100);
    assert.equal(meta.pinned, true);
    assert.equal(meta.nodeCount, 5);
    assert.equal(meta.totalTokens, 900);
  });

  test('sessionMetaToJsonArray 可被 JSON.parse 还原', () => {
    const arr = [m.sessionMetaFromRaw({ sessionId: 's1' }), m.sessionMetaFromRaw({ sessionId: 's2' })];
    const parsed = JSON.parse(m.sessionMetaToJsonArray(arr));
    assert.equal(parsed.length, 2);
    assert.equal(parsed[1].sessionId, 's2');
  });

  summarize();
}
