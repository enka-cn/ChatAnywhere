# ChatAnyWhere 开发指南（给并行 Coding Agent 的共同约定）

> 必读。先读 `docs/harmonyos_llm_vibe_blueprint.md`（产品/架构总控规范），再读本文件（工程约定与已验证事实），随后才动代码。
> 还在生成的 `docs/API_REFERENCE.md` 是外部 API 事实参考（DeepSeek 协议 + 本地 SDK 摘录），其余队友写完后可查阅。

## 1. 项目事实（已验证，勿再猜测）

| 项 | 值 |
| --- | --- |
| 工程根 | `C:\codes\ChatAnyWhere` |
| 应用包名 | `com.example.chatanywhere` |
| 设备形态 | phone（entry 模块 `chat`） |
| SDK | HarmonyOS 26.0.0（API 26），位于 `C:\Application\DevEco Studio\sdk\default` |
| 构建 | hvigor 6.26.4（DevEco 内置），**无需联网、无需签名**，未签名 HAP 仅不可安装，编译验证完全可用 |
| 单次构建 | 10 秒左右 |
| 类型检查 | ArkTS 编译器即类型检查器；`.ets` 中类型错误 = 构建失败 |

### 构建命令（必须走脚本，脚本带跨 Agent 文件锁）

```powershell
pwsh tools/build.ps1                      # 构建整个入口 HAP（会编译全部 HAR）
pwsh tools/build.ps1 -Module core_model   # 只构建单个 HAR（内层循环，快）
```

脚本会串行化并发构建、只打印编译诊断、日志落盘 `build-logs/`。**不要直接调用 hvigor**，否则并发构建会争抢 `.hvigor` 缓存。
退出码：0 成功 / 1 编译失败 / 2 等锁超时（稍后重试即可）/ 3 工具链缺失。

### 平台 API 的唯一事实来源 = 本地 SDK 声明文件

不要凭记忆写 HarmonyOS API。动手前用 grep/read 查：

- `C:\Application\DevEco Studio\sdk\default\openharmony\ets\api\*.d.ts`（原生开放能力）
- `C:\Application\DevEco Studio\sdk\default\openharmony\ets\kits\@kit.*.d.ts`（Kit 聚合入口，import 用这个）
- `C:\Application\DevEco Studio\sdk\default\openharmony\ets\component\*.d.ts`（ArkUI 组件属性）
- `C:\Application\DevEco Studio\sdk\default\hms\ets\api\@hms.collaboration.rcp.d.ts`（rcp 流式网络，属于 HMS SDK）
- `C:\Application\DevEco Studio\sdk\default\hms\ets\kits\@kit.RemoteCommunicationKit.d.ts`

例：查 Asset Store Kit 用法 → read `...\ets\api\@ohos.security.asset.d.ts`；查 `bindSheet` → `component\common.d.ts`。

## 2. ArkTS 语言限制（本 SDK 实测结果，务必遵守）

已用探针文件在本工程实测（结论可直接采信）：

| 能力 | 结果 | 正确写法 |
| --- | --- | --- |
| `interface` + 对象字面量 | ✅ 允许 | `const x: Foo = { a: 1 }` |
| 嵌套对象字面量 | ✅ 允许 | 内层也要有已声明类型 |
| `Record<string,T>` **对象字面量** | ❌ 编译错误 `arkts-no-untyped-obj-literals` | 用 `Map<string,T>`；或 `const m = JSON.parse('{}') as Record<string,T>` 后逐项 `m[k]=v` |
| `Object.keys` / `Object.values` | ✅ 允许 | 遍历 Record 用 `for (const k of Object.keys(rec))` |
| `for...in` | ❌ 禁止 | 用 `Object.keys` / Map |
| 生成器 `function*` / `async function*` / `AsyncIterable` / `for await` | ❌ **不支持** `arkts-no-generators` | 一律用回调：`send(..., callbacks)`；流式事件用 `onEvent: (e: StreamEvent) => void` |
| `any` / `unknown` | ❌ 禁止 | 显式类型；`catch (e)` 里用 `const err = e as Error` |
| 对象展开 `{...a}` | ❌ 禁止 | 显式构造；数组展开 `[...arr]` ✅ 允许 |
| `as const`、`declare`、装饰器（除 ArkUI） | ❌ 禁止 | 用 `readonly` / 显式类型 |
| `class` 字段 | ✅ 允许（含 `private readonly`、`static`、`get`） | 字段必须初始化 |
| async/await、`Promise.all`、`Map`/`Set`、`JSON.parse`+`as`、模板字符串、可选链 `?.`、`??`、`Array.sort`、`setTimeout/setInterval` | ✅ 全部允许 | — |
| 联合字面量类型 + `switch` | ✅ 允许 | `type Kind = 'a'\|'b'` |
| ArkUI `@Observed`/`@ObjectLink`/`LazyForEach`/`IDataSource`/`bindSheet`/`@Builder`/`@Styles`/`@Extend`/`Toggle`/`Slider`/`Progress`/`Flex`/`Scroller`/`promptAction`/`router` | ✅ 全部编译通过（已探针验证） | 见 `chat/src/main/ets/pages/*` 现有写法 |

