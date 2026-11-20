# core_context 逻辑要点（给 QA 写测试用）

用量 = 估算 token ÷ 上下文窗口；R = 缓存价差倍率。

触发（判定顺序 idle→switched→attention→low_ratio，空对话返回 none）：
- idle：now-lastActiveAt > ttl×1000（ttl>0）
- switched：isModelChanged=true
- attention：用量>0.7（aggressive 0.5；policy=off 仅此项仍触发）
- low_ratio：R≤10 且用量>0.6（aggressive 0.45）

break-even = round(α/(1-α)·R)，α=0.75 → 3R。

compactToCheckpoint：保留最近 8 节点（4 轮），更早的归档；短对话至少留 1 个节点；before/after 按整段路径前后估算。

pickPrunableNodeIds：尾部保留 keepRecentCount（默认 4）个不动，更早的含 tool_call/tool_result/web_search_call 且未 pruned 的节点返回。

assemble：固定 base→persona→skill(按 skillId 字典序)→memory，层间分隔符为 `\n\n---\n\n`；变量 {{date}}/{{time}}/{{weekday}}/{{model}}/{{user}}/{{clipboard}}，未知变量原样保留；clipboard 仅在非空时注入。
