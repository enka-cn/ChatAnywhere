/**
 * 技能创造室的本地规则草稿（packages/core_plugin/util/CreatorHeuristic.ets）
 *
 * 对应 Blueprint Milestone 4 的最短演示路径：无 Key 时用自然语言「屏蔽某站点 / 调整输出格式」
 * 也能生成可通过 Schema 校验的草稿 + 中文 Diff + 试跑输入（heuristicDraftRaw），
 * 以及「从对话沉淀为技能」（distillDraftRaw）。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_plugin/src/main/ets/util/CreatorHeuristic.ts';
const SCHEMA_P = 'packages/core_plugin/src/main/ets/SkillSchema.ts';
const BUILTIN_P = 'packages/core_plugin/src/main/ets/BuiltinSkills.ts';
const H = await tryImport(P);
const S = await tryImport(SCHEMA_P);
const B = await tryImport(BUILTIN_P);

if (!H) {
  skip('技能创造室本地规则（全部用例）', missingReason(P));
  summarize();
} else if (!S || !B) {
  skip('技能创造室本地规则（依赖缺失）', missingReason(!S ? SCHEMA_P : BUILTIN_P));
  summarize();
} else {
  const parse = (json) => JSON.parse(json);
  const configOf = (result) => parse(parse(result.draftManifestJson).savedConfigJson);

  test('空需求返回中文提示（不生成草稿）', () => {
    const r = H.heuristicDraftRaw('', '');
    assert.equal(r.ok, false);
    assert.ok(r.error.includes('一句话'));
    assert.equal(r.draftManifestJson, '');
  });

  test('自然语言新建 Web 清洗技能：识别「屏蔽站点」与「markdown 输出」', () => {
    const r = H.heuristicDraftRaw('帮我做个技能：联网搜索技术文档时屏蔽 bilibili.com，输出 markdown', '');
    assert.equal(r.ok, true, r.error);
    const draft = parse(r.draftManifestJson);
    assert.equal(draft.tier, 'L1_DECLARATIVE');
    assert.ok(draft.name.length > 0);
    assert.ok(draft.description.includes('屏蔽'));
    assert.ok(draft.runtimePayload.allowedDomains.length > 0);

    const config = configOf(r);
    assert.deepEqual(config.blockedSites, ['bilibili.com']);
    assert.equal(config.outputFormat, 'markdown');

    assert.ok(r.summary.includes('屏蔽 bilibili.com'), r.summary);
    assert.ok(r.summary.includes('Markdown'), r.summary);
    assert.ok(r.diffText.length > 0);
    const warnings = parse(r.securityWarningsJson);
    assert.ok(Array.isArray(warnings));
    const sample = parse(r.sampleInput);
    assert.ok(typeof sample === 'object');
  });

  test('改造现有技能：版本号 patch +1、保留原有配置、Diff 标记新增屏蔽域名', () => {
    const oldManifest = B.builtinWebSearchJson();
    const r = H.heuristicDraftRaw('在技术文档清洗技能里屏蔽 zhihu.com，每次只要 5 条', oldManifest);
    assert.equal(r.ok, true, r.error);
    const draft = parse(r.draftManifestJson);
    assert.equal(draft.id, 'tech_doc_search');
    assert.equal(draft.version, '1.0.1');
    const config = configOf(r);
    assert.ok(config.blockedSites.includes('zhihu.com'));
    assert.equal(config.count, 5);
    assert.ok(r.diffText.includes('+ 新增屏蔽域名：zhihu.com'), r.diffText);
    assert.ok(r.diffText.includes('~ 版本：1.0.0 → 1.0.1'), r.diffText);
  });

  test('识别数量 / 抓取篇数 / 超时 / 相关度阈值等配置意图', () => {
    // 注意：count 规则取文本中第一个「N 条/篇」，因此把「每次 N 条」写在最前面
    const r = H.heuristicDraftRaw('每次 8 条，联网搜索时抓取前 3 篇正文，超时 10 秒，相关度 2', '');
    assert.equal(r.ok, true, r.error);
    const config = configOf(r);
    assert.equal(config.fetchTopK, 3);
    assert.equal(config.fetchTimeoutMs, 10000);
    assert.equal(config.minRerankScore, 2);
    assert.equal(config.count, 8);
  });

  test('相关度支持一位小数（2.5 不再被截断为整数）', () => {
    const r = H.heuristicDraftRaw('相关度 2.5', '');
    assert.equal(r.ok, true, r.error);
    // 实现已用 firstDecimal 解析阈值；验证不再按 parseInt 截断成 2
    assert.equal(configOf(r).minRerankScore, 2.5);
  });

  test('需求含汇率关键词时套用汇率技能模板（GET + 公开汇率域名 + 示例输入）', () => {
    const r = H.heuristicDraftRaw('做一个美元换算人民币的技能', '');
    assert.equal(r.ok, true, r.error);
    const draft = parse(r.draftManifestJson);
    assert.equal(draft.id, 'fx_rate_convert');
    assert.ok(draft.runtimePayload.allowedDomains.includes('open.er-api.com'));
    assert.equal(draft.runtimePayload.httpTemplate.method, 'GET');
    const sample = parse(r.sampleInput);
    assert.equal(sample.from, 'USD');
    assert.equal(sample.to, 'CNY');
  });

  test('需求含天气关键词时套用天气技能模板（示例输入为经纬度）', () => {
    const r = H.heuristicDraftRaw('我要查实时天气', '');
    assert.equal(r.ok, true, r.error);
    const draft = parse(r.draftManifestJson);
    assert.equal(draft.id, 'weather_now');
    const sample = parse(r.sampleInput);
    assert.ok(Object.prototype.hasOwnProperty.call(sample, 'latitude'));
    assert.ok(Object.prototype.hasOwnProperty.call(sample, 'longitude'));
  });

  test('无匹配模板时生成「纯提示词技能」并通过 Schema 校验', () => {
    const r = H.heuristicDraftRaw('做一个专门安慰人的聊天技能', '');
    assert.equal(r.ok, true, r.error);
    const draft = parse(r.draftManifestJson);
    assert.equal(draft.tier, 'L1_DECLARATIVE');
    assert.ok(draft.promptSnippet.includes('安慰'));
    assert.deepEqual(draft.runtimePayload.allowedDomains, []);
    assert.equal(draft.runtimePayload.httpTemplate, undefined);
    assert.equal(S.validateManifestJson(r.draftManifestJson).ok, true);
    const warnings = parse(r.securityWarningsJson);
    assert.ok(warnings.some((w) => w.includes('只注入提示词')), JSON.stringify(warnings));
    assert.equal(r.sampleInput, '{}');
  });

  test('所有成功草稿都必须是合法 JSON 且通过 validateManifestJson', () => {
    const requirements = [
      '联网检索技术资料并屏蔽 example.com，输出要点列表',
      '查天气预报',
      '美元兑人民币换算，保留 4 位小数',
      '帮我润色文档'
    ];
    for (const req of requirements) {
      const r = H.heuristicDraftRaw(req, B.builtinWebSearchJson());
      assert.equal(r.ok, true, `${req} → ${r.error}`);
      const parsed = parse(r.draftManifestJson);
      assert.ok(parsed.id.length > 0);
      assert.equal(S.validateManifestJson(r.draftManifestJson).ok, true);
    }
  });

  // ---------------- 从对话沉淀 ----------------
  test('distillDraftRaw：空对话返回中文提示', () => {
    const r = H.distillDraftRaw('', '');
    assert.equal(r.ok, false);
    assert.ok(r.error.includes('没有可以提炼'));
  });

  test('distillDraftRaw：无旧清单时生成「对话沉淀技能」提示词草稿', () => {
    const r = H.distillDraftRaw('用户：请每次都先列结论再解释\n助手：好的，我记住了。', '');
    assert.equal(r.ok, true, r.error);
    const draft = parse(r.draftManifestJson);
    assert.equal(draft.name, '对话沉淀技能');
    assert.equal(draft.version, '1.0.0');
    assert.ok(draft.description.includes('从对话沉淀'), draft.description);
    assert.ok(draft.promptSnippet.includes('沿用其中的处理方式'), draft.promptSnippet);
    assert.ok(r.summary.includes('沉淀'));
    assert.equal(S.validateManifestJson(r.draftManifestJson).ok, true);
  });

  test('distillDraftRaw：有旧清单时在原有提示词后补充要点并递增版本', () => {
    const oldManifest = B.builtinWebSearchJson();
    const r = H.distillDraftRaw('用户：以后引用资料时按 [1][2] 标号\n助手：明白。', oldManifest);
    assert.equal(r.ok, true, r.error);
    const draft = parse(r.draftManifestJson);
    assert.equal(draft.id, 'tech_doc_search');
    assert.equal(draft.version, '1.0.1');
    assert.ok(draft.promptSnippet.includes('按 [1][2] 标号'), draft.promptSnippet);
    assert.ok(draft.promptSnippet.includes('检索到外部资料时'), '应保留旧提示词');
    assert.ok(r.diffText.includes('~ 版本：1.0.0 → 1.0.1'), r.diffText);
    assert.ok(r.summary.includes('补充'));
  });

  summarize();
}