其他硬规则：

- 所有 `.ets` 文件顶层 `export` 的公共 API 必须有显式类型；禁止把平台对象（`Context` 除外）做成模块级单例常量在 import 时初始化，必须通过 `init()`/工厂异步初始化。
- `JSON.parse(x) as T` 是唯一推荐的动态 JSON 入口。`JSON.stringify(obj)` 对 interface 对象正常工作；**不要** `JSON.stringify(Map)`（会得到 `{}`）。
- 一个 `.ets` 页面文件只能有一个 `@Entry`；`@Entry` 页面必须登记在 `chat/src/main/resources/base/profile/main_pages.json`。
- 禁止在 UI 线程做重活：RDB/网络都是异步；长循环要分片。
- 所有面向用户的文案用**直白中文**，禁止英文工程术语、禁止在 UI 暴露 "schema/token 缓存命中率" 之类原始字段名（用「对话记忆」「联网清洗」「能力抽屉」等通俗叫法，缓存命中率显示为「本省钱 xx%」之类可自行润色，但保留数值含义）。

## 3. 模块划分、依赖方向与所有权（并行时严格不越界）

```
packages/core_model      ← 无依赖            (队友 core-model)
packages/core_protocol   → core_model        (队友 core-protocol)
packages/core_context    → core_model, core_protocol (队友 core-context)
packages/core_plugin     → core_model, core_protocol (队友 core-plugin)
chat (entry HAP)         → 以上全部          (队友 ui-chat / ui-skills；Lead 负责 app 层接线)
```

**依赖只能向左/向上单向**，禁止反向 import（core_model 里不能 import core_plugin）。

每个 HAR 的对外 API 一律由包根 `Index.ets` 导出，跨模块只能：

```ts
import { ConversationNode, ModelLayer } from '@app/core_model';
```

**禁止** `import ... from '../../../packages/core_model/src/main/ets/xxx'` 这类穿透路径。

### 契约冻结

- `packages/*/src/main/ets/interfaces/*.ets` 与各包 `Index.ets` 的导出是**冻结契约**。实现文件可以随便加，但接口签名不得擅自改。
- 确实需要改契约时：`send_message` 给 lead 说明「改什么/为什么/影响谁」，由 lead 统一改并由 lead 通知受影响方。**不要**为了自己方便改别人的模块。
- 每个模块内部实现由该模块所有者独占写权限；UI 队友只写 `chat/src/main/ets/pages/*`、`components/*`、`viewmodel/*`、`model/ChatRuntime*.ets` 中分配给你的文件。
- Lead 独占：`build-profile.json5`、根 `oh-package.json5`、`AppScope/**`、`chat/src/main/module.json5`、`chat/src/main/resources/**`、`chat/src/main/ets/abilities/**`、`chat/src/main/ets/app/**`、`chat/src/main/ets/pages/Index.ets`、`docs/**`、`tools/**`。

### 目录约定

- `src/main/ets/interfaces/` — 纯契约（interface/type，无运行时副作用）
- `src/main/ets/` — 实现类（`XxxStore.ets`、`XxxAdapter.ets`）
- `src/main/ets/impl/` — 平台强绑定实现（RDB、rcp、asset 等），便于单元测试绕开
- 每个模块可带 `src/main/ets/util/` 纯函数工具（保持零平台依赖，便于 QA 用 Node 跑逻辑测试）

## 4. 架构与运行时接线（谁被谁创建）

