# 源码审查指引（给审查 Agent）

> 本文件面向**外部审查者/审查 Agent**，说明这个源码包怎么看、重点审什么、哪些已被验证、哪些无法在离线环境验证。
> 快速了解项目请先读 [`README.md`](../README.md)，需求来源是 [`harmonyos_llm_vibe_blueprint.md`](harmonyos_llm_vibe_blueprint.md)。

## 1. 包内容与排除项

- **包含**：全部源码（4 个 HAR + entry HAP）、工程配置、文档、构建/测试脚本、纯逻辑测试用例与重构静态断言。
- **不包含**（有意排除，避免干扰审查）：
  - `oh_modules/`、`node_modules/`（依赖，需 `ohpm install --all` 或 DevEco 打开时自动同步）
  - `build/`、`.hvigor/`、`build-logs/`（构建产物与日志）
  - `.idea/`、`local.properties`（本机 IDE/本地配置，DevEco 会自动生成）
  - `dist/`（本源码包自身）

## 2. 建议阅读顺序

1. `README.md` —— 架构、能力清单、构建/运行、已知限制。
2. `docs/design/chatanywhere_v3_pura_x_max.html` —— **v3 UI/交互设计稿（视觉与布局基准，含文末「ArkUI 适配指令」）**。
3. `docs/harmonyos_llm_vibe_blueprint.md` —— 业务需求与 6 条架构红线。
4. `docs/DEV_GUIDE.md` —— 工程约定、**ArkTS 实测限制表**、**§10 v3 设计系统/文案纪律/功能模型**、**§7 功能降级登记**。
5. `docs/API_REFERENCE.md` —— DeepSeek 协议逐字事件载荷 + 本地 SDK d.ts 摘要（含 20 条「未确认项」）。
6. 各包**冻结契约**（先看接口再看实现）：
   - `packages/core_model/Index.ets` + `src/main/ets/interfaces/*.ets`
   - `packages/core_protocol/Index.ets` + `src/main/ets/interfaces/*.ets`（`ThinkingLevel` 6 档、`RequestOptions.topP`）
   - `packages/core_context/Index.ets` + `src/main/ets/interfaces/*.ets`
   - `packages/core_plugin/Index.ets` + `src/main/ets/interfaces/*.ets`（`SkillMarkdownCodec`）
7. 应用层装配与编排：`chat/src/main/ets/app/AppServices.ets` → `model/ChatRuntimeApi.ets`（冻结）→ `model/ChatRuntime.ets`（≤500 行门面）→ `model/runtime/*`（SessionController / StreamTurnExecutor / ToolLoopRunner / TurnCoordinator / SettingsController / PromptComposer …）。
8. v3 设计系统与功能模型：`app/Theme.ets`（色板/尺寸/图标）、`app/Breakpoint.ets`（600vp 双栏）、`app/EffortLevels.ets`（6 档）、`app/PersonaStore.ets`（角色与技能三级继承）+ `resources/{base,dark}/element/color.json`。
9. 页面与组件：`pages/ChatPage.ets`（双栏/折叠主对话）、`SkillCreatorPage.ets`（SKILL.md 编辑器）、`SkillManagerPage.ets`、`SettingsPage.ets` + `components/*`（SessionDrawer / SourcePane / AttachSheet / PersonaSheet / Settings*View / SkillDetailView …）、`bridge/*`。
10. 测试：`tools/logic-tests/`（`prepare.ps1` 纯逻辑抽取；`cases/*.test.mjs` 为 **457 条**断言，含 6 档思考、SKILL.md 往返、v3 设计静态门禁）。

## 3. 架构约束（审查时优先确认）

依赖必须单向：`core_model ← core_protocol ← (core_context, core_plugin) ← chat`。

- 跨模块只允许 `import ... from '@app/<pkg>'`（包根 `Index.ets`），**禁止**穿透到 `packages/*/src/main/ets/...` 子路径。
- 契约文件（`interfaces/**` + 各包 `Index.ets` 导出签名）视为冻结；实现方新增私有文件不改变契约。
- `core_context` 必须零平台依赖（不得 import `@kit.*`），以便 Node 直跑单测。
- 密钥只允许进 Asset Store（`core_model/impl/AssetSecretStore.ets`），禁止出现在 Preferences/RDB/日志；Skill 清单只存 `assetKeyAlias` / `{{secret:别名}}` 占位符。

## 4. 建议重点审查的实现

