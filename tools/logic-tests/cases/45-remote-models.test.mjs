/**
 * 上游 `/models` 探测纯逻辑（packages/core_protocol/util/RemoteModels.ets，v3.2）
 *
 * 覆盖三家端点 URL 组装（DeepSeek `/models`、Anthropic `/v1/models`、OpenAI 兼容 `/v1` 去重）
 * 与响应解析容错（data[]/models[]/裸数组/坏 JSON→[]、display_name/name/id 回退、去重）。
 * 说明：真实网络响应不可测（无 Key），这里用官方文档同形的合成 fixture。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_protocol/src/main/ets/util/RemoteModels.ts';
const m = await tryImport(P);

if (!m) {
  skip('真实模型探测（全部用例）', missingReason(P));
  summarize();
} else {
  const ids = (list) => list.map((x) => x.modelId);

  // ---------------- 响应解析 ----------------
  test('OpenAI / DeepSeek 标准响应：{object:list, data:[{id}]}', () => {
    const list = m.parseModelsResponse(JSON.stringify({
      object: 'list',
      data: [{ id: 'model-a', object: 'model', owned_by: 'x' }, { id: 'model-b' }]
    }));
    assert.deepEqual(ids(list), ['model-a', 'model-b']);
    assert.equal(list[0].displayName, 'model-a', 'displayName 缺省回退 id');
    assert.ok(list[0].metaJson.includes('model-a'), '原始信息应保留在 metaJson');
  });

  test('Anthropic 响应：display_name 优先于 id', () => {
    const list = m.parseModelsResponse(JSON.stringify({
      data: [{ id: 'claude-sonnet-x', display_name: 'Claude Sonnet X', type: 'model' }]
    }));
    assert.equal(list.length, 1);
    assert.equal(list[0].modelId, 'claude-sonnet-x');
    assert.equal(list[0].displayName, 'Claude Sonnet X');
  });

  test('变体响应：{models:[…]}、{model:…}、{name:…}', () => {
    assert.deepEqual(ids(m.parseModelsResponse('{"models":[{"id":"m-data"}]}')), ['m-data']);
    assert.deepEqual(ids(m.parseModelsResponse('{"data":[{"model":"m-model"}]}')), ['m-model']);
    assert.deepEqual(ids(m.parseModelsResponse('{"data":[{"name":"m-name"}]}')), ['m-name']);
  });

  test('裸数组响应：字符串与对象混合、非法元素跳过', () => {
    const list = m.parseModelsResponse('["plain-a", {"id":"obj-b","display_name":"对象 B"}, 123, null]');
    assert.deepEqual(ids(list), ['plain-a', 'obj-b']);
    assert.equal(list[0].displayName, 'plain-a');
    assert.equal(list[1].displayName, '对象 B');
  });

  test('重复 modelId 去重（保留第一次出现）', () => {
    const list = m.parseModelsResponse(JSON.stringify({
      data: [{ id: 'dup', display_name: '第一次' }, { id: 'dup', display_name: '第二次' }]
    }));
    assert.equal(list.length, 1);
    assert.equal(list[0].displayName, '第一次');
  });

  test('空 id / 空展示名回退：display_name → name → id', () => {
    const list = m.parseModelsResponse(JSON.stringify({
      data: [{ id: 'only-id' }, { id: 'with-name', name: '名字' }, { id: '', display_name: '无 id' }]
    }));
    assert.deepEqual(ids(list), ['only-id', 'with-name']);
    assert.equal(list[0].displayName, 'only-id');
    assert.equal(list[1].displayName, '名字');
  });

  test('非法 JSON / 空 body / 非列表结构 / null 一律返回空数组，绝不抛错', () => {
    for (const body of ['{bad', '', '   ', null, undefined, '{}', '{"data":[]}', '"string"', '42', '{"data":"x"}']) {
      assert.deepEqual(m.parseModelsResponse(body), [], `body=${String(body)}`);
    }
  });

  test('modelIdsOf：只取 id 列表', () => {
    const list = m.parseModelsResponse('{"data":[{"id":"a"},{"id":"b"}]}');
    assert.deepEqual(m.modelIdsOf(list), ['a', 'b']);
    assert.deepEqual(m.modelIdsOf([]), []);
  });

  // ---------------- URL 组装 ----------------
  test('modelsUrl：DeepSeek → {base}/models（不带 /v1）', () => {
    assert.equal(m.modelsUrl('deepseek_responses', 'https://api.deepseek.com'),
      'https://api.deepseek.com/models');
    assert.equal(m.modelsUrl('deepseek_responses', 'https://api.deepseek.com/'),
      'https://api.deepseek.com/models');
  });

  test('modelsUrl：Anthropic → {base}/v1/models', () => {
    assert.equal(m.modelsUrl('anthropic_messages', 'https://api.anthropic.com'),
      'https://api.anthropic.com/v1/models');
    assert.equal(m.modelsUrl('anthropic_messages', 'https://proxy.example.com'),
      'https://proxy.example.com/v1/models');
  });

  test('modelsUrl：OpenAI 兼容 baseUrl 含 /v1 时不重复拼接，否则补 /v1/models', () => {
    assert.equal(m.modelsUrl('openai_chat', 'https://api.openai.com/v1'),
      'https://api.openai.com/v1/models');
    assert.equal(m.modelsUrl('openai_chat', 'https://api.openai.com'),
      'https://api.openai.com/v1/models');
    assert.equal(m.modelsUrl('openai_chat', 'https://proxy.example.com/v1/'),
      'https://proxy.example.com/v1/models');
  });

  test('openAiCompatModelsUrl：已以 /models 结尾时原样返回；空 base 回退 /v1/models', () => {
    assert.equal(m.openAiCompatModelsUrl('https://x.example.com/v1/models'),
      'https://x.example.com/v1/models');
    assert.equal(m.openAiCompatModelsUrl('https://x.example.com/v1/models/'),
      'https://x.example.com/v1/models');
    assert.equal(m.openAiCompatModelsUrl(''), '/v1/models');
    assert.equal(m.openAiCompatModelsUrl(null), '/v1/models');
  });

  summarize();
}