Lead 会在 `chat/src/main/ets/app/AppServices.ets` 写唯一装配点：

```ts
modelLayer    = await createModelLayer(context)          // core_model
protocolLayer = createProtocolLayer({ secrets: modelLayer.secrets })
contextLayer  = createContextLayer()
pluginLayer   = await createPluginLayer({
  skills: modelLayer.repo, settings: modelLayer.repo,
  secrets: modelLayer.secrets, protocol: protocolLayer,
  cleaner: ???  // 插件层内建
})
```

`ChatRuntime`（ui-chat 实现）持有四层 + 当前 `ModelProfile` + `TrajectoryApi`，负责：发送消息 → 投影历史 → 流式收事件 → 落盘节点 → 通知 UI（含缓存命中率、标题、分支切换、记忆压缩）。

UI 页面通过 `AppServices.get()` 拿单例，**不要**自己 new 服务、不要在页面里直接 `getRdbStore`。

## 5. 安全与数据红线

1. API Key / MCP Token 只能进 Asset Store Kit（`@ohos.security.asset`，import 自 `@kit.AssetStoreKit`）；manifest 里只存 `assetKeyAlias`。Preferences/RDB 只存非敏感配置。
2. 所有会话/轨迹/技能**必须先落盘再回 UI**（append-only，绝不能只存内存）。
3. 原始历史永不物理删除：压缩只标记 `archived: true`，FTS5 仍可回捞。
4. 网络白名单：L1/L2/L3 插件只允许访问 `runtimePayload.allowedDomains`，默认拒绝；LAN 编辑器必须手动开启、页面退出即释放端口。
5. 任何"生成并应用技能"的路径必须走：Schema 校验 → 沙箱试跑 → Diff 展示 → 用户确认 → RDB 落盘 + 旧版本快照。

## 6. 质量线（每个模块交付前自查）

- [ ] `pwsh tools/build.ps1 -Module <你的模块>` 返回 `BUILD-OK`
- [ ] 公共 API 全部有中文/英文注释说明用途与异常
- [ ] 平台 API 逐个对照本地 `.d.ts`，没有猜测的方法名/字段名
- [ ] 无 `any`/`unknown`/生成器/Record 字面量/对象展开
- [ ] 无 `TODO` 占位留在已宣称完成的路径上；确实降级的功能要在 `docs/DEV_GUIDE.md` §7 登记（由 lead 更新）
- [ ] 新增/修改文件的路径都在自己的写作用域内
- [ ] 纯逻辑（解析器/压缩决策/提示词装配/清洗策略/分块器）带可脱离鸿蒙运行的自测入口（见 §8）

## 7. 已确认的功能降级（透明登记，最终写进 README）

