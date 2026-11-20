# ChatAnyWhere · 任意聊

> 按 [`docs/harmonyos_llm_vibe_blueprint.md`](docs/harmonyos_llm_vibe_blueprint.md) 实现的 **HarmonyOS NEXT（API 26）原生大模型对话应用**：
> 统一 Item 树 + 只增轨迹 + 多厂商流式协议 + 缓存感知压缩 + 插件微内核 + 手机端「技能创造室」。
> UI 按 [`docs/design/chatanywhere_v3_pura_x_max.html`](docs/design/chatanywhere_v3_pura_x_max.html) 设计稿落地：**华为 Pura X Max 折叠形态（5.4″ 外屏 / 7.7″ 阔内屏）双栏 Master-Detail**、6 档思考、Cherry Studio 级角色配置、SKILL.md 编辑器。
>
> **交付状态**：4 个 HAR + entry HAP 全部落地，`hvigor assembleHap` **BUILD SUCCESSFUL**；
> 纯逻辑 Node 单测 **30 个文件 / 475 条断言全绿**（含 37 项设计/架构静态门禁）；受环境限制（无签名证书、无模型 API Key）未做真机联调，详见 [§5 已知限制](#5-已知限制透明说明)。

---

## 1. 快速开始

### 1.1 环境要求
| 项 | 要求 |
| --- | --- |
| DevEco Studio | 26.0.0（内置 HarmonyOS 26.0.0 SDK / hvigor 6.26.4 / ohpm） |
| 设备 | HarmonyOS NEXT 手机或模拟器（API 26+） |
| Node.js | DevEco 自带 Node 24（无需另装） |

### 1.2 命令行构建（无需打开 IDE）
```powershell
# 首次：安装本地依赖（源码包不含 oh_modules；DevEco Studio 打开工程时会自动同步）
ohpm install --all

# 构建入口 HAP（连同 4 个 HAR 一起编译）
pwsh tools/build.ps1

# 只编译单个 HAR（内层循环）
pwsh tools/build.ps1 -Module core_model
```
产物：`chat/build/default/outputs/default/chat-default-unsigned.hap`

> **签名说明**：工程已带 DevEco 自动签名配置；但本机签名材料在 CLI 下会报 `11014003 Init keystore failed`（环境问题，与源码无关）。
> `tools/build.ps1` 检测到该错误时会临时跳过签名重跑，并在结束后自动恢复 `build-profile.json5`，此时输出
> `BUILD-OK (all) [unsigned verification: ...]`——用于编译验证，产物为 unsigned HAP；真机安装请在 DevEco Studio 中用自动签名运行。
> 仅需审查源码时，建议先读 [`docs/REVIEW_GUIDE.md`](docs/REVIEW_GUIDE.md)（阅读顺序、重点审查项与已验证/未验证边界）。

### 1.3 运行
1. DevEco Studio 打开工程根目录。
2. `File > Project Structure > Signing Configs` 勾选自动签名。
3. 运行 `chat` 模块到手机/模拟器。
4. **启动即对话页**：左上角抽屉图标 → 底部「设置」→ 填 DeepSeek（或 Anthropic / OpenAI 兼容）API Key → 返回对话直接提问。
5. 密钥写入 HarmonyOS **Asset Store Kit** 加密存储，不落 Preferences / 数据库 / 日志。

---

## 2. 架构

### 2.1 模块与依赖方向（单向、契约通信）

```
packages/core_model      数据层：Item/节点/会话模型、轨迹树、RDB+FTS5、Asset 密钥、导入导出
        ▲
packages/core_protocol   协议层：SSE 引擎、rcp 流式、DeepSeek Responses / Anthropic / OpenAI 兼容
        ▲                 （依赖 core_model）
packages/core_context    上下文层：缓存感知压缩、四层提示词装配（纯逻辑、零平台依赖）
packages/core_plugin     插件层：微内核 + L1/L2/L3 + 双轨联网清洗 + 技能创造室（依赖 model/protocol）
        ▲
chat（entry HAP）        应用层：ArkUI 页面、AppServices 装配、ChatRuntime 门面（会话/流式/工具循环三控制器）、系统桥接
```

每个 HAR 只通过包根 `Index.ets` 暴露公共 API；契约位于各包 `src/main/ets/interfaces/`，实现方可替换、消费方不感知。
跨模块 import 形如 `import { ConversationNode } from '@app/core_model'`，禁止穿透到子路径。

### 2.2 关键分层职责

| 模块 | 核心文件 | 职责 |
| --- | --- | --- |
| core_model | `RdbRepository` / `TrajectoryStore` / `AssetSecretStore` / `SessionExporter` / `ModelLayerFactory` | SQLite 五表（sessions/nodes/nodes_fts/skills/skill_snapshots）、只增轨迹与分支、FTS5→LIKE 三级降级、Asset 密钥、ZIP 导入导出（含 chat-demo v3 双向映射） |
| core_protocol | `SseParser` / `RcpStreamClient` / `DeepSeekResponsesAdapter` / `AnthropicAdapter` / `OpenAICompatAdapter` / `ModelCatalog` / `ProtocolLayerFactory` | rcp 流式（tracing.httpEventsHandler）、三厂商事件解析、模型目录、标题生成、连接测试 |
| core_context | `CacheAwareCompactor` / `PromptAssembler` / `PromptPresets` | 四类压缩触发 + break-even 经济性、四层提示词固定排序（缓存前缀稳定） |
| core_plugin | `PluginKernelImpl` / `SkillSchema` / `SkillDiff` / `runners/*` / `WebCleaner` / `SkillCreatorAgent` / `BuiltinSkills` | Disposable 可逆回收、原子升级/回滚、L1/L2/L3、双轨清洗、创造模式元 Agent + 本地规则兜底、4 个内置技能 |
| chat | `AppServices` / `Theme` / `Breakpoint` / `PersonaStore` / `EffortLevels` / `ChatRuntime`（门面）/ `model/runtime/*` / `pages/*` / `components/*` / `bridge/*` | 装配、v3 设计令牌与深色模式、折叠/双栏响应式、角色与技能三级继承、6 档思考、对话编排（门面 + 会话/流式/工具循环/回合协调器）、全中文 ArkUI、分享/通知/局域网编辑 |

### 2.3 目录

```
ChatAnyWhere/
├── chat/                                   # entry HAP
│   └── src/main/ets/
│       ├── app/            AppServices、Routes、Theme（v3 令牌）、Breakpoint（600vp 双栏）、
│       │                   EffortLevels（6 档）、PersonaStore（角色与技能三级继承）
│       ├── model/          ChatRuntime（≤500 行门面）、ChatRuntimeApi（冻结契约）、RuntimeHolder
│       │   └── runtime/    SessionController / StreamTurnExecutor / ToolLoopRunner / TurnCoordinator /
│       │                   SettingsController / PromptComposer / NodeFactory 等（均 ≤500 行）
│       ├── pages/          ChatPage（双栏/折叠主对话页）、SkillCreatorPage（SKILL.md 编辑器）、
│       │                   SkillManagerPage（技能 Master-Detail）、SettingsPage（设置 Master-Detail）
│       ├── components/     IconBtn（统一图标按钮）、VendorCard（模型厂商卡）、PersonaAvatarPicker（头像选择）、MarkdownBlock、StreamingMessage、MemoryGaugeBar、MessageDataSource、
│       │                   SessionDrawer、SourcePane、AttachSheet、PersonaSheet、ModelCapsule、BranchSelector、
│       │                   Settings*View（角色/模型/记忆/跨端）、SkillCard、SkillDetailView、ConfigForm、
│       │                   CreatorMasterList、SkillMdPreview
│       ├── bridge/         LiveViewBridge、ShareKitBridge、LanEditorServer
│       ├── chatability/    ChatAbility（入口 + 分享意图接收，loadContent = pages/ChatPage）
│       └── chatbackupability/
├── packages/               四个 HAR（见上）
├── tools/
│   ├── build.ps1           跨 Agent 串行化构建（文件锁 + 诊断过滤 + 签名失败自动 unsigned 回退）
│   └── logic-tests/        纯逻辑 Node 单测（prepare/run + 用例文件 + 静态断言）
├── docs/
│   ├── design/chatanywhere_v3_pura_x_max.html  v3 UI/交互设计稿（Pura X Max 原型，视觉基准）
│   ├── harmonyos_llm_vibe_blueprint.md   需求/架构总控规范
│   ├── DEV_GUIDE.md                      工程约定、ArkTS 实测限制、v3 设计系统/文案纪律/功能模型、降级登记
│   ├── API_REFERENCE.md                  DeepSeek 协议逐字事件 + 本地 SDK API 事实（含 20 条未确认项）
│   ├── LOGIC_NOTES_core_context.md       压缩阈值/公式速查
│   ├── REVIEW_GUIDE.md                   面向审查 Agent 的阅读顺序与审查清单
│   └── TEST_REPORT.md                    构建矩阵、用例统计、五 Milestone 验收、重构验收、v3 验收
└── build-profile.json5                    工程/产品/模块注册（4 HAR + entry）
```

---

## 3. 能力清单

| 能力 | 实现 | 说明 |
| --- | --- | --- |
| 统一 Item 树与只增轨迹 | core_model | 分支切换、fork、归档不删除；压缩后原文仍在 RDB/FTS5 |
| RDB 持久化与检索 | core_model | 五表幂等建表、事务写入、FTS5+LIKE 互补检索 |
| 密钥加密托管 | core_model | Asset Store Kit，`Map<Tag,Value>` + Uint8Array，别名寻址 |
| ZIP 导入导出 | core_model | `manifest.json`+`nodes.jsonl`；额外产出/识别 chat-demo v3 结构 |
| SSE 增量解析 | core_protocol | 跨分片、多行 data、CRLF 拆片、注释、flush；纯逻辑 |
| DeepSeek Responses 流式 | core_protocol | 无 `[DONE]`、`response.completed` 终止、cached_tokens、reasoning、tool_call、web_search_call 原样回传（signature） |
| 多厂商适配 | core_protocol | Anthropic Messages、OpenAI Chat Completions（任意兼容端点） |
| 异构模型切换 | core_protocol | 同厂商 vendorRaw 透传；异构 fallbackSummary 降级，不产生 400 |
| 缓存感知压缩 | core_context | 空闲过期 / 切模型 / 质量红线 / 低倍率经济；break-even `(α/(1-α))·R` |
| 四层提示词 | core_context | base→persona→skill(字典序)→memory；6 个动态变量；同输入幂等 |
| 插件微内核 | core_plugin | Disposable 逆序回收、原子升级、版本回滚、零残留卸载 |
| L1 声明式插件 | core_plugin | HTTP 模板 + `{{input.x}}/{{config.x}}/{{secret:别名}}` + 域名白名单 + responsePath |
| L2 远程 MCP | core_plugin | initialize → tools/list → tools/call，JSON-RPC + SSE，Bearer 取自 Asset |
| L3 端侧脚本 | core_plugin | 接口/校验/白名单完整；当前构建执行后端降级为明确中文错误；**UI 已隐藏 L3 入口**（待接入 QuickJS-NG NAPI 再开放） |
| 双轨联网清洗 | core_plugin | 轨道 A 原厂工具；轨道 B `/v1/tools/search` + `/v1/tools/fetch`，阈值过滤 + 8s 超时降级 |
| 技能创造室 | core_plugin + UI | **Master-Detail SKILL.md 编辑器**：`SkillMarkdownCodec` ↔ Manifest、编辑/预览、试跑、保存（原子升级+快照）、底部 AI 改写；无 Key 中文提示 |
| 主对话体验（v3） | chat | **折叠/双栏响应式**（≥600vp：232 会话栏 + 680 画布 + 288 信源栏；折叠：单栏 + 抽屉）；顶栏 44 模型胶囊（6 档）+ 角色胶囊 + 新对话；用户深色气泡 / AI 无气泡通栏；思考胶囊 + 检索步骤；复制/重试/分支 `<1/3>`/来源滑出；一体胶囊输入（「+」仅附件：相册/文档/链接）+ 附件 chips；`LazyForEach` + cachedCount(6)；记忆条 <60% 隐藏 |
| 角色与思考（v3） | chat/app | 6 档思考（关闭/Min/Low/Med/High/xHigh，三厂商离线映射）；Cherry Studio 级角色：系统提示词 + `{{date}}`/`{{clipboard}}`、默认模型、Temperature 0–2、Top-P、上下文轮数、默认绑定技能；新会话继承全局默认角色 |
| 技能三级继承 | chat/app | 全局总开关 ⊂ 角色默认绑定 ⊂ 当前对话临时开关；运行时只注入生效技能；对话页「本对话技能」chips 实时切换 |
| 设计系统（v3.1） | chat/app/Theme.ets + components/IconBtn.ets | Pura X Max 精确色板（品牌蓝 `#2563EB`/`#4F83FF`）、原生舒适字号阶梯（正文档 15.5/行高 26）、尺寸（顶栏 48/折叠 44、栏宽 232·236·220、信源 288、输入圆角 24）、`IconBtn` 统一居中图标按钮（按压微缩反馈）；`base/dark` 46 键（含 8 个角色头像低饱和底色）；禁止硬编码色值 |
| 角色与提示词（v3.2） | chat/app + SettingsPersonaView | **二级视图**：一级纵向列表（40×40 圆形头像 + 名称 + 默认标识 + 绑定模型摘要 + 右箭头，支持搜索/新建）→ 二级编辑（头像可选 10 图标 × 8 低饱和配色、提示词/采样参数/技能绑定/复制/删除/设默认）；`avatarIcon/avatarTone` 旧数据兼容 |
| 真实模型与密钥（v3.2） | core_protocol + core_model + SettingsModelsView | **不再内置任何占位模型**：厂商预设 + 真实 `/models` 探测（DeepSeek / Anthropic / OpenAI 兼容），探测结果落 RDB `provider_models`，勾选启用的模型才出现在顶栏与角色配置；测试连接/拉取支持输入框未保存的新 Key；`VendorCard` 独立组件修复状态不刷新 |
| 记忆与缓存（v3.2） | chat | 设置页显示**当前对话**（标题/消息数/上下文 Token 与窗口占比/缓存命中率）+「立即整理记忆」；**最近整理结果**（时间、整理前 → 整理后 Token、可展开摘要全文） |
| 设置与技能管理（v3） | chat | 设置 Master-Detail（角色与提示词 / 模型与密钥 / 记忆与缓存 / 跨端与数据，`category` 直达）；技能 Master-Detail（开关、schema 参数、回滚/试跑/导出/删除、编辑 SKILL.md） |
| 系统桥接 | chat/bridge | 分享链接接收与清洗摘要、后台进度通知、局域网 HTTP 编辑器（裸 TCP） |

### 与 Blueprint 6 条架构红线的对应

1. **纯原生渲染**：`List` + 块级增量 Markdown（`splitBlocks`/`parseInline`，已闭合块冻结复用，仅活跃块 32ms 节流），无 ArkWeb 套壳。
2. **统一 Item 树 + 只增轨迹**：`CanonicalItem`/`ConversationNode` 唯一内部状态；`activeChildId` 表达分支；压缩只归档。
3. **缓存感知优先**：压缩器按缓存倍率与 TTL 决策，避免破坏 30–50 倍前缀缓存收益。
4. **插件微内核与可逆副作用**：注册即返回 `Disposable`；L1 JSON / L2 MCP / L3 沙箱三级隔离。
5. **创造模式落盘可回滚**：Schema 校验 → 沙箱试跑 → 中文 Diff → 用户确认 → RDB 落盘 + 上版快照。
6. **直白中文 UI 与硬件级密钥安全**：全中文文案；密钥只进 Asset Store。

---

## 4. 测试与验证

```powershell
# 纯逻辑单测（Node 24，离线，自动复制 .ets→.ts）
pwsh tools/logic-tests/run.ps1

# 全量构建（带跨 Agent 锁）
pwsh tools/build.ps1
```

验证方式（本环境可执行的全部手段）：

| 手段 | 覆盖 |
| --- | --- |
| ArkTS 编译器类型检查 | 全部 5 个模块、约 2.5 万行 ArkTS/TS；`BUILD SUCCESSFUL` |
| Node 纯逻辑单测 | SSE 解析、三厂商事件解析、压缩决策、提示词装配、Skill Schema/Diff、清洗查询与阈值、chat-demo 编解码、Markdown 分块、Token/Json 工具等 23 文件 / 405 断言 |
| 结构检查 | HAP 打包内容确认 `ets/modules.abc` 含全部 HAR 字节码 |
| 人工代码审查 | 契约一致性、写作用域、降级路径中文错误、无 TODO 残留 |

详见 [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md)。

---

## 5. 已知限制（透明说明）

| 项 | 现状 | 原因 / 影响 |
| --- | --- | --- |
| 真机或模拟器联调 | **未执行** | 无模型 API Key；CLI 仅能编译校验。公开仓库的 `build-profile.json5` 已脱敏（`signingConfigs: []`），本机签名材料备份在 gitignore 的 `build-profile.local.json5`；真机安装需在 DevEco Studio 重新自动签名 |
| 真实网络链路 | 未端到端跑通 | 无 Key/无外网；rcp 流式、Search/Fetch、MCP、**真实 `/models` 模型探测**均按官方文档与 SDK d.ts 实现，解析器可容错（探测解析有合成 fixture 单测） |
| 原生 `native_core`（C++ NAPI） | 以纯 ArkTS 等价实现替代 | 无 QuickJS-NG 源码与 NDK 交叉编译验证条件；ArkTS 版可编译、可测 |
| L3 QuickJS 端侧脚本沙箱 | 接口/白名单/校验完整，执行返回明确中文错误；**UI 已隐藏 L3 入口** | 同上；不静默失败，也不在界面上暴露半成品 |
| 端侧实况窗 | 降级为「系统通知 + 应用内进度条」 | 本 SDK 不存在三方可用的 `@ohos.app.ability.LiveView`（见 API_REFERENCE §9） |
| FTS5 | 优先 FTS5，失败自动降级 LIKE | SDK 未暴露 FTS5 可用性；中文短词（<3 字）走 LIKE |
| DeepSeek 原厂联网工具 | 与函数工具/标题互斥；带信源过滤时改用轨道 B | 官方错误文案表明互斥、边界未公布；保守互斥避免 400 |
| chat-demo 导出 | 额外产出 v3 结构，但无法保证 `manifest.json` 为 ZIP 首条目、无图片原件 | HarmonyOS zlib 不支持精细控制 ZIP 条目顺序/二进制附件 |
| 局域网编辑 | 固定端口 8123、无二维码、导入 ZIP 用路径输入、Git 订阅仅匿名 GET | SDK 无法读回随机分配端口；避免引入额外依赖/权限 |
| 摘要请求标题 | 整理记忆的摘要请求可能多等 ≤5s | 协议层按「历史 user 消息 ≤1 条」推断是否请求 `response.title`；不计费、不影响正确性 |
| UI 视觉与交互（v3） | 已按 Pura X Max 设计稿落地（双栏/折叠、6 档思考、角色配置、SKILL.md 编辑器、附件、信源栏、记忆条），**无真机渲染验证** | 无设备；静态断言与编译期检查代替（见 TEST_REPORT §13）；折叠手势/键盘避让/深色观感/相册与文档 Picker 需真机冒烟 |
| 附件能力 | 相册图片/PDF 文档/网页链接可附加并随用户消息落盘（`image`/`file_ref` items）；拍照入口暂不提供 | 拍照需相机权限与额外 Kit 授权；模型侧读图/读文件能力由各厂商适配器降级（部分仅 DeepSeek 支持 `file_id` 引用） |
| 思考档位厂商差异 | OpenAI 兼容 `xhigh → high`（无 max 档）；DeepSeek `med` 发 `medium`（服务端归一化 high） | 各厂商参数集不同；只会降低思考强度，不会 400（详见 DEV_GUIDE §10.4） |

详细登记见 [`docs/DEV_GUIDE.md`](docs/DEV_GUIDE.md) §7。

---

## 6. 工程协作说明

本工程由 Team Lead + 8 名并行 Agent（4 个核心 HAR、2 个 UI 域、1 个运行时重构、1 个 QA）按契约分区实现。并发安全措施：

- `tools/build.ps1` 用文件锁串行化 hvigor 构建，避免 `.hvigor` 缓存争抢；检测到本机签名材料不可用时自动「临时跳过签名 → 重跑 → 恢复 build-profile.json5」，保证编译验证不被环境问题阻塞；
- 冻结契约：各包 `interfaces/**` 与 `Index.ets` 导出签名、`ChatRuntimeApi.ets`，变更须 Lead 仲裁；
- 写作用域按模块/文件划分，跨模块修改一律先报备；
- `build-logs/`、`dist/`、`tools/logic-tests/build/` 已加入 `.gitignore`，避免污染检索上下文；
- UI 设计系统与中文文案纪律（禁教学句、禁硬编码色、统一 `SymbolGlyph` 图标）见 [`docs/DEV_GUIDE.md`](docs/DEV_GUIDE.md) §10。
