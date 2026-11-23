# ChatAnyWhere 验收测试报告（QA）

> **报告人**：`qa-verify`（独立验证，不修改任何 `packages/*` 与 `chat/*` 源码）
> **最终快照**：构建矩阵 2026-11-19 20:08:58–20:09:18；用例运行 2026-11-19 20:09:39（Asia/Shanghai）
> —— 此为 ui-chat / ui-skills 均已完工（任务板 task-6/task-7 完成）后的最后一次全绿复核。
> **验证前提（重要）**：本次验收**没有真机联调**（无签名证书、无设备、无 API Key、无外网调用）。
> 因此验证手段 = **ArkTS 编译期类型检查（hvigor）+ 纯逻辑 Node 单测 + 代码审查**；
> 所有涉及 RDB / rcp / Asset / ShareKit / 实况窗 / QuickJS / 真机 UI 的端到端行为，
> 只能判定为「逻辑就绪，未做设备验证」，不计入「达成」。

---

## 1. 环境与工具链

| 项 | 值 |
| --- | --- |
| 工程根 | `C:\codes\ChatAnyWhere` |
| 操作系统 | Windows（PowerShell 7 / pwsh） |
| SDK | HarmonyOS 26.0.0（API 26），`C:\Application\DevEco Studio\sdk\default` |
| 构建 | hvigor 6.26.4（DevEco 内置），`pwsh tools/build.ps1`（自带跨 Agent 文件锁，串行化并发构建） |
| 测试运行时 | `C:\Application\DevEco Studio\tools\node\node.exe` — **Node v24.14.1**（原生 TS 类型擦除） |
| 测试依赖 | 仅 Node 内置模块（`node:assert` / `node:fs` / `node:url` / `node:path`），无三方依赖、可离线 |

测试命令：

```powershell
# 全量纯逻辑回归（自动先跑 prepare）
pwsh tools/logic-tests/run.ps1
# 只跑某类用例
pwsh tools/logic-tests/run.ps1 -Filter sse
# 只重建产物不跑用例
pwsh tools/logic-tests/prepare.ps1
```

---

## 2. 测试方法与工具实现

### 2.1 为什么需要 `prepare.ps1`

`.ets` 不能直接被 Node 运行，且 ArkTS 源码存在三类「Node 语义不兼容」：

1. 相对 import 不带扩展名（ESM 必须显式扩展名）；
2. **Node 的 TS 类型擦除只删类型语法、不做类型推导**：`import { SomeInterface }` 会保留为真实导入，
   运行时抛 `does not provide an export named …`（已实测）；
3. `@app/core_model` 等 oh-package 别名 Node 不认。

`prepare.ps1` 的处理（只读被测源码）：

- **显式清单**（`$manifest` 常量，见文件内注释）只拷贝纯逻辑文件及其「纯逻辑传递依赖闭包」；
- 依据全仓 `export` 表把命名 import **拆成 `import type {…}`（被擦除）与值导入**；
- `@app/*` 别名 → 生成 `build/_shims/<pkg>.ts` 转发；无法从纯逻辑提供的值导出会生成「调用即抛错」同名 shim
  （导入期不炸、失败点精确）；
- `import @kit.* / @ohos.* / @hms.*` 的文件、ArkUI 装饰器文件、含 `enum/namespace/declare`
  的文件（Node 擦除不支持代码生成）**一律跳过并记录**；
- 跳过清单 / 未命中清单 / 告警写入 `build/_prepare-report.json`，由 `run.ps1` 汇总。

### 2.2 `run.ps1`

扫描 `tools/logic-tests/cases/*.test.mjs`，用 DevEco Node 逐个运行；每个用例文件输出
`PASS/FAIL/SKIP <中文测试名>` 与一行机器可读 `SUMMARY passed=… failed=… skipped=…`；
失败（含用例文件 import 期崩溃）退出码非 0。

**并发保护**：`prepare.ps1` 会先清空并重写 `build/`，两个 `run.ps1` 并发执行会互相删文件
（表现为随机 skip 或找不到 `.ts`）。`run.ps1` 因此加了与 `tools/build.ps1` 同思路的
目录抢占锁（`tools/logic-tests/.run.lock`，20 分钟陈旧锁自动回收，等锁超时退出码 2），
把「prepare + 全部用例」串行化；已用两个并发进程实测：两者均 `RESULT: PASS`。

### 2.3 `prepare` 产物现状

| 项 | 数量 |
| --- | --- |
| 拷贝纯逻辑文件 | **50** |
| 跳过（平台绑定 / ArkUI / 不可擦除语法） | **5**（见下表） |
| 清单未命中（模块未实现） | **1** |
| 告警 | **0** |

跳过的 5 个文件与原因：

| 文件 | 原因 |
| --- | --- |
| `core_plugin/runners/NetHttp.ets` | `platform-kit-import`（`@kit.NetworkKit`） |
| `chat/components/MarkdownBlock.ets` | `arkui-decorator`（`@Component` struct；纯函数从同目录 `MarkdownParser.ets` 覆盖） |
| `core_plugin/runners/L2McpClient.ets` | 传递依赖平台网络层 |
| `core_plugin/WebCleaner.ets` | 传递依赖平台网络层（纯逻辑已被 `util/WebClean.ets` 覆盖） |
| `core_plugin/runners/L1DeclarativeRunner.ets` | 传递依赖 `NetHttp.ets` |

清单未命中：`chat/src/main/ets/*Chunk*.ets`（分块器实际落在 `MarkdownParser.ets`，已被 `*Markdown*.ets` 规则命中，
故该项只是清单冗余，无覆盖缺口）。

---

## 3. 构建矩阵（最终全绿快照）

> 构建结果以 `tools/build.ps1` 输出为准（带跨 Agent 锁串行构建）。时间戳为 Asia/Shanghai。
> 最终复核：**5/5 BUILD-OK，0 error，0 warning**（此前快照中的 warning 已随实现收敛）。

| 模块 | 结果 | 开始时间 | 日志文件 | 备注 |
| --- | --- | --- | --- | --- |
| `core_model` | **BUILD-OK** | 20:08:58 | `build-logs/core_model-20261119-200858.log` | 0 error / 0 warning |
| `core_protocol` | **BUILD-OK** | 20:09:04 | `build-logs/core_protocol-20261119-200904.log` | 0 error / 0 warning |
| `core_context` | **BUILD-OK** | 20:09:09 | `build-logs/core_context-20261119-200909.log` | 0 error / 0 warning |
| `core_plugin` | **BUILD-OK** | 20:09:14 | `build-logs/core_plugin-20261119-200913.log` | 0 error / 0 warning |
| `chat`（entry HAP，含全部 HAR 链接） | **BUILD-OK** | 20:09:18 | `build-logs/all-20261119-200918.log` | 0 error / 0 warning |

架构约束核对：依赖方向（core_model ← core_protocol ← core_context/core_plugin ← chat）由编译通过间接验证；
未发现反向 import 导致的编译失败。

Warnings 说明：最终快照 **0 warning**（全部模块）。历史快照（20:04 前后）曾有 31 条
`ArkTS:WARN Function may throw exceptions. Special handling is required.`
集中在 `core_model/impl/RdbRepository.ets`（RDB 读写/JSON 序列化）与少量 chat UI 文件；
在最终快照中已清零。后续仍建议写库路径保持 try/catch 防御（见 §9 风险 4）。

### 3.1 并行开发窗口内的构建失败记录（均已恢复，非最终状态）

| 时间 | 模块 | 错误原文摘要 | 归属 | 结论 |
| --- | --- | --- | --- | --- |
| 19:47 | core_model | `ModelLayerFactory.ets:42/47` `arkts-no-structural-typing` | core-model | 已修复，19:50 起 OK |
| 19:51 | core_plugin | `CreatorHeuristic.ets:17-23 Cannot find module './util/JsonLite'`、`PluginLayerFactory.ets:29 arkts-no-untyped-obj-literals`、`CreatorHeuristic.ets:606 arkts-no-any-unknown` | core-plugin | 已修复，19:56 起 OK |
| 19:52 | all（chat） | `ChatRuntime.ets:1165 pendingReuseNodeId 不存在`、`:1199 参数个数`、`:1209/1223 appendAssistantNode 不存在` | ui-chat | 已恢复，19:57 起 OK |
| 19:54 | core_plugin（依赖 core_model） | `SessionExporter.ets:251 arkts-no-any-unknown` + `importChatDemoArchive 不存在` | core-model | 已恢复，19:56 起 OK |
| 20:00 | all（chat） | `SettingsPage.ets:185 applyProfiles 不存在` | ui-skills | 已恢复，20:01 起 OK |
| 20:05 | 测试运行 | 一轮 4 个用例文件级 ERROR（恰好落在队友改源码窗口，`prepare` 拷贝到半成品） | QA 侧观察 | 重跑即全绿；已给 `prepare` 清理加退避重试降低假失败 |

> 说明：`tools/build.ps1` 的锁只能串行化「构建」，无法隔离「源码正在被并发编辑」。
> 因此单次失败需结合归属与时间戳判断，不能直接当作缺陷。

---

## 4. 用例统计（最终）

| 指标 | 值 |
| --- | --- |
| 运行时间 | **2026-11-19 20:09:39**（最终快照） |
| 用例文件 | **23 个** |
| 断言（assert）级用例 | **405 条** |
| 通过 | **405** |
| 失败 | **0** |
| 跳过（用例级） | **0** |
| 结果 | `RESULT: PASS`（`run.ps1` 退出码 0） |

按文件分布：

| 文件 | 断言数 | 覆盖主题 |
| --- | --- | --- |
| `00-tokens.test.mjs` | 22 | Token 估算（中/英/空/混排）、item/node/batch、cacheHitRatio、contextUsageRatio |
| `01-jsonutil.test.mjs` | 12 | JsonUtil 安全取值、缺字段/类型不符、嵌套读取、Record 构造 |
| `02-ids.test.mjs` | 5 | ID 前缀、唯一性（500 次）、各类 ID |
| `10-sse-parser.test.mjs` | 22 | 单帧/多行 data/CRLF/跨分片半帧/注释/多帧/id 粘滞/retry/单独 CR/flush/reset |
| `11-deepseek-sse.test.mjs` | 20 | DeepSeek Responses 全事件（text/reasoning/tool_call/web_search+signature/usage+cached_tokens/title/completed/failed/incomplete/未知容错）；含 2 条缺陷回归断言 |
| `12-anthropic-sse.test.mjs` | 14 | message_start/block/tool_use/thinking+signature/message_delta/stop/错误中文映射 |
| `13-openai-sse.test.mjs` | 12 | content/reasoning_content/tool_calls/[DONE]/finish_reason/usage(cached)/流内 error |
| `20-compactor.test.mjs` | 22 | 四类 trigger、policy=off/aggressive、break-even=round(3R)、idle 优先级、compactToCheckpoint、pickPrunable |
| `21-prompt-assembler.test.mjs` | 20 | 四层顺序、skill 字典序、变量替换、幂等（字节一致）、clipboard/user、内置角色 |
| `22-trajectory-logic.test.mjs` | 18 | 活动路径、分支切换、默认子节点、根→叶回溯、防环、排序/索引 |
| `23-node-codec.test.mjs` | 24 | 节点 JSON 无损往返/坏数据容错、FTS5 查询串、LIKE、片段、JSONL、会话元信息 |
| `30-web-clean.test.mjs` | 26 | site:/-site:/after:/lang: 组装、阈值过滤、排序去重、summary 降级、提示词块、错误中文 |
| `31-domain-util.test.mjs` | 11 | host 提取/规范化、白名单精确+子域、通配符拒绝、https 强制、URL 模板主机判定 |
| `32-skill-schema.test.mjs` | 35 | id/version/tier/L1/L2/L3、HTTPS+白名单强制、明文密钥检测、configSchema 校验、默认配置、中文摘要 |
| `33-skill-diff.test.mjs` | 16 | 新建/无变化/名称/版本/分级/启用/域名/配置项/配置值/提示词/工具/HTTP 模板 Diff 与统计 |
| `34-adapters-build-request.test.mjs` | 24 | 三适配器 buildRequest：同厂商 vendorRaw/signature 透传、异构 fallbackSummary 降级、联网工具限制、投影规则 |
| `35-markdown-block.test.mjs` | 25 | 块级分块（8 种块）、行内解析、表格、CRLF、**流式追加历史块 id/signature 不变** |
| `36-model-catalog.test.mjs` | 12 | 内置模型经济性参数（50/30/4）、协议、中文 label、密钥只存别名、注册/覆盖/内置判定 |
| `37-builtin-skills.test.mjs` | 9 | 4 个内置 L1 技能：Schema 校验、字典序、无明文密钥、占位符/responsePath、默认配置 |
| `38-protocol-utils.test.mjs` | 13 | 标题兜底、rcp/HTTP 错误中文映射、URL 拼接/https 判定/snippet |
| `39-creator-heuristic.test.mjs` | 12 | 自然语言→技能草稿（屏蔽站点/输出格式/数量/超时/阈值）、Diff、示例输入、对话沉淀 |
| `40-chat-demo-codec.test.mjs` | 12 | chat-demo v3 双向投影、分支 current_message_id、signature/sources、坏数据 warning、往返一致 |
| `41-l1-mcp.test.mjs` | 19 | L1 模板占位符/URL 编码/JSON 转义/格式化后缀/响应路径；MCP JSON-RPC/SSE/tools 提取/call 结果 |

---

## 5. 覆盖明细（按模块）

| 模块 | 已被自动化覆盖的纯逻辑 | 关键结论 |
| --- | --- | --- |
| `core_model` | `util/Tokens`、`util/JsonUtil`、`util/Ids`、`util/NodeCodec`、`util/TrajectoryLogic`、`util/ChatDemoCodec` | 树形分支、append-only、FTS5 查询构造、chat-demo 往返均正确 |
| `core_protocol` | `SseParser`、`adapters/DeepSeekSse`、`AnthropicSse`、`OpenAiSse`、三个 Adapter 的 `buildRequest`、`ModelCatalog`、`util/{TitleUtil,ErrorText,UrlUtil,JsonLite}` | 三厂商事件解析、缓存命中 token 映射、异构降级投影、错误中文化 |
| `core_context` | `CacheAwareCompactor`、`PromptAssembler`、`PromptPresets` | 四触发/经济性/保留窗口；四层提示词顺序与幂等 |
| `core_plugin` | `SkillSchema`、`SkillDiff`、`util/WebClean`、`util/DomainUtil`、`BuiltinSkills`、`util/CreatorHeuristic`、`util/L1Template`、`util/McpProtocol`、`util/JsonLite` | 技能校验/中文 Diff/双轨清洗/白名单/创造室草稿/L1 模板/L2 协议 |
| `chat` | `components/MarkdownParser`（`splitBlocks`/`parseInline`/`blockSpacing`） | 块级分块与流式历史块冻结（签名稳定） |