| 项 | 决策 | 原因 |
| --- | --- | --- |
| 原生 `native_core`（C++ NAPI: SSE/Markdown/QuickJS） | 以纯 ArkTS 等价实现替代；C++ 版不作为交付必须项 | 当前环境无 QuickJS-NG 源码与 NDK 交叉编译验证条件；ArkTS 版可编译、可测试、行为等价 |
| L3 QuickJS 端侧脚本沙箱 | 保留完整接口/权限白名单/校验，执行后端返回「当前构建未启用端侧脚本沙箱」的可读中文错误，不允许静默失败 | 同上 |
| `AsyncIterable<StreamEvent>` 接口 | 改为回调式 `StreamCallbacks.onEvent` | ArkTS 不支持生成器/AsyncIterable（实测） |
| `Record<string, Object>` 动态 payload | 改为显式 `StreamPayload` 接口字段 | ArkTS 禁止 Record 字面量（实测），显式字段反而更安全 |
| DeepSeek 原厂联网工具与函数工具 / 标题共存 | 声明 `deepseek_web_search` / `deepseek_read_url` 时**不发送函数工具、不发送 title**；带信源过滤（域名/语言/时间）时改为不声明原厂工具，走 `core_plugin` 轨道 B 独立清洗 | 官方错误文案表明工具互斥，边界不明；保守互斥可避免 400 |
| `web_search_call` 回传的 `action.queries` | 契约 `VendorRaw` 未保存该字段，重建 input item 时传空数组；`signature/page/sources/kind/status` 均原样保留 | read_link 正文还原依赖 signature，官方说明其余字段可变，故不影响正确性 |
| `response.output_text.annotation.added`（url_citation 角标） | 未映射为 `StreamEvent`（无对应事件类型）；来源改由 `web_search_call` 的 sources 提供 | 避免为单一厂商的展示态字段扩张冻结契约 |
| 自定义 OpenAI 兼容模型持久化 | 协议层启动时读取 `SettingsKeys.CUSTOM_BASE_URL / CUSTOM_MODEL_ID`（及 `ANTHROPIC_BASE_URL`）自动注册；设置页需把这两项落盘，重启才不丢 | 协议层不直接写设置，保持层间单向依赖 |
| 摘要/整理请求的标题生成 | 协议层按「历史中 user 消息 ≤1 条」推断是否请求 `response.title`；整理记忆的摘要请求可能多等最多 5s（不计费、不影响正确性） | 避免为单次请求在冻结契约里加开关；如需精确控制可后续加 `RequestOptions.enableTitle` |
| chat-demo v3 导出兼容性 | 导入：自动识别并完整映射（fragment→Item、current_message_id→活动分支、signature 保留）；导出：额外产出 `chat_session_index.json` + `chat_sessions/*.json`，但 **`manifest.json` 无法保证 ZIP 首个条目**（zlib 只有目录压缩）、不含 `<id>_files/` 图片原件、`THINK.elapsed_secs`/`FILE` 尺寸等字段缺省、system 消息不导出 | HarmonyOS zlib 不支持精细控制 ZIP 条目顺序与二进制附件；日常对话场景正常 |
| L2（远程 MCP）真实联调 | 协议流程完整实现（initialize → tools/list → tools/call、JSON-RPC、Mcp-Session-Id、Bearer 取自 Asset）；未对真实 MCP Server 联网验证；Streamable HTTP 走 net.http 非流式请求，服务端若保持 SSE 长连接可能读超时（一次性响应无碍） | 构建环境无外网/无 MCP 服务 |
| 双轨联网清洗真实联调 | 按 API 参考实现 `count 1–50`、`need_content`、`rerank_score/authority` 阈值、8s Fetch 超时降级；未用真实 Key 端到端验证 | 无 API Key |
| L1 模板密钥占位符 | 约定 `{{secret:资产别名}}` 由运行器从 Asset Store 注入；密钥不落清单、不进日志 | 避免明文密钥进入可分享的 Skill JSON |
| v3 六档思考的厂商边界 | OpenAI 兼容端点 `xhigh → high`（无 max 档）；DeepSeek `med` 发 `medium`（服务端归一化 high）；`supportsThinking=false` 不发思考参数 | 各厂商参数集不同；偏差只会降低思考强度，不会 400 |
| v3 采样参数互斥 | Anthropic thinking 开启或已设 temperature 时不透传 `top_p`；OpenAI 推理模型发 `reasoning_effort` 时不透传 `top_p` | 严格端点会因同时采样参数 400 |
| v3.2 模型目录无占位模型 | `ModelCatalog` 只保留 3 条厂商预设（deepseek/anthropic/openai_compat），**不含任何具体模型 id**；模型必须经用户对真实端点「测试连接 / 拉取模型」后写入 RDB `provider_models` 并勾选启用，才会出现在顶栏与角色配置中；新发现模型默认未勾选 | 避免再次出现"假模型能选但不可用"；无模型时 UI 给中文引导 |
| v3.2 自定义 OpenAI 兼容端点思考能力 | `supportsThinking` 按模型名启发式（gpt-5*/o1/o3/o4*/*reasoner*/*thinking*/deepseek-r* 等才 true），其余不发送 `reasoning_effort` | 非推理模型被塞 reasoning 参数会 400；启发式宁可少发 |
| v3.3 线性马达触感 | 思考档位跨档时调用 `vibrator.startVibration`（VIBRATE 权限）；无振动硬件、权限被拒或异常时 `try/catch + .catch()` 静默跳过，不阻塞 UI | 不同设备马达能力不同；只作为质感增强，不影响功能 |
| v3.2 公开仓库签名配置 | `build-profile.json5` 已脱敏（`signingConfigs: []`），本机签名材料备份在 gitignore 的 `build-profile.local.json5`；DevEco 可一键重新自动签名 | 避免把用户绝对路径/加密口令推进公开 Git |

## 8. 脱离鸿蒙的纯逻辑自测（QA 提供）