| 关注点 | 文件 |
| --- | --- |
| 只增轨迹、分支切换、压缩归档不删除 | `packages/core_model/src/main/ets/TrajectoryStore.ets`、`impl/RdbRepository.ets` |
| FTS5→LIKE 降级、事务、UPSERT 保留 archived | `packages/core_model/src/main/ets/impl/RdbRepository.ets` |
| SSE 跨分片解析正确性 | `packages/core_protocol/src/main/ets/SseParser.ets` |
| 三厂商事件映射与异构降级 | `core_protocol/src/main/ets/adapters/*Sse.ets`、`*Adapter.ets` |
| rcp 流式（`Configuration.tracing.httpEventsHandler`、超时、取消、session 关闭） | `core_protocol/src/main/ets/impl/RcpStreamClient.ets` |
| 压缩经济性决策（四触发 / policy / break-even） | `core_context/src/main/ets/CacheAwareCompactor.ets` |
| 四层提示词顺序与幂等（缓存前缀稳定） | `core_context/src/main/ets/PromptAssembler.ets` |
| Disposable 逆序回收、原子升级/回滚、零残留 | `core_plugin/src/main/ets/PluginKernelImpl.ets` |
| 插件域名白名单、密钥注入、L1 模板 | `core_plugin/src/main/ets/runners/L1DeclarativeRunner.ets`、`util/{DomainUtil,L1Template}.ets` |
| 创造模式闭环（校验→试跑→Diff→确认→落盘+快照） | `core_plugin/src/main/ets/SkillCreatorAgent.ets`、`SkillSchema.ets`、`SkillDiff.ets` |
| 对话编排（落盘优先、32ms 节流、工具循环、标题/用量） | `chat/src/main/ets/model/ChatRuntime.ets`（门面）+ `model/runtime/{SessionController,StreamTurnExecutor,ToolLoopRunner,SnapshotNotifier}.ets` |
| 门面与子模块的职责边界、状态归属、行为等价 | `model/ChatRuntimeApi.ets` 24 个方法 → `model/runtime/*` 对照；重点看 `SnapshotNotifier` 的 32ms 节流与结束清空 |
| 块级增量 Markdown（闭合块冻结） | `chat/src/main/ets/components/MarkdownParser.ets`、`MarkdownBlock.ets` |
| 主消息虚拟列表（长会话不全量挂载） | `components/MessageDataSource.ets`（`IDataSource`、`onDataAdd/onDataChange/onDataReloaded`）+ `pages/ChatPage.ets`（`LazyForEach` + `.cachedCount(6)`） |
| 设计令牌与深色模式（无硬编码色、Pura X Max 精确色板） | `app/Theme.ets`、`resources/base/element/color.json`、`resources/dark/element/color.json`（各 38 键） |
| 折叠/双栏响应式（600vp） | `app/Breakpoint.ets` + `pages/{ChatPage,SkillCreatorPage,SkillManagerPage,SettingsPage}.ets` |
| 6 档思考与三厂商映射 | `app/EffortLevels.ets` + `core_protocol/interfaces/ProtocolTypes.ets` + `adapters/{DeepSeekResponsesAdapter,AnthropicAdapter,OpenAICompatAdapter}.ets` |
| 角色（Cherry Studio 级）与技能三级继承 | `app/PersonaStore.ets`、`components/SettingsPersonaView.ets`、`model/runtime/{SettingsController,PromptComposer}.ets` |
| SKILL.md ↔ Manifest 编解码 | `core_plugin/src/main/ets/SkillMarkdown.ets` + `pages/SkillCreatorPage.ets` |
| 附件（相册/文档/链接）落盘为 Item | `components/AttachSheet.ets`、`model/runtime/NodeFactory.ets`、`ChatRuntimeApi.AttachmentRef` |
| UI 文案纪律（反教学句）与信息架构 | `pages/ChatPage.ets`、`components/{ModelCapsule,MemoryGaugeBar,SessionDrawer,SourcePane,PersonaSheet}.ets`、`pages/SettingsPage.ets` + `components/Settings*View.ets` |
| 无 Key / 插件降级路径不崩溃 | `chat/src/main/ets/app/AppServices.ets`、`pages/ChatPage.ets`、各页面 |

## 5. 已验证 vs 未验证（请按此判定，不要高估）

**已验证（可复现）**
- 完整构建：4 个 HAR + entry HAP 编译通过（`tools/build.ps1`；本机签名材料在 CLI 下不可用时脚本自动 unsigned 校验并恢复配置）。
- 纯逻辑：`pwsh tools/logic-tests/run.ps1` → **28 个用例文件 / 458 条断言全绿**（离线、零三方依赖）。\n- v3.1 视觉打磨：原生字号阶梯、顶栏/栏宽/信源尺寸、`IconBtn` 居中图标按钮（按压微缩）、颜色资源 38 键不变（见 `docs/TEST_REPORT.md` §14）。
- 静态门禁：**25 项**（`90-refactor-static` 11 + `91-design-v3-static` 14）——无硬编码色（`bridge/LanEditorServer.ets` 内嵌 HTML CSS 豁免）、无教学文案、虚拟列表/门面拆分/入口切换/设计令牌/资源键一致性。
- v3 设计验收：色板 38 键与精确色值、Breakpoint 600vp（4 页/5 处）、侧栏 224/232/216 + 画布 660 + 信源 280、6 档思考、SKILL.md 编辑器接线、附件契约、角色与技能三级继承、5 个 v2 组件已清理（见 `docs/TEST_REPORT.md` §13）。
- 详见 `docs/TEST_REPORT.md`（构建矩阵、逐文件覆盖、五 Milestone DoD、重构 §12、v3 §13）。

