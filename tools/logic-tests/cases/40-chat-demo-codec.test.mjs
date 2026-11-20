/**
 * chat-demo v3 历史导入/导出（packages/core_model/util/ChatDemoCodec.ets）
 *
 * 对应 Blueprint Milestone 5：「兼容 chat-demo 的 ZIP 历史导入导出」。
 * 验证：统一 Item 树 ↔ chat-demo v3 session 的双向投影、分支活动路径、
 * signature/sources 保留、坏数据容错（warning 而非抛错）。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_model/src/main/ets/util/ChatDemoCodec.ts';
const TRAJ_P = 'packages/core_model/src/main/ets/util/TrajectoryLogic.ts';
const C = await tryImport(P);
const T = await tryImport(TRAJ_P);

if (!C) {
  skip('chat-demo 编解码（全部用例）', missingReason(P));
  summarize();
} else if (!T) {
  skip('chat-demo 编解码（依赖缺失）', missingReason(TRAJ_P));
  summarize();
} else {
  const BASE = 1700000000000;
  function node(nodeId, parentId, role, items, createdAt, tokenEstimate = 0) {
    return { nodeId, parentId, sessionId: 's1', role, items, tokenEstimate, createdAt };
  }
  const text = (t) => ({ id: `i_${t}`, kind: 'text', text: t });

  // ---------------- 时间 ----------------
  test('chatDemoTimeToMillis / millisToChatDemoTime 往返', () => {
    const iso = '2026-11-19T04:05:06.000Z';
    assert.equal(C.chatDemoTimeToMillis(iso), Date.parse(iso));
    assert.equal(C.chatDemoTimeToMillis(''), 0);
    assert.equal(C.chatDemoTimeToMillis(null), 0);
    assert.equal(C.chatDemoTimeToMillis('not a date'), 0);
    const back = C.millisToChatDemoTime(BASE);
    assert.equal(back, new Date(BASE).toISOString());
    assert.ok(back.endsWith('Z'));
  });

  test('resultsToSources：保留 url/title/snippet/site_name，丢弃空条目', () => {
    const sources = C.resultsToSources([
      { url: 'https://a', title: 'A', snippet: 'sa', site_name: '站点A', published_at: '2026-01-01' },
      { url: '', title: '' },
      { title: '只有标题' }
    ]);
    assert.equal(sources.length, 2);
    assert.equal(sources[0].siteName, '站点A');
    assert.equal(sources[1].title, '只有标题');
    assert.deepEqual(C.resultsToSources(undefined), []);
  });

  // ---------------- 导出 ----------------
  test('nodesToChatDemoSession：基本信息、数字 id、父链、current_message_id、token 用量', () => {
    const meta = { sessionId: 's1', title: '测试会话', createdAt: BASE, updatedAt: BASE + 2000, pinned: true };
    const nodes = [
      node('u1', null, 'user', [text('你好')], BASE),
      node('a1', 'u1', 'assistant', [text('你好，有什么可以帮你')], BASE + 1000),
      node('u2', 'a1', 'user', [text('继续聊')], BASE + 2000)
    ];
    const session = C.nodesToChatDemoSession(meta, nodes, 'u2');
    assert.equal(session.id, 's1');
    assert.equal(session.title, '测试会话');
    assert.equal(session.pinned, true);
    assert.equal(session.messages.length, 3);
    assert.deepEqual(session.messages.map((m) => m.id), [1, 2, 3]);
    assert.deepEqual(session.messages.map((m) => m.parent_id), [null, 1, 2]);
    assert.deepEqual(session.messages.map((m) => m.role), ['USER', 'ASSISTANT', 'USER']);
    assert.equal(session.messages[0].fragments[0].type, 'REQUEST');
    assert.equal(session.messages[1].fragments[0].type, 'RESPONSE');
    assert.equal(session.current_message_id, 3);
    assert.equal(session.inserted_at, new Date(BASE).toISOString());
  });

  test('nodesToChatDemoSession：thinking_enabled / search_enabled 与 THINK/TOOL_SEARCH 片段', () => {
    const reasoning = { id: 'r', kind: 'reasoning', text: '先想想' };
    const search = {
      id: 'w', kind: 'web_search_call',
      vendorRaw: { provider: 'deepseek', searchKind: 'search', sources: [{ title: '来源', url: 'https://s', snippet: '摘要' }] }
    };
    const nodes = [
      node('u1', null, 'user', [text('查一下')], BASE),
      node('a1', 'u1', 'assistant', [reasoning, search, text('结论')], BASE + 1)
    ];
    const session = C.nodesToChatDemoSession({ sessionId: 's1', title: 't', createdAt: BASE, updatedAt: BASE }, nodes, 'a1');
    const assistant = session.messages[1];
    assert.equal(assistant.thinking_enabled, true);
    assert.equal(assistant.search_enabled, true);
    const types = assistant.fragments.map((f) => f.type);
    assert.ok(types.includes('THINK'));
    assert.ok(types.includes('TOOL_SEARCH'));
    assert.ok(types.includes('RESPONSE'));
    const searchFragment = assistant.fragments.find((f) => f.type === 'TOOL_SEARCH');
    assert.equal(searchFragment.results[0].title, '来源');
  });

  test('nodesToChatDemoSession：tool_call / tool_result(error) 转为 TIP 片段；system 节点不导出', () => {
    const call = { id: 'c', kind: 'tool_call', toolName: 'get_weather', argumentsJson: '{"city":"北京"}' };
    const result = { id: 'r', kind: 'tool_result', text: '失败', isError: true };
    const nodes = [
      node('sys', null, 'system', [text('系统提示')], BASE - 1),
      node('u1', null, 'user', [text('天气')], BASE),
      node('a1', 'u1', 'assistant', [call, result], BASE + 1)
    ];
    const session = C.nodesToChatDemoSession({ sessionId: 's1', title: 't', createdAt: BASE, updatedAt: BASE }, nodes, 'a1');
    assert.equal(session.messages.length, 2);
    assert.ok(!session.messages.some((m) => (m.fragments || []).some((f) => (f.content || '').includes('系统提示'))));
    const assistant = session.messages[1];
    const tip = assistant.fragments.find((f) => f.type === 'TIP');
    assert.ok(tip);
    assert.ok(tip.content.includes('get_weather'));
  });

  test('nodesToChatDemoSession：空会话导出空 messages，current_message_id 为 null', () => {
    const session = C.nodesToChatDemoSession({ sessionId: 's1', title: '空', createdAt: BASE, updatedAt: BASE }, [], null);
    assert.deepEqual(session.messages, []);
    assert.equal(session.current_message_id, null);
  });

  test('nodesToChatDemoIndexEntry：索引项字段', () => {
    const entry = C.nodesToChatDemoIndexEntry(
      { sessionId: 's1', title: '标题', createdAt: BASE, updatedAt: BASE + 5, pinned: true }, 7);
    assert.equal(entry.id, 's1');
    assert.equal(entry.title, '标题');
    assert.equal(entry.pinned, true);
    assert.equal(entry.message_count, 7);
    assert.equal(entry.updated_at, new Date(BASE + 5).toISOString());
  });

  // ---------------- 导入 ----------------
  function chatDemoSession(over = {}) {
    return {
      id: 'ext_1',
      title: '导入的会话',
      current_message_id: 3,
      inserted_at: new Date(BASE).toISOString(),
      updated_at: new Date(BASE + 3000).toISOString(),
      messages: [
        { id: 1, parent_id: null, role: 'USER', fragments: [{ type: 'REQUEST', content: '你好' }] },
        {
          id: 2, parent_id: 1, role: 'ASSISTANT',
          fragments: [{ type: 'THINK', content: '先想一下' }, { type: 'RESPONSE', content: '这是回答' }]
        },
        { id: 3, parent_id: 2, role: 'USER', fragments: [{ type: 'REQUEST', content: '继续' }] }
      ],
      ...over
    };
  }

  test('chatDemoSessionToNodes：角色/父子链/items/sessionId/活动路径', () => {
    const warnings = [];
    const nodes = C.chatDemoSessionToNodes(chatDemoSession(), 'new_s1', warnings);
    assert.equal(nodes.length, 3);
    assert.deepEqual(nodes.map((n) => n.role), ['user', 'assistant', 'user']);
    assert.deepEqual(nodes.map((n) => n.parentId), [null, nodes[0].nodeId, nodes[1].nodeId]);
    assert.ok(nodes.every((n) => n.sessionId === 'new_s1'));
    assert.equal(nodes[0].items[0].text, '你好');
    assert.equal(nodes[1].items.length, 2);
    assert.equal(nodes[1].items[0].kind, 'reasoning');
    assert.equal(nodes[1].items[0].text, '先想一下');
    assert.equal(nodes[1].items[1].text, '这是回答');
    assert.deepEqual(warnings, []);
    // current_message_id=3 → 活动叶子为最后一条
    assert.equal(T.resolveActiveLeafId(nodes, null), nodes[2].nodeId);
  });

  test('chatDemoSessionToNodes：分支切换（current_message_id 指向另一分支）', () => {
    const session = chatDemoSession({
      current_message_id: 3,
      messages: [
        { id: 1, parent_id: null, role: 'USER', fragments: [{ type: 'REQUEST', content: '问' }] },
        { id: 2, parent_id: 1, role: 'ASSISTANT', fragments: [{ type: 'RESPONSE', content: '分支A' }] },
        { id: 3, parent_id: 1, role: 'ASSISTANT', fragments: [{ type: 'RESPONSE', content: '分支B' }] }
      ]
    });
    const nodes = C.chatDemoSessionToNodes(session, 's1', []);
    const leaf = T.resolveActiveLeafId(nodes, null);
    const leafNode = nodes.find((n) => n.nodeId === leaf);
    assert.equal(leafNode.items[0].text, '分支B');
  });

  test('chatDemoSessionToNodes：缺失上级 / 非 USER-ASSISTANT 角色 / 未知片段都降级并写 warning', () => {
    const session = chatDemoSession({
      current_message_id: null,
      messages: [
        { id: 1, parent_id: 99, role: 'SYSTEM', fragments: [{ type: 'REQUEST', content: 'x' }] },
        { id: 2, parent_id: 1, role: 'ASSISTANT', fragments: [{ type: 'WEIRD_TYPE', content: '怪东西' }] }
      ]
    });
    const warnings = [];
    const nodes = C.chatDemoSessionToNodes(session, 's1', warnings);
    assert.equal(nodes.length, 2);
    assert.ok(warnings.some((w) => w.includes('上级')), JSON.stringify(warnings));
    assert.ok(warnings.some((w) => w.includes('角色')), JSON.stringify(warnings));
    assert.ok(warnings.some((w) => w.includes('未识别的片段')), JSON.stringify(warnings));
    const weird = nodes[1].items[0].text;
    assert.ok(weird.includes('未识别的记录'), weird);
    assert.ok(weird.includes('怪东西'), '未知片段内容不能丢');
  });

  test('chatDemoSessionToNodes：签名/来源（TOOL_SEARCH）保留', () => {
    const session = chatDemoSession({
      current_message_id: 2,
      messages: [
        { id: 1, parent_id: null, role: 'USER', fragments: [{ type: 'REQUEST', content: '读链接' }] },
        {
          id: 2, parent_id: 1, role: 'ASSISTANT',
          fragments: [{
            type: 'TOOL_OPEN',
            url: 'https://example.com/a', title: '文章 A', signature: 'SIG_1',
            results: [{ url: 'https://example.com/a', title: '文章 A', snippet: '摘要', signature: 'SIG_1' }]
          }]
        }
      ]
    });
    const nodes = C.chatDemoSessionToNodes(session, 's1', []);
    const item = nodes[1].items[0];
    assert.equal(item.kind, 'web_search_call');
    assert.equal(item.vendorRaw.signature, 'SIG_1');
    assert.equal(item.vendorRaw.searchKind, 'read_link');
    assert.equal(item.vendorRaw.pageMeta.url, 'https://example.com/a');
  });

  // ---------------- 往返 ----------------
  test('往返：导出后再导入，文本 / 角色 / 父子链 / token 估算保持一致', () => {
    const meta = { sessionId: 's1', title: '往返', createdAt: BASE, updatedAt: BASE + 1000 };
    const original = [
      node('u1', null, 'user', [text('第一个问题')], BASE, 12),
      node('a1', 'u1', 'assistant', [text('第一个回答')], BASE + 1, 34),
      node('u2', 'a1', 'user', [text('第二个问题')], BASE + 2, 56)
    ];
    const session = C.nodesToChatDemoSession(meta, original, 'u2');
    const warnings = [];
    const imported = C.chatDemoSessionToNodes(session, 's1', warnings);
    assert.equal(imported.length, 3);
    assert.deepEqual(imported.map((n) => n.role), ['user', 'assistant', 'user']);
    assert.deepEqual(imported.map((n) => n.items.map((i) => i.text)), [
      ['第一个问题'], ['第一个回答'], ['第二个问题']
    ]);
    assert.deepEqual(imported.map((n) => n.tokenEstimate), [12, 34, 56]);
    assert.deepEqual(warnings, []);
    assert.equal(T.resolveActiveLeafId(imported, null), imported[2].nodeId);
  });

  summarize();
}
