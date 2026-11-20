/**
 * v3 思考档位（6 档）与采样参数（topP）映射矩阵
 * （core_protocol/adapters/{DeepSeekResponsesAdapter,AnthropicAdapter,OpenAICompatAdapter}.ets）
 *
 * 契约（core-protocol v3 通知）：
 * - ThinkingLevel = off|min|low|med|high|xhigh；
 * - DeepSeek reasoning.effort：off→none / min|low→low / med→medium / high→high / xhigh→max；
 * - Anthropic thinking.budget_tokens：min 1024 / low 2048 / med 4096 / high 8192 / xhigh 16384，
 *   且恒 max_tokens > budget_tokens（小值会被抬高）；
 * - OpenAI 兼容 reasoning_effort：off→不传 / min|low→low / med→medium / high|xhigh→high；
 *   supportsThinking=false 时任何档位都不传；
 * - topP 透传规则各不相同，越界（<=0 或 >1）一律不发。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const DS_P = 'packages/core_protocol/src/main/ets/adapters/DeepSeekResponsesAdapter.ts';
const AN_P = 'packages/core_protocol/src/main/ets/adapters/AnthropicAdapter.ts';
const OP_P = 'packages/core_protocol/src/main/ets/adapters/OpenAICompatAdapter.ts';
const [ds, an, op] = await Promise.all([tryImport(DS_P), tryImport(AN_P), tryImport(OP_P)]);

function profile(over = {}) {
  return {
    providerId: 'deepseek', modelId: 'deepseek-flash', protocol: 'deepseek_responses',
    baseUrl: 'https://api.deepseek.com', assetKeyAlias: 'k', contextWindow: 1000000,
    cacheMissToHitRatio: 50, cacheIdleTtlSec: 3600, supportsServerWebTools: true,
    supportsThinking: true, supportsJsonSchema: true, label: '测试', ...over
  };
}
function node() {
  return { nodeId: 'n1', parentId: null, sessionId: 's', role: 'user', items: [{ id: 'i', kind: 'text', text: '你好' }], tokenEstimate: 1, createdAt: 1 };
}
function options(over = {}) { return { thinkingLevel: 'low', webMode: 'off', ...over }; }
const bodyOf = (adapter, prof, opt) => JSON.parse(adapter.buildRequest(prof, [node()], opt).bodyJson);

// ============================== DeepSeek ==============================
if (!ds) {
  skip('DeepSeek 6 档思考映射（全部用例）', missingReason(DS_P));
} else {
  const a = new ds.DeepSeekResponsesAdapter();
  test('[DS] reasoning.effort 六档全覆盖', () => {
    const map = { off: 'none', min: 'low', low: 'low', med: 'medium', high: 'high', xhigh: 'max' };
    for (const [level, effort] of Object.entries(map)) {
      const body = bodyOf(a, profile(), options({ thinkingLevel: level }));
      assert.equal(body.reasoning.effort, effort, `level=${level}`);
    }
  });

  test('[DS] supportsThinking=false 时不发 reasoning（任何档位）', () => {
    for (const level of ['off', 'min', 'low', 'med', 'high', 'xhigh']) {
      const body = bodyOf(a, profile({ supportsThinking: false }), options({ thinkingLevel: level }));
      assert.equal(body.reasoning, undefined, `level=${level}`);
    }
  });

  test('[DS] topP 合法值透传为 top_p；undefined/越界不发；与思考档位无关', () => {
    assert.equal(bodyOf(a, profile(), options({ topP: 0.5 })).top_p, 0.5);
    assert.equal(bodyOf(a, profile(), options({ topP: 1 })).top_p, 1);
    assert.equal(bodyOf(a, profile(), options()).top_p, undefined);
    for (const bad of [0, -0.1, 1.01, 2]) {
      assert.equal(bodyOf(a, profile(), options({ topP: bad })).top_p, undefined, `topP=${bad}`);
    }
    // 不支持思考的模型也允许采样参数
    assert.equal(bodyOf(a, profile({ supportsThinking: false }), options({ topP: 0.8 })).top_p, 0.8);
  });
}

// ============================== Anthropic ==============================
if (!an) {
  skip('Anthropic 6 档思考映射（全部用例）', missingReason(AN_P));
} else {
  const a = new an.AnthropicAdapter();
  const ap = profile({ providerId: 'anthropic', modelId: 'claude-sonnet', protocol: 'anthropic_messages', baseUrl: 'https://api.anthropic.com' });

  test('[AN] thinking.budget_tokens 六档映射：1024/2048/4096/8192/16384', () => {
    const map = { min: 1024, low: 2048, med: 4096, high: 8192, xhigh: 16384 };
    for (const [level, budget] of Object.entries(map)) {
      const body = bodyOf(a, ap, options({ thinkingLevel: level }));
      assert.equal(body.thinking.type, 'enabled', `level=${level}`);
      assert.equal(body.thinking.budget_tokens, budget, `level=${level}`);
      assert.ok(body.max_tokens > budget, `max_tokens(${body.max_tokens}) 必须 > budget(${budget})`);
    }
  });

  test('[AN] off → 不发 thinking，max_tokens=4096；开思考时默认 max_tokens=8192', () => {
    const off = bodyOf(a, ap, options({ thinkingLevel: 'off' }));
    assert.equal(off.thinking, undefined);
    assert.equal(off.max_tokens, 4096);
    const med = bodyOf(a, ap, options({ thinkingLevel: 'med' }));
    assert.equal(med.max_tokens, 8192);
  });

  test('[AN] max_tokens 小于等于 budget 时被抬高到 budget+2048', () => {
    const body = bodyOf(a, ap, options({ thinkingLevel: 'high', maxOutputTokens: 1000 }));
    assert.equal(body.thinking.budget_tokens, 8192);
    assert.equal(body.max_tokens, 8192 + 2048);
  });

  test('[AN] topP 仅在「思考关闭且未设 temperature」时透传', () => {
    assert.equal(bodyOf(a, ap, options({ thinkingLevel: 'off', topP: 0.5 })).top_p, 0.5);
    // 思考开启：不发
    assert.equal(bodyOf(a, ap, options({ thinkingLevel: 'med', topP: 0.5 })).top_p, undefined);
    // temperature 优先：不发 top_p
    assert.equal(bodyOf(a, ap, options({ thinkingLevel: 'off', topP: 0.5, temperature: 0.7 })).top_p, undefined);
    // 越界不发
    for (const bad of [0, 1.01, -1]) {
      assert.equal(bodyOf(a, ap, options({ thinkingLevel: 'off', topP: bad })).top_p, undefined, `topP=${bad}`);
    }
  });
}

// ============================== OpenAI 兼容 ==============================
if (!op) {
  skip('OpenAI 兼容 6 档思考映射（全部用例）', missingReason(OP_P));
} else {
  const a = new op.OpenAICompatAdapter();
  const oprofile = profile({ providerId: 'openai', modelId: 'gpt-4o', protocol: 'openai_chat', baseUrl: 'https://api.openai.com/v1' });

  test('[OP] reasoning_effort 六档映射：off 不传 / min|low→low / med→medium / high|xhigh→high', () => {
    const map = { off: undefined, min: 'low', low: 'low', med: 'medium', high: 'high', xhigh: 'high' };
    for (const [level, effort] of Object.entries(map)) {
      assert.equal(bodyOf(a, oprofile, options({ thinkingLevel: level })).reasoning_effort, effort, `level=${level}`);
    }
  });

  test('[OP] supportsThinking=false 时任何档位都不发 reasoning_effort', () => {
    for (const level of ['min', 'low', 'med', 'high', 'xhigh']) {
      const body = bodyOf(a, profile({ providerId: 'openai', modelId: 'gpt-4o', protocol: 'openai_chat', supportsThinking: false }),
        options({ thinkingLevel: level }));
      assert.equal(body.reasoning_effort, undefined, `level=${level}`);
    }
  });

  test('[OP] topP 仅在未发 reasoning_effort 时透传；越界不发', () => {
    // 思考开启（会发 reasoning_effort）→ 不发 top_p
    assert.equal(bodyOf(a, oprofile, options({ thinkingLevel: 'med', topP: 0.5 })).top_p, undefined);
    // 思考关闭 → 发
    assert.equal(bodyOf(a, oprofile, options({ thinkingLevel: 'off', topP: 0.5 })).top_p, 0.5);
    // supportsThinking=false（不发 reasoning_effort）→ 发
    const noThink = profile({ providerId: 'openai', modelId: 'gpt-4o', protocol: 'openai_chat', supportsThinking: false });
    assert.equal(bodyOf(a, noThink, options({ thinkingLevel: 'high', topP: 0.5 })).top_p, 0.5);
    for (const bad of [0, 1.01, -0.5, 2]) {
      assert.equal(bodyOf(a, oprofile, options({ thinkingLevel: 'off', topP: bad })).top_p, undefined, `topP=${bad}`);
    }
  });
}

summarize();
