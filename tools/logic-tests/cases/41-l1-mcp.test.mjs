/**
 * L1 声明式执行器纯逻辑 + L2 MCP 协议纯逻辑
 * （core_plugin/util/L1Template.ets、core_plugin/util/McpProtocol.ets）
 *
 * 对应 Blueprint Milestone 3：L1 模板占位符/域名语法组装、响应路径抽取；
 * L2 远程 MCP 的 JSON-RPC 2.0 组包、SSE 响应解析、tools/list 与 tools/call 结果提取。
 * 平台网络请求不在本用例范围（靠编译期检查和手工验收）。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const L1_P = 'packages/core_plugin/src/main/ets/util/L1Template.ts';
const MCP_P = 'packages/core_plugin/src/main/ets/util/McpProtocol.ts';
const L = await tryImport(L1_P);
const M = await tryImport(MCP_P);

function jsonOf(text) { return JSON.parse(text); }

// ============================== L1 模板 ==============================
if (!L) {
  skip('L1 模板（全部用例）', missingReason(L1_P));
} else {
  test('[L1] extractSecretAliases：提取并去重密钥别名，忽略其他占位符', () => {
    const aliases = L.extractSecretAliases(
      'Bearer {{secret:deepseek.apiKey}} and {{secret:other.key}} and {{secret:deepseek.apiKey}} {{input.q}}');
    assert.deepEqual(aliases, ['deepseek.apiKey', 'other.key']);
    assert.deepEqual(L.extractSecretAliases('无占位符'), []);
    assert.deepEqual(L.extractSecretAliases(null), []);
  });

  test('[L1] escapeJsonString：引号/反斜杠安全转义', () => {
    assert.equal(L.escapeJsonString('a"b'), 'a\\"b');
    assert.equal(L.escapeJsonString('普通文本'), '普通文本');
  });

  test('[L1] readPathValue：点路径 + 数组下标取值', () => {
    const record = {
      results: [{ title: '第一条' }, { title: '第二条' }],
      data: { items: [{ name: '张三' }], count: 3 }
    };
    assert.equal(L.readPathValue(record, 'data.items.0.name'), '张三');
    assert.equal(L.readPathValue(record, 'data.count'), '3');
    assert.equal(L.readPathValue(record, 'results.1.title'), '第二条');
    assert.equal(L.readPathValue(record, 'results.5.title'), '');
    assert.equal(L.readPathValue(record, 'missing.path'), '');
    assert.equal(L.readPathValue(null, 'a'), '');
    assert.equal(L.readPathValue(record, ''), '');
  });

  test('[L1] renderTemplate(URL 模式)：input/config 值做 URL 编码，secret 与格式化后缀不编码', () => {
    const secrets = new Map([['deepseek.apiKey', 'sk-TEST']]);
    const out = L.renderTemplate(
      'https://api.deepseek.com/v1/tools/search?q={{input.query}}&token={{secret:deepseek.apiKey}}',
      '{"query":"hello world"}', '{}', secrets, true);
    assert.ok(out.includes('q=hello%20world'), out);
    assert.ok(out.includes('token=sk-TEST'), out);
  });

  test('[L1] renderTemplate(正文模式)：字符串值做 JSON 转义，避免破坏请求体 JSON', () => {
    // 入参是按行的 JSON 文本（契约即字符串），不是对象
    const out = L.renderTemplate('{"title":"{{input.title}}"}', '{"title":"他说\\"你好\\""}', '{}', new Map(), false);
    const parsed = jsonOf(out);
    assert.equal(parsed.title, '他说"你好"');
  });

  test('[L1] renderTemplate：格式化后缀 include_sites / exclude_sites / join_space / json', () => {
    const input = '{}';
    const config = '{"allowed":["a.com","b.com"],"blocked":["x.com"],"langs":["zh","en"]}';
    assert.equal(L.renderTemplate('q{{config.allowed|include_sites}}', input, config, new Map(), false),
      'q site:a.com OR site:b.com');
    assert.equal(L.renderTemplate('q{{config.blocked|exclude_sites}}', input, config, new Map(), false),
      'q -site:x.com');
    assert.equal(L.renderTemplate('{{config.langs|join_space}}', input, config, new Map(), false), 'zh en');
    assert.equal(L.renderTemplate('{{config.langs|json}}', input, config, new Map(), false), '["zh","en"]');
  });

  test('[L1] renderTemplate：未知占位符原样保留；缺失 secret 渲染为空串', () => {
    const out = L.renderTemplate('前{{unknown.token}}后{{secret:missing}}', '{}', '{}', new Map(), false);
    assert.equal(out, '前{{unknown.token}}后');
  });

  test('[L1] renderTemplate：now/date 变量格式正确', () => {
    const now = L.renderTemplate('{{now}}', '{}', '{}', new Map(), false);
    assert.match(now, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
    assert.match(L.renderTemplate('{{date}}', '{}', '{}', new Map(), false), /^\d{4}-\d{2}-\d{2}$/);
  });

  test('[L1] extractByResponsePath：按路径抽取、空路径返回原文、非法 JSON 返回空串', () => {
    const raw = JSON.stringify({ results: [{ title: 'A' }], data: { items: [{ name: 'N' }] } });
    assert.ok(L.extractByResponsePath(raw, 'results').includes('"A"'));
    assert.equal(L.extractByResponsePath(raw, 'data.items.0.name'), 'N');
    assert.equal(L.extractByResponsePath(raw, ''), raw);
    assert.equal(L.extractByResponsePath('{broken', 'results'), '');
    assert.ok(L.extractByResponsePath('[1,2,3]', 'x').length > 0);
  });

  test('[L1] containsPlaceholder / parseHeaderText / config 读取工具', () => {
    assert.equal(L.containsPlaceholder('a {{input.q}} b', 'input.q'), true);
    assert.equal(L.containsPlaceholder('a', 'input.q'), false);

    const headers = L.parseHeaderText('{"Content-Type":"application/json","X-Count":3}');
    assert.equal(headers.get('Content-Type'), 'application/json');
    assert.equal(headers.get('X-Count'), '3');
    assert.equal(L.parseHeaderText('{broken').size, 0);

    assert.deepEqual(L.readConfigStringList('{"sites":["a.com"]}', 'sites'), ['a.com']);
    assert.deepEqual(L.readConfigStringList('{bad', 'sites'), []);
    assert.equal(L.readConfigObject('{"o":{"a":1}}', 'o').a, 1);
    assert.equal(L.readConfigObject('{bad', 'o'), null);
  });

  test('[L1] compactResultText：超长截断', () => {
    const long = 'x'.repeat(300);
    const short = L.compactResultText(long, 100);
    assert.ok(short.startsWith('x'.repeat(100)));
    assert.ok(short.endsWith('（结果较长，已截断）'), short.slice(-12));
    assert.equal(L.compactResultText('短文本', 100), '短文本');
  });
}

// ============================== L2 MCP ==============================
if (!M) {
  skip('MCP 协议（全部用例）', missingReason(MCP_P));
} else {
  test('[MCP] buildJsonRpcRequest / notification 结构正确', () => {
    const request = jsonOf(M.buildJsonRpcRequest(7, 'tools/list', '{}'));
    assert.equal(request.jsonrpc, '2.0');
    assert.equal(request.id, 7);
    assert.equal(request.method, 'tools/list');
    assert.deepEqual(request.params, {});

    const notification = jsonOf(M.buildJsonRpcNotification('notifications/initialized', ''));
    assert.equal(notification.jsonrpc, '2.0');
    assert.equal(notification.method, 'notifications/initialized');
    assert.equal(notification.id, undefined);
  });

  test('[MCP] buildInitializeParams / buildToolsListParams / buildToolCallParams', () => {
    const init = jsonOf(M.buildInitializeParams('2025-06-18', 'ChatAnyWhere', '1.0.0'));
    assert.equal(init.protocolVersion, '2025-06-18');
    assert.equal(init.clientInfo.name, 'ChatAnyWhere');
    assert.equal(init.clientInfo.version, '1.0.0');
    assert.equal(typeof init.capabilities, 'object');

    assert.deepEqual(jsonOf(M.buildToolsListParams()), {});

    const call = jsonOf(M.buildToolCallParams('get_weather', '{"city":"北京"}'));
    assert.equal(call.name, 'get_weather');
    assert.deepEqual(call.arguments, { city: '北京' });
    const badArgs = jsonOf(M.buildToolCallParams('f', '{broken'));
    assert.deepEqual(badArgs.arguments, {});
  });

  test('[MCP] collectSseData：多帧/多行 data/CRLF/注释', () => {
    const body = ': keep-alive\r\ndata: {"a":1}\r\n\r\ndata: 第一行\ndata: 第二行\n\n';
    const payloads = M.collectSseData(body);
    assert.equal(payloads.length, 2);
    assert.equal(payloads[0], '{"a":1}');
    assert.equal(payloads[1], '第一行\n第二行');
    assert.deepEqual(M.collectSseData(''), []);
    assert.deepEqual(M.collectSseData(null), []);
  });

  test('[MCP] parseRpcBody：普通 JSON 与 SSE 两种响应都能解析', () => {
    const plain = M.parseRpcBody('{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}', 'application/json');
    assert.equal(plain.ok, true);
    assert.ok(plain.resultJson.includes('"tools"'));

    const sse = M.parseRpcBody('event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}\n\n',
      'text/event-stream');
    assert.equal(sse.ok, true);
    assert.ok(sse.resultJson.includes('protocolVersion'));

    assert.equal(M.parseRpcBody('', 'application/json').ok, false);
    assert.ok(M.parseRpcBody('', 'application/json').error.includes('空响应'));
  });

  test('[MCP] parseRpcBody：JSON-RPC error 响应返回中文错误', () => {
    const r = M.parseRpcBody('{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}',
      'application/json');
    assert.equal(r.ok, false);
    assert.ok(r.error.length > 0);
    assert.ok(r.error.includes('Method not found'), r.error);
  });

  test('[MCP] extractTools：name/description/inputSchema → parametersJson（缺省补空对象）', () => {
    const tools = M.extractTools(JSON.stringify({
      tools: [
        { name: 'search', description: '搜索', inputSchema: { type: 'object', properties: { q: { type: 'string' } } } },
        { name: 'noSchema' },
        { description: '没有名字会被丢弃' }
      ]
    }));
    assert.equal(tools.length, 2);
    assert.equal(tools[0].name, 'search');
    assert.equal(tools[0].description, '搜索');
    assert.ok(tools[0].parametersJson.includes('"q"'));
    assert.equal(tools[1].parametersJson, '{"type":"object","properties":{}}');
    assert.deepEqual(M.extractTools('{bad'), []);
  });

  test('[MCP] extractProtocolVersion / extractCallOutcome', () => {
    assert.equal(M.extractProtocolVersion('{"protocolVersion":"2025-06-18"}'), '2025-06-18');
    assert.equal(M.extractProtocolVersion('{bad'), '');

    const ok = M.extractCallOutcome(JSON.stringify({
      content: [{ type: 'text', text: '第一段' }, { type: 'text', text: '第二段' }, { type: 'image', data: 'x' }]
    }));
    assert.equal(ok.ok, true);
    assert.ok(ok.text.includes('第一段'));
    assert.ok(ok.text.includes('第二段'));
    assert.ok(ok.text.includes('图片结果'));

    const err = M.extractCallOutcome(JSON.stringify({ isError: true, content: [{ type: 'text', text: '工具失败' }] }));
    assert.equal(err.ok, false);
    assert.equal(err.error, '工具失败');

    const empty = M.extractCallOutcome('{"content":[]}');
    assert.equal(empty.ok, false);
    assert.ok(empty.error.includes('没有返回可读内容'));
  });

  test('[MCP] limitText 截断', () => {
    const text = M.limitText('x'.repeat(200), 50);
    assert.ok(text.startsWith('x'.repeat(50)));
    assert.ok(text.endsWith('（已截断）'), text.slice(-8));
    assert.equal(M.limitText('短', 50), '短');
  });
}

summarize();