`tools/logic-tests/` 会把纯逻辑 `.ets` 复制为 `.ts`（改写相对 import 后缀），用 Node 24 的 TS 类型擦除直接运行：

```powershell
pwsh tools/logic-tests/run.ps1
```

纯逻辑文件（SSE 解析、压缩决策、提示词装配、清洗策略、Markdown 分块、Token 估算、Diff 生成）**不得 import 任何平台 Kit**，以便被这套测试覆盖。平台绑定实现（RDB/rcp/asset）不做 Node 测试，靠编译期类型检查 + 手工验收清单。

## 9. 协作协议

1. **任务板**：`team_task_list` 找到你的任务并 `claim`，完成后 `complete`。
2. **写作用域**：只写任务写明的目录；跨模块改动先 message lead。
3. **构建串行**：只通过 `tools/build.ps1` 构建（自动加锁），失败重试前先看日志里的第一条错误（后续错误常是连锁反应）。
4. **汇报格式**（`send_message` 给 lead）：
   ```
   DONE <模块>: BUILD-OK
   - 交付文件: ...
   - 公开 API 变更: 无 / ...
   - 已知缺口/降级: ...
   - 需要 lead 处理: ...
   ```
   遇到阻塞（契约冲突、平台 API 不存在、无法修复的编译错误）立刻汇报，不要自己改契约。
5. **不要**修改 `build-logs/`、`.hvigor/`、`oh_modules/`、`build/`。
6. 队友之间不要互相等待：你需要的契约已落地；若缺 API，先按契约写并汇报，不要空转。

## 10. UI 设计系统与中文文案纪律（重构后强制）

### 10.1 设计令牌（唯一取色/取图入口）

- `chat/src/main/ets/app/Theme.ets`：
  - `Theme.*` 语义色（全部走 `app.color.*` 资源，`resources/dark/element/color.json` 自动切换深浅色）；
  - `Layout.*` 间距（s1..s8 / pagePadding）、圆角（radiusS/M/L/XL/Pill）、字号（fontCaption..fontHero）、行高、顶栏高度、透明度、动效时长；
  - `Icons.*` 鸿蒙系统符号（`SymbolGlyph(Icons.send)`，名称已对照本机 SDK `sysResource.js` 的 symbol 表核验）。
- **硬规则**：
  1. 禁止在任何 `.ets` 里写 `#RRGGBB` / `#AARRGGBB` 色值；颜色只能来自 `Theme.*`（或新增 `color.json` 键 + Theme 访问器，深浅两份必须同键）。
  2. 禁止用 ASCII 字符/emoji 当操作图标（`＋`、`▾`、`⚙` 等）；一律 `SymbolGlyph`。
  3. 间距/字号只能用 `Layout.*`，不要出现零散魔法数字（特殊排版除外，需注释原因）。
  4. **图标按钮统一走 `components/IconBtn.ets`**（v3.1：`Stack({alignContent:Alignment.Center})` + `SymbolGlyph` + `stateStyles` 按压微缩），不要直接给 `SymbolGlyph` 设宽高（会偏左上）；顶栏/抽屉/消息操作栏/输入栏复用同一容器。
  4. 数值语义色（记忆条占用）用 `Theme.memoryColor(ratio)`。

### 10.2 中文文案纪律（反「保姆式说明书」）

- **禁止**：`小提示：…`、`聊两句就…`、`会先在心里推理一遍…`、`要不要联网`、`问题想多深` 这类教学句/口语问句；选项组下方不写整句解释；底栏入口不写双行副标题。
- **要求**：标题/按钮用 2–4 字名词（`思考模式`、`联网模式`、`模型`、`能力`、`分支`、`新对话`）；状态用单行短句；解释信息放进图标 tooltip / 二级页 / 折叠区，不常驻主界面。
- 空状态只留一行品牌语 + 操作入口，不写教程段落。
- 未实现能力（如 L3 端侧脚本）**不在 UI 暴露**，不要用「当前构建未启用」之类的说明占位。

### 10.3 页面信息架构（v3.1 定稿：Pura X Max 5.4″外屏 / 7.7″阔内屏）