**未验证（环境限制，非实现遗漏）**
- 真机/模拟器端到端：无模型 API Key；本机 DevEco 签名材料在 CLI 下不可用（`11014003`），只有 unsigned 编译校验。
- RDB/FTS5、Asset Store、rcp 真实流、Search/Fetch 真实响应、MCP 真实服务端、通知/分享/局域网端口。
- v3 UI：折叠/展开手势与动画、双栏观感、深色模式实际效果、相册/文档 Picker、键盘避让、20 轮长对话帧率、虚拟列表滚动性能。
- 附件真实上传与厂商读图/读文件能力、AI 改写真实流式（需 Key）。
- L3 QuickJS 沙箱（见 `docs/DEV_GUIDE.md §7`，当前返回明确中文错误，且 UI 已隐藏入口）。

## 6. 审查清单（建议逐条打勾）

- [ ] 依赖方向无反向 import；跨模块只用包根 `@app/*`
- [ ] 契约（`interfaces/**`、`Index.ets` 导出、`ChatRuntimeApi.ets`）与实现签名一致，无隐式契约变更
- [ ] 所有会话/轨迹/技能写入先落盘再回 UI；压缩只归档不物理删除
- [ ] 密钥不落明文（Asset Store / `{{secret:别名}}`），日志不含 Key
- [ ] 插件 L1/L2 域名白名单默认拒绝；L3 降级不静默且 UI 不暴露
- [ ] 技能「生成/修改」必经 Schema 校验 → 试跑 → Diff（SKILL.md 编辑器为保存前校验）→ 落盘 + 快照
- [ ] ArkTS 限制（禁 any/unknown、生成器/AsyncIterable、`Record` 字面量、对象展开、for-in）无违反
- [ ] 网络/解析/平台调用均有 try/catch 与中文错误文案（无 TODO/占位）
- [ ] UI 文案为短标签/名词，无「小提示 / 会先在心里推理 / 聊两句就」等教学句
- [ ] UI 无硬编码 `#RRGGBB`；颜色走 `Theme` + `resources` 深浅色（v3 色板 38 键一致）；图标用 `SymbolGlyph`
- [ ] v3 响应式：`Breakpoint` 600vp 驱动「展开双栏 / 折叠单栏」；折叠态复杂页面走「列表 → 详情」二级栈
- [ ] v3.1 信息架构：展开态侧栏 232（对话）/236（技能、创造室）/220（设置）、画布 680、信源栏 288、顶栏 48（折叠态 44）、输入圆角 24；图标按钮统一 `IconBtn`（Stack 居中 + 按压反馈）
- [ ] 6 档思考（关闭/Min/Low/Med/High/xHigh）与三厂商离线映射符合 DEV_GUIDE §10.4；旧 `quick/deep` 仅迁移分支
- [ ] 技能三级继承（全局开关 ⊂ 角色绑定 ⊂ 会话临时开关）：运行时只注入 active 技能
- [ ] 附件以 `image`/`file_ref` items 随用户消息落盘；「+」仅用于附件（不得承载技能开关）
- [ ] 主消息列表使用 `LazyForEach` + `cachedCount(6)`，流式气泡独立挂载
- [ ] `ChatRuntime.ets` 为门面且 `model/runtime/*` 各文件 ≤500 行，无循环依赖
- [ ] 纯逻辑文件无 `@kit.*` 依赖（否则 Node 测试覆盖失效）

## 7. 复现命令（可选）

```powershell
# 依赖（源码包不含 oh_modules；DevEco 打开工程会自动同步）
ohpm install --all

# 构建
pwsh tools/build.ps1

# 纯逻辑单测（不需要设备）
pwsh tools/logic-tests/run.ps1
```

> 注：本机 DevEco 自动签名材料在 CLI 下可能报 `11014003 Init keystore failed`（环境问题，与源码无关）。
> `tools/build.ps1` 会自动「临时跳过签名 → 重跑 → 恢复 `build-profile.json5`」，输出 `BUILD-OK (all) [unsigned verification: ...]`；
> 校对时请确认 `build-profile.json5` 的 `signingConfigs` 在构建后仍保留（脚本使用原子写入恢复）。
> 真机安装请在 DevEco Studio 中使用自动签名运行。