---

## 6. 未覆盖项与原因（明确清单）

| # | 未覆盖内容 | 原因 | 补偿手段 |
| --- | --- | --- | --- |
| 1 | `core_model/impl/RdbRepository`（建表/事务/FTS5/LIKE 降级）、`AssetSecretStore`、`SessionExporter`（zlib ZIP） | 依赖 `@ohos.data.relationalStore` / `@ohos.security.asset` / `@ohos.zlib`，Node 不可运行 | 编译期类型检查 + 代码审查 + 真机验收清单 |
| 2 | `core_protocol/impl/RcpStreamClient`（rcp 流式、取消、超时） | 依赖 HMS `@kit.RemoteCommunicationKit` | 同上；SSE 语义已由 `SseParser` 单测覆盖 |
| 3 | `core_plugin` 平台类：`PluginKernelImpl`（mount/unmount/Disposable 残留）、`WebCleaner`（HTTP）、`runners/{L1DeclarativeRunner,L2McpClient,NetHttp,L3SandboxRunner}`、`SkillCreatorAgent` | 依赖 `@kit.NetworkKit` / 网络会话 / QuickJS 沙箱 | 纯逻辑层已覆盖（Schema/Diff/MCP 组包/模板渲染）；生命周期与残留需真机 |
| 4 | `chat` 全部页面/组件/bridge/model（ChatPage、ChatRuntime、MarkdownBlock 渲染、CapabilitySheet、SettingsPage、SkillCreatorPage、LanEditorServer、LiveViewBridge、ShareKitBridge） | ArkUI 渲染/手势/生命周期，需真机或模拟器 | 编译期类型检查；纯解析函数已单测 |
| 5 | 真实网络端到端：真实 SSE 流、DeepSeek Search/Fetch 真响应、远程 MCP、服务端标题、真实 400 边界 | 无 API Key / 无外网策略 | 合成 fixture（事实来源：`docs/API_REFERENCE.md` §1/§2） |
| 6 | 真机性能与交互 DoD：20 轮长对话不掉帧、16/32ms 节流、List+LazyForEach 复用、半模态手势、实况窗/通知、分享直达、局域网编辑器端口释放 | 无真机/无签名证书 | 需按 §8 真机清单人工验收 |
| 7 | RDB/FTS5 设备端行为（MATCH 语法、trigram 分词、LIKE 降级路径） | 依赖设备 SQLite；Node 只验证查询串构造 | 真机「重建索引 + 早期细节回捞」验收 |
| 8 | L3 QuickJS 端侧脚本执行 | 已在 `docs/DEV_GUIDE.md §7` 登记降级：当前构建返回明确中文错误，不静默失败 | 已用 `SkillSchema` 校验脚本禁用能力 + 用例覆盖「未启用」告警 |
| 9 | ArkTS 专属约束的全量 lint（禁 any/生成器/Record 字面量等） | ArkTS 编译器本身即类型检查器，构建矩阵兜底；本轮未接 `code-linter` | 建议 CI 增加 lint 任务 |
| 10 | UI 文案「直白中文」全量人工审查 | 时间与设备限制，仅抽查纯逻辑产出文案（错误映射、原因文案、Diff） | 建议产品走查 |

---

## 7. Blueprint 五 Milestone DoD 逐条对照

判定口径（无真机前提下）：
**达成** = 自动化可完全验证且通过；**部分** = 纯逻辑/编译层验证通过，但设备端未验证；
**未达成** = 无任何可验证证据。

### Milestone 1：原生骨架 + DeepSeek Responses API

| DoD 条目 | 判定 | 证据 / 未验证点 |
| --- | --- | --- |
| 填 Key 后可流畅 20 轮以上长对话不掉帧 | **未达成（不可验证）** | 无真机/无 Key；帧率与渲染性能只能真机验收。编译层 `chat` BUILD-OK |
| 编辑历史提问可生成新分支并自由切换 | **部分** | `TrajectoryLogic` 18 断言（activeChildId 走链、分支切换、默认子节点、防环）+ `ChatDemoCodec` 分支 `current_message_id` 往返；UI 长按菜单/切换交互未真机验证 |
| 界面实时显示本轮缓存命中率 | **部分** | `Tokens.cacheHitRatio` 与 DeepSeek `usage.input_tokens_details.cached_tokens` → `usage_final` 映射已单测；UI 展示与节流未真机 |
| 自动生成会话标题 | **部分** | `response.completed.response.title → title_generated`、`TitleUtil` 本地兜底 13 断言；UI 展示未真机 |

### Milestone 2：多厂商无损切换 + 双轨联网清洗

| DoD 条目 | 判定 | 证据 / 未验证点 |
| --- | --- | --- |
| 同一会话先 `deepseek-flash` 联网搜索，再切其他厂商继续追问不报 400 且上下文连贯 | **部分** | 三适配器 `buildRequest` 24 断言：同厂商 `web_search_call` 原样回传 `kind/page/signature`；异构厂商用 `fallbackSummary` 降级为纯文本、不夹带未知字段；DeepSeek 联网工具与过滤条件互斥、从不传 `tool_choice`。**真实 400 边界与跨厂商切换未联网验证** |
| 非 DeepSeek 模型开启「联网清洗」能调用 DeepSeek Search/Fetch 并附来源引用作答 | **部分** | `WebClean` 26 断言：`site:`/`-site:`/`after:`/`lang:` 组装、`rerank_score ≥ 1.5` 与 `authority` 过滤、按质量排序去重、summary 降级、带编号来源块与防注入声明；真实 API 调用未验证 |

### Milestone 3：插件微内核（L1 + L2 MCP）+ 模块化提示词工坊

| DoD 条目 | 判定 | 证据 / 未验证点 |
| --- | --- | --- |
| 导入一份 JSON 即热添加 L1 工具插件并立即被模型调用 | **部分** | `SkillSchema` 35 断言（L1 校验/白名单/HTTPS/明文密钥阻断/默认配置）+ `BuiltinSkills` 9 断言（4 个 L1 技能全部通过校验）+ `L1Template` 模板渲染；`PluginKernel.mount/executeTool` 平台路径未测 |
| 配置远程 MCP Server URL 可自动发现工具并审批执行 | **部分** | `McpProtocol` 19 断言（JSON-RPC 组包、SSE 解析、tools/list 提取、tools/call 结果提取）；`L2McpClient` 真实会话/审批未测 |
| 卸载插件后无残余监听与内存泄漏 | **未达成（不可验证）** | 需真机 + `Disposable` 回收检查；纯逻辑无对应入口 |

### Milestone 4：手机端「技能创造室」+ 跨端编辑

| DoD 条目 | 判定 | 证据 / 未验证点 |
| --- | --- | --- |
| 纯手机上一句自然语言改造网页清洗技能（屏蔽站点/输出格式）→ 试跑通过 → 一键生效 → 重启不丢 | **部分** | `CreatorHeuristic` 12 断言（识别屏蔽 bilibili.com / 输出 Markdown / 数量 / 超时 / 相关度，生成可通过 Schema 校验的草稿 + 中文 Diff + 试跑输入）+ `SkillDiff` 16 断言；**RDB 落盘、重启保留、版本回滚（`atomicUpgrade`/`rollback`）未在设备验证** |

### Milestone 5：缓存感知压缩 + QuickJS + 鸿蒙原生联动

| DoD 条目 | 判定 | 证据 / 未验证点 |
| --- | --- | --- |
| `deepseek-flash` 连续 10 轮不误触压缩、保持高缓存命中 | **部分** | `Compactor` 22 断言：R=50 模型 65% 用量不触发 economic、≥70% 才 attention、idle 优先于换模型、`policy=off` 仍守硬红线；真实命中率与 10 轮体验需真机 |
| 模拟超过缓存过期时间续聊自动触发零沉没成本压缩，早期细节可 FTS5 回捞 | **部分** | idle 触发（`idleMs > ttl`）+ `compactToCheckpoint` 保留最近 8 节点/归档清单/摘要降级 + `NodeCodec.buildFtsQuery`/`likePattern`/`makeSnippet`；设备端 FTS5 与回捞未验证 |
| 浏览器分享长文链接到 App 一键完成清洗总结 | **未达成（不可验证）** | `WebClean.cleanFetchDoc` 逻辑已测；`ShareKitBridge`/`LanEditorServer`/实况窗为平台桥接，无真机 |
| （附带）兼容 `chat-demo` 的 ZIP 导入导出 | **部分** | `ChatDemoCodec` 12 断言（双向投影/分支/signature/坏数据容错/往返）；`SessionExporter` 的 zlib 打包解包平台路径未测 |

**汇总**：编译层 **5/5 模块 BUILD-OK**；DoD 中纯逻辑可验证部分全部通过；
受「无真机、无 Key」限制，**没有一条 DoD 可作为端到端「达成」**，均落在「部分」或「不可验证」，
这与「验收前提」一致，属于环境限制而非实现失败。

---

## 8. 缺陷与实现约定

### 8.1 本轮发现并已修复的缺陷（QA 报 → owner 修 → 回归断言锁住）

| # | 严重度 | 位置 | 问题 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | 低-中 | `core_protocol/adapters/DeepSeekSse.ets:372`（旧行号） | `extractDeepSeekTitle` 对非 JSON 直接 `JSON.parse`，代理返回 HTML 错误页时抛未捕获 `SyntaxError` | **已修复**（改用 `parseRecord` 容错）；`11-deepseek-sse` 增加回归断言 |
| 1b | 中 | 同文件 `response.function_call_arguments.delta/done` | 曾把 `item_id` 当 `callId` 下发，导致工具结果回传 call_id 配错 | **已修复**（owner 顺带修复）；增加「`callId===undefined`、`itemId` 正确」回归断言 |
| 2 | 低 | `core_plugin/util/DomainUtil.ets` `hostFromUrlTemplate` | 行为与函数注释不符（host 段占位符原样返回而非空串），导致 L1 校验错误文案出现 `{{input.host}}` | **已修复**（scheme/host 占位符均返回空串）；`31-domain-util` 增加「不可静态判定 → 必被白名单拒绝」安全断言 |
| 3 | 低（观察） | `core_plugin/BuiltinSkills.ets` | 注释称「按 skill id 字典序」，实际数组顺序不符 | **已修复**（改为字典序，注释与实现一致）；`37-builtin-skills` 断言排序 |
| 4 | 低（观察） | `core_plugin/util/CreatorHeuristic.ets` | 「相关度 2.5」被 `parseInt` 截断为 2 | **已修复**（改用 `firstDecimal`）；`39-creator-heuristic` 断言 2.5 |

最终状态：**0 个未修复缺陷**。

### 8.2 实现约定 / 非缺陷取舍（供维护者知悉）

1. **SseParser 单独 CR 行尾**：`feed()` 末尾遇到单个 `\r` 时会等待下一片（兼容 CRLF 被拆片），
   若流确实以单独 CR 结束则由 `flush()` 兜底吐出；已有用例锁定该行为。
2. `CacheAwareCompactor.breakEvenTurns = round(3R)`（alpha=0.75），`policy=off` 仍保留 attention 硬红线；
   与契约文档一致。
3. `builtinSkillJsonList()` 顺序 = `builtinSkillIds()` 顺序 = 字典序；`PluginKernel` 侧仍会独立排序兜底。
4. Node 逻辑测试通过 ≠ ArkTS 编译通过：`enum/namespace`、ArkUI 装饰器文件被跳过（5 个），
   该事实由构建矩阵兜底（见 §3）。

---

## 9. 遗留风险

| # | 风险 | 影响 | 建议 |
| --- | --- | --- | --- |
| 1 | **无真机 / 无签名证书 / 无 API Key** | 所有端到端 DoD（流式渲染、RDB/FTS5、Asset、分享、实况窗、QuickJS、性能）未验证 | 按 §8 DoD 表逐条做真机验收；准备 1 个 DeepSeek Key + 1 个兼容端点即可覆盖主要路径 |
| 2 | 快照时点的源码一致性 | 本报告为 20:09 全绿快照；其后若有人继续改源码，数据可能失效 | 以「task-6/task-7 完成 + 20:09 全绿」为交付基线；如需再改，重新复跑 `build.ps1` + `run.ps1` |
| 3 | `res/rcp` 真实网络不可测 | SSE 分片边界、代理错误页、超时/取消行为仅靠合成 fixture | 真机弱网测试；建议保留 `SseParser` 单测为回归门禁 |
| 4 | 历史警告（RdbRepository `Function may throw exceptions`） | 最终快照已清零，但 RDB 写库/解析路径的异常防御仍建议保留 | 真机验收时关注首启建库、导入损坏 ZIP、FTS5 建表失败降级路径 |
| 5 | FTS5 依赖设备 SQLite 能力 | 查询串构造已测，设备端 MATCH/trigram/LIKE 降级未验证 | 真机「重建索引 + 早期细节回捞」验收 |
| 6 | 设备端权限/白名单 | 插件允许域名、LAN 编辑器端口、分享 Intent 均需真实系统授权 | 真机走查权限弹窗与失败文案 |
| 7 | ArkTS lint 未纳入门禁 | 编译器兜底类型检查，但规范问题（any/生成器）可能漏网 | CI 增加 `code-linter`（`code-linter.json5` 已存在） |

### 建议的真机验收清单（按 Milestone）

1. **M1**：填 DeepSeek Key → 连续 20 轮对话；滚动/流式不掉帧；编辑提问生成分支并切换；观察「省了 x%」与自动标题。
2. **M2**：DeepSeek 联网搜索一轮 → 切 Claude/OpenAI 兼容端点追问（同一会话）不报错；开「联网清洗」用非 DeepSeek 模型，验证来源角标。
3. **M3**：设置页导入一份 L1 技能 JSON → 对话中触发该工具；配置一个 MCP URL（可用本地 mock）→ 工具发现与审批；卸载后确认无监听/无残留。
4. **M4**：技能创造室说「屏蔽 bilibili.com，输出 Markdown」→ 试跑 → 应用 → 强杀重启，确认技能与版本回滚都在。
5. **M5**：`deepseek-flash` 连聊 10 轮看命中率；改系统时间/等缓存过期后续聊，确认「顺手整理」；检索早期细节经 FTS5 回捞；从浏览器分享长文链接一键总结；导入/导出 chat-demo ZIP。

