/**
 * SKILL.md ↔ SkillManifest 双向编解码（packages/core_plugin/SkillMarkdown.ets）
 *
 * v3 技能创造室改用 SKILL.md 编辑器，frontmatter/正文与 SkillManifest JSON 的互转必须可往返：
 * - 4 个内置技能的 `toManifestJson(toMarkdown(m), m)` 必须 ok 且关键字段不丢；
 * - 未知 frontmatter 键降级为配置项并告警（不丢信息）；
 * - 非法 tier / 空内容给出中文错误；
 * - L1 endpoint/请求模板、L2 MCP、L3 脚本、工具声明、域名列表、配置项都要能读写。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const MD_P = 'packages/core_plugin/src/main/ets/SkillMarkdown.ts';
const B_P = 'packages/core_plugin/src/main/ets/BuiltinSkills.ts';
const S_P = 'packages/core_plugin/src/main/ets/SkillSchema.ts';
const [MD, B, S] = await Promise.all([tryImport(MD_P), tryImport(B_P), tryImport(S_P)]);

if (!MD || !MD.SkillMarkdownCodec) {
  skip('SKILL.md 编解码（全部用例）', missingReason(MD_P));
  summarize();
} else if (!B || !S) {
  skip('SKILL.md 编解码（依赖缺失）', missingReason(!B ? B_P : S_P));
  summarize();
} else {
  const Codec = MD.SkillMarkdownCodec;
  const parse = (json) => JSON.parse(json);

  test('4 个内置技能：Manifest → SKILL.md → Manifest 往返成功且关键字段不丢', () => {
    for (const manifestJson of B.builtinSkillJsonList()) {
      const base = parse(manifestJson);
      const markdown = Codec.toMarkdown(manifestJson);
      assert.ok(markdown.startsWith('---'), `${base.id} 的 SKILL.md 缺少 frontmatter`);
      assert.ok(markdown.includes(`name: ${base.name}`), `${base.id} 的 name 未写入`);

      const result = Codec.toManifestJson(markdown, manifestJson);
      assert.equal(result.ok, true, `${base.id} 往返失败：${result.error}`);
      const back = parse(result.manifestJson);
      assert.equal(back.id, base.id);
      assert.equal(back.name, base.name);
      assert.equal(back.tier, base.tier);
      assert.equal(back.version, base.version);
      assert.equal(back.description, base.description);
      assert.deepEqual(back.runtimePayload.allowedDomains, base.runtimePayload.allowedDomains);
      if (base.runtimePayload.httpTemplate !== undefined) {
        assert.equal(back.runtimePayload.httpTemplate.urlTemplate, base.runtimePayload.httpTemplate.urlTemplate);
        assert.equal(back.runtimePayload.httpTemplate.method, base.runtimePayload.httpTemplate.method);
        assert.equal(back.runtimePayload.httpTemplate.responsePath, base.runtimePayload.httpTemplate.responsePath);
      }
      assert.ok(parse(back.toolSchemaJson).name === parse(base.toolSchemaJson).name, `${base.id} 工具声明丢失`);
      assert.equal(back.configSchema.length, base.configSchema.length, `${base.id} 配置项数量变化`);
      // 往返结果必须仍能通过 Schema 校验
      assert.equal(S.validateManifestJson(result.manifestJson).ok, true);
    }
  });

  test('往返幂等：toMarkdown 再解析一次，关键 frontmatter 稳定（不丢层级/域名/工具）', () => {
    for (const manifestJson of B.builtinSkillJsonList()) {
      const once = Codec.toMarkdown(manifestJson);
      const manifest2 = Codec.toManifestJson(once, manifestJson);
      assert.equal(manifest2.ok, true);
      const twice = Codec.toMarkdown(manifest2.manifestJson);
      const base = parse(manifestJson);
      assert.ok(twice.includes(`id: ${base.id}`));
      assert.ok(twice.includes(`name: ${base.name}`));
      assert.ok(twice.includes(`allowed_domains: ${base.runtimePayload.allowedDomains.join(', ')}`), base.id);
    }
  });

  test('newTemplate：生成的模板可直接解析为合法技能（L1 纯提示词）', () => {
    const md = Codec.newTemplate();
    const result = Codec.toManifestJson(md, '');
    assert.equal(result.ok, true, result.error);
    const manifest = parse(result.manifestJson);
    assert.equal(manifest.tier, 'L1_DECLARATIVE');
    assert.ok(manifest.promptSnippet.length > 0);
    assert.equal(S.validateManifestJson(result.manifestJson).ok, true);
  });

  test('空内容 / 非法 tier → 中文错误', () => {
    const empty = Codec.toManifestJson('   ', '');
    assert.equal(empty.ok, false);
    assert.ok(empty.error.includes('不能为空'));
    const badTier = Codec.toManifestJson('---\nid: a\ntier: 豪华版\n---\n正文', '');
    assert.equal(badTier.ok, false);
    assert.ok(badTier.error.includes('无法识别技能分级'), badTier.error);
  });

  test('tier 中文别名与 L1/L2/L3 兼容解析', () => {
    const l1 = Codec.toManifestJson('---\nid: alias_l1\nname: 测试\nversion: 1.0.0\ntier: 声明式\n---\n正文提示词', '');
    assert.equal(l1.ok, true, l1.error);
    assert.equal(parse(l1.manifestJson).tier, 'L1_DECLARATIVE');

    const l2 = Codec.toManifestJson(
      '---\nid: alias_l2\nname: 测试\nversion: 1.0.0\ntier: 远程 MCP\nendpoint: https://mcp.example.com/sse\nallowed_domains: mcp.example.com\n---\n正文提示词', '');
    assert.equal(l2.ok, true, l2.error);
    assert.equal(parse(l2.manifestJson).tier, 'L2_REMOTE_MCP');

    const l3 = Codec.toManifestJson(
      '---\nid: alias_l3\nname: 测试\nversion: 1.0.0\ntier: L3\nquick_js: function run(input) { return input; }\n---\n正文提示词', '');
    assert.equal(l3.ok, true, l3.error);
    assert.equal(parse(l3.manifestJson).tier, 'L3_QUICKJS_SANDBOX');
  });

  test('L2：endpoint 写入 mcpEndpoint，域名列表可解析（含 JSON 数组写法）', () => {
    const md = `---
id: mcp_demo
name: 远程技能
version: 1.0.0
tier: 远程 MCP
endpoint: https://mcp.example.com/sse
allowed_domains: ["mcp.example.com", "api.example.com"]
transport: sse
---
调用远程服务处理任务。`;
    const r = Codec.toManifestJson(md, '');
    assert.equal(r.ok, true, r.error);
    const m = parse(r.manifestJson);
    assert.equal(m.runtimePayload.mcpEndpoint, 'https://mcp.example.com/sse');
    assert.equal(m.runtimePayload.mcpTransport, 'sse');
    assert.deepEqual(m.runtimePayload.allowedDomains, ['mcp.example.com', 'api.example.com']);
  });

  test('L1：endpoint/method/request_body/response_path/工具声明可读写', () => {
    const md = `---
id: api_demo
name: 接口技能
version: 1.0.0
tier: 声明式
endpoint: https://api.example.com/v1/search
method: POST
allowed_domains: api.example.com
request_body: {"q":"{{input.q}}"}
response_path: data.results
tool: search_api
tool_description: 搜索接口
tool_parameters: {"type":"object","properties":{"q":{"type":"string"}}}
---
使用接口前先确认参数。`;
    const r = Codec.toManifestJson(md, '');
    assert.equal(r.ok, true, r.error);
    const m = parse(r.manifestJson);
    assert.equal(m.runtimePayload.httpTemplate.urlTemplate, 'https://api.example.com/v1/search');
    assert.equal(m.runtimePayload.httpTemplate.method, 'POST');
    assert.equal(m.runtimePayload.httpTemplate.responsePath, 'data.results');
    assert.equal(m.runtimePayload.httpTemplate.bodyTemplate, '{"q":"{{input.q}}"}');
    const tool = parse(m.toolSchemaJson);
    assert.equal(tool.name, 'search_api');
    assert.equal(tool.parameters.properties.q.type, 'string');
  });

  test('未知 frontmatter 键 → 降级为配置项并告警（不丢信息）', () => {
    const md = `---
id: cfg_demo
name: 配置技能
version: 1.0.0
tier: 声明式
my_threshold: 3
my_flag: true
---
正文。`;
    const r = Codec.toManifestJson(md, '');
    assert.equal(r.ok, true, r.error);
    const m = parse(r.manifestJson);
    const keys = m.configSchema.map((f) => f.key);
    assert.ok(keys.includes('my_threshold') && keys.includes('my_flag'), keys.join(','));
    const saved = parse(m.savedConfigJson);
    assert.equal(saved.my_threshold, 3);
    assert.equal(saved.my_flag, true);
    assert.ok(r.warnings.some((w) => w.includes('未知键')), JSON.stringify(r.warnings));
  });

  test('已有 base 的配置项：frontmatter 值写回 defaultValueJson 与 savedConfigJson', () => {
    const base = B.builtinWebSearchJson();
    const md = Codec.toMarkdown(base).replace(/count: \d+/, 'count: 7');
    const r = Codec.toManifestJson(md, base);
    assert.equal(r.ok, true, r.error);
    const m = parse(r.manifestJson);
    const countSpec = m.configSchema.find((f) => f.key === 'count');
    assert.equal(JSON.parse(countSpec.defaultValueJson), 7);
    assert.equal(parse(m.savedConfigJson).count, 7);
  });

  test('无 frontmatter / 未闭合 frontmatter：按正文提示词处理并告警（不崩）', () => {
    const plain = Codec.toManifestJson('只有一段正文，没有 frontmatter', '');
    assert.equal(plain.ok, false, '无 id 的纯正文无法构成合法清单');
    // 有 base 时纯正文应保留 base 并更新提示词
    const base = B.builtinFxRateJson();
    const plainWithBase = Codec.toManifestJson('新的正文提示词', base);
    assert.equal(plainWithBase.ok, true, plainWithBase.error);
    assert.equal(parse(plainWithBase.manifestJson).promptSnippet, '新的正文提示词');
    assert.ok(plainWithBase.warnings.some((w) => w.includes('没有找到 frontmatter')));

    const malformed = Codec.toManifestJson('---\nid: x\n正文没有结束标记', '');
    assert.ok(malformed.warnings.some((w) => w.includes('缺少结束的')), JSON.stringify(malformed.warnings));
  });

  test('toMarkdown：非法/空清单返回空串；不产生明文密钥', () => {
    assert.equal(Codec.toMarkdown(''), '');
    assert.equal(Codec.toMarkdown('{bad'), '');
    for (const manifestJson of B.builtinSkillJsonList()) {
      const md = Codec.toMarkdown(manifestJson);
      assert.ok(!/sk-[A-Za-z0-9]{16,}/.test(md), 'SKILL.md 不应含明文密钥');
    }
  });

  test('内置技能 SKILL.md 往返后仍通过 Schema 校验（防止 UI 保存被拒）', () => {
    for (const manifestJson of B.builtinSkillJsonList()) {
      const md = Codec.toMarkdown(manifestJson);
      const r = Codec.toManifestJson(md, manifestJson);
      assert.equal(r.ok, true, `${parse(manifestJson).id}: ${r.error}`);
      assert.equal(S.validateManifestJson(r.manifestJson).ok, true, `${parse(manifestJson).id} 校验失败`);
    }
  });

  summarize();
}