- **启动即主对话页**（`pages/ChatPage`）：**统一 Master-Detail 双栏架构**（`app/Breakpoint.ets`，≥600vp 展开态）：
  - 展开态：左侧常驻会话栏（232vp：新对话 / 收起 / 搜索 / 会话列表 / 底部创造室·技能·设置图标）+ 中间对话画布（内容最大 680vp）+ 按需右侧信源栏（288vp）；
  - 折叠态：单栏 + 左侧抽屉（78% / max 284vp），底部仅保留轻量入口；复杂页面走「列表 → 详情」二级栈。
- 顶栏 48vp（折叠态 44vp）：抽屉/收起图标 + 模型胶囊（模型名 · 6 档思考短标签 · chevron）+ 右：角色胶囊 + 新对话。
- 消息流：用户消息深色气泡（浅色模式 `#111827` 白字 / 深色模式品牌蓝白字，圆角 20 + 尾角 6，max 82%）；**AI 回复无气泡通栏**（15.5px / 行高 26）；思考与检索折叠为胶囊行（展开后左侧 2px 竖线 + 检索步骤 chips）；操作行 = 复制 / 重试 / 分支 `< 1/3 >` / 来源胶囊（展开态打开右侧信源栏，折叠态半模态）。
- 输入区：一体胶囊（圆角 24，`bgInput`，focus 品牌描边）：「+」**仅用于附件**（相册图片 / PDF 文档 / 网页链接）+ 自适应 TextArea + 圆形发送/停止；展开态输入框上方仅放「本对话技能」临时开关 chips；附件以 chips 展示在输入框上方。
- 记忆条：<60% 且未压缩时**完全隐藏**；60–85% / ≥85% / 整理中才出现 3px 进度条 + 百分比，点开一行状态 +「立即整理」。
- 技能创造室：Master-Detail（左可搜索技能列表 + 右 **SKILL.md 编辑器**：编辑/预览、试跑横幅、保存、底部 AI 改写）。
- 我的技能：Master-Detail（左列表 + 开关；右详情：全局启用、按 `configSchema` 动态参数卡、回滚/保存/删除/导出/试跑、域名 chips）。
- 设置：Master-Detail（左分类：**角色与提示词 / 模型与密钥 / 记忆与缓存 / 跨端与数据**；右详情）。角色配置为 Cherry Studio 级：名称、系统提示词（可插入 `{{date}}`/`{{clipboard}}`）、默认模型、6 档思考、Temperature 0–2、Top-P 0.1–1、轮数 4–50、默认绑定技能；支持新建/复制/删除/设为默认。
- 长按消息：复制 / 编辑 / 重新生成 / 切换分支 / 沉淀为技能。

### 10.4 v3 设计令牌关键值（与设计稿对齐，勿随意改）

| 令牌 | 浅色 | 深色 | 用途 |
| --- | --- | --- | --- |
| `bg_page` | `#FFFFFF` | `#0E1014` | 页面底色 |
| `bg_surface` | `#F5F6F8` | `#171A21` | 卡片/表面 |
| `bg_surface_2` | `#ECEEF2` | `#21252F` | 次级表面（选中/轨道） |
| `bg_input` | `#F3F4F7` | `#191C24` | 输入框/搜索框 |
| `bubble_user` | `#111827` | `#2563EB` | 用户气泡（白字） |
| `text_primary/secondary/tertiary` | `#111318` / `#5A6270` / `#8C94A3` | `#F2F4F8` / `#A1A9B8` / `#6D7585` | 文字三档 |
| `brand` | `#2563EB` | `#4F83FF` | 全站唯一品牌蓝（开关/选中/链接） |
| `violet` / `pink` | `#7C3AED` / `#EC4899` | `#8B5CF6` / `#F472B6` | 思考强度 High/xHigh 渐变与光晕（v3.3） |
| `border` | `#E6E8EE` | `#252934` | 边框/分割 |
| `warning` / `danger` | `#D97706` / `#DC2626` | `#F59E0B` / `#EF4444` | 记忆提醒 / 停止与错误 |

关键尺寸（`Layout`，v3.1）：顶栏 48（折叠态 44）、会话栏 232、技能/创造室栏 236、设置栏 220、信源栏 288、聊天内容最大宽 680、输入圆角 24、气泡 20/6、卡片 16、半模态顶部圆角 24（最大高度 82%）、抽屉 78%/max284；字号为原生舒适阶梯（fontCaption 11.5 / fontSmall 12.5 / fontUi 13.5 / fontBody 15 / fontChat 15.5 / fontTitle 16 / fontHeadline 17；lineChat 26 / lineBody 23 / lineTight 20）；图标按钮统一 `IconBtn`。