---

## 10. 结论

- **构建**：最终快照（2026-11-19 20:08:58–20:09:18）5/5 目标（4 个 HAR + entry HAP）全部 `BUILD-OK`，
  **0 error / 0 warning**。
- **纯逻辑**：最终快照（20:09:39）**23 个用例文件 / 405 条断言全绿**（0 失败 / 0 跳过），
  覆盖 Blueprint 五个 Milestone 中所有可脱离设备验证的核心算法
  （SSE/事件解析、三厂商投影、Token/压缩决策、提示词装配、清洗查询与阈值、技能 Schema/Diff、创造室规则、
  L1 模板/L2 协议、Markdown 分块、轨迹树、chat-demo 编解码）。
- **缺陷**：本轮共报告 2 个缺陷 + 2 个低危观察，**均已修复**，并补了回归断言；最终 0 未修缺陷。
- **验收结论**：**编译与纯逻辑层通过；端到端 DoD 因「无真机、无 Key」不可判定**，
  建议按 §9 真机清单完成最终产品验收后再宣布 Milestone 达成。
  交付基线 = 本轮最终快照（task-6 / task-7 均已完成）。

---

## 11. Lead 最终复核（清洁构建，2026-11-19 20:10–20:12）

在全部 7 名 Agent 交付并停止改动后，Lead 执行了一次**从零清洁构建**（删除 `chat/build`、`packages/*/build`、`.hvigor` 全部缓存）：

| 步骤 | 命令 | 结果 | 时间 |
| --- | --- | --- | --- |
| 清洁 | 删除 `chat/build`、`packages/*/build`、`.hvigor` | done | 20:10:44 |
| 全量构建 | `pwsh tools/build.ps1` | **BUILD-OK (all)**，31 条非阻塞 warning | 20:10:49 – 20:11:09 |
| 纯逻辑回归 | `pwsh tools/logic-tests/run.ps1` | **RESULT: PASS**（23 文件 / 405 断言） | 20:11 |
| 产物核验 | `chat/build/default/outputs/default/chat-default-unsigned.hap` | 2,563,566 bytes；`ets/modules.abc` 1,561,984 bytes（含 4 个 HAR 全部字节码）；`main_pages.json` 登记 5 个页面 | 20:11:09 |
| 脚手架清理 | 删除无引用的 `core_model/src/main/ets/CanonicalTypes.ets`（重复契约探针）、`core_plugin/src/main/ets/SkillManifest.ets`（废弃占位） | 重新构建仍 **BUILD-OK (all)** | 20:12:06 |

结论：清洁构建可复现、无隐藏缓存依赖；最终交付状态与 QA 报告一致。
31 条 warning 均为 `ArkTS:WARN Function may throw exceptions. Special handling is required.`（ArkTS 对平台 API 的建议性提示，非错误）。

---

## 12. 重构验收（前端视觉 + 架构瘦身）

> 验收人：`qa-verify`；数据快照：构建 2026-11-19 23:56:32–23:57:57；用例 2026-11-20 00:01:15（Asia/Shanghai）。
> 本轮改动范围：**仅入口 HAP 的 UI 与运行时组织**（task-8 视觉重构 / task-9 设置与技能瘦身 / task-10 LazyForEach / task-11 ChatRuntime 拆分门面），`packages/*` 底层未改。
> **验证前提不变**：无真机联调（无签名证书 / 无设备 / 无 API Key）；验证 = ArkTS 编译期类型检查 + 纯逻辑单测 + 静态源码断言 + 代码审查。

### 12.1 新增静态门禁

新增 [tools/logic-tests/cases/90-refactor-static.test.mjs](tools/logic-tests/cases/90-refactor-static.test.mjs)（11 条断言），用 `node:fs` 只读扫描源码，随 `run.ps1` 每次执行；把本轮重构的硬性约定固化下来（禁止硬编码色值/保姆文案、LazyForEach、行数上限、入口切换、L3 隐藏、资源键一致、契约与签名配置完整性）。

判定口径：**行数 = 非空行**（与 Lead 给的「现 494」一致：ChatRuntime.ets 总 559 行、非空 494 行；runtime 最大 SessionController.ets 非空 410 行）。

### 12.2 构建矩阵（unsigned 校验 + 签名配置恢复）

| 目标 | 结果 | 开始时间 | 日志 | 备注 |
| --- | --- | --- | --- | --- |
| `core_model` | **BUILD-OK** | 23:56:32 | `build-logs/core_model-20261119-235633.log` | 0 error / 27 warning |
| `core_protocol` | **BUILD-OK** | 23:56:49 | `build-logs/core_protocol-20261119-235650.log` | 0 error / 29 warning |
| `core_context` | **BUILD-OK** | 23:57:09 | `build-logs/core_context-20261119-235710.log` | 0 error / 27 warning |
| `core_plugin` | **BUILD-OK** | 23:57:26 | `build-logs/core_plugin-20261119-235727.log` | 0 error / 30 warning |
| `chat`（entry HAP，含全部 HAR） | **BUILD-OK [unsigned verification]** | 23:57:46 | 先失败：`build-logs/all-20261119-235746.log`（`Failed :chat:default@SignHap` / `ERROR: 11014003 Init keystore failed`）→ 回退重试成功：`build-logs/all-20261119-235746-unsigned.log` | 0 error / 27 warning |

签名回退链路（预期行为，已核实）：
1. 本机 CLI 签名材料不可用 → 原始全量构建在 `SignHap` 阶段报 `11014003 Init keystore failed`；
2. `tools/build.ps1` 检测到「纯签名失败、无编译错误」→ 临时把 `build-profile.json5` 的 `signingConfigs` 置空重试 → `BUILD-OK (all) [unsigned verification: signingConfigs 已临时跳过并恢复]`；
3. `finally` 恢复原配置。**恢复无损证据**：

| 项 | 构建前 | 构建后 |
| --- | --- | --- |
| `build-profile.json5` SHA256 | `67A102162DC92593B1B016E652031EB08D39E4D289749878C6064649DC34542C` | **同值**（完全一致） |
| 文件大小 | 2452 bytes | 2452 bytes |
| 签名字段 | `signingConfigs` / `certpath` / `storeFile` / `keyAlias` / `profile` / `signAlg` / `signingConfig` 均在 | 均在（90 静态用例断言） |

> 结论：HAP 通过的是「unsigned 编译验证」，未产出可安装签名包；但用户签名材料（keystore/cert/profile 路径与口令密文）字节级未被破坏。

Warnings 说明：本轮全量重编译如实记录 27–30 条 `ArkTS:WARN Function may throw exceptions. Special handling is required.`（全量构建 27 条 = `RdbRepository.ets` 24 + `SessionExporter.ets` 3），0 error。与 §11 的 31 条同源；R1 末次快照曾显示 0 warning 是增量/缓存未重复告警所致，本轮以全量重编译为准。

### 12.3 用例统计（最终）

| 指标 | 值 |
| --- | --- |
| 运行时间 | **2026-11-20 00:01:15** |
| 用例文件 | **24 个**（原 23 + 新增 `90-refactor-static`） |
| 断言级用例 | **416 条** = 原 405（全绿，R1 覆盖无衰减）+ 新增 11 条重构静态断言 |
| 通过 / 失败 / 跳过 | **416 / 0 / 0** |
| 结果 | `RESULT: PASS`（`run.ps1` 退出码 0） |
| prepare 产物 | 拷贝 48 个纯逻辑文件；跳过 5 个（平台绑定/ArkUI）；清单未命中 1（`*Chunk*` 冗余通配，实际分块器在 `MarkdownParser.ets`）；0 告警 |

### 12.4 静态重构断言逐项证据（11/11 通过）

| # | 检查项 | 结果 | 实测证据 |
| --- | --- | --- | --- |
| 1 | 无硬编码色值 `#RRGGBB` | **PASS** | 扫描 `chat/src/main/ets` **50 个文件**；唯一豁免 `bridge/LanEditorServer.ets` 的 `renderEditPage()`（:369）内嵌 HTML 模板：**模板内 10 个色值 / 6 行 CSS**，模板外 0；其余 49 个文件 0 |
| 2 | 保姆式文案关键词（7 个） | **PASS** | 7 关键词 × 50 文件 = **0 命中** |
| 3 | ChatPage 虚拟列表 | **PASS** | `ChatPage.ets:1185` `LazyForEach(`；`:1216` `.cachedCount(6)`；`ForEach(this.nodes` **0 次**；`components/MessageDataSource.ets` `implements IDataSource` 且含 `register/unregisterDataChangeListener` |
| 4 | ChatRuntime 门面行数 | **PASS** | `model/ChatRuntime.ets` 总 559 行 / **非空 494 行 ≤ 500** |
| 5 | runtime/ 拆分完整性 | **PASS** | `model/runtime/` **14 个文件**；SessionController 445 总/410 非空、StreamTurnExecutor 393/367、ToolLoopRunner 83/79（均 ≤500）；最大非空 410；门面引用 SessionController+StreamTurnExecutor，StreamTurnExecutor 使用 ToolLoopRunner |
| 6 | 入口切换 | **PASS** | `pages/Index.ets` **不存在**；`main_pages.json` 无 `pages/Index` 且首项 `pages/ChatPage`；`ChatAbility.ets:42` `loadContent('pages/ChatPage')` |
| 7 | 系统符号图标 | **PASS** | `SymbolGlyph` 全仓 **82 处 ≥ 60**（ChatPage 24、SettingsDataView/ModelCapsule 各 8、SettingsPage 6…） |
| 8 | 设计令牌复用 | **PASS** | `app/Theme.ets` 被 **21 个 UI 文件** import（不含自身，≥15）；导出 `Theme` / `Layout` / `Icons` 三类令牌 |
| 9 | 深浅色资源一致 | **PASS** | `base/element/color.json` **36 键** 与 `dark/element/color.json` **36 键** 集合完全一致；含 `brand`/`bg_page`/`text_primary` |
| 10 | L3 从 UI 隐藏 | **PASS** | `SkillManagerPage.ets:19` `TIER_L3 = 'L3_QUICKJS_SANDBOX'` 并过滤；`SkillCard.ets:10` `tierLabel` 仅返回「声明式 / 远程 MCP」，无用户可见 L3/端侧字符串（源码注释中「L3 不展示」说明保留，属文档而非 UI） |
| 11 | 契约 + 签名配置结构 | **PASS** | 4 个 `packages/*/Index.ets` 关键导出齐全；`interfaces/**` **19 个文件**；`ChatRuntimeApi` 9 个关键方法齐全；`build-profile.json5` 签名材料字段齐全 |

### 12.5 契约未回归证据（packages 底层 + 冻结文件）

无 git 仓库，采用「文件签名 + mtime + 写作用域」三重证据：

| 冻结文件 | SHA256（前 16 位） | mtime |
| --- | --- | --- |
| `packages/core_model/Index.ets` | `9b79c759005ce6cb` | 2026-11-19 19:54:39 |
| `packages/core_protocol/Index.ets` | `e270a284b5150af9` | 19:48:05 |
| `packages/core_context/Index.ets` | `912fcc44a3ec3f16` | 19:42:56 |
| `packages/core_plugin/Index.ets` | `722545ee896b346f` | 19:57:41 |
| `chat/src/main/ets/model/ChatRuntimeApi.ets` | `51a02a5ea2798152` | 19:40:31 |
| `chat/src/main/ets/model/RuntimeHolder.ets` | `2189bdd03ecf260a` | 20:01:42 |
| `chat/src/main/ets/app/AppServices.ets` | `ac70de8ea0b591c7` | 19:45:53 |

- `interfaces/**`：**19 个文件**，mtime 全部落在 19:35:49–19:41:53；内容结构由 90 用例与编译期 import 双重校验。
- `packages/*` 源码（排除构建产物 `BuildProfile.ets`）**最新 mtime = 20:05:48**（`CreatorHeuristic.ets`）；本轮重构任务从 23:10+ 开始且写作用域未包含 `packages/*`，两者互相印证「底层未改」。`packages/*/BuildProfile.ets` 的 23:54:43 mtime 是 hvigor 每次构建自动重生成的构建产物，非源码改动。
- `ChatRuntimeApi.ets` 方法结构断言（90 用例）：`init / send / stop / retryLast / switchBranch / editUserNode / branches / compactNow / searchHistory` 全部存在。
- 两处脚手架清理与本轮无关：`core_model/.../CanonicalTypes.ets`、`core_plugin/.../SkillManifest.ets` 已在 §11 Lead 清洁构建阶段作为「无引用脚手架」删除，全仓 0 处 import 引用（实际引用均指向 `interfaces/SkillManifest`），构建与 416 用例全绿；prepare 清单已同步移除这两项。

### 12.6 已知风险 / 真机冒烟建议

| # | 风险 | 说明 |
| --- | --- | --- |
| 1 | **无真机联调仍成立** | 视觉/手势/掉帧/内存、抽屉交互、键盘避让、MemoryGaugeBar 隐藏阈值、LazyForEach 长列表真实滚动性能均未验证 |
| 2 | unsigned 校验链路的边界 | 仅验证「构建前后 `build-profile.json5` 哈希一致 + 签名字段完整」；未验证真实签名安装包（本机缺签名材料，11014003 属环境问题） |
| 3 | 咨询类 warning 27–30 条 | `RdbRepository`/`SessionExporter` 的 `Function may throw exceptions`；建议真机首启建库、导入损坏 ZIP、FTS5 建表失败降级路径重点观察 |
| 4 | 静态门禁绑定当前基线 | `SymbolGlyph ≥60`、`Theme import ≥15`、颜色键=36、runtime 文件数≥10 等用于防回退；后续有意调整视觉基线时需同步更新断言 |
| 5 | LanEditorServer 色值豁免 | 10 个色值/6 行 CSS 位于发给电脑浏览器的内嵌 HTML 模板，无法使用 app 资源；用例按「模板字面量内」整体豁免，不会包庇其他硬编码 |
| 6 | 死代码删除无 git 追溯 | 见 §11 Lead 清洁构建记录，已确认无引用；如需审计建议后续引入版本库 |

**建议真机冒烟（按本轮重构重点）**：发送 → 停止 → 重试 → 切分支 → 手动压缩；抽屉「新对话 / 历史切换 / 长按重命名删除」；设置分组首页 + 4 个子页；技能列表 L3 不可见、详情表单可保存；MemoryGaugeBar 在 <60% 时完全隐藏；流式 32ms 节流下滚动跟随与输入框键盘避让。

### 12.7 结论

