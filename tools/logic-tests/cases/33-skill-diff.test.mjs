/**
 * 技能变更中文 Diff（packages/core_plugin/SkillDiff.ets）
 *
 * QA 清单要求：SkillDiff 文本包含增删标记（+/~/-）。补充覆盖新建/无变化/名称说明/
 * 分级/启用状态/域名/配置项/配置值/提示词/工具/HTTP 模板变化与汇总行。
 * 这是「技能创造室」Diff 卡片（Milestone 4）的展示基础。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_plugin/src/main/ets/SkillDiff.ts';
const D = await tryImport(P);

if (!D) {
  skip('技能变更 Diff（全部用例）', missingReason(P));
  summarize();
} else {
  function manifest(over = {}) {
    return {
      id: 'web_clean',
      version: '1.0.0',
      name: '联网清洗',
      description: '清洗网页',
      tier: 'L1_DECLARATIVE',
      enabled: true,
      author: 'user',
      promptSnippet: '',
      toolSchemaJson: '',
      configSchema: [],
      savedConfigJson: '{}',
      runtimePayload: {
        allowedDomains: ['old.com'],
        httpTemplate: {
          method: 'POST',
          urlTemplate: 'https://api.example.com/clean',
          bodyTemplate: '{"url":"{{input.url}}"}',
          timeoutMs: 8000
        }
      },
      ...over
    };
  }
  const j = (obj) => JSON.stringify(obj);

  test('新建技能（旧版为空）→ + 新建技能 与基础字段逐行展示', () => {
    const diff = D.diffManifestJson('', j(manifest()));
    assert.ok(diff.includes('+ 新建技能：联网清洗（web_clean）'), diff);
    assert.ok(diff.includes('+ 名称：联网清洗'));
    assert.ok(diff.includes('+ 分级：L1 声明式'));
    assert.ok(diff.includes('+ 允许访问域名：old.com'));
    assert.equal(D.hasDiffChanges(diff), true);
  });

  test('内容完全一致 → 输出「（内容没有变化）」且变化数为 0', () => {
    const same = j(manifest());
    const diff = D.diffManifestJson(same, same);
    assert.ok(diff.includes('（内容没有变化）'), diff);
    assert.equal(D.countDiffChanges(diff), 0);
    assert.equal(D.hasDiffChanges(diff), false);
    assert.equal(D.summarizeDiff(diff), '内容没有变化');
  });

  test('名称 / 说明 / 版本变化 → ~ 修改标记', () => {
    const diff = D.diffManifestJson(
      j(manifest({ name: '旧名', description: '旧说明', version: '1.0.0' })),
      j(manifest({ name: '新名', description: '新说明', version: '1.0.1', author: 'user' }))
    );
    assert.ok(diff.includes('~ 名称：旧名 → 新名'), diff);
    assert.ok(diff.includes('~ 说明：旧说明 → 新说明'), diff);
    assert.ok(diff.includes('~ 版本：1.0.0 → 1.0.1'), diff);
  });

  test('分级 / 启用状态变化 → 中文分级与启用文案', () => {
    const diff = D.diffManifestJson(
      j(manifest()),
      j(manifest({ tier: 'L2_REMOTE_MCP', enabled: false }))
    );
    assert.ok(diff.includes('~ 分级：L1 声明式 → L2 远程服务'), diff);
    assert.ok(diff.includes('~ 启用状态：已启用 → 已停用'), diff);
  });

  test('域名增删 → + 新增允许域名 / - 移除允许域名', () => {
    const oldManifest = manifest();
    const newManifest = manifest({
      runtimePayload: { ...oldManifest.runtimePayload, allowedDomains: ['new.com'] }
    });
    const diff = D.diffManifestJson(j(oldManifest), j(newManifest));
    assert.ok(diff.includes('+ 新增允许域名：new.com'), diff);
    assert.ok(diff.includes('- 移除允许域名：old.com'), diff);
  });

  test('新增/移除配置项与标签变化 → 中文 Diff', () => {
    const oldManifest = manifest({
      configSchema: [{ key: 'fmt', label: '旧标签', type: 'string', defaultValueJson: '""' }]
    });
    const newManifest = manifest({
      configSchema: [
        { key: 'fmt', label: '新标签', type: 'string', defaultValueJson: '""' },
        { key: 'minScore', label: '最低相关度', type: 'number', defaultValueJson: '1.5' }
      ]
    });
    const diff = D.diffManifestJson(j(oldManifest), j(newManifest));
    assert.ok(diff.includes('+ 新增配置项：最低相关度（minScore）'), diff);
    assert.ok(diff.includes('~ 配置项标签：旧标签 → 新标签'), diff);

    const removed = D.diffManifestJson(j(newManifest), j(oldManifest));
    assert.ok(removed.includes('- 移除配置项：最低相关度（minScore）'), removed);
  });

  test('配置值（string_list 域名类）→ 新增屏蔽域名（按标签识别语义）', () => {
    const schema = [{ key: 'blocked', label: '屏蔽域名', type: 'string_list', defaultValueJson: '[]' }];
    const oldManifest = manifest({ configSchema: schema, savedConfigJson: j({ blocked: [] }) });
    const newManifest = manifest({ configSchema: schema, savedConfigJson: j({ blocked: ['bilibili.com'] }) });
    const diff = D.diffManifestJson(j(oldManifest), j(newManifest));
    assert.ok(diff.includes('+ 新增屏蔽域名：bilibili.com'), diff);
  });

  test('配置值（数字/枚举）→ ~ 配置「标签」：旧 → 新', () => {
    const schema = [
      { key: 'minRerankScore', label: '最低相关度', type: 'number', defaultValueJson: '1.5' },
      { key: 'outputFormat', label: '输出格式', type: 'enum', defaultValueJson: '"summary"', options: ['summary', 'markdown'] }
    ];
    const oldManifest = manifest({ configSchema: schema, savedConfigJson: j({ minRerankScore: 1.5, outputFormat: 'summary' }) });
    const newManifest = manifest({ configSchema: schema, savedConfigJson: j({ minRerankScore: 2, outputFormat: 'markdown' }) });
    const diff = D.diffManifestJson(j(oldManifest), j(newManifest));
    assert.ok(diff.includes('~ 配置「最低相关度」：1.5 → 2'), diff);
    assert.ok(diff.includes('~ 配置「输出格式」：summary → markdown'), diff);
  });

  test('提示词片段：新增 / 移除 / 修改（含续行说明）', () => {
    const added = D.diffManifestJson(j(manifest()), j(manifest({ promptSnippet: '每次都先联网查证' })));
    assert.ok(added.includes('+ 新增提示词片段（8 字）'), added);

    const removed = D.diffManifestJson(j(manifest({ promptSnippet: '短片段' })), j(manifest()));
    assert.ok(removed.includes('- 移除提示词片段'), removed);

    const newSnippet = '这是一个更长的新版片段内容';
    const changed = D.diffManifestJson(
      j(manifest({ promptSnippet: '旧片段' })),
      j(manifest({ promptSnippet: newSnippet }))
    );
    assert.ok(changed.includes(`~ 提示词片段：3 字 → ${newSnippet.length} 字`), changed);
    assert.ok(changed.includes('新版开头：'), changed);
  });

  test('工具声明：新增 / 移除 → 中文 Diff', () => {
    const toolJson = j({ name: 'clean_web', description: '清洗网页', parameters: { type: 'object', properties: {} } });
    const added = D.diffManifestJson(j(manifest()), j(manifest({ toolSchemaJson: toolJson })));
    assert.ok(added.includes('+ 新增可调用工具：clean_web'), added);

    const removed = D.diffManifestJson(j(manifest({ toolSchemaJson: toolJson })), j(manifest()));
    assert.ok(removed.includes('- 移除可调用工具：clean_web'), removed);
  });

  test('HTTP 模板：新增 / 移除 / 请求体变化 / 超时变化', () => {
    const noTemplate = manifest({ runtimePayload: { allowedDomains: ['old.com'] } });
    assert.ok(D.diffManifestJson(j(noTemplate), j(manifest())).includes('+ 新增 HTTP 请求模板'));
    assert.ok(D.diffManifestJson(j(manifest()), j(noTemplate)).includes('- 移除 HTTP 请求模板'));

    const changedBody = manifest();
    changedBody.runtimePayload.httpTemplate.bodyTemplate = '{"q":"{{input.q}}"}';
    assert.ok(D.diffManifestJson(j(manifest()), j(changedBody)).includes('~ 请求体模板已调整'));

    const changedTimeout = manifest();
    changedTimeout.runtimePayload.httpTemplate.timeoutMs = 5000;
    const timeoutDiff = D.diffManifestJson(j(manifest()), j(changedTimeout));
    assert.ok(timeoutDiff.includes('~ 请求超时：8000 毫秒 → 5000 毫秒'), timeoutDiff);
  });

  test('countDiffChanges 只统计 +/~/− 行（续行不计入）', () => {
    const diff = D.diffManifestJson(
      j(manifest({ promptSnippet: '旧' })),
      j(manifest({ promptSnippet: '新的更长的提示词片段' }))
    );
    // 只有「~ 提示词片段」一行是变化行，「新版开头：」是续行
    assert.equal(D.countDiffChanges(diff), 1);
  });

  test('summarizeDiff：自定义文本统计与空文本', () => {
    assert.equal(D.summarizeDiff('+ 新增A\n~ 修改B\n- 移除C'), '共 3 处变化（新增 1 项、修改 1 项、移除 1 项）');
    assert.equal(D.summarizeDiff(''), '没有变化');
    // 统计前会 trim，缩进的 +/~/− 行也计入
    assert.equal(D.summarizeDiff('  + 缩进的变化行\n普通行'), '共 1 处变化（新增 1 项）');
    assert.equal(D.summarizeDiff('普通行'), '内容没有变化');
  });

  test('新版 JSON 无法解析 → 返回明确中文提示', () => {
    const diff = D.diffManifestJson(j(manifest()), '{broken');
    assert.ok(diff.includes('无法解析'), diff);
    assert.equal(D.countDiffChanges(diff), 0);
  });

  test('旧版 JSON 无法解析 → 按「新建技能」处理（提示不丢）', () => {
    const diff = D.diffManifestJson('{broken', j(manifest()));
    assert.ok(diff.includes('+ 新建技能'), diff);
  });

  test('diff 末尾附「共 N 处变化」汇总行', () => {
    const diff = D.diffManifestJson(j(manifest({ name: 'A' })), j(manifest({ name: 'B' })));
    assert.match(diff, /共 \d+ 处变化/);
    assert.ok(diff.includes('修改 1 项'));
  });

  summarize();
}