### 10.5 v3 功能模型

- **思考强度 6 档**（`ThinkingLevel`）：`off | min | low | med | high | xhigh`，UI 短标签「关闭 / Min / Low / Med / High / xHigh」；由 `EffortLevels` 管理，旧值 `quick/deep` 仅在迁移函数中出现。三厂商 Adapter 离线映射如下（`core_protocol` 已实现并自测 64 断言）：

  | 档位 | DeepSeek `reasoning.effort` | Anthropic `thinking.budget_tokens` | OpenAI 兼容 `reasoning_effort` |
  | --- | --- | --- | --- |
  | off | `none` | 不发 thinking | 不传 |
  | min | `low` | 1024 | `low` |
  | low | `low` | 2048 | `low` |
  | med | `medium`（服务端归一化 high） | 4096 | `medium` |
  | high | `high` | 8192 | `high` |
  | xhigh | `max` | 16384 | `high`（OpenAI 无 max 档） |

  约束：Anthropic 强制 `max_tokens > budget_tokens`；`supportsThinking=false` 时三厂商均不发送思考参数；OpenAI 推理模型与 `top_p` 互斥（发 `reasoning_effort` 时不通传 `top_p`）；Anthropic thinking 开启或已设 temperature 时不透传 `top_p`。
- **角色（Persona）**：`app/PersonaStore.ets` 持久化（Preferences JSON）；会话绑定角色（`persona.session.<id>`），新建对话继承全局默认角色（模型 + 思考档位）。
- **技能三级继承**：全局总开关（SkillRepository.enabled）⊂ 角色默认绑定（`PersonaProfile.defaultSkills`）⊂ 当前对话临时开关（`skill.override.<sessionId>`）；`PersonaStore.effectiveSkills` 计算，运行时只注入生效技能。
- **附件**：`AttachmentRef{kind: image|file|link}` → `CanonicalItem`（image / file_ref），随用户消息落盘。
- **角色头像（v3.2）**：`PersonaProfile.avatarIcon / avatarTone` 存 key 字符串；`app/PersonaAvatars.ets` 提供 10 个系统符号图标 + 8 个低饱和底色（`color.json` 的 `avatar_bg_*`，base/dark 各 46 键），旧数据缺字段时 sanitize 回退 `persona/blue`。

### 10.6 v3.2 模型目录与记忆透明化

- **真实模型注册表**：RDB 表 `provider_models(provider_id, model_id, display_name, meta_json, enabled, discovered_at)`（`core_model/impl/RdbRepository.ets` 实现 `ModelRegistryApi`）。`ModelCatalog.init()` 只装载 `enabled=true` 的记录并配厂商预设生成 `ModelProfile`；`hasModels()=false` 时顶栏显示「未选择模型」并引导去设置。
- **探测端点**（`core_protocol/ProtocolLayerFactory` + `util/RemoteModels.ets`）：

  | 厂商 | 端点 | 鉴权 |
  | --- | --- | --- |
  | DeepSeek | `GET {baseUrl}/models` | `Authorization: Bearer` |
  | Anthropic | `GET {baseUrl}/v1/models` | `x-api-key` + `anthropic-version: 2023-06-01` |
  | OpenAI 兼容 | `GET {baseUrl}/models`（已含 `/v1` 不重复拼） | `Authorization: Bearer` |

  `testConnection(profile, apiKeyOverride?)` / `listRemoteModels(profile, apiKeyOverride?)` 优先使用输入框里未保存的新 Key；`parseModelsResponse` 兼容 `data[] / models[] / 裸数组 / 字符串数组`，坏 JSON 返回 `[]`。
- **记忆整理透明化**：`RuntimeSnapshot` 暴露 `hasModel / lastCompactionAt / lastCompactionBeforeTokens / lastCompactionAfterTokens / lastCompactionSummary`；设置「记忆与缓存」卡展示当前会话 Token/窗口占比、缓存命中率，并支持「立即整理记忆」与最近整理前后对比 + 摘要展开。
- **SKILL.md 编解码**：`core_plugin/SkillMarkdown.ets` 的 `SkillMarkdownCodec`（manifest ↔ markdown），创造室/技能页共用。