- **构建**：5/5 目标 BUILD-OK；HAP 走 unsigned 校验（11014003 环境签名问题）且 `build-profile.json5` 字节级恢复无损，签名字段完整。
- **用例**：24 文件 / **416 断言全绿**（405 回归 + 11 重构静态门禁），0 失败 / 0 跳过。
- **重构目标核验**：颜色令牌化（0 硬编码）、文案瘦身（0 保姆文案）、主列表虚拟化（LazyForEach + cachedCount(6) + 无 ForEach 全量）、上帝类拆分（ChatRuntime 非空 494 行 + runtime/ 14 文件最大 410 行）、入口收敛（Index 删除、ChatPage 启动）、L3 隐藏、深浅色资源一致 —— **代码与构建层全部达成**。
- **缺陷**：本轮**未发现需要修复的缺陷**；2 处脚手架删除已由 §11 Lead 记录为有意清理。
- **残余**：端到端体验仍需按 §12.6 真机冒烟；无真机前不得宣布「视觉/性能 DoD 达成」。

---

## 13. v3 设计落地验收（Pura X Max 双栏/折叠 + 6 档思考 + 角色/技能 Master-Detail + SKILL.md 编辑器）

> 验收人：`qa-verify`；数据快照：构建 2026-11-20 12:24:06–12:25:44；用例 2026-11-20 12:26:50（Asia/Shanghai）。
> 设计基准：`C:\Users\Enka\Downloads\chatanywhere_v3_pura_x_max.html`（CSS 变量 10–48、布局 190–528、ArkUI 指令 530–551）。
> 本轮范围（task-13..18）：主对话页 v3、设置中心 Master-Detail、我的技能 Master-Detail、创造室 SKILL.md 编辑器、运行时角色/技能/附件/6 档接线。
> **验证前提不变**：无真机联调（无签名证书 / 无设备 / 无 API Key）；验证 = ArkTS 编译期类型检查 + 纯逻辑单测 + v3 静态源码断言 + 代码审查。

### 13.1 测试基建更新

- `prepare.ps1` 显式清单新增：`packages/core_plugin/src/main/ets/SkillMarkdown.ets`、`chat/src/main/ets/app/EffortLevels.ets`（后者只 import `@app/core_protocol` 的类型 `ThinkingLevel`，被改写为 `import type` 擦除，Node 侧可直接跑）。
- 新增用例：
  - `42-thinking-levels.test.mjs`（10 断言）：三适配器 6 档映射矩阵 + `topP` 透传规则；
  - `43-skill-markdown.test.mjs`（12 断言）：`SkillMarkdownCodec` 往返/告警/非法 tier/L1·L2·L3 映射；
  - `44-effort-levels.test.mjs`（5 断言）：6 档短标签、默认 med、索引容错、`quick/deep` 迁移；
  - `91-design-v3-static.test.mjs`（14 断言）：v3 设计静态门禁（见 §13.4）。
- 更新用例：`34-adapters-build-request.test.mjs` 的思考 fixture 改为 6 档（DeepSeek none/low/low/medium/high/max；Anthropic budget 1024/2048/4096/8192/16384 且 `max_tokens > budget`；OpenAI low/low/medium/high/high，`off`/不支持思考时不发 `reasoning_effort`）；`90-refactor-static.test.mjs` 颜色基线由 36 → **38 键**（v3 色板），其余 R2 断言保留；并发构建持锁时签名恢复断言显式 skip（避免 unsigned 回退窗口误报）。

### 13.2 构建矩阵（unsigned 校验 + 签名配置 SHA256 前后一致）

| 目标 | 结果 | 开始时间 | 日志 | 备注 |
| --- | --- | --- | --- | --- |
| `core_model` | **BUILD-OK** | 12:24:06 | `build-logs/core_model-20261120-122407.log` | 0 error / 27 warning |
| `core_protocol` | **BUILD-OK** | 12:24:24 | `build-logs/core_protocol-20261120-122425.log` | 0 error / 29 warning |
| `core_context` | **BUILD-OK** | 12:24:39 | `build-logs/core_context-20261120-122515.log` | 0 error / 27 warning |
| `core_plugin` | **BUILD-OK** | 12:25:30 | `build-logs/core_plugin-20261120-122530.log` | 0 error / 30 warning |
| `chat`（entry HAP，含全部 HAR） | **BUILD-OK [unsigned verification]** | 12:25:44 | `build-logs/all-20261120-122544-unsigned.log` | 0 error / 27 warning；原始日志因 `SignHap` / `11014003 Init keystore failed` 触发脚本的临时跳过签名重试，`finally` 自动恢复 |

| 项 | 构建前 | 构建后 |
| --- | --- | --- |
| `build-profile.json5` SHA256 | `67A102162DC92593B1B016E652031EB08D39E4D289749878C6064649DC34542C` | **同值** |
| 文件大小 | 2452 bytes | 2452 bytes |

结论：HAP 为 **unsigned 编译验证**（本机 CLI 缺签名材料，环境问题）；签名字段（signingConfigs/certpath/storeFile/keyAlias/profile/signAlg）字节级未被破坏。Warnings 与 §12 同源（`RdbRepository`/`SessionExporter` 的 `Function may throw exceptions` 咨询提示），非错误。

### 13.3 用例统计（最终）

| 指标 | 值 |
| --- | --- |
| 运行时间 | **2026-11-20 12:26:50** |
| 用例文件 | **28 个** |
| 断言级用例 | **457 条**（R1 405 + R2 静态 11 + v3 新增/扩展 41） |
| 通过 / 失败 / 跳过 | **457 / 0 / 0** |
| 结果 | `RESULT: PASS`（`run.ps1` 退出码 0） |
| prepare 产物 | 拷贝 50 个纯逻辑文件；跳过 5（平台绑定/ArkUI）；清单未命中 1（`*Chunk*` 冗余通配）；0 告警 |

### 13.4 v3 静态断言逐项证据（`91-design-v3-static` 14/14 通过；`90` 11/11 通过）

| # | 检查项 | 结果 | 实测证据 |
| --- | --- | --- | --- |
| 1 | v3 色板 38 键 + 精确色值 | **PASS** | `base`/`dark` 各 **38 键**且键集合一致；`brand` base `#2563EB` / dark `#4F83FF`；`bubble_user` base `#111827` / dark `#2563EB`；`bg_page` base `#FFFFFF` / dark `#0E1014` |
| 2 | 无硬编码色值 | **PASS** | 扫描 `chat/src/main/ets` **54 个文件**；唯一豁免 `bridge/LanEditorServer.ets` `renderEditPage()` 内嵌 HTML 模板（**10 个色值 / 6 行 CSS**，模板外 0）；其余文件 0 |
| 3 | 教学/保姆文案 | **PASS** | 7 关键词 × 54 文件 = **0 命中** |
| 4 | 响应式双栏基建 | **PASS** | `app/Breakpoint.ets` 阈值 `UNFOLDED_MIN_VP = 600`；被 **4 个页面** import；`Breakpoint.watch(` **5 处**（ChatPage:227 / SettingsPage:47 / SkillManagerPage:46 / SkillCreatorPage:114 + 文档示例） |
| 5 | Master-Detail 侧栏宽度 | **PASS** | `Layout.sidebarChat=224` / `sidebarSkills=232` / `sidebarSettings=216`（Theme.ets:125–127）；ChatPage:1667 / SkillManagerPage:484 / SettingsPage:321 均已引用；`Layout.chatMaxWidth=660`、`Layout.sourcePaneWidth=280`（Theme.ets:124/128） |
| 6 | 6 档思考 | **PASS** | `EffortLevels.ALL` = 关闭/Min/Low/Med/High/xHigh；`ThinkingLevel = off\|min\|low\|med\|high\|xhigh`；带引号的旧值 `quick/deep` **仅**出现在 `EffortLevels.normalize` 迁移分支（quick→med / deep→high） |
| 7 | ChatPage 虚拟列表 | **PASS** | `LazyForEach`（ChatPage.ets:1618）+ `.cachedCount(6)`（:1650）；`ForEach(this.nodes` **0 次** |
| 8 | 创造室 SKILL.md 编辑器 | **PASS** | `SkillCreatorPage.ets:17` import `SkillMarkdownCodec`；:241 `toMarkdown`、:259 `newTemplate`、:322 `toManifestJson` |
| 9 | 角色与提示词接线 | **PASS** | `SettingsPage.ets:15` import `SettingsPersonaView`、:305 渲染；该 View 内使用 `requirePersonas()/PersonaStore`（委派链成立） |
| 10 | 运行时契约（附件/角色/技能芯片） | **PASS** | `ChatRuntimeApi.ets:12` `AttachmentRef`、:105 `send(text, attachments?: AttachmentRef[])`、:129 `toggleSessionSkill`、:78 `personaName`、:80 `skillChips`；ChatPage.ets:206/641/722 附件状态与透传 |
| 11 | `SkillMarkdownCodec` 导出与能力 | **PASS** | `packages/core_plugin/Index.ets` 导出 `SkillMarkdownCodec`/`SkillMarkdownResult`；`toMarkdown`/`toManifestJson`/`newTemplate` 三静态方法齐全；`43` 用例 12 断言验证 4 个内置技能往返 |
| 12 | 视觉一致性 | **PASS** | `SymbolGlyph` **91 处**（≥60）；`app/Theme.ets` 被 **23 个 UI 文件** import（≥15） |
| 13 | 架构行数约束 | **PASS** | `ChatRuntime.ets` 非空 **338 行**（总 405）；`model/runtime/` **15 个文件**均 ≤500：SessionController 413/447、StreamTurnExecutor 401/428、ToolLoopRunner 79/82（最大 413 非空行） |
| 14 | 旧 v2 清理 | **PASS** | 5 个无引用组件已删除（CapabilitySheet/DiffCard/CreatorInputBar/CreatorSessionFactory/SkillDraftText，均 `exists=False`）；`main_pages.json` 仍 **4 页**（ChatPage/SkillCreatorPage/SkillManagerPage/SettingsPage）；`components/` 现存 21 个文件 |

### 13.5 设计稿对照（Pura X Max）

| 设计项 | 落地证据（静态层） |
| --- | --- |
| 展开态 224 会话栏 + 660 画布 + 280 滑出信源栏 | `Layout.sidebarChat=224` / `chatMaxWidth=660` / `sourcePaneWidth=280`；`ChatPage.ets:4` 布局注释、:1477 `SourcePane(...)`、:1691 `unfolded && sourcePaneOpen` 条件渲染 |
| 折叠态单栏 + 左侧抽屉 | `SessionDrawer.ets` 组件存在；`Breakpoint.watch` 实时切换（ChatPage:227）；折叠态单栏路径由 `unfolded` 分支控制 |
| 顶栏 44 + 模型胶囊（6 档短标签）+ 角色胶囊 + 新对话 | `ModelCapsule.ets`、`PersonaSheet.ets` 存在；`snapshot.personaName`/`skillChips` 已接入 ChatRuntimeApi；`EffortLevels.short()` 提供 6 档标签 |
| 用户深色气泡 / AI 通栏 / 思考胶囊+检索 chips | 色板 `bubble_user`/`bubble_user_text` 精确匹配设计稿；`StreamingMessage.ets` + `MarkdownBlock.ets` 提供渲染（观感需真机） |
| 一体胶囊输入 + 附件（相册/文档/链接）+ 本对话技能 chips | `AttachSheet.ets` 组件 + ChatPage 附件状态/透传；`toggleSessionSkill` + `skillChips` 已接线 |
| 记忆条 <60% 完全隐藏 | `MemoryGaugeBar.ets` 存在（隐藏阈值属渲染逻辑，未做静态数值断言，需真机冒烟确认） |
| 设置中心四分类 + 角色与提示词（CRUD/变量/采样/绑定技能） | `SettingsPersonaView.ets` / `SettingsModelsView.ets` / `SettingsMemoryView.ets` / `SettingsDataView.ets` + SettingsPage Master-Detail（216 侧栏） |
| 我的技能 Master-Detail（开关/参数/回滚/试跑/编辑 SKILL.md） | `SkillManagerPage.ets`（232 侧栏）+ `SkillDetailView.ets` + `ConfigForm.ets`；列表过滤 L3 仍由 `90` 断言 |
| 创造室 Master-Detail SKILL.md 编辑器（编辑/预览/试跑/保存/AI 改写） | `SkillCreatorPage.ets` + `CreatorMasterList.ets` + `SkillMdPreview.ets`；`SkillMarkdownCodec` 三方法接入；codec 往返由 `43` 保障 |
| 6 档思考映射（协议层） | `42-thinking-levels` 10 断言：DeepSeek effort、Anthropic budget 且 max_tokens>budget、OpenAI reasoning_effort、topP 三套规则与越界不发送 |

### 13.6 契约 / 回归

| 项 | 证据 |
| --- | --- |
| `packages/core_model` 本轮零改动 | 最新源码 mtime = **2026-11-19 19:54:39**；`Index.ets` SHA256 前 16 位 `9B79C759005CE6CB`（与 §12 一致） |
| `packages/core_context` 本轮零改动 | 最新源码 mtime = **2026-11-19 19:45:16**；`Index.ets` `912FCC44A3EC3F16`（与 §12 一致） |
| `packages/core_protocol` 契约扩展（已登记） | `Index.ets` 未变（`E270A284B5150AF9`）；`interfaces/ProtocolTypes.ets` 11-20 12:01:53 变更为 6 档 `ThinkingLevel` + `topP`（`6C61EB085998F9DA`）；三个 `buildRequest` 11-20 12:04 更新；旧 fixture 已同步为 6 档并新增 `42` 矩阵用例 |
| `packages/core_plugin` 契约扩展（已登记） | `Index.ets` 11-20 12:06:17 变更为 `A125861CFC8C15AF`（追加 `SkillMarkdownCodec`/`SkillMarkdownResult` 导出，原导出保留）；新增纯逻辑 `SkillMarkdown.ets`（12:07:48） |
| `ChatRuntimeApi` 扩展（已登记） | 11-20 11:57:49 变更 `37212962E93337C5`（138 行）：新增 `AttachmentRef`、`send(text, attachments?)`、`toggleSessionSkill`、`skillChips`/`personaName`；`91` 静态断言锁定这些成员 |
| `ChatRuntime` / `runtime/*` 行数约束 | `ChatRuntime.ets` 非空 338 行；`runtime/` 15 文件最大 413 非空行（均 ≤500） |
| 跨轮回归 | 405 条 R1 用例全绿（逻辑层无衰减）；`90` R2 门禁 11/11 通过（颜色基线更新为 38 键） |

