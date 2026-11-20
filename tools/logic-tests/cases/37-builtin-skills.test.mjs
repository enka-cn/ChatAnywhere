/**
 * 内置示例技能（packages/core_plugin/BuiltinSkills.ets）
 *
 * 对应 Blueprint Milestone 3：至少 3 个可用的 L1 技能（这里 4 个），带 configSchema /
 * toolSchema / promptSnippet / allowedDomains；且必须通过 SkillSchema 校验、不含明文密钥。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_plugin/src/main/ets/BuiltinSkills.ts';
const SCHEMA_P = 'packages/core_plugin/src/main/ets/SkillSchema.ts';
const B = await tryImport(P);
const S = await tryImport(SCHEMA_P);

if (!B) {
  skip('内置技能（全部用例）', missingReason(P));
  summarize();
} else if (!S) {
  skip('内置技能校验（SkillSchema 产物缺失）', missingReason(SCHEMA_P));
  summarize();
} else {
  const EXPECTED_IDS = ['fx_rate_convert', 'tech_doc_search', 'weather_now', 'web_article_extract'];

  test('内置技能清单：4 个技能、按 skill id 字典序稳定排列', () => {
    const list = B.builtinSkillJsonList();
    assert.equal(list.length, 4);
    assert.deepEqual(B.builtinSkillIds(), EXPECTED_IDS);
    const parsedIds = list.map((json) => JSON.parse(json).id);
    assert.deepEqual(parsedIds, EXPECTED_IDS);
    assert.deepEqual(parsedIds, [...parsedIds].sort(), '必须按 skill id 字典序排列（缓存前缀稳定）');
    assert.deepEqual(list, B.builtinSkillJsonList());
  });

  test('每个内置技能都能通过 SkillSchema 校验（L1 声明式、含工具声明/提示词/白名单）', () => {
    for (const json of B.builtinSkillJsonList()) {
      const result = S.validateManifestJson(json);
      assert.equal(result.ok, true, `校验失败：${result.error}`);
      assert.ok(Array.isArray(result.warnings));
    }
  });

  test('每个内置技能的关键字段完整且可用', () => {
    for (const json of B.builtinSkillJsonList()) {
      const rec = JSON.parse(json);
      assert.equal(rec.tier, 'L1_DECLARATIVE');
      assert.equal(rec.enabled, true);
      assert.equal(rec.author, 'builtin');
      assert.ok(rec.version.match(/^\d+\.\d+\.\d+$/));
      assert.ok(/[\u4e00-\u9fff]/.test(rec.name), `中文名：${rec.name}`);
      assert.ok(rec.description.length > 0);
      assert.ok(rec.promptSnippet.length > 0);
      assert.ok(rec.configSchema.length > 0);
      assert.ok(rec.runtimePayload.allowedDomains.length > 0);

      const tool = JSON.parse(rec.toolSchemaJson);
      assert.ok(tool.name.length > 0);
      assert.ok(tool.description.length > 0);
      assert.equal(tool.parameters.type, 'object');
    }
  });

  test('内置技能不含明文密钥：DeepSeek 相关技能用 {{secret:别名}} 占位符', () => {
    const text = B.builtinSkillJsonList().join('\n');
    assert.ok(!/sk-[A-Za-z0-9]{16,}/.test(text), '不得出现明文 sk- 密钥');
    assert.ok(text.includes('{{secret:deepseek.apiKey}}'));
    assert.ok(!text.includes('api.deepseek.com'.replace('api.', 'sk-')));
  });

  test('tech_doc_search：请求体模板带 config 占位符，responsePath=results', () => {
    const rec = JSON.parse(B.builtinWebSearchJson());
    const template = rec.runtimePayload.httpTemplate;
    assert.equal(template.urlTemplate, 'https://api.deepseek.com/v1/tools/search');
    assert.equal(template.method, 'POST');
    assert.equal(template.responsePath, 'results');
    assert.ok(template.bodyTemplate.includes('{{config.count}}'));
    assert.ok(template.bodyTemplate.includes('{{input.query}}'));
    assert.ok(rec.configSchema.some((f) => f.key === 'blockedSites'));
    assert.deepEqual(rec.runtimePayload.allowedDomains, ['api.deepseek.com']);
  });

  test('web_article_extract：urlTemplate 指向 fetch 端点、responsePath=content', () => {
    const rec = JSON.parse(B.builtinWebExtractJson());
    assert.equal(rec.runtimePayload.httpTemplate.urlTemplate, 'https://api.deepseek.com/v1/tools/fetch');
    assert.equal(rec.runtimePayload.httpTemplate.responsePath, 'content');
    assert.ok(rec.runtimePayload.httpTemplate.bodyTemplate.includes('{{input.url}}'));
  });

  test('fx_rate_convert / weather_now：无需密钥、GET 模板含输入占位符、白名单匹配域名', () => {
    const fx = JSON.parse(B.builtinFxRateJson());
    assert.equal(fx.runtimePayload.httpTemplate.method, 'GET');
    assert.ok(fx.runtimePayload.httpTemplate.urlTemplate.includes('{{input.from}}'));
    assert.deepEqual(fx.runtimePayload.allowedDomains, ['open.er-api.com']);

    const weather = JSON.parse(B.builtinWeatherJson());
    assert.ok(weather.toolSchemaJson.length > 0);
    assert.ok(weather.runtimePayload.httpTemplate.urlTemplate.includes('{{input.latitude}}'));
    assert.deepEqual(weather.runtimePayload.allowedDomains, ['api.open-meteo.com']);
  });

  test('默认配置生成：每个技能的 configSchema 都能生成可解析的默认配置', () => {
    for (const json of B.builtinSkillJsonList()) {
      const defaults = JSON.parse(S.buildDefaultConfigJson(json));
      assert.ok(Object.keys(defaults).length > 0);
      const rec = JSON.parse(json);
      for (const field of rec.configSchema) {
        assert.ok(Object.prototype.hasOwnProperty.call(defaults, field.key), `缺默认值：${field.key}`);
      }
    }
    const searchDefaults = JSON.parse(S.buildDefaultConfigJson(B.builtinWebSearchJson()));
    assert.equal(searchDefaults.count, 10);
    assert.equal(searchDefaults.needContent, false);
    assert.equal(searchDefaults.outputFormat, 'summary');
    assert.deepEqual(searchDefaults.blockedSites, []);
  });

  test('内置技能 JSON 生成幂等（两次调用内容一致）', () => {
    assert.equal(B.builtinWebSearchJson(), B.builtinWebSearchJson());
    assert.deepEqual(B.builtinSkillJsonList(), B.builtinSkillJsonList());
  });

  summarize();
}
