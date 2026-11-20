/**
 * 四层提示词装配器（packages/core_context/PromptAssembler.ets）
 *
 * 覆盖 QA 清单：四层固定顺序 base→persona→skill(按 skillId 字典序)→memory、
 * {{date}}/{{time}}/{{weekday}}/{{model}}/{{user}}/{{clipboard}} 变量替换（未知变量原样保留）、
 * 同输入幂等（字节级一致，KV Cache 前缀稳定）、内置角色 ≥4、clipboard 仅显式传入才注入。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_context/src/main/ets/PromptAssembler.ts';
const m = await tryImport(P);

if (!m || !m.PromptAssembler) {
  skip('提示词装配器（全部用例）', missingReason(P));
  summarize();
} else {
  const { PromptAssembler } = m;
  const asm = new PromptAssembler();
  // 固定本地时间 2026-11-19 14:05（月份索引 10 = 11 月）
  const NOW = new Date(2026, 10, 19, 14, 5).getTime();
  const pad2 = (n) => (n < 10 ? `0${n}` : `${n}`);
  const expectDate = (() => { const d = new Date(NOW); return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`; })();
  const expectTime = (() => { const d = new Date(NOW); return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`; })();
  const expectWeekday = (() => { const d = new Date(NOW); return ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'][d.getDay()]; })();
  const SEP = '\n\n---\n\n';
  const baseInput = (over = {}) => ({ skillSnippets: [], now: NOW, ...over });

  // ---------------- renderTemplate ----------------
  test('renderTemplate 替换 date/time/weekday/model/user/clipboard 六个变量', () => {
    const out = asm.renderTemplate(
      '{{date}} {{time}} {{weekday}} {{model}} {{user}} {{clipboard}}',
      baseInput({ modelLabel: '深度求索·极速', userName: '小明', clipboard: '剪贴内容' })
    );
    assert.equal(out, `${expectDate} ${expectTime} ${expectWeekday} 深度求索·极速 小明 剪贴内容`);
  });

  test('renderTemplate 未知变量原样保留（技能片段可保留自己的占位写法）', () => {
    assert.equal(asm.renderTemplate('保留 {{unknown}} 原样', baseInput()), '保留 {{unknown}} 原样');
  });

  test('renderTemplate：modelLabel 为空时用「当前模型」，userName/clipboard 为空串', () => {
    assert.equal(asm.renderTemplate('[{{model}}][{{user}}][{{clipboard}}]', baseInput()), '[当前模型][][]');
  });

  test('renderTemplate：不传 now 时使用当前时间，仅校验格式（不依赖机器时区）', () => {
    const out = asm.renderTemplate('{{date}} {{time}} {{weekday}}', { skillSnippets: [] });
    assert.match(out, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2} 星期[日一二三四五六]$/);
  });

  // ---------------- assemble 顺序 ----------------
  test('四层顺序固定：base → persona → skill(字典序) → memory', () => {
    const result = asm.assemble(baseInput({
      personaPrompt: '你在严谨研究员模式',
      skillSnippets: [
        { skillId: 'b_skill', name: '技能乙', snippet: '乙的要点' },
        { skillId: 'a_skill', name: '技能甲', snippet: '甲的要点' }
      ],
      memorySummary: '之前聊过天气',
      retrievedMemories: ['早期细节一', '早期细节二']
    }));
    assert.deepEqual(result.segments.map((s) => s.layer),
      ['base', 'persona', 'skill', 'skill', 'memory', 'memory', 'memory']);
    assert.deepEqual(result.segments.filter((s) => s.layer === 'skill').map((s) => s.id), ['a_skill', 'b_skill']);
    assert.deepEqual(result.segments.filter((s) => s.layer === 'memory').map((s) => s.id),
      ['memory_summary', 'memory_1', 'memory_2']);
  });

  test('技能片段按 skillId 字典序（字符串比较），与传入顺序无关', () => {
    const result = asm.assemble(baseInput({
      skillSnippets: [
        { skillId: 's_z', name: 'Z', snippet: 'z' },
        { skillId: 's_a', name: 'A', snippet: 'a' },
        { skillId: 's_m', name: 'M', snippet: 'm' }
      ]
    }));
    assert.deepEqual(result.segments.filter((s) => s.layer === 'skill').map((s) => s.id), ['s_a', 's_m', 's_z']);
  });

  test('systemPrompt = 各段用固定分隔线 \\n\\n---\\n\\n 拼接', () => {
    const result = asm.assemble(baseInput({ personaPrompt: '角色提示', memorySummary: '记忆摘要' }));
    assert.equal(result.systemPrompt, result.segments.map((s) => s.content).join(SEP));
  });

  test('同输入两次装配结果逐字节一致（幂等，KV Cache 前缀稳定的前提）', () => {
    const inp = baseInput({
      personaPrompt: '角色提示 {{model}}',
      skillSnippets: [{ skillId: 'k2', name: '二', snippet: '二 {{date}}' }, { skillId: 'k1', name: '一', snippet: '一' }],
      memorySummary: '摘要',
      retrievedMemories: ['细节一'],
      modelLabel: '模型甲',
      userName: '小明',
      webEnabled: true,
      deepThinking: true
    });
    const a = asm.assemble(inp);
    const b = asm.assemble(inp);
    assert.equal(a.systemPrompt, b.systemPrompt);
    assert.deepEqual(a.segments, b.segments);
  });

  // ---------------- 分层内容规则 ----------------
  test('base 层内置中文基座并渲染出当前日期/星期/时间/模型', () => {
    const result = asm.assemble(baseInput({ modelLabel: '模型甲' }));
    const base = result.segments[0];
    assert.equal(base.layer, 'base');
    assert.ok(base.content.includes('ChatAnyWhere'));
    assert.ok(base.content.includes(expectDate));
    assert.ok(base.content.includes(expectWeekday));
    assert.ok(base.content.includes(expectTime));
    assert.ok(base.content.includes('模型甲'));
  });

  test('webEnabled / deepThinking 追加行为约定（联网引用编号、不泄露思考过程）', () => {
    const result = asm.assemble(baseInput({ webEnabled: true, deepThinking: true }));
    const base = result.segments[0].content;
    assert.ok(base.includes('这一轮开启了联网'));
    assert.ok(base.includes('不要输出思考过程'));
    const plain = asm.assemble(baseInput()).segments[0].content;
    assert.ok(!plain.includes('这一轮开启了联网'));
  });

  test('systemBase 覆盖内置基座（自定义基座也做变量替换）', () => {
    const result = asm.assemble(baseInput({ systemBase: '自定义基座，今天是 {{date}}' }));
    const base = result.segments[0].content;
    assert.equal(base, `自定义基座，今天是 ${expectDate}`);
    assert.ok(!base.includes('ChatAnyWhere'));
  });

  test('personaPrompt 为空时没有 persona 段', () => {
    const result = asm.assemble(baseInput());
    assert.equal(result.segments.filter((s) => s.layer === 'persona').length, 0);
  });

  test('persona 段内容会做变量替换', () => {
    const result = asm.assemble(baseInput({ personaPrompt: '当前模型 {{model}}' }));
    assert.equal(result.segments.filter((s) => s.layer === 'persona')[0].content, '当前模型 当前模型');
  });

  test('空 snippet / 空 memory 被跳过，不产生空段', () => {
    const result = asm.assemble(baseInput({
      skillSnippets: [
        { skillId: 'a', name: 'A', snippet: '   ' },
        { skillId: 'b', name: 'B', snippet: '有效' }
      ],
      retrievedMemories: ['', '   ']
    }));
    assert.equal(result.segments.filter((s) => s.layer === 'skill').length, 1);
    assert.equal(result.segments.filter((s) => s.id.startsWith('memory_')).length, 0);
  });

  test('memorySummary 带固定前缀，retrievedMemories 按传入顺序编号', () => {
    const result = asm.assemble(baseInput({ memorySummary: '摘要正文', retrievedMemories: ['片段一', '片段二'] }));
    const mems = result.segments.filter((s) => s.layer === 'memory');
    assert.ok(mems[0].content.includes('摘要正文'));
    assert.ok(mems[1].content.includes('片段一'));
    assert.ok(mems[2].content.includes('片段二'));
    assert.ok(mems[1].content.includes('第 1 段'));
    assert.ok(mems[2].content.includes('第 2 段'));
  });

  // ---------------- clipboard / user ----------------
  test('clipboard 仅在显式传入且非空时注入', () => {
    const without = asm.assemble(baseInput());
    assert.equal(without.segments.filter((s) => s.id === 'clipboard').length, 0);

    const withCb = asm.assemble(baseInput({ clipboard: '一段剪贴板内容' }));
    const seg = withCb.segments.filter((s) => s.id === 'clipboard')[0];
    assert.ok(seg);
    assert.ok(seg.content.includes('一段剪贴板内容'));
  });

  test('userName 显式传入时追加称呼约定段并渲染 {{user}}', () => {
    const withUser = asm.assemble(baseInput({ userName: '小明' }));
    const seg = withUser.segments.filter((s) => s.id === 'user_name')[0];
    assert.ok(seg);
    assert.ok(seg.content.includes('小明'));

    const without = asm.assemble(baseInput());
    assert.equal(without.segments.filter((s) => s.id === 'user_name').length, 0);
  });

  // ---------------- personas ----------------
  test('内置角色 ≥4 个且含「通用助手」，字段完整', () => {
    const list = asm.personas();
    assert.ok(list.length >= 4);
    assert.ok(list.some((p) => p.id === 'general' && p.name === '通用助手'));
    for (const p of list) {
      assert.ok(p.id && p.name && p.description && p.prompt, `角色字段完整：${p.id}`);
    }
  });

  test('persona(id) 命中返回角色，未知 id 返回 null', () => {
    const coder = asm.persona('coder');
    assert.ok(coder);
    assert.equal(coder.name, '代码搭档');
    assert.equal(asm.persona('not_exist'), null);
  });

  test('personas() 返回副本，调用方修改不会污染内置角色', () => {
    const list = asm.personas();
    const before = asm.personas().length;
    list.push({ id: 'hacked', name: 'x', description: 'x', prompt: 'x' });
    assert.equal(asm.personas().length, before);
  });

  summarize();
}