### 13.7 未覆盖项与风险

| # | 风险/未覆盖 | 说明 |
| --- | --- | --- |
| 1 | **无真机联调仍成立** | 折叠/展开实时切换与手势、224+660+280 双栏观感、深色模式、信源栏滑出动画、AttachSheet 系统 Picker（相册/文档）、键盘避让、6 档滑条交互、MemoryGaugeBar <60% 隐藏观感均未设备验证 |
| 2 | 真实 Key 链路 | 角色 prompt 生效、AI 改写（创造室）、技能执行、附件上传到模型均需真机 + API Key |
| 3 | unsigned 校验边界 | 仅验证编译与 `build-profile.json5` SHA256 前后一致；未产出可安装签名包（11014003 为环境缺签名材料） |
| 4 | 咨询类 warning 27–30 条 | `RdbRepository`/`SessionExporter` 的 `Function may throw exceptions`；建议真机首启建库/导入 ZIP/FTS5 降级路径观察 |
| 5 | 静态门禁基线 | 38 色键、SymbolGlyph ≥60、Theme import ≥15、侧栏 224/232/216、Breakpoint 600vp 等为设计基线；后续有意调整需同步更新断言 |
| 6 | 记忆条隐藏阈值 | `<60% 且未压缩` 为渲染逻辑，静态断言未覆盖数值分支；写入真机冒烟清单 |
| 7 | 并发构建窗口 | `90` 的签名恢复断言在检测到 `.build.lock` 时显式 skip（避免 unsigned 回退窗口误报）；最终快照无构建持锁，断言实际执行并通过（0 skip） |

**建议真机冒烟清单（v3 重点）**：
1. **折叠/展开**：窗口宽度跨 600vp 来回切换，双栏（224/660/280）与单栏+抽屉即时适配；抽屉开合、遮罩、返回栈。
2. **主对话页**：模型胶囊 6 档切换并确认持久化；角色胶囊切换 +「定制角色与提示词」跳设置 `category=personas`；发送/停止/重试/分支 `<1/3>`/来源胶囊→信源栏；附件（相册/文档/链接）+ chips 发送与展示；本对话技能 chips 激活/未激活/全局停用提示；记忆条 <60% 完全隐藏、点开「立即整理」。
3. **设置中心**：四分类切换 + `category` 直达；角色新建/复制/删除/设默认/保存、`{{date}}`/`{{clipboard}}` 插入、6 档滑条、Temperature/Top-P/轮数、绑定技能；模型测试连接；记忆策略；局域网开关与导出导入。
4. **我的技能**：列表开关、详情 ConfigForm 保存、回滚/试跑/导出/删除、编辑 SKILL.md 跳创造室；L3 不可见。
5. **创造室**：编辑/预览切换、试跑横幅、保存落盘（重启保留）、AI 改写（有 Key 路径 + 无 Key 中文提示）、折叠态二级栈。
6. **深色/浅色**：38 色令牌在深色下观感、用户气泡/AI 通栏对比度。

### 13.8 结论

- **构建**：最终快照（12:24:06–12:25:44）5/5 BUILD-OK；HAP 为 unsigned 编译验证，`build-profile.json5` SHA256 前后一致、签名材料完整。
- **用例**：**28 文件 / 457 断言全绿**（0 失败 / 0 跳过）；R1 405 条回归无衰减。
- **v3 静态门禁**：`91-design-v3-static` **14/14** + `90-refactor-static` **11/11**，覆盖色板/双栏/6 档/角色/附件/SKILL.md/虚列表/契约/行数/清理。
- **缺陷**：本轮**未发现需要修复的缺陷**（Lead 已修复构建期问题）；旧 v2 组件 5 个删除、`main_pages` 4 页均核实。
- **残余**：端到端视觉/交互/性能仍**不可判定**（无真机、无 Key），需按 §13.7 真机冒烟后宣布 v3 设计 DoD 达成。

---

## 14. v3.1 UI 打磨验收（Gemini UI polish 应用后）

> 验收人：`qa-verify`；数据快照：构建 2026-11-20 16:15:04–16:16:08；用例 2026-11-20 16:16:54（Asia/Shanghai）。
> 输入：用户提供的 `dist/ChatAnyWhere_UI_Polished.zip`（**保留原包，未删除**）；Lead 已应用并逐文件对比确认改动面。
> **验证前提不变**：无真机联调（无签名证书 / 无设备 / 无 API Key）；验证 = ArkTS 编译期类型检查 + 纯逻辑单测 + 静态源码断言 + 代码审查。

### 14.1 改动面与断言复核

本轮应用范围 = **8 个文件**（7 改 + 1 新增），实测 mtime 全部为 2026-11-20 06:53:22–06:54:06：

| 文件 | 变化 |
| --- | --- |
| `app/Theme.ets` | 原生舒适字号阶梯、顶栏 48/折叠 44、画布 680、侧栏 232/236/220、信源 288、输入圆角 24、`pressOpacity` |
| `components/IconBtn.ets` | **新增**：`Stack({ alignContent: Alignment.Center })` + `SymbolGlyph` + `stateStyles` 按压（opacity 0.62 + scale 0.94） |
| `components/ModelCapsule.ets` | v3.1 视觉微调 |
| `components/SessionDrawer.ets` | v3.1 视觉微调 + IconBtn 复用 |
| `components/SourcePane.ets` | v3.1 视觉微调 + IconBtn 复用 |
| `components/StreamingMessage.ets` | v3.1 视觉微调 + IconBtn 复用 |
| `pages/ChatPage.ets` | v3.1 布局/尺寸/字号 + IconBtn 复用 |
| `pages/SettingsPage.ets` | v3.1 布局/尺寸/字号 + IconBtn 复用 |

Lead 更新的 `91-design-v3-static.test.mjs` 断言复核结论：
- 侧栏宽度基线 224/232/216 → **232/236/220** 与 `Theme.ets:112–114` 一致；
- 新增「v3.1 打磨」断言与源码一致（IconBtn 结构/tokens 全部命中）；
- QA **增强**了该断言覆盖度（**仅改测试，未改源码**）：IconBtn 复用由 `≥3` 收紧为 **≥5 且逐个校验 5 个目标文件**；token 覆盖由 8 项扩展为**完整字号 7 档 + 行高 3 档 + 全部尺寸/圆角 + `pressOpacity`**；修正测试名称与判定一致。

### 14.2 构建矩阵（unsigned 校验 + 签名配置 SHA256 前后一致）

| 目标 | 结果 | 开始时间 | 日志 | 备注 |
| --- | --- | --- | --- | --- |
| `core_model` | **BUILD-OK** | 16:15:04 | `build-logs/core_model-20261120-161505.log` | 0 error / 27 warning |
| `core_protocol` | **BUILD-OK** | 16:15:21 | `build-logs/core_protocol-20261120-161521.log` | 0 error / 29 warning |
| `core_context` | **BUILD-OK** | 16:15:37 | `build-logs/core_context-20261120-161537.log` | 0 error / 27 warning |
| `core_plugin` | **BUILD-OK** | 16:15:52 | `build-logs/core_plugin-20261120-161552.log` | 0 error / 30 warning |
| `chat`（entry HAP，含全部 HAR） | **BUILD-OK [unsigned verification]** | 16:16:08 | `build-logs/all-20261120-161608-unsigned.log` | 0 error / 27 warning；本机签名材料不可用（`SignHap` / `11014003`）触发临时跳过签名重试，结束后自动恢复 |

| 项 | 构建前 | 构建后 |
| --- | --- | --- |
| `build-profile.json5` SHA256 | `67A102162DC92593B1B016E652031EB08D39E4D289749878C6064649DC34542C` | **同值** |
| 文件大小 | 2452 bytes | 2452 bytes |

Warnings 仍为 `Function may throw exceptions` 咨询类（`RdbRepository`/`SessionExporter`），非错误；跨轮未新增。

### 14.3 用例统计（最终）

| 指标 | 值 |
| --- | --- |
| 运行时间 | **2026-11-20 16:16:54** |
| 用例文件 | **28 个** |
| 断言级用例 | **458 条**（v3 基线 457 + 新增 v3.1 打磨断言 1） |
| 通过 / 失败 / 跳过 | **458 / 0 / 0** |
| 结果 | `RESULT: PASS`（`run.ps1` 退出码 0） |
| prepare 产物 | 拷贝 50 个纯逻辑文件；跳过 5；清单未命中 1；0 告警 |

### 14.4 v3.1 打磨证据（逐项，`91` 15/15 通过）

| # | 检查项 | 结果 | 实测证据 |
| --- | --- | --- | --- |
| 1 | IconBtn 新增与结构 | **PASS** | `components/IconBtn.ets` 54 行；`export struct IconBtn`、`Stack({ alignContent: Alignment.Center })`、`SymbolGlyph`、`stateStyles({pressed, normal})`、`pressOpacity + scale(0.94)` 按压反馈齐全 |
| 2 | IconBtn 复用 | **PASS** | **5 个文件 import + 19 处使用**：ChatPage.ets:35（10 处）、SettingsPage.ets:12（1）、SessionDrawer.ets:7（5）、SourcePane.ets:6（1）、StreamingMessage.ets:7（2） |
| 3 | 原生舒适字号阶梯（7 档） | **PASS** | `fontCaption=11.5`（Theme.ets:94）、`fontSmall=12.5`(:95)、`fontUi=13.5`(:96)、`fontBody=15`(:97)、`fontChat=15.5`(:98)、`fontTitle=16`(:100)、`fontHeadline=17`(:101) |
| 4 | 行高（3 档） | **PASS** | `lineChat=26`(:104)、`lineBody=23`(:105)、`lineTight=20`(:106) |
| 5 | 顶栏 / 画布 / 信源 / 圆角 | **PASS** | `topBarHeight=48`(:108)、`topBarFoldedHeight=44`(:109)、`chatMaxWidth=680`(:111)、`sourcePaneWidth=288`(:115)、`inputRadius=24`(:87)、`radiusPill=999`(:85)、`pressOpacity=0.62`(:124) |
| 6 | 侧栏宽度 v3.1 | **PASS** | `sidebarChat=232`(:112)、`sidebarSkills=236`(:113)、`sidebarSettings=220`(:114)；ChatPage/SkillManagerPage/SettingsPage 均已引用对应令牌 |
| 7 | 颜色资源不变 | **PASS** | `base`/`dark` 各 **38 键**、键集合一致；精确值不变（brand `#2563EB`/`#4F83FF`、bubble_user `#111827`/`#2563EB`、bg_page `#FFFFFF`/`#0E1014`）；v3.1 指纹：base SHA256 前 16 `72C8E5B3B273F13E`、dark `B6863233B6B0E06A` |
| 8 | 无新增硬编码色值 | **PASS** | 扫描 `chat/src/main/ets` **55 个文件**：仅 LanEditorServer 内嵌 HTML 模板 10 个色值（6 行 CSS，模板外 0）；其余 0 |
| 9 | 教学文案仍为 0 | **PASS** | 7 个关键词 × 55 文件 = **0 命中** |
| 10 | 视觉统计 | **PASS** | `SymbolGlyph` **75 处**（≥60）；`app/Theme.ets` 被 **24 个 UI 文件** import（≥15） |
| 11 | v3 功能无回归 | **PASS** | 全部仍绿：Breakpoint 600vp（4 页/5 处）、LazyForEach + cachedCount(6)（无 `ForEach(this.nodes`）、6 档思考（EffortLevels/ThinkingLevel/旧值仅迁移分支）、PersonaStore 链路、SkillMarkdownCodec、AttachmentRef/send(attachments)/toggleSessionSkill/personaName/skillChips |
| 12 | 架构行数 | **PASS** | ChatRuntime 非空 338 行；`runtime/` 15 文件最大 413 非空行（均 ≤500） |

### 14.5 契约 / 回归

| 项 | 证据 |
| --- | --- |
| `packages/*` 本轮零改动 | 源码最新 mtime 仍为 **2026-11-20 12:07:48**（`core_plugin/SkillMarkdown.ets`，上一轮 v3 时间戳）；4 个 HAR 构建均 OK，无契约变更 |
| `ChatRuntimeApi` / `ChatRuntime` 未动 | `ChatRuntimeApi.ets` mtime 11-20 11:57:49；`ChatRuntime.ets` mtime 12:14:13（均早于本轮 06:53 应用窗口之前的上一轮；本轮 8 文件清单不含它们） |
| 入口页未变 | `main_pages.json` 仍 4 页（ChatPage / SkillCreatorPage / SkillManagerPage / SettingsPage） |
| 用户输入包保留 | `dist/ChatAnyWhere_UI_Polished.zip` 未删除、未修改 |

### 14.6 未覆盖项与风险

| # | 风险/未覆盖 | 说明 |
| --- | --- | --- |
| 1 | **无真机联调仍成立** | 折叠手势、深色观感、AttachSheet 系统 Picker、键盘避让、按压微缩动效、680 画布/288 信源栏在真机比例的观感均未设备验证 |
| 2 | 真实 Key 链路 | 角色 prompt 生效、AI 改写、附件上传、技能执行仍未真实联调 |
| 3 | unsigned 校验边界 | 仅验证编译与 `build-profile.json5` SHA256 前后一致；未产出可安装签名包（11014003 环境缺签名材料） |
| 4 | 咨询类 warning 27–30 条 | `RdbRepository`/`SessionExporter` 的 `Function may throw exceptions`；非 v3.1 引入 |
| 5 | 静态门禁基线 | 232/236/220、680/288、字号 7 档、`pressOpacity` 等为 v3.1 基线；后续再打磨需同步更新 `91` 断言 |
| 6 | IconBtn 视觉居中 | 静态断言只能验证 `Stack({alignContent: Alignment.Center})` 结构；图标是否真正居中需真机目测 |

**建议真机冒烟（v3.1 重点）**：
1. 顶栏/抽屉/消息操作栏/输入栏的 IconBtn 图标居中与按压反馈（透明度 + 微缩）是否一致；长按/快速连点无抖动。
2. 字号阶梯在 680 画布下的阅读舒适度；用户深色气泡与 AI 通栏的行高 26 观感；侧栏 232/236/220 与信源 288 的比例。
3. 折叠/展开切换（600vp）时顶栏 48↔44、画布宽度、抽屉与信源栏过渡是否平滑。
4. 输入胶囊圆角 24、聚焦边框、附件 chips 与「本对话技能」chips 排布。
5. 深色模式下 38 色令牌对比度；设置中心与创建室的长列表滚动。

### 14.7 结论

