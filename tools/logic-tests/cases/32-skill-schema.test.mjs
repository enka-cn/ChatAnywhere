/**
 * 技能 Schema 校验（packages/core_plugin/SkillSchema.ets）
 *
 * QA 清单要求：缺 id / 非法 tier / 域名缺失；补充覆盖 id/版本/HTTP 模板/白名单/https 强制、
 * 明文密钥检测、L3 禁用能力、configSchema 类型与范围校验、默认值生成、中文摘要。
 * 依据 Blueprint §3.5 与 SkillManifest 契约（configSchema 为数组、toolSchemaJson 为 JSON 文本）。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_plugin/src/main/ets/SkillSchema.ts';
const S = await tryImport(P);

if (!S) {
  skip('SkillSchema 校验（全部用例）', missingReason(P));
  summarize();
} else {
  function validL1(over = {}) {
    return {
      id: 'web_clean',
      version: '1.0.0',
      name: '技术文档联网清洗',
      description: '把抓到的网页洗成干净的正文',
      tier: 'L1_DECLARATIVE',
      enabled: true,
      configSchema: [
        { key: 'minRerankScore', label: '最低相关度', type: 'number', defaultValueJson: '1.5', min: 0, max: 3 },
        { key: 'outputFormat', label: '输出格式', type: 'enum', defaultValueJson: '"summary"', options: ['summary', 'markdown'] },
        { key: 'blockedDomains', label: '屏蔽域名', type: 'string_list', defaultValueJson: '[]' },
        { key: 'enableCache', label: '启用缓存', type: 'boolean', defaultValueJson: 'true' }
      ],
      runtimePayload: {
        httpTemplate: {
          method: 'POST',
          urlTemplate: 'https://api.example.com/clean',
          headersJson: '{"Content-Type":"application/json"}',
          bodyTemplate: '{"url":"{{input.url}}"}',
          timeoutMs: 8000
        },
        allowedDomains: ['api.example.com']
      },
      toolSchemaJson: JSON.stringify({
        name: 'clean_web', description: '清洗网页正文', parameters: { type: 'object', properties: {} }
      }),
      ...over
    };
  }
  const j = (obj) => JSON.stringify(obj);

  // ---------------- 基础校验器 ----------------
  test('isValidSkillId：小写字母开头、2-48 位、只含小写/数字/下划线', () => {
    assert.equal(S.isValidSkillId('web_clean'), true);
    assert.equal(S.isValidSkillId('ab'), true);
    assert.equal(S.isValidSkillId('a'), false);
    assert.equal(S.isValidSkillId('WebClean'), false);
    assert.equal(S.isValidSkillId('1abc'), false);
    assert.equal(S.isValidSkillId('_ab'), false);
    assert.equal(S.isValidSkillId('a' .repeat(49)), false);
    assert.equal(S.isValidSkillId(null), false);
  });

  test('isValidVersion / bumpPatchVersion', () => {
    assert.equal(S.isValidVersion('1.0.0'), true);
    assert.equal(S.isValidVersion('1.0'), false);
    assert.equal(S.isValidVersion('v1.0.0'), false);
    assert.equal(S.bumpPatchVersion('1.2.3'), '1.2.4');
    assert.equal(S.bumpPatchVersion('bad'), '1.0.1');
  });

  test('tierLabel / isKnownTier：三分级中文名', () => {
    assert.equal(S.tierLabel('L1_DECLARATIVE'), 'L1 声明式');
    assert.equal(S.tierLabel('L2_REMOTE_MCP'), 'L2 远程服务');
    assert.equal(S.tierLabel('L3_QUICKJS_SANDBOX'), 'L3 端侧脚本');
    assert.equal(S.tierLabel('weird'), '未知分级');
    assert.equal(S.isKnownTier('L2_REMOTE_MCP'), true);
    assert.equal(S.isKnownTier('L9'), false);
  });

  test('defaultJsonForType：五种字段类型的默认值', () => {
    assert.equal(S.defaultJsonForType('boolean', []), 'false');
    assert.equal(S.defaultJsonForType('number', []), '0');
    assert.equal(S.defaultJsonForType('string', []), '""');
    assert.equal(S.defaultJsonForType('string_list', []), '[]');
    assert.equal(S.defaultJsonForType('enum', ['a', 'b']), '"a"');
  });

  // ---------------- validateManifestJson 主路径 ----------------
  test('合法 L1 清单校验通过（error 为空）', () => {
    const result = S.validateManifestJson(j(validL1()));
    assert.equal(result.ok, true, `期望通过，实际错误：${result.error}`);
    assert.equal(result.error, '');
    assert.ok(Array.isArray(result.warnings));
  });

  test('缺 id → 校验失败且中文错误含「缺少技能 id」', () => {
    const result = S.validateManifestJson(j(validL1({ id: '' })));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('缺少技能 id'), result.error);
  });

  test('非法 id（大写/带横线）→ 校验失败并说明命名规则', () => {
    const result = S.validateManifestJson(j(validL1({ id: 'Bad-ID' })));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('不合法'));
    assert.ok(result.error.includes('小写字母'));
  });

  test('非法 tier → 校验失败且列出三个合法分级', () => {
    const result = S.validateManifestJson(j(validL1({ tier: 'L9_MAGIC' })));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('分级'));
    assert.ok(result.error.includes('L1'));
  });

  test('非法版本号 → 校验失败', () => {
    const result = S.validateManifestJson(j(validL1({ version: '1.0' })));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('版本号'));
  });

  test('L1 既无 HTTP 模板也无提示词片段 → 校验失败', () => {
    const manifest = validL1({ runtimePayload: { allowedDomains: ['api.example.com'] }, toolSchemaJson: '' });
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('HTTP 模板或提示词片段'));
  });

  test('L1 请求地址不是 https（且非本地回环）→ 校验失败', () => {
    const manifest = validL1();
    manifest.runtimePayload.httpTemplate.urlTemplate = 'http://api.example.com/clean';
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('https://'), result.error);
  });

  test('L1 请求域名不在 allowedDomains 白名单 → 校验失败（默认拒绝）', () => {
    const manifest = validL1({ runtimePayload: { ...validL1().runtimePayload, allowedDomains: ['other.com'] } });
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('白名单'), result.error);
  });

  test('非法域名（通配符）→ 校验失败并说明只能填域名', () => {
    const manifest = validL1({ runtimePayload: { ...validL1().runtimePayload, allowedDomains: ['*.example.com'] } });
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('域名白名单'), result.error);
    assert.ok(result.error.includes('通配符'), result.error);
  });

  test('请求头出现明文 sk- 密钥 → 校验失败并提示改用 {{secret:别名}}', () => {
    const manifest = validL1();
    manifest.runtimePayload.httpTemplate.headersJson =
      '{"Authorization":"Bearer sk-abcdefghijklmnopqrstuvwx"}';
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('明文密钥'), result.error);
    assert.ok(result.error.includes('{{secret:'), result.error);
  });

  test('L2 缺 MCP 地址 / 用 http 明文 → 校验失败', () => {
    const missing = S.validateManifestJson(j(validL1({ tier: 'L2_REMOTE_MCP', runtimePayload: { allowedDomains: [] } })));
    assert.equal(missing.ok, false);
    assert.ok(missing.error.includes('MCP 地址'));

    const insecure = S.validateManifestJson(j(validL1({
      tier: 'L2_REMOTE_MCP',
      runtimePayload: { mcpEndpoint: 'http://mcp.example.com/sse', allowedDomains: ['mcp.example.com'] }
    })));
    assert.equal(insecure.ok, false);
    assert.ok(insecure.error.includes('https://'));
  });

  test('L2 合法 MCP 地址通过，但告警提示以服务端 tools/list 为准', () => {
    const manifest = validL1({
      tier: 'L2_REMOTE_MCP',
      runtimePayload: { mcpEndpoint: 'https://mcp.example.com/sse', allowedDomains: ['mcp.example.com'] }
    });
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, true, result.error);
    assert.ok(result.warnings.some((w) => w.includes('tools/list')), JSON.stringify(result.warnings));
  });

  test('L3：缺脚本 / 含被禁能力 → 校验失败；合法脚本通过但告警沙箱未启用', () => {
    const noCode = S.validateManifestJson(j(validL1({ tier: 'L3_QUICKJS_SANDBOX', runtimePayload: { allowedDomains: [] } })));
    assert.equal(noCode.ok, false);
    assert.ok(noCode.error.includes('脚本代码'));

    const dangerous = S.validateManifestJson(j(validL1({
      tier: 'L3_QUICKJS_SANDBOX',
      runtimePayload: { allowedDomains: [], quickJsCode: 'const fs = require("fs");' }
    })));
    assert.equal(dangerous.ok, false);
    assert.ok(dangerous.error.includes('被禁止'), dangerous.error);

    const ok = S.validateManifestJson(j(validL1({
      tier: 'L3_QUICKJS_SANDBOX',
      runtimePayload: { allowedDomains: [], quickJsCode: 'function run(input) { return input; }' }
    })));
    assert.equal(ok.ok, true, ok.error);
    assert.ok(ok.warnings.some((w) => w.includes('端侧脚本沙箱')));
  });

  // ---------------- configSchema 校验 ----------------
  test('configSchema 缺 key / key 非法 / key 重复 → 校验失败', () => {
    const noKey = validL1({ configSchema: [{ label: '标签', type: 'string', defaultValueJson: '""' }] });
    assert.ok(S.validateManifestJson(j(noKey)).error.includes('缺少 key'));

    const badKey = validL1({ configSchema: [{ key: '1bad', label: '标签', type: 'string', defaultValueJson: '""' }] });
    assert.equal(S.validateManifestJson(j(badKey)).ok, false);

    const dup = validL1({
      configSchema: [
        { key: 'dup', label: 'A', type: 'string', defaultValueJson: '""' },
        { key: 'dup', label: 'B', type: 'string', defaultValueJson: '""' }
      ]
    });
    const dupResult = S.validateManifestJson(j(dup));
    assert.equal(dupResult.ok, false);
    assert.ok(dupResult.error.includes('重复'));
  });

  test('enum 类型缺 options → 校验失败', () => {
    const manifest = validL1({ configSchema: [{ key: 'fmt', label: '格式', type: 'enum', defaultValueJson: '"a"' }] });
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('options'));
  });

  test('min > max → 校验失败', () => {
    const manifest = validL1({
      configSchema: [{ key: 'n', label: '数量', type: 'number', defaultValueJson: '1', min: 10, max: 1 }]
    });
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, false);
    assert.ok(result.error.includes('最小值大于最大值'));
  });

  test('不支持的字段类型会被降级为文本并告警（不拒绝草稿）', () => {
    const manifest = validL1({ configSchema: [{ key: 'x', label: 'X', type: 'weird', defaultValueJson: '"a"' }] });
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, true, result.error);
    assert.ok(result.warnings.some((w) => w.includes('类型不受支持')));
  });

  test('默认值类型不符会被重置并告警（草稿可保存，配置仍可用）', () => {
    const manifest = validL1({
      configSchema: [{ key: 'num', label: '数字', type: 'number', defaultValueJson: '"不是数字"' }]
    });
    const result = S.validateManifestJson(j(manifest));
    assert.equal(result.ok, true, result.error);
    assert.ok(result.warnings.some((w) => w.includes('默认值')), JSON.stringify(result.warnings));
  });

  // ---------------- 配置生成 / 校验 ----------------
  test('buildDefaultConfigJson：按 configSchema 生成默认配置对象', () => {
    const config = JSON.parse(S.buildDefaultConfigJson(j(validL1())));
    assert.deepEqual(config, {
      minRerankScore: 1.5,
      outputFormat: 'summary',
      blockedDomains: [],
      enableCache: true
    });
    assert.equal(S.buildDefaultConfigJson('{bad'), '{}');
  });

  test('normalizeConfigJson：缺项补默认、多余键丢弃', () => {
    const result = S.normalizeConfigJson(j(validL1()), j({ minRerankScore: 2, unknownKey: 1 }));
    assert.equal(result.ok, true, result.error);
    const config = JSON.parse(result.configJson);
    assert.equal(config.minRerankScore, 2);
    assert.equal(config.outputFormat, 'summary');
    assert.equal(config.unknownKey, undefined);
  });

  test('normalizeConfigJson：空配置 → 全默认；类型/范围/枚举非法 → 中文错误', () => {
    const defaults = JSON.parse(S.normalizeConfigJson(j(validL1()), '').configJson);
    assert.equal(defaults.minRerankScore, 1.5);

    const wrongType = S.normalizeConfigJson(j(validL1()), j({ minRerankScore: 'high' }));
    assert.equal(wrongType.ok, false);
    assert.ok(wrongType.error.includes('需要是数字'));

    const outOfRange = S.normalizeConfigJson(j(validL1()), j({ minRerankScore: 5 }));
    assert.equal(outOfRange.ok, false);
    assert.ok(outOfRange.error.includes('不能大于'));

    const badEnum = S.normalizeConfigJson(j(validL1()), j({ outputFormat: 'pdf' }));
    assert.equal(badEnum.ok, false);
    assert.ok(badEnum.error.includes('不在可选项里'));

    const badList = S.normalizeConfigJson(j(validL1()), j({ blockedDomains: [1, 2] }));
    assert.equal(badList.ok, false);
    assert.ok(badList.error.includes('只能放文本'));

    const badJson = S.normalizeConfigJson(j(validL1()), '{broken');
    assert.equal(badJson.ok, false);
    assert.ok(badJson.error.includes('不是合法的 JSON'));
  });

  test('validateConfigJson 与 normalizeConfigJson 同语义（语义化别名）', () => {
    const a = S.validateConfigJson(j(validL1()), j({ minRerankScore: 1 }));
    assert.equal(a.ok, true);
    assert.equal(a.configJson, S.normalizeConfigJson(j(validL1()), j({ minRerankScore: 1 })).configJson);
  });

  test('withConfigJson 把配置写回清单 savedConfigJson', () => {
    const merged = S.withConfigJson(j(validL1()), j({ minRerankScore: 2 }));
    const rec = JSON.parse(merged);
    assert.equal(JSON.parse(rec.savedConfigJson).minRerankScore, 2);
  });

  test('buildConfigSchema + configEntries：可编辑字段往返', () => {
    const schemaJson = S.buildConfigSchema([
      { key: 'minScore', label: '最低相关度', type: 'number', defaultValueJson: '1.5', min: 0, max: 3, hint: '越大越严格' },
      { key: 'fmt', label: '格式', type: 'enum', defaultValueJson: '"a"', options: ['a', 'b'] }
    ]);
    const entries = S.configEntries(j(validL1({ configSchema: JSON.parse(schemaJson) })));
    assert.equal(entries.length, 2);
    assert.equal(entries[0].key, 'minScore');
    assert.equal(entries[0].min, 0);
    assert.equal(entries[0].max, 3);
    assert.equal(entries[0].hint, '越大越严格');
    assert.deepEqual(entries[1].options, ['a', 'b']);
  });

  test('manifestDomains / describeManifest 的中文摘要', () => {
    assert.deepEqual(S.manifestDomains(j(validL1())), ['api.example.com']);
    assert.deepEqual(S.manifestDomains('{bad'), []);

    const desc = S.describeManifest(j(validL1()));
    assert.ok(desc.includes('技术文档联网清洗'));
    assert.ok(desc.includes('L1 声明式'));
    assert.ok(desc.includes('含可调用工具'));
    assert.ok(desc.includes('可访问 1 个域名'));

    const noDomain = S.describeManifest(j(validL1({ runtimePayload: { allowedDomains: [] } })));
    assert.ok(noDomain.includes('不访问网络'));
    assert.equal(S.describeManifest('{bad'), '无法识别的技能清单');
  });

  // ---------------- 规范化 / 告警 ----------------
  test('normalizeManifestJson：非法 JSON / 数组 / 空串都给出中文错误', () => {
    assert.equal(S.normalizeManifestJson('').ok, false);
    assert.ok(S.normalizeManifestJson('{bad').error.includes('不是合法的 JSON'));
    assert.ok(S.normalizeManifestJson('[1,2]').error.includes('必须是一个 JSON 对象'));
  });

  test('normalizeManifestJson：缺失字段补默认值并告警', () => {
    const result = S.normalizeManifestJson(j({ id: 'minimal_skill' }));
    assert.equal(result.ok, true);
    const rec = JSON.parse(result.manifestJson);
    assert.equal(rec.version, '1.0.0');
    assert.equal(rec.name, 'minimal_skill');
    assert.equal(rec.tier, 'L1_DECLARATIVE');
    assert.equal(rec.enabled, true);
    assert.equal(rec.author, 'user');
    assert.deepEqual(rec.configSchema, []);
    assert.ok(result.warnings.some((w) => w.includes('缺少分级')));
    assert.ok(rec.savedConfigJson.length > 0);
  });

  test('normalizeManifestJson：已保存配置无法识别时复位为默认并告警', () => {
    const manifest = validL1({ savedConfigJson: '{"minRerankScore": "坏值"}' });
    const result = S.normalizeManifestJson(j(manifest));
    assert.equal(result.ok, true);
    assert.ok(result.warnings.some((w) => w.includes('已重置为默认配置')));
    const rec = JSON.parse(result.manifestJson);
    assert.equal(JSON.parse(rec.savedConfigJson).minRerankScore, 1.5);
  });

  test('collectSecurityWarnings：域名过多 / 缺说明 / 缺工具声明都会提示', () => {
    const manifest = validL1({
      description: '',
      toolSchemaJson: '',
      runtimePayload: {
        ...validL1().runtimePayload,
        // 白名单必须仍包含 httpTemplate 的域名，否则会先因「域名不在白名单」提前失败
        allowedDomains: ['api.example.com', 'b.com', 'c.com', 'd.com', 'e.com', 'f.com', 'g.com', 'h.com', 'i.com']
      }
    });
    const warnings = S.collectSecurityWarnings(j(manifest));
    assert.ok(warnings.some((w) => w.includes('收敛')), JSON.stringify(warnings));
    assert.ok(warnings.some((w) => w.includes('技能说明为空')), JSON.stringify(warnings));
    assert.ok(warnings.some((w) => w.includes('没有声明可调用工具')), JSON.stringify(warnings));
  });

  test('findSecretLiteral：能发现 sk- 与 Bearer 明文密钥（截断展示）', () => {
    assert.ok(S.findSecretLiteral('Bearer sk-abcdefghijklmnopqrstuv').startsWith('Bearer sk-') ||
      S.findSecretLiteral('Bearer sk-abcdefghijklmnopqrstuv').length > 0);
    assert.equal(S.findSecretLiteral('没有密钥的普通文本'), '');
    assert.equal(S.findSecretLiteral(''), '');
  });

  test('validateQuickJsCode：空脚本 / 禁用能力 / 超长脚本', () => {
    assert.ok(S.validateQuickJsCode('').includes('脚本代码'));
    assert.ok(S.validateQuickJsCode('eval("1")').includes('被禁止'));
    assert.ok(S.validateQuickJsCode('x'.repeat(20001)).includes('过长'));
    assert.equal(S.validateQuickJsCode('function run(x) { return x + 1; }'), '');
  });

  summarize();
}
