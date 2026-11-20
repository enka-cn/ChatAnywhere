/**
 * 三厂商适配器 buildRequest：统一 Item 树 → 目标厂商请求体投影
 * （core_protocol/adapters/{DeepSeekResponsesAdapter,AnthropicAdapter,OpenAICompatAdapter}.ets）
 *
 * 核心 DoD（Blueprint Milestone 2）：同厂商原样回传 web_search_call/signature；
 * 异构厂商用 fallbackSummary 无损降级（严禁未知字段导致 400）；
 * DeepSeek 声明服务端联网工具时不得带过滤条件/强制 tool_choice。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const DEEPSEEK_P = 'packages/core_protocol/src/main/ets/adapters/DeepSeekResponsesAdapter.ts';
const ANTHROPIC_P = 'packages/core_protocol/src/main/ets/adapters/AnthropicAdapter.ts';
const OPENAI_P = 'packages/core_protocol/src/main/ets/adapters/OpenAICompatAdapter.ts';

const [deepMod, anthMod, openaiMod] = await Promise.all([
  tryImport(DEEPSEEK_P), tryImport(ANTHROPIC_P), tryImport(OPENAI_P)
]);

function profile(over = {}) {
  return {
    providerId: 'deepseek',
    modelId: 'deepseek-flash',
    protocol: 'deepseek_responses',
    baseUrl: 'https://api.deepseek.com',
    assetKeyAlias: 'deepseek_key',
    contextWindow: 1000000,
    cacheMissToHitRatio: 50,
    cacheIdleTtlSec: 3600,
    supportsServerWebTools: true,
    supportsThinking: true,
    supportsJsonSchema: true,
    label: '深度求索·极速',
    ...over
  };
}
function node(nodeId, role, items, parentId = null) {
  return { nodeId, parentId, sessionId: 's1', role, items, tokenEstimate: 10, createdAt: 1 };
}
const textItem = (text) => ({ id: `i_${text.length}_${Math.random()}`, kind: 'text', text });
function options(over = {}) {
  return { thinkingLevel: 'quick', webMode: 'off', ...over };
}
const parseBody = (spec) => JSON.parse(spec.bodyJson);
const findInputItems = (body, type) => (body.input || []).filter((it) => it.type === type);

// ============================== DeepSeek ==============================
if (!deepMod) {
  skip('DeepSeek buildRequest（全部用例）', missingReason(DEEPSEEK_P));
} else {
  const adapter = new deepMod.DeepSeekResponsesAdapter();
  const p = profile();

  test('[DeepSeek] 基本请求：model/stream/instructions/input 与 /responses 端点', () => {
    const spec = adapter.buildRequest(p, [node('n1', 'user', [textItem('你好')])],
      options({ systemPrompt: '你是助手' }));
    const body = parseBody(spec);
    assert.equal(body.model, 'deepseek-flash');
    assert.equal(body.stream, true);
    assert.equal(body.instructions, '你是助手');
    assert.ok(Array.isArray(body.input));
    assert.equal(spec.url, 'https://api.deepseek.com/responses');
    assert.equal(spec.stream, true);
    assert.equal(spec.method, 'POST');
  });

  test('[DeepSeek] 第一轮且无工具时开启 title；第二轮不开启', () => {
    const first = parseBody(adapter.buildRequest(p, [node('n1', 'user', [textItem('你好')])], options()));
    assert.equal(first.title.enabled, true);

    const second = parseBody(adapter.buildRequest(p, [
      node('n1', 'user', [textItem('第一问')]),
      node('n2', 'assistant', [textItem('第一答')], 'n1'),
      node('n3', 'user', [textItem('第二问')], 'n2')
    ], options()));
    assert.equal(second.title, undefined);
  });

  test('[DeepSeek] 同厂商 web_search_call 原样回传 kind/page/signature（read_link 正文靠它）', () => {
    const item = {
      id: 'ws_1', kind: 'web_search_call',
      vendorRaw: {
        provider: 'deepseek', searchKind: 'read_link', signature: 'SIG_XYZ', status: 'completed',
        pageMeta: { url: 'https://example.com/a', title: '文章 A', publishedAt: '2026-01-02T00:00:00+00:00' }
      }
    };
    const body = parseBody(adapter.buildRequest(p, [
      node('n1', 'user', [textItem('读一下这篇')]),
      node('n2', 'assistant', [item], 'n1'),
      node('n3', 'user', [textItem('总结')], 'n2')
    ], options()));
    const searchItems = findInputItems(body, 'web_search_call');
    assert.equal(searchItems.length, 1);
    assert.equal(searchItems[0].signature, 'SIG_XYZ');
    assert.equal(searchItems[0].kind, 'read_link');
    assert.equal(searchItems[0].page.url, 'https://example.com/a');
    assert.equal(searchItems[0].page.published_at, '2026-01-02T00:00:00+00:00');
    assert.equal(searchItems[0].action.type, 'open_page');
  });

  test('[DeepSeek] 异构厂商 web_search_call 用 fallbackSummary 降级为纯文本（不塞未知字段）', () => {
    const item = {
      id: 'ws_2', kind: 'web_search_call',
      vendorRaw: { provider: 'anthropic', signature: 'ANTH_SIG', pageMeta: { url: 'https://x', title: 'X' } },
      fallbackSummary: '来自 Claude 联网的摘要：天气晴'
    };
    const body = parseBody(adapter.buildRequest(p, [
      node('n1', 'user', [textItem('查天气')]),
      node('n2', 'assistant', [item], 'n1'),
      node('n3', 'user', [textItem('继续')], 'n2')
    ], options()));
    assert.equal(findInputItems(body, 'web_search_call').length, 0);
    const json = JSON.stringify(body);
    assert.ok(!json.includes('ANTH_SIG'), '异构签名不得回传');
    const assistantMessage = (body.input || []).find((it) => it.type === 'message' && it.role === 'assistant');
    assert.ok(assistantMessage, '应降级成 assistant 文本消息');
    const text = assistantMessage.content.map((c) => c.text).join('');
    assert.ok(text.includes('天气晴'), text);
  });

  test('[DeepSeek] 异构且无 fallbackSummary 时用 sources 生成来源摘要文本', () => {
    const item = {
      id: 'ws_3', kind: 'web_search_call',
      vendorRaw: {
        provider: 'anthropic',
        sources: [{ title: '来源甲', url: 'u1', snippet: 's1' }, { title: '来源乙', url: 'u2', snippet: 's2' }]
      }
    };
    const body = parseBody(adapter.buildRequest(p, [
      node('n1', 'user', [textItem('查')]),
      node('n2', 'assistant', [item], 'n1'),
      node('n3', 'user', [textItem('继续')], 'n2')
    ], options()));
    const json = JSON.stringify(body);
    assert.ok(json.includes('[联网检索来源 2 条]'), json);
    assert.ok(json.includes('来源甲'));
  });

  test('[DeepSeek] tool_call / tool_result 投影为 function_call 与 function_call_output（call_id 配对）', () => {
    const call = { id: 'fc_i1', kind: 'tool_call', callId: 'call_1', toolName: 'get_weather', argumentsJson: '{"city":"北京"}' };
    const result = { id: 'fc_o1', kind: 'tool_result', callId: 'call_1', text: '晴 25 度' };
    const body = parseBody(adapter.buildRequest(p, [
      node('n1', 'user', [textItem('北京天气')]),
      node('n2', 'assistant', [call], 'n1'),
      node('n3', 'tool', [result], 'n2'),
      node('n4', 'user', [textItem('谢谢')], 'n3')
    ], options()));
    const calls = findInputItems(body, 'function_call');
    assert.equal(calls.length, 1);
    assert.equal(calls[0].call_id, 'call_1');
    assert.equal(calls[0].name, 'get_weather');
    assert.equal(calls[0].arguments, '{"city":"北京"}');
    const outputs = findInputItems(body, 'function_call_output');
    assert.equal(outputs.length, 1);
    assert.equal(outputs[0].call_id, 'call_1');
    assert.equal(outputs[0].output, '晴 25 度');
  });

  test('[DeepSeek] reasoning 带签名时回传 signature；checkpoint_summary 加中文前缀', () => {
    const reasoning = { id: 'r1', kind: 'reasoning', text: '先分析', vendorRaw: { provider: 'deepseek', signature: 'SIG_R' } };
    const summary = { id: 's1', kind: 'checkpoint_summary', text: '之前聊了天气' };
    const body = parseBody(adapter.buildRequest(p, [
      node('n0', 'user', [summary]),
      node('n1', 'user', [textItem('继续问')]),
      node('n2', 'assistant', [reasoning, textItem('答案')], 'n1')
    ], options()));
    const reasoningItems = findInputItems(body, 'reasoning');
    assert.equal(reasoningItems.length, 1);
    assert.equal(reasoningItems[0].signature, 'SIG_R');
    const json = JSON.stringify(body);
    assert.ok(json.includes('[对话记忆摘要] 之前聊了天气'), json);
  });

  test('[DeepSeek] input 不能以 assistant 结尾：自动补一条 user 续写提示', () => {
    const body = parseBody(adapter.buildRequest(p, [
      node('n1', 'user', [textItem('问')]),
      node('n2', 'assistant', [textItem('答')], 'n1')
    ], options()));
    const last = body.input[body.input.length - 1];
    assert.equal(last.type, 'message');
    assert.equal(last.role, 'user');
  });

  test('[DeepSeek] server_managed 且无过滤条件：声明原厂联网工具，且不传 tool_choice、忽略函数工具', () => {
    const spec = adapter.buildRequest(p, [node('n1', 'user', [textItem('查一下')])], options({
      webMode: 'server_managed',
      webTool: { mode: 'server_managed' },
      toolSpecs: [{ name: 'local_tool', description: '本地工具', parametersJson: '{}' }]
    }));
    const body = parseBody(spec);
    const toolNames = (body.tools || []).map((t) => t.type);
    assert.deepEqual(toolNames, ['deepseek_web_search', 'deepseek_read_url']);
    assert.equal(body.tool_choice, undefined, '绝不能强制 tool_choice');
    assert.equal((body.tools || []).length, 2);
  });

  test('[DeepSeek] 联网带过滤条件时不声明原厂联网工具（避免 400），改走函数工具', () => {
    const body = parseBody(adapter.buildRequest(p, [node('n1', 'user', [textItem('查')])], options({
      webMode: 'server_managed',
      webTool: { mode: 'server_managed', excludeDomains: ['bilibili.com'] },
      toolSpecs: [{ name: 'local_tool', description: '本地工具', parametersJson: '{}' }]
    })));
    const toolNames = (body.tools || []).map((t) => t.type === 'function' ? t.name : t.type);
    assert.ok(!toolNames.includes('deepseek_web_search'));
    assert.ok(toolNames.includes('local_tool'));
  });

  test('[DeepSeek] 思考档位映射（v3 六档）：off→none / min|low→low / med→medium / high→high / xhigh→max', () => {
    const effort = (level) => parseBody(adapter.buildRequest(p, [node('n1', 'user', [textItem('问')])],
      options({ thinkingLevel: level }))).reasoning.effort;
    assert.equal(effort('off'), 'none');
    assert.equal(effort('min'), 'low');
    assert.equal(effort('low'), 'low');
    assert.equal(effort('med'), 'medium');
    assert.equal(effort('high'), 'high');
    assert.equal(effort('xhigh'), 'max');

    const noThink = parseBody(adapter.buildRequest(profile({ supportsThinking: false }),
      [node('n1', 'user', [textItem('问')])], options()));
    assert.equal(noThink.reasoning, undefined);
  });

  test('[DeepSeek] 输出长度默认 8192，可被 maxOutputTokens 覆盖', () => {
    const body = parseBody(adapter.buildRequest(p, [node('n1', 'user', [textItem('问')])], options()));
    assert.equal(body.max_output_tokens, 8192);
    const custom = parseBody(adapter.buildRequest(p, [node('n1', 'user', [textItem('问')])],
      options({ maxOutputTokens: 1234 })));
    assert.equal(custom.max_output_tokens, 1234);
  });

  test('[DeepSeek] 连接测试请求：非流式、1 token、/responses', () => {
    const spec = adapter.buildPingRequest(p);
    const body = parseBody(spec);
    assert.equal(spec.stream, false);
    assert.equal(body.max_output_tokens, 1);
    assert.equal(spec.url, 'https://api.deepseek.com/responses');
    assert.equal(adapter.parsePingResponse(200, '{}').ok, true);
    assert.ok(adapter.parsePingResponse(401, '{}').message.includes('密钥无效'));
    assert.ok(adapter.parsePingResponse(429, '{}').message.includes('太频繁'));
    assert.ok(adapter.parsePingResponse(500, '{}').message.includes('服务端'));
  });
}

// ============================== Anthropic ==============================
if (!anthMod) {
  skip('Anthropic buildRequest（全部用例）', missingReason(ANTHROPIC_P));
} else {
  const adapter = new anthMod.AnthropicAdapter();
  const ap = profile({
    providerId: 'anthropic', modelId: 'claude-sonnet', protocol: 'anthropic_messages',
    baseUrl: 'https://api.anthropic.com', label: 'Claude'
  });

  test('[Anthropic] 基本请求：max_tokens 必填、system 顶层、/v1/messages 与版本头', () => {
    const spec = adapter.buildRequest(ap, [node('n1', 'user', [textItem('你好')])],
      options({ systemPrompt: '你是助手', thinkingLevel: 'off' }));
    const body = parseBody(spec);
    assert.equal(body.model, 'claude-sonnet');
    assert.equal(body.stream, true);
    assert.equal(body.max_tokens, 4096); // 未开思考时的默认值
    assert.equal(body.system, '你是助手');
    assert.equal(body.thinking, undefined);
    assert.equal(spec.url, 'https://api.anthropic.com/v1/messages');
    assert.equal(spec.headers.get('anthropic-version'), '2023-06-01');

    // 开启思考（med 档）后 max_tokens 提升到思考默认值，budget=4096
    const thinking = parseBody(adapter.buildRequest(ap, [node('n1', 'user', [textItem('你好')])],
      options({ systemPrompt: '你是助手', thinkingLevel: 'med' })));
    assert.equal(thinking.max_tokens, 8192);
    assert.equal(thinking.thinking.type, 'enabled');
    assert.equal(thinking.thinking.budget_tokens, 4096);
  });

  test('[Anthropic] 相邻同角色 user 消息合并为一条', () => {
    const body = parseBody(adapter.buildRequest(ap, [
      node('n1', 'user', [textItem('第一句')]),
      node('n2', 'user', [textItem('第二句')], 'n1')
    ], options()));
    assert.equal(body.messages.length, 1);
    assert.equal(body.messages[0].role, 'user');
    assert.equal(body.messages[0].content.length, 2);
  });

  test('[Anthropic] 深度思考（xhigh）：thinking.enabled + budget=16384，max_tokens 必须大于 budget', () => {
    const body = parseBody(adapter.buildRequest(ap, [node('n1', 'user', [textItem('想一下')])],
      options({ thinkingLevel: 'xhigh', maxOutputTokens: 5000 })));
    assert.equal(body.thinking.type, 'enabled');
    assert.equal(body.thinking.budget_tokens, 16384);
    assert.ok(body.max_tokens > 16384, `max_tokens 必须大于 budget：${body.max_tokens}`);
    assert.equal(body.temperature, undefined, '思考模式下不能自定义 temperature');
  });

  test('[Anthropic] 函数工具投影为 input_schema', () => {
    const body = parseBody(adapter.buildRequest(ap, [node('n1', 'user', [textItem('用工具')])], options({
      toolSpecs: [{ name: 'get_weather', description: '查天气', parametersJson: '{"type":"object","properties":{}}' }]
    })));
    assert.equal(body.tools[0].name, 'get_weather');
    assert.ok(body.tools[0].input_schema);
    assert.equal(body.tools[0].input_schema.type, 'object');
  });

  test('[Anthropic] thinking 块只有带签名才回传；tool_use/tool_result 配对', () => {
    const signedThinking = { id: 't1', kind: 'reasoning', text: '思考', vendorRaw: { provider: 'anthropic', signature: 'SIG' } };
    const unsignedThinking = { id: 't2', kind: 'reasoning', text: '无签名思考' };
    const call = { id: 'c1', kind: 'tool_call', callId: 'toolu_1', toolName: 'get_weather', argumentsJson: '{"city":"北京"}' };
    const result = { id: 'r1', kind: 'tool_result', callId: 'toolu_1', text: '晴', isError: false };
    const body = parseBody(adapter.buildRequest(ap, [
      node('n1', 'user', [textItem('天气')]),
      node('n2', 'assistant', [unsignedThinking, signedThinking, call], 'n1'),
      node('n3', 'user', [result], 'n2')
    ], options()));
    const allBlocks = body.messages.flatMap((m) => m.content);
    const thinkingBlocks = allBlocks.filter((b) => b.type === 'thinking');
    assert.equal(thinkingBlocks.length, 1, '无签名 thinking 必须丢弃');
    assert.equal(thinkingBlocks[0].signature, 'SIG');
    const toolUse = allBlocks.find((b) => b.type === 'tool_use');
    assert.equal(toolUse.id, 'toolu_1');
    assert.deepEqual(toolUse.input, { city: '北京' });
    const toolResult = allBlocks.find((b) => b.type === 'tool_result');
    assert.equal(toolResult.tool_use_id, 'toolu_1');
  });

  test('[Anthropic] 异构 web_search_call 降级为文本块', () => {
    const item = { id: 'ws', kind: 'web_search_call', fallbackSummary: 'Claude 的联网摘要' };
    const body = parseBody(adapter.buildRequest(ap, [
      node('n1', 'user', [textItem('查')]),
      node('n2', 'assistant', [item], 'n1'),
      node('n3', 'user', [textItem('继续')], 'n2')
    ], options()));
    assert.ok(JSON.stringify(body).includes('Claude 的联网摘要'));
  });
}

// ============================== OpenAI 兼容 ==============================
if (!openaiMod) {
  skip('OpenAI 兼容 buildRequest（全部用例）', missingReason(OPENAI_P));
} else {
  const adapter = new openaiMod.OpenAICompatAdapter();
  const op = profile({
    providerId: 'openai', modelId: 'gpt-4o', protocol: 'openai_chat',
    baseUrl: 'https://api.openai.com/v1', label: 'OpenAI'
  });

  test('[OpenAI] 基本请求：stream_options.include_usage、system 首条消息、/chat/completions', () => {
    const spec = adapter.buildRequest(op, [node('n1', 'user', [textItem('你好')])],
      options({ systemPrompt: '你是助手' }));
    const body = parseBody(spec);
    assert.equal(body.model, 'gpt-4o');
    assert.equal(body.stream, true);
    assert.equal(body.stream_options.include_usage, true);
    assert.equal(body.messages[0].role, 'system');
    assert.equal(body.messages[0].content, '你是助手');
    assert.equal(spec.url, 'https://api.openai.com/v1/chat/completions');
  });

  test('[OpenAI] assistant tool_calls + tool 消息配对（tool_call_id）', () => {
    const call = { id: 'c1', kind: 'tool_call', callId: 'call_1', toolName: 'get_weather', argumentsJson: '{"city":"北京"}' };
    const result = { id: 'r1', kind: 'tool_result', callId: 'call_1', text: '晴' };
    const body = parseBody(adapter.buildRequest(op, [
      node('n1', 'user', [textItem('天气')]),
      node('n2', 'assistant', [call], 'n1'),
      node('n3', 'tool', [result], 'n2'),
      node('n4', 'user', [textItem('谢谢')], 'n3')
    ], options()));
    const assistant = body.messages.find((m) => m.role === 'assistant');
    assert.equal(assistant.tool_calls[0].id, 'call_1');
    assert.equal(assistant.tool_calls[0].function.name, 'get_weather');
    const tool = body.messages.find((m) => m.role === 'tool');
    assert.equal(tool.tool_call_id, 'call_1');
    assert.equal(tool.content, '晴');
  });

  test('[OpenAI] reasoning_content 只对 DeepSeek 系端点回填（严格端点会 400）', () => {
    const reasoning = { id: 'r1', kind: 'reasoning', text: '思考过程' };
    const nodes = [
      node('n1', 'user', [textItem('问')]),
      node('n2', 'assistant', [reasoning, textItem('答')], 'n1')
    ];
    const openaiBody = parseBody(adapter.buildRequest(op, nodes, options()));
    assert.equal(openaiBody.messages.find((m) => m.role === 'assistant').reasoning_content, undefined);

    const dsProfile = profile({ providerId: 'deepseek', modelId: 'deepseek-chat', protocol: 'openai_chat' });
    const dsBody = parseBody(adapter.buildRequest(dsProfile, nodes, options()));
    assert.equal(dsBody.messages.find((m) => m.role === 'assistant').reasoning_content, '思考过程');
  });

  test('[OpenAI] 函数工具投影为 {type:function,function:{...}}', () => {
    const body = parseBody(adapter.buildRequest(op, [node('n1', 'user', [textItem('用工具')])], options({
      toolSpecs: [{ name: 'get_weather', description: '查天气', parametersJson: '{"type":"object","properties":{}}' }]
    })));
    assert.equal(body.tools[0].type, 'function');
    assert.equal(body.tools[0].function.name, 'get_weather');
    assert.equal(body.tools[0].function.parameters.type, 'object');
  });

  test('[OpenAI] 异构 web_search_call 降级为 assistant 文本；max_tokens 仅在显式传入时出现', () => {
    const item = { id: 'ws', kind: 'web_search_call', fallbackSummary: '联网摘要内容' };
    const body = parseBody(adapter.buildRequest(op, [
      node('n1', 'user', [textItem('查')]),
      node('n2', 'assistant', [item], 'n1'),
      node('n3', 'user', [textItem('继续')], 'n2')
    ], options()));
    assert.ok(JSON.stringify(body.messages).includes('联网摘要内容'));
    assert.equal(body.max_tokens, undefined);

    const withMax = parseBody(adapter.buildRequest(op, [node('n1', 'user', [textItem('问')])],
      options({ maxOutputTokens: 100 })));
    assert.equal(withMax.max_tokens, 100);
  });
}

summarize();