- **构建**：最终快照（16:15:04–16:16:08）5/5 BUILD-OK；HAP 为 unsigned 编译验证，`build-profile.json5` SHA256 前后一致、签名材料完整。
- **用例**：**28 文件 / 458 断言全绿**（0 失败 / 0 跳过）；R1/R2/v3 功能断言无回归。
- **v3.1 打磨**：IconBtn 居中容器（5 文件 / 19 处复用）、原生舒适字号阶梯、顶栏/画布/侧栏/信源/圆角令牌全部落地；颜色资源仍 38 键精确不变、无新增硬编码色、教学文案 0。
- **断言复核**：Lead 更新的 `91` 侧栏基线与 v3.1 源码一致；QA 仅增强测试覆盖度（未改业务源码）。
- **缺陷**：本轮**未发现需要修复的缺陷**。
- **残余**：观感/动效/性能仍需按 §14.6 真机冒烟；无真机前不得宣布 v3.1 视觉 DoD 达成。

---

## 15. v3.2 真机反馈修复验收（注册表/真实模型/记忆透明化）

> 验收人：`qa-verify`；数据快照：构建 2026-11-20 18:02:26–18:03:06；用例 2026-11-20 18:02:23（Asia/Shanghai）。
> 范围（task-21..25）：三项真机反馈修复 —— ①模型/密钥页保存后状态不刷新；②模型列表是内置占位假模型；③记忆整理不透明。
> **验证前提不变**：无真机联调（无设备 / 无 API Key）；验证 = ArkTS 编译期类型检查 + 纯逻辑单测 + v3.2 静态断言 + 代码审查。
> 本轮构建配置按公开仓库要求**已脱敏**：`build-profile.json5` 的 `signingConfigs: []`，本机签名材料移到被 `.gitignore` 忽略的 `build-profile.local.json5`（因此本轮 HAP 构建**不再需要 unsigned 回退**，也没有 `11014003` 签名失败）。

### 15.1 改动面

| 层 | 改动 |
| --- | --- |
| `packages/core_model` | 新增 `provider_models` 表（RdbRepository:105 建表 + :283 执行 + 索引）+ `interfaces/ModelRegistryApi.ets`（4 方法）+ Index 导出 `ProviderModelRecord/ModelRegistryApi` |
| `packages/core_protocol` | `ModelCatalog` 重写为「厂商预设 + RDB 注册表」真实目录（368 行，无任何硬编码模型 id）；新增纯逻辑 `util/RemoteModels.ets`（`parseModelsResponse/modelsUrl/openAiCompatModelsUrl/modelIdsOf`，164 行）并 Index 导出；`ProtocolLayer` 的 `testConnection/listRemoteModels` 增加 `apiKeyOverride` 第二参数 |
| chat·设置页 | 角色一级列表 + 二级编辑（`PersonaAvatars` 10 图标 × 8 配色）；模型页 `VendorCard` 独立 `@Component` + 真实拉取/勾选落库；记忆页记忆卡（当前对话/立即整理/最近整理前后 Token+摘要） |
| chat·运行时/对话页 | `RuntimeSnapshot` 增 `hasModel` + 4 个整理字段（共 5 项扩展）；无模型中文引导；真实模型胶囊/角色头像；`persona.modelId` 空=跟随当前模型 |
| 构建配置 | `build-profile.json5` 脱敏（`signingConfigs: []`）；`build-profile.local.json5` 本机材料 + `.gitignore` 忽略 |

### 15.2 构建矩阵（脱敏构建配置，无 unsigned 回退）

| 目标 | 结果 | 开始时间 | 日志 | 备注 |
| --- | --- | --- | --- | --- |
| `core_model` | **BUILD-OK** | 18:02:26 | `build-logs/core_model-20261120-180226.log` | 0 error / 0 warning |
| `core_protocol` | **BUILD-OK** | 18:02:30 | `build-logs/core_protocol-20261120-180231.log` | 0 error / 0 warning |
| `core_context` | **BUILD-OK** | 18:02:37 | `build-logs/core_context-20261120-180237.log` | 0 error / 30 warning（依赖重编译：RdbRepository 27 + SessionExporter 3） |
| `core_plugin` | **BUILD-OK** | 18:02:50 | `build-logs/core_plugin-20261120-180251.log` | 0 error / 33 warning（+RcpStreamClient 2 + NetHttp 1） |
| `chat`（entry HAP，含全部 HAR） | **BUILD-OK** | 18:03:06 | `build-logs/all-20261120-180307.log` | 0 error / 0 warning（增量复用上轮编译产物） |

| 项 | 构建前 | 构建后 |
| --- | --- | --- |
| `build-profile.json5` SHA256 | `64849EA5196064CE6DA4A4ED7469B3FE20FC0FFCF2F2CEBCCCBFCDD227067BB1` | **同值** |
| 文件大小 | 1621 bytes | 1621 bytes |
| 签名配置 | `signingConfigs: []`（脱敏） | 同（构建不写回） |

说明：所有 warning 仍为 `ArkTS:WARN Function may throw exceptions. Special handling is required.`（平台 API 建议性提示，`RdbRepository`/`SessionExporter`/`RcpStreamClient`/`NetHttp`），本轮未新增 error。

### 15.3 用例统计（最终）

| 指标 | 值 |
| --- | --- |
| 运行时间 | **2026-11-20 18:02:23** |
| 用例文件 | **30 个** |
| 断言级用例 | **475 条** |
| 通过 / 失败 / 跳过 | **475 / 0 / 0** |
| 结果 | `RESULT: PASS`（`run.ps1` 退出码 0） |
| prepare 产物 | 拷贝 51 个纯逻辑文件（新增 `ModelCatalog.ets`/`util/RemoteModels.ets`）；跳过 5；清单未命中 1；0 告警 |

本轮测试基线更新（均为**测试侧**改动，未改业务源码）：
- **重写** `36-model-catalog.test.mjs`（11 用例）：默认空目录/无硬编码模型 id/三厂商预设/`buildProfile`（含 OpenAI 兼容思考推断）/`init` 从 fake 注册表装载 enabled/`applyDiscoveredModels` 保留勾选与去重/`setModelEnabled`/`defaultProfile=null`/`register` 临时覆盖/自定义端点地址跟随设置。
- **新增** `45-remote-models.test.mjs`（12 用例）：`parseModelsResponse` 的 `data[]`/`models[]`/裸数组/`model`/`name` 变体/坏 JSON→[]/去重/displayName 回退；`modelsUrl` 三家端点与 `/v1` 去重。
- **更新** `90`（色键 38→**46**、interfaces 19→**20**、签名断言改为「已脱敏：无绝对路径/明文口令 + local 备份被 gitignore」）、`91`（色键 46）。
- **新增** `92-design-v32-static.test.mjs`（11 用例）：三项 Bug 根因与契约落盘（见 §15.4）。

### 15.4 三项 Bug 根因修复证据（`92` 11/11 通过）

| Bug | 根因 | 修复证据（静态可验证） |
| --- | --- | --- |
| ① 模型/密钥页保存后状态**不刷新** | 按值传参的 `@Builder vendorCard(...)`，父状态更新不会重建已按值捕获的 UI | 新增独立 `components/VendorCard.ets`（197 行，`@Component` + `@Prop` 接收 configured/url/testing/pulling 等状态）；`SettingsModelsView.ets:416/438/461` 三处渲染 `VendorCard({...})`；全文件**无** `@Builder vendorCard(` |
| ② 模型列表是**内置占位假模型** | `ModelCatalog` 硬编码 5 个模型；无真实探测与注册表 | `ModelCatalog.ets` 368 行重写：**0 个** `deepseek-flash/deepseek-v4-pro/claude-sonnet/claude-opus/gpt-4.1-mini`；保留三厂商预设（providerId/协议/地址/缓存经济性/能力）；实现 `init/hasModels/defaultProfile(null)/providerMeta/buildProfile/applyDiscoveredModels/setModelEnabled`；真实端点 `util/RemoteModels.ets`（DeepSeek `/models`、Anthropic `/v1/models`、OpenAI 兼容含 `/v1` 去重）；`ProtocolLayer` 探测支持未保存新 Key（`apiKeyOverride`）；设置页 `testConnection`(:266)/`listRemoteModels`(:287)/`applyDiscoveredModels`(:292) 闭环；`RdbRepository` 建 `provider_models` 表（:105）并实现 4 个注册表方法（:1190/:1269/:1293/:1330）；`core_model.Index` 导出 `ProviderModelRecord/ModelRegistryApi` |
| ③ 记忆整理**不透明** | 快照无整理指标、设置页看不到前后变化 | `ChatRuntimeApi.RuntimeSnapshot` 增 5 字段（`:90 hasModel`、`:92/:94/:96/:98 lastCompactionAt/BeforeTokens/AfterTokens/Summary`）；`SettingsMemoryView.ets:22` 状态、`:65–68` 从快照同步、`:92` `compactNow()`、`:98` 调 `getChatRuntime().compactNow()`；记忆卡展示当前对话/立即整理/上次整理前后 Token 与摘要 |

附带修复（同轮）：
- **角色二级列表 + 头像**：`PersonaProfile.avatarIcon/avatarTone`（PersonaStore:29/31），`sanitize` 对旧数据回退默认 `persona`/`blue`（PersonaStore:330+）；`PersonaAvatars.ets` **10 个 ICONS**（:27–38）+ **8 个 TONES**（:40–49）+ `iconOf/toneOf`（:52/:62）；`SettingsPersonaView` 引用 `PersonaAvatars` + `selectedId` 列表↔详情（`openDetail`/`backToList`）。
- **无模型引导**：`ChatPage.ets:722/1342` 用 `snapshot.hasModel` 显示中文引导；`:569` 跳转 `SettingsPageParams { category: 'models' }`。
- **角色空 modelId=跟随当前模型**：`PersonaSheet.ets:29`、`SettingsPersonaView.ets:19`、`SettingsController.ets:149` 三处语义一致。

### 15.5 静态断言总览

| 文件 | 结果 | 覆盖 |
| --- | --- | --- |
| `92-design-v32-static` | **11/11 PASS** | v3.2 三项 Bug 根因、注册表/provider_models、RemoteModels 导出、头像 10×8、46 色键、脱敏构建配置 |
| `90-refactor-static` | **11/11 PASS** | 46 色键/8 avatar_bg_*、interfaces 20、脱敏签名断言、入口/L3/虚列表/契约/行数等 R2 基线 |
| `91-design-v3-static` | **15/15 PASS** | v3/v3.1 设计基线（双栏/6 档/角色/附件/SKILL.md/IconBtn/25 项令牌）同步 46 色键 |
| 合计 | **37/37 PASS** | — |

### 15.6 契约 / 回归

| 项 | 证据 |
| --- | --- |
| `core_model` 本轮新增能力（已登记） | `Index.ets` 17:38:13 变更 `EFB010538B6C3B28`（+`ProviderModelRecord/ModelRegistryApi`）；新增 `interfaces/ModelRegistryApi.ets` `09010EEEE00B5DEB`（33 行，4 方法）；`RdbRepository.ets` 17:42:06 增 `provider_models` 表与注册表方法 |
| `core_protocol` 本轮新增能力（已登记） | `Index.ets` 17:43:55 变更 `24239D429861F111`（+RemoteModels 4 个导出）；`ModelCatalog.ets` 17:48:47 `2EB28E2AE9C243E4`（368 行，去占位重写）；新增 `util/RemoteModels.ets` `B6FF6107D3B9731A`（164 行） |
| `ChatRuntimeApi` 扩展（已登记） | 17:38:13 `BBEC5EB0320C5919`（148 行）：新增 `hasModel` + 4 个整理字段（5 字段扩展），方法签名未破坏 |
| 未改动 | `core_context` 源码最新 mtime 仍 2026-11-19 19:45:16；`main_pages.json` 仍 **4 页** |
| 行数约束 | `ChatRuntime.ets` 非空 **338** 行；`SessionController` 409、`StreamTurnExecutor` 401（`runtime/*` 全部 ≤500） |
| 跨轮回归 | R1/R2/v3/v3.1 全部用例保持绿（475/475），v3.1 打磨断言（IconBtn/字号/侧栏 232/236/220）无回归 |

### 15.7 未覆盖项与风险

| # | 风险/未覆盖 | 说明 |
| --- | --- | --- |
| 1 | **无真机联调仍成立** | 保存密钥后的即时状态刷新（VendorCard `@Prop` 重渲染）、测试连接网络往返、真实 `/models` 拉取/勾选/顶栏出现、记忆卡数值观感、折叠手势/深色/Picker/键盘避让均未设备验证 |
| 2 | **无 API Key** | 三家真实 `/models` 响应（DeepSeek/Anthropic/OpenAI 兼容）只用官方同形合成 fixture 验证解析；真实鉴权失败/限流/空列表路径未联网 |
| 3 | 真实端点差异 | Anthropic `x-api-key` + `anthropic-version` 头、OpenAI 兼容中转站 `display_name` 变体等按文档实现，需真机联调确认 |
| 4 | RDB 注册表 | `provider_models` 建表/事务/迁移只在编译期验证，设备端「重启后模型列表仍在」需真机验收 |
| 5 | 咨询类 warning | 模块重编译出现 30/33 条 `Function may throw exceptions`（RdbRepository/SessionExporter/RcpStreamClient/NetHttp），0 error；非 v3.2 新增 |
| 6 | 构建配置脱敏 | 本轮 HAP 为纯 `BUILD-OK`（无 unsigned 回退）；**未产出可安装签名包**，如本机要安装需用 `build-profile.local.json5` 临时替换 |
| 7 | 静态门禁基线 | 46 色键/20 interfaces/10×8 头像/固定文案等用于防回退，后续有意调整需同步更新断言 |

**建议真机冒烟清单（v3.2 重点）**：
1. **模型链路**：设置→模型与密钥 → 输入新 Key（未保存）→「测试连接」即时出结果 → 「拉取模型」出真实清单 → 勾选 1-2 个 → 保存 → **状态立即刷新为「已加密保存/已启用」**（不重启）→ 返回对话页顶栏出现真实模型胶囊 → 角色编辑里可选该模型。
2. **无模型引导**：清空/新装（无模型）→ 对话页出现中文引导 → 点击直达设置 `category=models` → 拉取并勾选后引导消失。
3. **记忆透明化**：设置→记忆与缓存 → 当前对话卡显示 Token/占用 → 点「立即整理」→ 显示「正在生成检查点摘要…」→ 完成后最近整理卡显示前后 Token 与摘要摘要 → 返回对话页记忆条数值一致。
4. **角色**：设置→角色与提示词 → 一级列表（头像 40×40/默认标识/绑定模型/搜索/新建）→ 进二级编辑换头像（10 图标×8 配色）→ 保存 → 列表头像即时更新；角色绑定模型为空时对话框显示「跟随当前模型」。
5. **回归**：折叠/展开、6 档思考、附件、SKILL.md 编辑、技能开关等 v3/v3.1 功能无回归。

