# 鸿蒙原生可扩展大模型对话应用：Vibe Coding 开发方案与代码框架

> **文档定位**：本文件是面向本地 Coding Agent（如 DeepSeek Harness / 本地 DeepSeek 编程模型）的**架构总控规范与接口契约（Blueprint）**。
> **协作分工**：本文档锁定架构边界、数据结构、核心接口与分阶段验收标准；具体业务实现、ArkUI 细节与单元测试交由本地 Coding Agent 按 Milestone 逐步生成与迭代。

## 1. 给本地 Coding Agent 的总控指令（Hard Invariants）

在编写任何代码前，本地 Agent 必须严格遵守以下 **6 条架构红线**，不得自行降级或改道：

1. **纯原生渲染，禁止 ArkWeb 套壳主对话流**
   主对话列表必须使用 HarmonyOS NEXT 原生 `List` + `LazyForEach` + 块级增量 Markdown 渲染（参考 [ycj3/streaming-markdown](https://github.com/ycj3/streaming-markdown) 思路或 C++ `md4c` NAPI），历史已闭合块冻结复用，仅对末尾活跃块按 16ms/32ms 帧窗口节流刷新。仅允许对复杂 Mermaid 图表按需懒加载轻量离屏视图。

2. **统一 Item 树 + 只增不改轨迹（Append-Only Trajectory）**
   严禁使用 OpenAI 旧版扁平 `messages[]` 作为内部存储模型。内部状态必须以 [DeepSeek Responses API](https://api-docs.deepseek.com/zh-cn/api/create-response) 的 Item 语义为核心，外层套用类似 [deepseek-ai/chat-demo](https://github.com/deepseek-ai/chat-demo/blob/main/README.zh-CN.md) 的树形消息分支结构（支持编辑、重试、分支切换），并借鉴 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Trajectory 理念保持前缀字节级稳定。

3. **缓存感知优先于机械压缩（KV Cache First）**
   根据 [DeepSeek 官方定价](https://api-docs.deepseek.com/zh-cn/quick_start/pricing)，`deepseek-flash` 缓存命中与未命中价差达 **50 倍**（0.04 元 vs 2.00 元/百万 tokens），`deepseek-v4-pro` 达 **30 倍**（0.30 元 vs 9.00 元）。严禁每轮动态改写历史摘要破坏前缀缓存；必须实现基于缓存倍率 $R$ 与空闲过期窗口的 `CacheAwareCompactor`。

4. **插件微内核与可逆副作用（Reversible Side Effects）**
   借鉴 [DeepSeek Harness](https://www.deepseek.com/zh/harness/)（Cordis 微内核）的「一切皆插件」与可逆副作用回收机制：任何插件注册的工具、Hook、定时规则与 UI 快捷入口必须返回 `Disposable` 回收句柄，卸载或更新时零残留。受鸿蒙应用安全边界约束，严禁动态下发 `.so` 或无沙箱 `eval`，插件严格划分为 **L1 声明式 JSON / L2 远程 MCP / L3 QuickJS-NG NAPI 沙箱**。

5. **创造模式（Skill Creator Agent）必须落盘与可回滚**
   仿照 DeepSeek Harness「创造模式」内置手机端技能生成 Agent，通过对话生成或修改 Skill。生成产物**禁止只停留在内存中导致重启清零**，必须走完「Schema 校验 → 沙箱试跑（Dry-run）→ 变更 Diff 展示 → 用户确认 → RDB/沙箱目录落盘 + 保留上一版本快照」闭环。

6. **直白中文 UI 与硬件级密钥安全**
   所有面向用户的界面文案必须使用直白通俗的中文（如「能力抽屉」「联网清洗」「对话记忆条」「技能创造室」），禁止暴露晦涩工程术语。所有 API Key 与 MCP Token 必须通过 HarmonyOS `Asset Store Kit` 加密托管，严禁明文写入 Preferences 或数据库。

## 2. 技术栈与工程目录结构（HarmonyOS NEXT / API 14+）

### 2.1 核心底座选型

| 层次 | 选型方案 | 核心职责 | 
| ----- | ----- | ----- | 
| UI 展示层 | ArkTS / ArkUI 声明式组件 | 单手交互布局、半模态抽屉、增量 Markdown 渲染、实况窗与系统分享接入 | 
| 网络层 | [Remote Communication Kit (`rcp`)](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/remote-communication-rcp) | HTTP/2 多路复用、原生 SSE 流式分片读取、独立超时与取消控制 | 
| 存储与检索 | [`@ohos.data.relationalStore` (RDB)](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-data-relationalstore-i) + [FTS5 BM25](https://developer.huawei.com/consumer/cn/blog/topic/03206131555831070) | 会话树存储、Skill 版本落盘、历史原文毫秒级全文检索、分布式多端同步 | 
| 安全层 | HarmonyOS `Asset Store Kit` / `HUKS` | 多厂商 API Key、MCP 鉴权凭证隔离存储 | 
| 原生计算核心 | C++20 NAPI（`native_core`） | SSE 语义事件解析、增量 Markdown AST、本地 Tokenizer 估算、QuickJS-NG 脚本沙箱 | 

### 2.2 模块化目录规划（HAP + 多 HAR 解耦）

本地 Agent 初始化工程时，请严格按以下模块划分，保证各层仅通过 `interfaces/` 契约通信：

```
harmony-llm-app/
├── entry/                              # 主 HAP：页面路由、ArkUI 视图、系统 Kit 桥接
│   └── src/main/ets/
│       ├── pages/
│       │   ├── ChatPage.ets            # 主对话页（顶栏模型胶囊 + 消息树 + 记忆条 + 输入栏）
│       │   ├── SkillCreatorPage.ets    # 「技能创造室」页面（创造模式对话 + Diff/试跑卡片）
│       │   ├── SkillManagerPage.ets    # 已装技能列表 + Schema 自动生成的原生参数表单
│       │   └── SettingsPage.ets        # 模型厂商配置、缓存策略开关、局域网编辑入口
│       ├── components/
│       │   ├── StreamingMessage.ets    # 块级增量 Markdown + 折叠式检索/思考时间轴
│       │   ├── CapabilitySheet.ets     # 底部半模态「能力抽屉」（联网/插件/提示词开关）
│       │   └── MemoryGaugeBar.ets      # 悬浮「对话记忆条」与手动整理入口
│       └── bridge/
│           ├── LiveViewBridge.ets      # 鸿蒙实况窗：后台深度搜索进度同步
│           ├── ShareKitBridge.ets      # 接收系统分享的链接/PDF，直达清洗总结
│           └── LanEditorServer.ets     # 局域网临时 HTTP Web 编辑器（仅手动开启时运行）
├── packages/
│   ├── core_model/                     # HAR：统一数据模型、Trajectory 树、RDB/FTS5 仓库
│   │   └── src/main/ets/
│   │       ├── CanonicalTypes.ets      # 核心 Item / Node / Session 契约
│   │       ├── TrajectoryStore.ets     # 只增不改日志与分支切换管理
│   │       └── RdbRepository.ets       # SQLite 建表、FTS5 索引、ZIP 导入导出
│   ├── core_protocol/                  # HAR：多厂商 API Adapter + SSE 引擎
│   │   └── src/main/ets/
│   │       ├── ProviderAdapter.ets     # 统一适配器接口与能力声明
│   │       ├── DeepSeekResponsesAdapter.ets  # Responses API（含 web_search_call 回传）
│   │       ├── AnthropicAdapter.ets    # Messages API 适配
│   │       ├── OpenAICompatAdapter.ets # Chat Completions 兼容端点适配
│   │       └── RcpStreamClient.ets     # 基于 rcp 的流式请求与取消控制
│   ├── core_plugin/                    # HAR：插件微内核、双轨清洗引擎、创造模式 Agent
│   │   └── src/main/ets/
│   │       ├── PluginKernel.ets        # 轻量微内核（注册/依赖/Hook/Disposable 回收）
│   │       ├── SkillManifest.ets       # Skill JSON Schema 与 config_schema 规范
│   │       ├── L1DeclarativeRunner.ets # L1 声明式 HTTP/模板插件执行器
│   │       ├── L2McpClient.ets         # L2 远程 MCP（Streamable HTTP / SSE）客户端
│   │       ├── L3SandboxRunner.ets     # L3 QuickJS-NG 沙箱桥接与权限白名单
│   │       ├── DeepSeekWebCleaner.ets  # 双轨联网引擎（原厂托管 + 独立 Search/Fetch 清洗）
│   │       └── SkillCreatorAgent.ets   # 仿 DeepSeek Harness 的「创造模式」元 Agent
│   ├── core_context/                   # HAR：缓存感知压缩引擎 + 模块化提示词工坊
│   │   └── src/main/ets/
│   │       ├── CacheAwareCompactor.ets # 基于价差倍率与过期窗口的压缩决策器
│   │       └── PromptAssembler.ets     # 四层提示词装配与动态变量替换
│   └── native_core/                    # C++ NAPI 原生库
│       └── src/main/cpp/
│           ├── sse_parser.cpp          # 高速 SSE 分片与事件帧解析
│           ├── md_incremental.cpp      # 增量 Markdown 块级 AST（md4c）
│           └── quickjs_sandbox.cpp     # QuickJS-NG 沙箱（限内存/超时/无直访 FS）
└── docs/
    └── VIBE_BLUEPRINT.md               # 本规范文档（供本地 Agent 随时回查）

```

## 3. 核心数据契约与接口骨架（Contracts）

本地 Agent 必须先落盘以下接口定义并保持签名稳定，再分别填充实现。

### 3.1 统一 Item 树与轨迹模型（`core_model/CanonicalTypes.ets`）

支持树形分支、原样回传 DeepSeek 服务端搜索块（含 `kind`、`page`、`signature`），并在跨厂商切换模型时通过 `fallbackSummary` 做无损降级投影。

```
export type ItemKind =
  | 'text'
  | 'reasoning'
  | 'image'
  | 'file_ref'
  | 'tool_call'
  | 'tool_result'
  | 'web_search_call'
  | 'checkpoint_summary';

export interface CanonicalItem {
  id: string;
  kind: ItemKind;
  text?: string;
  // 用于 tool_call / tool_result
  callId?: string;
  toolName?: string;
  argumentsJson?: string;
  // 用于 file_ref / image（优先走 Files API file_id 避免大 Base64 阻塞移动网络）
  fileId?: string;
  mimeType?: string;
  // 用于 DeepSeek Responses API web_search_call 原样回传
  vendorRaw?: {
    provider: 'deepseek' | string;
    searchKind?: 'search' | 'deep_search' | 'read_link' | 'image_search' | 'deep_image_search';
    signature?: string;     // read_link 加密网页签名，同厂商多轮必须原样回传
    pageMeta?: { url: string; title: string; publishedAt?: string };
    sources?: Array<{ title: string; url: string; snippet: string; siteName?: string }>;
  };
  // 跨模型切换时，供异构 Adapter 降级投影的精简摘要
  fallbackSummary?: string;
  // 标记是否已被大载荷卸载（原文仍在 RDB，不在活跃上下文中发送）
  payloadPruned?: boolean;
}

export interface ConversationNode {
  nodeId: string;
  parentId: string | null;
  sessionId: string;
  role: 'system' | 'user' | 'assistant' | 'tool';
  items: CanonicalItem[];
  modelId?: string;
  providerId?: string;
  tokenEstimate: number;
  createdAt: number;
  // 用于消息分支切换（同一 parentId 下可有多个子节点）
  activeChildId?: string;
}

```

### 3.2 多厂商协议适配器（`core_protocol/ProviderAdapter.ets`）

每个模型配置必须携带 `cacheMissToHitRatio`（缓存未命中/命中价差倍率）与 `contextWindow`，供压缩引擎做经济性决策。

```
export interface ModelProfile {
  providerId: string;          // 不可变 ID，避免孤立历史会话
  modelId: string;             // 如 'deepseek-flash' | 'deepseek-v4-pro'
  protocol: 'deepseek_responses' | 'anthropic_messages' | 'openai_chat' | 'gemini';
  baseUrl: string;
  assetKeyAlias: string;       // Asset Store Kit 中的密钥别名（非明文 Key）
  contextWindow: number;       // 如 1_000_000
  cacheMissToHitRatio: number; // 如 deepseek-flash=50, deepseek-v4-pro=30, openai=4
  cacheIdleTtlSec: number;     // 估算服务端缓存自然过期秒数（用于过期窗口压缩）
  supportsServerWebTools: boolean;
  supportsThinking: boolean;
  supportsJsonSchema: boolean;
}

export interface StreamEvent {
  type:
    | 'reasoning_delta'
    | 'text_delta'
    | 'tool_call_delta'
    | 'web_search_status'
    | 'usage_final'
    | 'title_generated'
    | 'completed'
    | 'error';
  payload: Record<string, Object>;
}

export interface ProviderAdapter {
  readonly protocol: ModelProfile['protocol'];
  /**
   * 将统一 Trajectory 投影为目标厂商请求体。
   * 规则：同厂商原样透传 vendorRaw（如 DeepSeek signature）；
   * 异构厂商自动降级使用 fallbackSummary，严禁因未知字段导致 400。
   */
  buildRequest(
    profile: ModelProfile,
    nodes: ConversationNode[],
    options: RequestOptions
  ): HttpRequestSpec;

  /** 将原生 SSE 事件帧解析为统一 StreamEvent（注意 Responses API 无 [DONE]） */
  parseSseEvent(eventName: string, dataJson: string): StreamEvent[];
}

```

### 3.3 双轨联网与信息清洗引擎（`core_plugin/DeepSeekWebCleaner.ets`）

融合 [DeepSeek 全家桶 API（2026-11-13）](https://api-docs.deepseek.com/zh-cn/news/news261113) 与 [独立 Search & Fetch API](https://api-docs.deepseek.com/zh-cn/guides/search)：

* **轨道 A（原厂托管）**：当模型为 `deepseek-flash` 且用户未启用域名黑白名单时，直接声明 `deepseek_web_search` 与 `deepseek_read_url`（工具本身零计费，支持深度思考最多约 20 次自主搜索；注意不可同时传 `tool_choice` 强制调用）。

* **轨道 B（跨模型独立清洗插件）**：当模型为任意其他厂商，或用户开启了信源过滤规则时，调用 `POST https://api.deepseek.com/v1/tools/search`（100 QPS，5 元/千次）与 `POST https://api.deepseek.com/v1/tools/fetch`（25 QPS，5 元/千次），按质量分与权威度本地清洗。

```
export interface WebCleanPolicy {
  mode: 'auto' | 'server_managed' | 'standalone_clean';
  includeDomains: string[];   // 转为 site:a OR site:b
  excludeDomains: string[];   // 转为 -site:x
  afterDate?: string;         // 转为 after:YYYY-MM-DD
  languages?: string[];       // 转为 lang:zh,en
  minRerankScore: number;     // 默认 1.5（DeepSeek 官方优质结果阈值）
  minAuthority: number;       // 默认 2 或 3（>=3 为极权威）
  fetchTopK: number;          // 0=仅用 600-800 字 summary 省 Token；>0 并发 Fetch Markdown
  fetchTimeoutMs: number;     // 默认 8000ms，超时自动降级回 summary
}

export interface CleanedWebDoc {
  title: string;
  url: string;
  siteName?: string;
  publishedAt?: string;
  rerankScore: number;
  authority: number;
  contentForModel: string;    // 清洗裁剪后的 summary 或 Markdown 正文
  usedFallbackSummary: boolean;
}

```

### 3.4 缓存感知的四段式上下文压缩器（`core_context/CacheAwareCompactor.ets`）

核心原则：**不为省小钱而破坏 30x–50x 的前缀缓存命中**。

```
export type CompactionTrigger =
  | 'none'
  | 'idle_cache_expired'    // 距上次活跃超过 cacheIdleTtlSec，顺手压缩零沉没成本
  | 'model_switched'        // 切换异构模型，原厂缓存必然作废，免费压缩窗口
  | 'attention_threshold'   // 超过质量红线（如 140K tokens）或用户手动触发
  | 'low_ratio_economic';   // 仅对低缓存倍率模型（R <= 10）在 60% 窗口触发

export interface CompactionDecision {
  shouldCompact: boolean;
  trigger: CompactionTrigger;
  estimatedBreakEvenTurns: number; // 公式: (alpha / (1 - alpha)) * R
  pruneToolPayloadsOnly: boolean;  // true 时仅在入库前裁剪尾部大载荷，不破坏历史前缀
}

export interface CacheAwareCompactor {
  evaluate(
    profile: ModelProfile,
    nodes: ConversationNode[],
    lastActiveAt: number,
    isModelChanged: boolean
  ): CompactionDecision;

  /**
   * 生成不可变的 CheckpointSummary 节点并落库。
   * 原始历史节点标记为 archived 保留在 RDB 与 FTS5，永不物理删除。
   */
  compactToCheckpoint(
    nodes: ConversationNode[],
    summaryModel: ModelProfile
  ): Promise<ConversationNode>;
}

```

### 3.5 插件微内核与 Skill 契约（`core_plugin/PluginKernel.ets` & `SkillManifest.ets`）

借鉴 Cordis 可逆副作用设计，并强制要求 `configSchema` 让手机端自动渲染原生表单，免去手改 JSON。

```
export interface Disposable {
  dispose(): void;
}

export type PluginTier = 'L1_DECLARATIVE' | 'L2_REMOTE_MCP' | 'L3_QUICKJS_SANDBOX';

export interface SkillManifest {
  id: string;
  version: string;
  name: string;               // 直白中文名，如「技术文档联网清洗」
  description: string;
  tier: PluginTier;
  enabled: boolean;
  // 供手机端自动渲染原生开关/滑块/标签芯片表单，避免手改 JSON
  configSchema: Record<string, {
    label: string;
    type: 'boolean' | 'number' | 'string' | 'string_list' | 'enum';
    defaultValue: Object;
    min?: number;
    max?: number;
    options?: string[];
  }>;
  // 暴露给大模型的 Function Calling Schema（可选）
  toolSchema?: Record<string, Object>;
  // 挂载的提示词片段（按固定排序注入，保障 KV Cache 前缀稳定）
  promptSnippet?: string;
  // L1 HTTP 模板 / L2 MCP URL / L3 QuickJS 脚本源码
  runtimePayload: {
    httpTemplate?: Record<string, Object>;
    mcpEndpoint?: string;
    quickJsCode?: string;
    allowedDomains: string[]; // 网络访问白名单
  };
}

export interface PluginKernel {
  mount(manifest: SkillManifest): Promise<Disposable>;
  unmount(skillId: string): Promise<void>;
  /** 原子更新：先验证并试跑，成功后落盘并将旧版存入回滚栈 */
  atomicUpgrade(manifest: SkillManifest, dryRunInput?: string): Promise<{ ok: boolean; error?: string }>;
  rollback(skillId: string): Promise<boolean>;
}

```

### 3.6 仿 DeepSeek Harness「创造模式」的技能生成 Agent（`core_plugin/SkillCreatorAgent.ets`）

解决「手机端难编辑 Skill」的主路径：**用自然语言/语音描述需求 → 元 Agent 生成结构化 Manifest/脚本 → 沙箱试跑 → 展示中文 Diff → 一键生效并落盘**。

```
export interface CreatorSessionState {
  targetSkillId?: string;          // 为空表示新建，非空表示改造现有技能
  draftManifest?: SkillManifest;   // 待审批草稿
  previousManifest?: SkillManifest;// 用于渲染 Diff 与回滚
  dryRunReport?: {
    passed: boolean;
    latencyMs: number;
    sampleOutput: string;
    securityWarnings: string[];
  };
}

/**
 * SkillCreatorAgent 绑定五个内置元工具，通过 Responses API 结构化输出驱动：
 * 1. list_installed_skills   - 读取当前已装 Skill 清单与配置
 * 2. draft_skill_manifest    - 生成或修改完整的 SkillManifest（严格符合 JSON Schema）
 * 3. dry_run_skill           - 在受控沙箱中用模拟输入试跑草稿，返回耗时与结果
 * 4. commit_skill_to_rdb     - 仅在用户点击 UI「确认应用」后调用，落盘并热挂载
 * 5. distill_from_chat       - 从一段真实对话记录中反向提炼可复用的 Skill 草稿
 */
export interface SkillCreatorAgent {
  sendInstruction(userText: string, state: CreatorSessionState): AsyncIterable<StreamEvent>;
  confirmAndCommit(draft: SkillManifest): Promise<void>;
}

```

## 4. UI 信息架构与交互规范（供 ArkUI 实现参照）

所有高频操作必须在单手拇指热区内完成，坚持**默认极简、按需展开、全中文直白命名**：

| 页面 / 抽屉 | 核心布局与交互要求 | 鸿蒙原生增强 | 
| ----- | ----- | ----- | 
| 主对话页（`ChatPage`） | 顶栏居中「模型与思考」胶囊（一键切模型 + 快速/深度思考/深度搜索三档）；中间为块级增量渲染流与折叠式「检索与清洗过程」时间轴；底部输入框上方贴合一条极细的悬浮「对话记忆条」 | 长耗时深度搜索切后台时同步至**实况窗**；支持消息长按「编辑/重试/切换分支/沉淀为技能」 | 
| 底部「能力抽屉」（`CapabilitySheet`） | 输入框左侧点按拉起半模态面板，集中控制「联网清洗模式」「已装技能开关」「当前角色提示词」 | 遵循 HarmonyOS 半模态手势转场，与输入法键盘高度平滑衔接 | 
| 「技能创造室」（`SkillCreatorPage`） | 上半区为「创造模式」对话流（支持语音输入需求）；一旦元 Agent 产出草稿，消息流内直接内嵌「变更对比 + 一键试跑 + 应用生效 / 放弃」操作卡片 | 试跑结果与错误日志实时折叠展示，非开发者无需看代码即可完成改造 | 
| 技能管理与跨端编辑（`SkillManagerPage`） | 点开任意技能自动按 `configSchema` 渲染原生开关/滑块/域名标签芯片；右上角提供「Git 订阅同步」与「电脑局域网编辑」临时开关 | 局域网编辑基于本地轻量 HTTP 服务，打开即显示本机 IP 二维码，关闭页面自动释放端口 | 

## 5. Vibe Coding 分阶段开发任务书（喂给本地 DeepSeek Agent 的执行清单）

建议按以下 **5 个 Milestone** 依次驱动本地 Agent 开发。每次开工只喂当前 Milestone 的目标与 DoD，验证通过再进入下一阶段。

### Milestone 1：原生骨架与 DeepSeek Responses API 跑通

* **目标**：搭建 HAP + HAR 目录结构，打通 `rcp` 流式请求、`DeepSeekResponsesAdapter`、RDB 会话树存储与 `Asset Store Kit` 密钥存取；实现 `ChatPage` 的块级增量 Markdown 流式渲染与消息分支切换。

* **特别提醒本地 Agent**：DeepSeek Responses API 是无状态的，SSE 终止事件为 `response.completed`（无 `[DONE]`）；必须完整解析 `reasoning_text`、`output_text`、`usage.input_tokens_details.cached_tokens` 与 `response.title`。

* **验收标准（DoD）**：填入 DeepSeek Key 后可流畅进行 20 轮以上长对话不掉帧；编辑历史提问可生成新分支并自由来回切换；界面实时显示本轮缓存命中率与自动生成的会话标题。

### Milestone 2：多厂商无损切换与双轨联网清洗引擎

* **目标**：补齐 `AnthropicAdapter`、`OpenAICompatAdapter`（支持任意 OpenAI 兼容端点）及异构切换时的 `fallbackSummary` 降级投影；实现 `DeepSeekWebCleaner` 双轨引擎与底部「能力抽屉」。

* **特别提醒本地 Agent**：轨道 A（`deepseek_web_search`/`deepseek_read_url`）必须原样回传 `web_search_call` 与 `signature`，且开启时不得传入强制 `tool_choice`；轨道 B（独立 `/v1/tools/search` + `/v1/tools/fetch`）必须支持 `site:`/`-site:`/`after:` 语法组装、`rerank_score >= 1.5` 过滤，以及 Fetch 超时 8 秒自动降级回 `summary`。

* **验收标准（DoD）**：同一会话内先用 `deepseek-flash` 联网搜索，再中途切换为其他厂商模型继续追问不报 400 且上下文连贯；使用非 DeepSeek 模型时开启「联网清洗」，能成功调用 DeepSeek Search/Fetch 清洗过滤结果并附带来源引用作答。

### Milestone 3：插件微内核（L1 + L2 MCP）与模块化提示词工坊

* **目标**：实现 `PluginKernel`（含 `Disposable` 可逆回收）、`L1DeclarativeRunner`、`L2McpClient` 与 `PromptAssembler`（四层提示词 + `{{date}}`/`{{clipboard}}` 动态变量）；上线 `SkillManagerPage` 的 `configSchema` 原生表单渲染。

* **特别提醒本地 Agent**：已启用的工具定义与提示词片段必须按 `skill.id` 字典序固定排列，确保 KV Cache 前缀字节级稳定。

* **验收标准（DoD）**：通过导入一份 JSON 即可热添加一个 L1 工具插件并立即在对话中被模型调用；配置一个远程 MCP Server URL 可自动发现工具并审批执行；卸载插件后无残余监听与内存泄漏。

### Milestone 4：手机端「技能创造室」（创造模式）与跨端编辑

* **目标**：实现 `SkillCreatorAgent` 与 `SkillCreatorPage`，打通「语音/文字提需求 → 生成 `SkillManifest` → 沙箱试跑 → Diff 卡片确认 → RDB 原子落盘与回滚」闭环；同步实现「从对话沉淀为技能」及 `LanEditorServer`（局域网临时 Web 编辑）+ Git 订阅拉取。

* **特别提醒本地 Agent**：严禁只保存在内存状态中，必须验证「创造新技能 → 强杀重启 App → 技能仍在且可回滚到上一版本」。

* **验收标准（DoD）**：纯在手机上通过一句自然语言让「技能创造室」改造网页清洗技能（例如屏蔽指定站点并调整输出格式），试跑通过后一键生效，重启 App 不丢失。

### Milestone 5：缓存感知压缩引擎、QuickJS 沙箱与鸿蒙原生联动

* **目标**：落地 `CacheAwareCompactor`（实现空闲过期压缩、切模型压缩、质量红线 Checkpoint 压缩与 FTS5 历史原文回捞）；在 `native_core` 集成 QuickJS-NG 支持 L3 端侧脚本插件；接入鸿蒙实况窗、Share Kit 分享直连清洗与兼容 `chat-demo` 的 ZIP 历史导入导出。

* **验收标准（DoD）**：在 `deepseek-flash` 连续对话 10 轮不误触压缩、保持高缓存命中；模拟超过缓存过期时间续聊时自动触发零沉没成本压缩，且追问早期细节可通过 FTS5 准确回捞；从浏览器分享一篇长文链接到本 App 可一键完成清洗总结。

## 6. 供本地 Agent 查阅的官方协议参考

 1. [DeepSeek 全家桶应用 API 发布说明（2026/11/13）](https://api-docs.deepseek.com/zh-cn/news/news261113)

 2. [DeepSeek Responses API 接口参考](https://api-docs.deepseek.com/zh-cn/api/create-response)

 3. [DeepSeek 独立网页搜索与抓取（Search & Fetch）文档](https://api-docs.deepseek.com/zh-cn/guides/search)

 4. [DeepSeek 联网工具（Web Tools）指南](https://api-docs.deepseek.com/zh-cn/guides/web_tools)

 5. [DeepSeek 模型与缓存峰谷定价](https://api-docs.deepseek.com/zh-cn/quick_start/pricing)

 6. [DeepSeek Harness 开源仓库（Everything is a Plugin / 创造模式参考）](https://github.com/deepseek-ai/deepseek-harness)

 7. [DeepSeek Chat Demo（无后端消息树与导入导出参考）](https://github.com/deepseek-ai/chat-demo/blob/main/README.zh-CN.md)

 8. [HarmonyOS Remote Communication Kit (`rcp`) 参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/remote-communication-rcp)

 9. [HarmonyOS `@ohos.data.relationalStore` (RDB) 接口参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-data-relationalstore-i)

10. [HarmonyOS SQLite FTS5 与 BM25 本地检索实践](https://developer.huawei.com/consumer/cn/blog/topic/03206131555831070)

11. [HarmonyOS ArkTS 流式 Markdown 渲染组件 `@ycj3/streaming-markdown`](https://github.com/ycj3/streaming-markdown)