### 15.8 结论

- **构建**：最终快照（18:02:26–18:03:06）5/5 BUILD-OK，0 error；构建配置已脱敏（`signingConfigs: []`），`build-profile.json5` SHA256 前后一致（`64849EA5…067BB1`），本机签名材料仅存于 gitignore 的 `build-profile.local.json5`。
- **用例**：**30 文件 / 475 断言全绿**（0 失败 / 0 跳过）；prepare 51 拷贝/0 告警；新增 v3.2 目录/探测/静态用例 23 条。
- **三项 Bug 根因修复**均在静态与单测层得到证据：@Builder 按值传参已消除（独立 VendorCard）、占位模型已清零（真实探测 + RDB 注册表）、记忆透明化 5 指标 + UI 卡已接线。
- **契约**：core_model/core_protocol 为新增能力且已登记；`main_pages` 4 页；行数约束保持。
- **缺陷**：本轮**未发现需要修复的缺陷**。
- **残余**：真实网络/真机链路（Key 保存刷新、测试连接、真实 /models、RDB 重启保持、观感）仍需按 §15.7 冒烟；无真机前不得宣布 v3.2 真机反馈闭环达成。

---

## 16. v3.3 交互与动效升级验收（抽屉关闭 / 四态模型胶囊 / 6 档特效面板）

> 验收人：`qa-verify`；数据快照：构建 2026-11-23 10:46:10–10:47:0x；用例 2026-11-23 10:46:07（Asia/Shanghai）。
> 范围（task-27/28）：① 折叠抽屉「点右空白/左滑」关闭；② 模型添加四态胶囊（idle/loading/success/error）；③ 6 档思考特效面板 + 振动兜底。
> **验证前提不变**：无真机联调（无设备 / 无 API Key）；验证 = ArkTS 编译期类型检查 + 纯逻辑单测 + v3.3 静态断言 + 代码审查。
> 构建配置为**两态**：工作区保留本机签名（`skip-worktree` 隐藏、不会提交），仓库 HEAD 版本已脱敏（`signingConfigs: []`）。

### 16.1 改动面（git 工作区）

v3.3 应用范围 = 8 个已跟踪文件修改 + 2 个新增组件（`git status` 实测；README/DEV_GUIDE 为同轮文档改动）：

| 文件 | 变化 |
| --- | --- |
| `pages/ChatPage.ets` | 折叠抽屉：装饰 `Blank()` → 右空白可点关闭容器；`drawerDragX + translate` 跟手；`PanGesture(PanDirection.Left, distance: 8)`，`offsetX < -48` 关闭 |
| `components/ModelProbeChip.ets`（新增，139 行） | 四态模型添加胶囊（idle/loading/success/error） |
| `components/VendorCard.ets` | chips 区渲染 `ModelProbeChip` |
| `components/SettingsModelsView.ets` | `modelStatuses: ModelAddStatus[]` 整体替换 + `setModelEnabled` 成功/失败流转 + enabled 回显 success |
| `components/ReasoningEffortPanel.ets`（新增，304 行） | 6 档面板：三层品牌色叠层、sparkles/thinking 徽章 + 同心 Circle 光环、档位字弹跳、振动 try/catch + 去抖 |
| `components/ModelCapsule.ets` | 接入 `ReasoningEffortPanel`，内联 Slider 清零 |
| `resources/{base,dark}/element/color.json` | 各 **48 键**（新增 violet `#7C3AED/#8B5CF6`、pink `#EC4899/#F472B6`） |
| `module.json5` | 新增 `ohos.permission.VIBRATE` |
| `app/Theme.ets` | 新增 `violet/pink` 令牌 |

### 16.2 构建矩阵（本机签名态触发 unsigned 回退；仓库态脱敏）

| 目标 | 结果 | 开始时间 | 日志 | 备注 |
| --- | --- | --- | --- | --- |
| `core_model` | **BUILD-OK** | 10:46:10 | `build-logs/core_model-20261123-104611.log` | 0 error / 30 warning |
| `core_protocol` | **BUILD-OK** | 10:46:24 | `build-logs/core_protocol-20261123-104624.log` | 0 error / 32 warning |
| `core_context` | **BUILD-OK** | 10:46:36 | `build-logs/core_context-20261123-104636.log` | 0 error / 30 warning |
| `core_plugin` | **BUILD-OK** | 10:46:47 | `build-logs/core_plugin-20261123-104648.log` | 0 error / 33 warning |
| `chat`（entry HAP，含全部 HAR） | **BUILD-OK [unsigned verification]** | 10:47:01 | `build-logs/all-20261123-104701-unsigned.log` | 0 error / 30 warning；工作区本机签名在 CLI 下报 `11014003` → 脚本临时跳过签名重试并自动恢复 |

| 构建配置两态 | 证据 |
| --- | --- |
| 工作区（本机签名） | `build-profile.json5` SHA256 构建前 = 构建后 = `0259B43A…35C665`（2448B）；`git update-index --skip-worktree` 隐藏，不会提交 |
| 仓库 HEAD（公开脱敏） | `git show HEAD:build-profile.json5` SHA256 前 16 = `781A762B56A7A391`；`signingConfigs: []`、无 `certpath/keyPassword/storePassword/C:\Users`、product 保留 `"signingConfig": "default"` |
| 本机材料备份 | `build-profile.local.json5` 存在且被 `.gitignore` 忽略 |

说明：模块重编译出现的 30/32/30/33 条 warning 均为 `ArkTS:WARN Function may throw exceptions.`（RdbRepository/SessionExporter/RcpStreamClient/NetHttp 等平台 API 建议提示），0 error；非 v3.3 引入。

### 16.3 用例统计（最终）

| 指标 | 值 |
| --- | --- |
| 运行时间 | **2026-11-23 10:46:07** |
| 用例文件 | **31 个** |
| 断言级用例 | **481 条** |
| 通过 / 失败 / 跳过 | **481 / 0 / 0** |
| 结果 | `RESULT: PASS`（`run.ps1` 退出码 0） |
| prepare 产物 | 拷贝 51 个纯逻辑文件；跳过 5；清单未命中 1；0 告警 |

基线更新（仅测试侧）：`90/91/92` 色键 **46 → 48**（并断言 violet/pink 精确值）；`92` 的「构建配置脱敏」改为**读取 `git show HEAD:build-profile.json5`**（工作区可能是本机签名态），断言仓库版本 `signingConfigs=[]` 且无敏感字段，同时断言 `build-profile.local.json5` 存在且被 gitignore；**新增 `93-design-v33-static.test.mjs`**（6 条 v3.3 断言）。

### 16.4 三项改动证据（`93` 6/6 通过）

| 项 | 证据（文件:行/数量） |
| --- | --- |
| ① 抽屉关闭三入口 | `ChatPage.ets:1772–1818` 抽屉区块：scrim `onClick → drawerOpen=false`（:1779）、抽屉 `translate({ x: this.drawerDragX })`（:1789）、`PanGesture({ direction: PanDirection.Left, distance: 8 })`（:1791）、`const shouldClose = e.offsetX < -48`（:1795）、右空白 `Column().layoutWeight(1).height('100%').onClick(...)`（:1809–1812）；区块内**无装饰 `Blank()`**，关闭入口 **3 处** |
| ② 四态模型胶囊 | `ModelProbeChip.ets` 139 行：`@Prop status`（:26）；`idleChip`(:36)/`loadingChip`(:57, `LoadingProgress`:59)/`successChip`(:74, `Icons.check`:76, `successSubtle`:87)/`errorChip`(:92, `Icons.retry`:95, `dangerSubtle`:106)；switch 分派 :127–134；`VendorCard.ets:9` import + `:192` 渲染；`SettingsModelsView.ets:48` `modelStatuses`、`:332` `setStatusFor`、`:315` enabled→success 回显、添加流程 :351–380（idle/error→loading→success，失败回 error 可重试，调用 `catalog.setModelEnabled`） |
| ③ 6 档特效面板 | `ReasoningEffortPanel.ets` 304 行：`vibrator` import(:13)、`private vibrate()`(:148)、`try {`(:153)/`catch`(:160)、`vibrator.startVibration`(:157)（去抖 `lastVibrated` + 不 await）；三层叠层渐变 `backgroundColor(Theme.brand)`(:240)/`Theme.violet`(:246)/`Theme.pink`(:252)（opacity 随档位过渡）；同心 `Circle` 光环(:184/:188)；`Icons.thinking → Icons.sparkles`(:192)；`ModelCapsule.ets:10` import + `:134` 使用；`ModelCapsule` 内**无 `Slider(`**（内联滑块已移入面板） |
| Lead 基建 | `color.json` base/dark 各 **48 键**（v3.3 指纹：base `7752411019C6C472`、dark `F622FCE70588D9FE`），violet `#7C3AED/#8B5CF6`、pink `#EC4899/#F472B6`；`module.json5:21` 含 `ohos.permission.VIBRATE`；`Theme.ets:39/40` 暴露 violet/pink |
| 纪律扫描 | 新增两个组件 **0 个 `#RRGGBB` 硬编码**、**0 个教学文案关键词**；全仓扫描（`90/91`）同步覆盖 48 色键与新增组件 |

### 16.5 静态断言总览

| 文件 | 结果 | 覆盖 |
| --- | --- | --- |
| `93-design-v33-static` | **6/6 PASS** | 抽屉三入口/左滑 -48、四态胶囊、6 档面板振动兜底、48 色键 + VIBRATE + Theme、新增组件纪律 |
| `92-design-v32-static` | **11/11 PASS** | v3.2 三项 Bug 根因 + 头像 10×8 + 48 色键 + git HEAD 脱敏断言 |
| `91-design-v3-static` | **15/15 PASS** | v3/v3.1 设计基线 + 46→48 色键（含 violet/pink 精确值） |
| `90-refactor-static` | **11/11 PASS** | 48 色键/20 interfaces/git HEAD 脱敏/入口/L3/虚列表/契约/行数 |
| 合计 | **43/43 PASS** | — |

### 16.6 契约 / 回归

| 项 | 证据 |
| --- | --- |
| `packages/*` 本轮零改动 | 最新源码 mtime 与 v3.2 一致：core_model 11-20 17:42:06、core_protocol 11-20 17:48:47、core_plugin 11-20 17:41:45、core_context 11-19 19:45:16 |
| `ChatRuntimeApi` / `ChatRuntime` 未动 | 与 v3.2 一致（本轮 git 改动不含 model/） |
| 入口 | `main_pages.json` 仍 4 页 |
| 行数约束 | `ChatRuntime.ets` 非空 338 行；`SessionController` 409、`StreamTurnExecutor` 401（`runtime/*` 全部 ≤500） |
| 跨轮回归 | R1/R2/v3/v3.1/v3.2 全部用例保持绿（481/481）；v3.2 模型目录/探测/注册表断言无回归 |
| 构建配置两态 | 工作区本机签名（`0259B43A…`，skip-worktree 隐藏）；仓库 HEAD 脱敏（`781A762B…`，`signingConfigs: []`）；本机备份 `build-profile.local.json5` 被 gitignore |

### 16.7 未覆盖项与风险

| # | 风险/未覆盖 | 说明 |
| --- | --- | --- |
| 1 | **无真机联调仍成立** | 抽屉左滑跟手/阀值手感、点击右空白关闭、振动马达触感（VIBRATE 权限实际授权）、渐变/光环呼吸观感、档位字弹跳、loading 转圈均未设备验证 |
| 2 | **无 API Key** | 四态胶囊的真实添加链路（真实 `/models` → 勾选 → `setModelEnabled` 成功/失败）未联调 |
| 3 | 构建配置两态 | 工作区本机签名在 CLI 下仍报 `11014003`（走 unsigned 回退）；仓库版本已脱敏，但**未产出可安装签名包** |
| 4 | 振动兼容性 | `vibrator.startVibration` 已 try/catch + `.catch()` 兜底；无马达/无权限设备上的静默表现需真机确认 |
| 5 | 咨询类 warning | 模块重编译 30–33 条 `Function may throw exceptions`（平台 API 建议提示），0 error |
| 6 | 静态门禁基线 | 48 色键/20 interfaces/阈值 -48/四态文案等为当前基线，后续再调交互需同步更新断言 |
| 7 | git 工作区两态 | `build-profile.json5` 被 skip-worktree 隐藏，`git status` 不显示其本机修改；CI 上需确保使用仓库脱敏版本 |

**建议真机冒烟清单（v3.3 重点）**：
1. **抽屉**：折叠态打开抽屉 → 手指在抽屉面板上向左慢滑（跟手位移、松手回弹）→ 滑过约 1/6 宽度松手自动关闭；在右侧空白区点一下立即关闭；遮罩点击关闭；关闭动画 120Hz 平滑无跳变。
2. **四态模型**：设置→模型与密钥 → 拉取模型后逐个「+ 模型名」：点击后进入 loading（转圈、防连点）→ 成功变绿勾（success）→ 再点不重复添加；断网/错误 Key 时变红「重新添加」+ 失败原因，点击可重试；已启用模型进页面回显 success。
3. **6 档面板**：打开模型胶囊 → 思考强度面板：拖动滑条 6 档字弹跳、背景品牌蓝/紫/粉随档位渐变、光环呼吸；每档切换有轻振动（无马达/无权限静默不崩）；关闭面板后胶囊短标签同步。
4. **回归**：折叠/展开、模型胶囊 6 档、角色头像、附件、记忆卡、SKILL.md 编辑等 v3/v3.1/v3.2 功能无回归。

### 16.8 结论

- **构建**：最终快照（10:46:10–10:47:0x）5/5 BUILD-OK，0 error；工作区本机签名触发 unsigned 回退且恢复无损（工作区 SHA256 前后一致 `0259B43A…`），仓库 HEAD 已脱敏（`signingConfigs: []`）。
- **用例**：**31 文件 / 481 断言全绿**（0 失败 / 0 跳过）；prepare 51 拷贝/0 告警。
- **v3.3 三项改动**静态证据齐全：抽屉三入口 + 左滑 -48 阈值、ModelProbeChip 四态 + 模型页状态机、ReasoningEffortPanel 叠层/光环/振动兜底 + ModelCapsule 接入且内联 Slider 清零；基础设施（48 色键/VIBRATE/Theme 令牌）全部落地。
- **契约**：packages 与 ChatRuntimeApi/​ChatRuntime 本轮零改动；main_pages 4 页；行数约束保持。
- **缺陷**：本轮**未发现需要修复的缺陷**。
- **残余**：真机交互/振动/动效观感与真实模型添加链路仍需按 §16.7 冒烟；无真机前不得宣布 v3.3 交互 DoD 达成。

---

## 17. v3.4 交互修复验收（抽屉退场动画 / 取消模型 / 能量槽面板）

> 验收人：`qa-verify`；数据快照：构建 2026-11-23 11:07:36–11:08:27；用例 2026-11-23 11:07:26（Asia/Shanghai）。
> 范围（task-30/31）：① 抽屉退场动画（状态变化收口 `setDrawerOpen` + animateTo + 子节点 transition）；② 模型胶囊「取消添加」双向链路；③ 6 档思考面板删除 Slider → 手写能量槽。
> **验证前提不变**：无真机联调（无设备 / 无 API Key）；验证 = ArkTS 编译期类型检查 + 纯逻辑单测 + v3.4 静态断言 + 代码审查。
> 构建配置两态：工作区保留本机签名（`skip-worktree` 隐藏），仓库 HEAD 已脱敏（`signingConfigs: []`）。

### 17.1 改动面（git 工作区）

v3.4 应用范围 = 8 个已跟踪文件（6 chat + 2 core_protocol）+ README 文档：

| 文件 | 变化 |
| --- | --- |
| `pages/ChatPage.ets` | 新增 `setDrawerOpen(open)`：`drawerDragX=0` + `getUIContext().animateTo({ duration: 220, curve: EaseOut })`；**9 处** drawerOpen 赋值全部收口；抽屉 if 块重构为两个直接子节点（scrim OPACITY 220ms / 抽屉层 move(START) 220ms） |
| `components/ModelProbeChip.ets` | success 恢复可点击（点击=取消）；loading 保持不可点击（防连点）；idle/error 仍可点击添加/重试 |
| `components/SettingsModelsView.ets` | 新增 `toggleModel()` 双向：success→loading→`catalog.unregister`→`load()`→idle；取消活跃模型自动切换/`clearActiveProfile`；失败保持 success + `toggleError` |
| `components/VendorCard.ets` | 新增 `notice` 透传（danger 小字错误提示） |
| `components/ReasoningEffortPanel.ets` | 重做 460 行：自然高度 + 底部安全区、`bgSurface` 卡片 + 顶部柔光、右上 6 格能量柱、删除 Slider → `onAreaChange + onTouch` 吸附能量槽 + 渐变填充 + 白边发光圆钮 |
| `app/AppServices.ets` | 新增 `async clearActiveProfile()` |
| `packages/core_protocol/interfaces/ProtocolLayer.ets` | `ModelCatalogApi` 新增 `unregister(providerId, modelId)` |
| `packages/core_protocol/ModelCatalog.ets` | 实现 `unregister`（关闭 enabled + reload，RDB 记录保留） |

### 17.2 构建矩阵（工作区本机签名态触发 unsigned 回退；仓库态脱敏）

| 目标 | 结果 | 开始时间 | 日志 | 备注 |
| --- | --- | --- | --- | --- |
| `core_model` | **BUILD-OK** | 11:07:36 | `build-logs/core_model-20261123-110737.log` | 0 error / 30 warning |
| `core_protocol` | **BUILD-OK** | 11:07:49 | `build-logs/core_protocol-20261123-110749.log` | 0 error / 32 warning |
| `core_context` | **BUILD-OK** | 11:08:02 | `build-logs/core_context-20261123-110802.log` | 0 error / 30 warning |
| `core_plugin` | **BUILD-OK** | 11:08:13 | `build-logs/core_plugin-20261123-110813.log` | 0 error / 33 warning |
| `chat`（entry HAP，含全部 HAR） | **BUILD-OK [unsigned verification]** | 11:08:26 | `build-logs/all-20261123-110827-unsigned.log` | 0 error / 30 warning；工作区本机签名报 `11014003` → 脚本临时跳过签名重试并自动恢复 |

| 构建配置两态 | 证据 |
| --- | --- |
| 工作区（本机签名） | `build-profile.json5` SHA256 构建前 = 后 = `0259B43A…35C665`（2448B）；`skip-worktree` 隐藏，不提交 |
| 仓库 HEAD（公开脱敏） | `git show HEAD:build-profile.json5`：`signingConfigs: []`、无 certpath/keyPassword/storePassword/用户路径、product 保留 `"signingConfig": "default"` |
| 本机材料备份 | `build-profile.local.json5` 存在且被 `.gitignore` 忽略 |

warnings 仍为 `ArkTS:WARN Function may throw exceptions.`（平台 API 建议提示，RdbRepository/SessionExporter/RcpStreamClient/NetHttp），0 error。

### 17.3 用例统计（最终）

| 指标 | 值 |
| --- | --- |
| 运行时间 | **2026-11-23 11:07:26** |
| 用例文件 | **32 个** |
| 断言级用例 | **487 条** |
| 通过 / 失败 / 跳过 | **487 / 0 / 0** |
| 结果 | `RESULT: PASS`（`run.ps1` 退出码 0） |
| prepare 产物 | 拷贝 51 个纯逻辑文件；跳过 5；未命中 1；0 告警 |

基线更新（仅测试侧）：`93-design-v33-static` 的抽屉断言由旧字面量 `this.drawerOpen = false` 改为 v3.4 口径（`setDrawerOpen(` / `animateTo(duration:220)` / `TransitionEffect.OPACITY` / `TransitionEffect.move(TransitionEdge.START)` / `layoutWeight(1)` / `-48` / 无装饰 `Blank()`，并断言 drawerOpen 直接赋值仅 1 处、setDrawerOpen 调用 ≥9 处）；**新增 `94-design-v34-static.test.mjs`**（6 条）。

### 17.4 三项修复证据（`94` 6/6 + 更新后的 `93` 6/6 通过）

| 项 | 证据（文件:行/数量） |
| --- | --- |
| ① 抽屉退场动画 | `ChatPage.ets:502` `private setDrawerOpen(open)`：`:503 drawerDragX = 0`、`:504 getUIContext().animateTo({ duration: 220, curve: EaseOut })`；`drawerOpen` 直接赋值全文件仅 **1 处**、`this.setDrawerOpen(` 调用 **9 处**；抽屉块 `:1784` 起：scrim `.transition(TransitionEffect.OPACITY.animation({duration:220}))`(:1791) + 点击关闭、抽屉层 `.transition(TransitionEffect.move(TransitionEdge.START).animation({duration:220}))`(:1813) + `translate(drawerDragX)` + 右空白 `layoutWeight(1)` 点击关闭 + `PanGesture(PanDirection.Left)` `offsetX < -48`(:1819)；区块内无装饰 `Blank()` |
| ② 取消模型 | `ModelProbeChip.ets`：idle `.onClick`(:51)、**success `.onClick`(:89，取消)**、error `.onClick`(:123，重试)；loadingChip(:57) 无 onClick（防连点）；`SettingsModelsView.ets:321` `toggleModel()`、`:372 catalog.unregister(providerId, modelId)`、`:400 services.clearActiveProfile()`、`:45 toggleError` + `:385/:407` 失败提示、`:456` 透传 `notice`；`VendorCard.ets:25 @Prop notice` + `:208` 渲染 |
| ③ 能量槽面板 | `ReasoningEffortPanel.ets` 实际 **460 行**（Lead 述 427，按实测记录）：**无 `Slider(`**、无 `height('100%')`（自然高度 + 底部安全区）、0 硬编码色值；`:325 energyBars()` 复用 `ForEach(EffortLevels.ALL)`（6 格阶梯柱）；`:369 energyTrough()` 手写能量槽：`:399 onAreaChange` 记宽度 + `:405 onTouch` 吸附 + `:383 linearGradient` 渐变填充 + `:386/:391 Circle` 光晕/白边圆钮；`:316/:451 bgSurface` + `:436 linearGradient` 顶部柔光；保留 `:301/:305 Circle` 徽章呼吸、`vibrator.startVibration`(:246) + try/catch 兜底 |
| 契约 | `ProtocolLayer.ets:70 unregister(providerId, modelId)`；`ModelCatalog.ets:247 async unregister(...)`（关闭 enabled + reload，RDB 记录保留）；`AppServices.ets:265 async clearActiveProfile()`；颜色仍 **48 键** base/dark 一致（未新增色键） |

### 17.5 静态断言总览

| 文件 | 结果 | 覆盖 |
| --- | --- | --- |
| `94-design-v34-static` | **6/6 PASS** | v3.4 三项修复（退场动画结构/能量槽无 Slider/取消链路/契约/色彩与文案纪律） |
| `93-design-v33-static` | **6/6 PASS** | v3.3 基线（已更新 setDrawerOpen 口径）+ 四态胶囊 + 48 色键 |
| `92-design-v32-static` | **11/11 PASS** | v3.2 三项 Bug 根因 + 头像 + 48 色键 + git HEAD 脱敏 |
| `91-design-v3-static` | **15/15 PASS** | v3/v3.1 设计基线 + 48 色键（violet/pink 精确值） |
| `90-refactor-static` | **11/11 PASS** | 48 色键/20 interfaces/git HEAD 脱敏/入口/L3/虚列表/行数 |
| 合计 | **49/49 PASS** | — |

### 17.6 契约 / 回归

| 项 | 证据 |
| --- | --- |
| `core_protocol` 本轮新增能力（已登记） | `interfaces/ProtocolLayer.ets` 11-23 10:57:44 `4DC5DBB890EDF04C`（+`ModelCatalogApi.unregister`）；`ModelCatalog.ets` 10:57:44 `ECA401B97B364679`（+`unregister` 实现，关闭 enabled + reload）；`Index.ets` 未变（`24239D429861F111`） |
| `AppServices` 扩展（已登记） | 11-23 10:57:44 `43830F17FE96959E`（+`clearActiveProfile`） |
| 未改动 | `ChatRuntimeApi.ets` 仍 `BBEC5EB0320C5919`（11-20 17:38:13，v3.4 未动）；`core_model` 最新 mtime 11-20 17:42:06、`core_context` 11-19 19:45:16、`core_plugin` 11-20 17:41:45（均未动）；`main_pages.json` 仍 4 页 |
| 行数约束 | `ChatRuntime.ets` 非空 338；`SessionController` 409、`StreamTurnExecutor` 401（`runtime/*` 全部 ≤500）；面板 460 行（UI 组件无 500 限制） |
| 跨轮回归 | R1→v3.3 全部用例保持绿（487/487）；v3.3 抽屉/四态/面板断言按 v3.4 口径更新后仍绿 |

### 17.7 未覆盖项与风险

| # | 风险/未覆盖 | 说明 |
| --- | --- | --- |
| 1 | **无真机联调仍成立** | 抽屉退场动画流畅度（220ms opacity+move）、左滑跟手回弹、三入口关闭手感、能量槽拖动手感（吸附/白边圆钮发光/6 格柱点亮）、档位字弹跳与振动、loading 转圈观感均未设备验证 |
| 2 | **无 API Key** | 取消添加真实链路（成功取消 → RDB 保留记录 → 列表回 idle；取消活跃模型 → 自动切换/清空）未联网验证 |
| 3 | 构建配置两态 | 工作区本机签名在 CLI 下仍报 `11014003`（走 unsigned 回退）；仓库 HEAD 已脱敏但**未产出可安装签名包** |
| 4 | 面板实现与 Lead 描述 | 实际 **460 行**（Lead 述 427），功能断言全部命中；仅作行数记录，不影响判定 |
| 5 | 振动兼容性 | `vibrator.startVibration` + `.catch()` + try/catch 双层兜底；无马达/无权限设备静默表现需真机确认 |
| 6 | 咨询类 warning | 模块重编译 30–33 条 `Function may throw exceptions`（平台 API 建议提示），0 error |
| 7 | 静态门禁基线 | 抽屉 220ms/阈值 -48、能量槽 6 格/圆钮、48 色键等为当前基线，后续调交互需同步更新断言 |

**建议真机冒烟清单（v3.4 重点）**：
1. **抽屉退场**：折叠态打开抽屉 → 点右空白/遮罩/左滑过 48vp 三种方式关闭，退场 220ms 淡出+左移平滑无跳变；左滑中途松手回弹跟手；快速连点开/关无残影。
2. **取消模型**：设置→模型与密钥 → 已添加模型点胶囊取消：变 loading（防连点）→ 成功回 idle；取消当前活跃模型后自动切到剩余第一个（顶栏胶囊同步），无剩余模型时顶栏出现无模型引导；断网/错误 Key 时取消失败保持 success + 红色小字原因（VendorCard notice）。
3. **能量槽**：打开模型胶囊 → 思考强度面板：拖动手写能量槽逐格吸附 0–5、渐变填充与白边发光圆钮跟手、右上 6 格能量柱逐格点亮、档位大字弹跳与振动；面板自然高度、底部安全区不顶到导航条；无 Slider。
4. **回归**：抽屉三入口、四态添加、6 档短标签、角色头像、记忆卡、SKILL.md 等 v3/v3.1/v3.2/v3.3 功能无回归。

### 17.8 结论

- **构建**：最终快照（11:07:36–11:08:27）5/5 BUILD-OK，0 error；工作区本机签名触发 unsigned 回退且恢复无损（工作区 SHA256 前后一致 `0259B43A…`），仓库 HEAD 已脱敏（`signingConfigs: []`）。
- **用例**：**32 文件 / 487 断言全绿**（0 失败 / 0 跳过）；prepare 51 拷贝/0 告警。
- **v3.4 三项修复**静态证据齐全：`setDrawerOpen` 收口 + animateTo 220ms + 两子节点 OPACITY/move(START)；success 可取消 + toggleModel/unregister/clearActiveProfile 双向链路；能量槽面板删除 Slider 改为 onTouch 吸附 + 渐变 + 6 格柱 + 自然高度。
- **契约**：`ModelCatalogApi.unregister` / `ModelCatalog.unregister` / `AppServices.clearActiveProfile` 已登记；`ChatRuntimeApi`/`ChatRuntime` 未动；main_pages 4 页；颜色仍 48 键。
- **缺陷**：本轮**未发现需要修复的缺陷**。
- **残余**：真机退场流畅度/左滑跟手/能量槽手感/取消真实链路仍需按 §17.7 冒烟；无真机前不得宣布 v3.4 交互修复闭环达成。
