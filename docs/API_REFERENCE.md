# API_REFERENCE (generated 2026-11-19)

权威离线参考，供实现 Agent 直接照抄，**不要凭记忆改 API 名**。

来源与证据等级：

- `[C]` **CONFIRMED** — 文档原文 / `.d.ts` 原文（本节给出行号或引文）。
- `[I]` **INFERRED** — 由已确认事实推得，未在文档中逐字出现。
- `[U]` **未确认** — 文档未公布、或本地 SDK 无此内容；实现前必须实测或降级设计。

DeepSeek 文档来源（均于 2026-11-19 抓取，`.md` 端点可取到干净原文，例如
`https://api-docs.deepseek.com/zh-cn/api/create-response.md`）：

- https://api-docs.deepseek.com/zh-cn/api/create-response
- https://api-docs.deepseek.com/zh-cn/guides/responses_api
- https://api-docs.deepseek.com/zh-cn/guides/web_tools
- https://api-docs.deepseek.com/zh-cn/guides/search
- https://api-docs.deepseek.com/zh-cn/quick_start/pricing
- https://api-docs.deepseek.com/zh-cn/guides/kv_cache
- https://api-docs.deepseek.com/zh-cn/guides/conversation_title
- https://api-docs.deepseek.com/zh-cn/guides/thinking_mode

HarmonyOS 来源（本地 SDK，唯一事实源）：

- API 26 / SDK 根：`C:\Application\DevEco Studio\sdk\default`
- OpenHarmony：`...\openharmony\ets\{api,component,kits,arkts}`
- HMS：`...\hms\ets\{api,kits}`（rcp 在此）
- **ArkTS 语言规则**：`...\openharmony\ets\build-tools\ets-loader\node_modules\typescript\lib\typescript.js`
  内含 `ArkTSLinter_1_0/CookBookMsg` 与 `ArkTSLinter_1_1/CookBookMsg` 两套规则字符串（第 155862 / 159794 行起），
  这是本机可 grep 的 ArkTS 限制清单，见 §11。

---

## 0. TL;DR for implementers

- **端点**：`POST https://api.deepseek.com/responses`（不是 `/v1/responses`），`Authorization: Bearer <key>`。API 无状态，每轮必须回传完整 `input`。[C]
- **流终止**：以 `event: response.completed` / `response.incomplete` / `response.failed` 结束，**没有 `data: [DONE]`**。任何等待 `[DONE]` 的解析器会挂死到超时。[C]
- **事件双重标识**：SSE 的 `event:` 名与 `data` JSON 里的 `"type"` 字段相同，另带单调递增 `sequence_number`。用 `type` 分派即可。[C]
- **思维链**：`reasoning.effort` ∈ `none|low|high|max`，`none` 关闭；`minimal→low`、`medium|xhigh→high`。思考模式下 `temperature` 无效。[C]
- **推理文本**：`response.reasoning_text.delta` 的 `delta` 累加 → `reasoning` item 的 `reasoning_text` 块；最终答案 `response.output_text.delta`。[C]（事件名 C，字段 I）
- **用量只信终点事件**：`usage` 在初始事件里恒为 `null`，必须读 `response.completed` 里 `response.usage`；缓存命中在 `usage.input_tokens_details.cached_tokens`。[C]
- **标题**：请求加 `"title": {"enabled": true}`，流式从终点事件 `response.title` 读；最多等 5 秒；不计费；只在会话第一轮开。[C]
- **联网工具**：`deepseek_web_search` / `deepseek_read_url`（Responses API 里只写 `{"type": "..."}`，`name` 可省）。**`tool_choice` 绝不能指定这两个**（400）。[C]
- **多轮回传**：把上一轮 `output` 原样放回 `input`，**保留 `kind`、`signature`**；`read_link` 的网页正文靠 `signature` 还原，丢了就再也拼不回来。[C]
- **联网工具与 `tool_choice`**：声明联网工具时 `tool_choice:"required"` 被当作 `auto`；`none` 关闭全部工具（含 read_url）。[C]
- **搜索 API 独立计费**：`/v1/tools/search` 与 `/v1/tools/fetch` 每次成功请求 5 元/千次；模型服务端搜索自 2026-11-18 12:00 起不计费，只算 token。[C]
- **HTTP 客户端**：`import { rcp } from '@kit.RemoteCommunicationKit'`；`rcp.createSession()` + `new rcp.Request(...)` + `session.fetch(request)`。[C]
- **rcp 流式回调位置（最容易写错）**：`onDataReceive` 在 `Configuration.tracing.httpEventsHandler` 里，**不是** Request 顶层字段。[C]
- **rcp 超时**：`transfer.transferMs` 默认 60000 ms，长回答必被腰斩；流式必须显式放大 `transferMs` 并设 `inactivityMs`/`connectMs`。[C]
- **权限**：rcp 与 TCP server 都要 `ohos.permission.INTERNET`（当前项目 `chat/src/main/module.json5` **尚未声明任何 requestPermissions**，需补）。[C]
- **密钥存储**：`@ohos.security.asset`，`AssetMap = Map<Tag, Value>`（**Map，不是对象字面量**）；`Tag.SECRET`/`Tag.ALIAS` 值必须是 `Uint8Array`。[C]
- **会话库**：`@ohos.data.relationalStore`，`StoreConfig` 必须给 `securityLevel`（S1–S4）；事务用 `createTransaction()` + `commit()/rollback()`（`beginTransaction/commit/rollBack` 旧接口仍在但别用）。[C]
- **FTS**：SDK 只暴露 `Tokenizer`（`NONE_TOKENIZER|ICU_TOKENIZER|CUSTOM_TOKENIZER`）与 `isTokenizerSupported()`；`CREATE VIRTUAL TABLE ... USING fts5` 的 DDL 文本未在 d.ts 出现 → 中文检索方案见 §6，标 `[U]` 需实测。
- **无 LiveView API**：SDK 中不存在 `@ohos.app.ability.LiveView`。实况类能力只有 `LiveFormExtensionAbility`（FormKit，API 20+）与 `NotificationSystemLiveViewContent`（系统代理专用）。[C]
- **分享接收**：`ShareExtensionAbility` 存在（继承 `UIExtensionAbility`，无自有成员）；`wantConstant.Action` 在 `@ohos.app.ability.wantConstant` 中**只有 `ACTION_SEND_TO_DATA`**；`ACTION_VIEW_DATA` 只在已废弃的 FA 模块 `@ohos.ability.wantConstant`。[C]
- **ArkTS 无生成器**：本地 linter 规则 #94 `arkts-no-generators`，`async function*` 与 `for await` 一律不可用；SDK 中 0 处 `AsyncIterable`。[C]
- **因此流式接口用回调**：`startStream(onEvent)` / `onDelta(cb)` 风格，不要设计 `AsyncIterable<Delta>`。[I，由 #94 推出]
- **JSON.parse**：返回 `any`（lib.es5），ArkTS 禁 `any`，必须 `as` 到你声明的 `class`/`interface` 再逐字段取；不要解构、不要 `for..in`。[C§11]

---

## 1. DeepSeek Responses API

### 1.1 端点与鉴权 `[C]`

```http
POST https://api.deepseek.com/responses
Authorization: Bearer <DEEPSEEK_API_KEY>
Content-Type: application/json
Accept: text/event-stream        # stream:true 时；非流式用 application/json
```

> 原文：“该 API 是**无状态**的：服务端不存储响应与会话。多轮对话需要客户端在每次请求的 `input` 中回传完整对话历史。”
> `previous_response_id` / `conversation` / `store` 均不支持；响应里 `store` 恒为 `false`。

### 1.2 请求体（`CreateResponseRequest`，`required: ["model"]`）`[C]`

| 字段 | 类型 | 必填 | 取值 / 说明 |
|---|---|---|---|
| `model` | string | ✅ | `deepseek-flash` \| `deepseek-v4-pro`（只有这两个） |
| `input` | string \| object[] | — | 纯字符串 = 一条 `user` 消息；或 item 列表。`input` 与 `instructions` 至少一个 |
| `instructions` | string \| null | — | 作为上下文第一条 system 消息 |
| `reasoning` | object | — | `{ "effort": "none"\|"low"\|"high"\|"max" }`；不传=默认开启 |
| `max_output_tokens` | integer | — | 含可见输出 + 思维链 |
| `stream` | boolean | — | 默认 `false` |
| `temperature` | number | — | `[0,2]`，默认 1；**思考模式下不生效** |
| `top_p` | number | — | 见下方模型差异 |
| `text` | object | — | `{"format":{"type":"text"}}` \| `{"type":"json_object"}` \| `{"type":"json_schema","name":..,"schema":..}` |
| `tools` | object[] | — | `type` ∈ `function` \| `custom` \| `web_search` \| `deepseek_web_search` \| `deepseek_read_url` |
| `tool_choice` | string \| object | — | `none` \| `auto`(默认) \| `required` \| `{"type":"function","name":"..."}` |
| `top_logprobs` | integer | — | `[0,20]` |
| `user` | string | — | ≤512 bytes，勿放隐私 |
| `safety_check` | object | — | DeepSeek 扩展：`{"level":"low"\|"high"}` |
| `title` | object | — | DeepSeek 扩展：`{"enabled":true}` |

`top_p` 行为（原文）[C]：

- `deepseek-flash`：思考模式默认 1.0，低于 0.95 按 0.95；非思考模式恒 1.0，传值被忽略。
- `deepseek-v4-pro`：思考模式启用工具调用时恒 0.95，否则 1.0（传值忽略）；非思考模式生效，默认 1.0。

**被静默忽略**（不报错，别指望生效）：`parallel_tool_calls`、`max_tool_calls`、`background`、`metadata`、`include`、`prompt`、`truncation`、`service_tier`、`safety_identifier`、`prompt_cache_key`、`prompt_cache_retention`、`context_management`、`stream_options`、`prefix`（Responses API 不支持续写）。[C]

`input` item 类型：[C]

- 支持：`message` / `function_call` / `function_call_output` / `custom_tool_call` / `custom_tool_call_output` / `reasoning` / `web_search_call`；其他类型被忽略。
- 角色：`user` / `assistant` / `system` / `developer`（`developer` 在 flash 上等同 `system`，在 v4-pro 上等同 `user`）。
- `deepseek-flash` 支持 `input_image`（`image_url` 或 `file_id`）；`assistant` 消息里的图片 → 400；`file_url` 不支持。
- `function_call` 会“归并到相邻 assistant 消息”；`reasoning` 的明文 `content` 同样归并。

### 1.3 SSE 帧格式 `[C]`

```
event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":"Hello","item_id":"7b65…","logprobs":[],"output_index":0,"sequence_number":4}
```

- 每条事件：一行 `event: <name>`、一行 `data: <单行 JSON>`、空行结束。
- `data` 内 `type` == `event` 名；`sequence_number` 从 0 递增，可用于丢包/乱序检测。
- **终止事件**：`response.completed` | `response.incomplete` | `response.failed`。**无 `data: [DONE]`**。
- `: keep-alive` 注释帧：Messages 协议明确有；Responses 未逐字说明 → `[U]`，解析器应按 SSE 规范忽略 `:` 开头行（这也无害）。

### 1.4 事件清单与载荷骨架

**A. 生命周期（载荷逐字来自文档示例）** `[C]`

```jsonc
// event: response.created   (sequence_number: 0)
{"type":"response.created","response":{
  "id":"19460ef2-…","object":"response","created_at":1793084908,"status":"in_progress",
  "background":false,"completed_at":null,"content_filters":null,"error":null,
  "incomplete_details":null,"instructions":null,"max_output_tokens":32,"max_tool_calls":null,
  "model":"deepseek-flash","moderation":null,"output":[],"parallel_tool_calls":true,
  "previous_response_id":null,"prompt_cache_key":null,"prompt_cache_retention":null,
  "reasoning":{"effort":"none","summary":null},"safety_identifier":null,"service_tier":"default",
  "store":false,"temperature":1.0,"text":{"format":{"type":"text"},"verbosity":null},
  "tool_choice":"auto","tools":[],"top_logprobs":0,"top_p":1.0,"truncation":"disabled",
  "usage":null,"user":null,"metadata":{}},"sequence_number":0}

// event: response.in_progress  —— 同上，response.status 仍是 "in_progress"，sequence_number: 1
```

**B. 输出 item / 内容块骨架** `[C]`

```jsonc
// event: response.output_item.added
{"type":"response.output_item.added",
 "item":{"type":"message","id":"7b653eb5-…","status":"in_progress","content":[],
         "phase":"final_answer","role":"assistant"},
 "output_index":0,"sequence_number":2}

// event: response.content_part.added
{"type":"response.content_part.added","content_index":0,"item_id":"7b65…","output_index":0,
 "part":{"type":"output_text","annotations":[],"logprobs":[],"text":""},"sequence_number":3}

// event: response.output_text.delta
{"type":"response.output_text.delta","content_index":0,"delta":"Hello",
 "item_id":"7b65…","logprobs":[],"output_index":0,"sequence_number":4}

// event: response.output_text.done（一次性给全文）
{"type":"response.output_text.done","content_index":0,"item_id":"7b65…","logprobs":[],
 "output_index":0,"sequence_number":14,"text":"Hello! 👋 How can I help you today?"}

// event: response.content_part.done
{"type":"response.content_part.done","content_index":0,"item_id":"7b65…","output_index":0,
 "part":{"type":"output_text","annotations":[],"logprobs":[],"text":"Hello! 👋 …"},"sequence_number":15}

// event: response.output_item.done
{"type":"response.output_item.done",
 "item":{"type":"message","id":"7b65…","status":"completed",
         "content":[{"type":"output_text","annotations":[],"logprobs":[],"text":"Hello! 👋 …"}],
         "phase":"final_answer","role":"assistant"},
 "output_index":0,"sequence_number":16}
```

> 注意 `item.phase: "final_answer"` —— 这是 message item 上的 DeepSeek 扩展字段，官方示例里出现，未在 schema 表里说明；不要依赖它做业务判断（`[I]`）。

**C. 思维链（名称 `[C]`，载荷 `[I]`）**

事件名（文档表格原文）：`response.reasoning_text.delta` / `response.reasoning_text.done`。

```jsonc
// [I] 未给出字面示例，按 OpenAI 同构 + 本 API 的 content_index 约定推断
{"type":"response.reasoning_text.delta","item_id":"<reasoning item id>","output_index":0,
 "content_index":0,"delta":"……","sequence_number":N}
{"type":"response.reasoning_text.done","item_id":"<reasoning item id>","output_index":0,
 "content_index":0,"text":"……","sequence_number":N}
```

- 思考以 `reasoning` item 出现在 `message` item **之前**；其 `content` 是 `reasoning_text` 块列表（明文，非 `encrypted_content`）。[C]
- 联网工具场景：“思考是一个 `reasoning` item，内容为 `reasoning_text`，`summary` 为空，不返回 `encrypted_content`。”[C]
- 实现建议：只依赖 `response.reasoning_text.delta` 的 `delta` 字符串与 `item_id`；若 `content_index` 缺失按 0 处理。**首次联调必须打印原始 `data` 校验。** 

**D. 函数调用（名称 `[C]`，载荷 `[I]`）**

事件：`response.function_call_arguments.delta` / `.done`。
`function_call` item 字段（`[C]` schema）：`type`、`id`、`status`、`call_id`、`name`、`arguments`（JSON **字符串**，可能非法/含未定义参数，调用前必须校验）。

```jsonc
// [I] 推断形态
{"type":"response.function_call_arguments.delta","item_id":"<fc item id>","output_index":1,
 "delta":"{\"loc","sequence_number":N}
{"type":"response.function_call_arguments.done","item_id":"<fc item id>","output_index":1,
 "arguments":"{\"location\":\"Beijing\"}","sequence_number":N}
```

回传结果用 `function_call_output`，`call_id` 必须配对：`{"type":"function_call_output","call_id":"fc1","output":"…"}`。[C]

**E. 服务端网页搜索生命周期** `[C]`

事件名（三件套，原文）：`response.web_search_call.in_progress` / `response.web_search_call.searching` / `response.web_search_call.completed`。

文档说明（原文，Responses 段）：

> “一次调用依次产生 `response.output_item.added`（带完整的 `action`）、`response.web_search_call.in_progress`、`response.web_search_call.searching`、`response.web_search_call.completed`，以及带 `sources`、`page`、`signature` 或 `error` 的 `response.output_item.done`。”
> “多个调用同时进行时，先全部 added，再逐个完成。请按 `output_index` 对应事件。”

即：**`searching/in_progress/completed` 三个事件的 `data` 载荷文档未给字面示例 → `[U]`**，但可确定它们必带 `type`、`item_id`（或 `output_index`）用于关联；渲染状态时以 `output_item.added`（含完整 `action`）与 `output_item.done`（含 `sources/page/signature/error`）为准，把中间三件套仅当作“进度信号”。

`web_search_call` item 的完整字段（`[C]`，逐字来自 web_tools 指南）：

```jsonc
{
  "type": "web_search_call",
  "id": "srvtoolu_s_00_3f2a9c...",
  "status": "completed",                       // in_progress | completed | incomplete | failed
  "kind": "search",                            // search | deep_search | read_link | image_search | deep_image_search
  "action": {
    "type": "search",                          // search | open_page | find_in_page
    "queries": ["DeepSeek V4.1"],
    "sources": [
      {"type":"url","url":"https://example.com/news","title":"...","snippet":"...",
       "site_name":"Example News","site_icon":"https://cdn.deepseek.com/site-icons/example.com",
       "published_at":"2026-01-02T03:04:05+00:00"}
    ]
  }
}
```

| `output[].kind` | `action.type` | 其他字段 |
|---|---|---|
| `search`、`deep_search`、`image_search`、`deep_image_search` | `search` | `action.queries` + `action.sources[]`（带 `title/snippet/site_name/site_icon/published_at`） |
| `deep_search` | `open_page` 或 `find_in_page`（带 `pattern`） | 打开网页时有 `page: {url,title,published_at}` |
| `read_link` | `open_page` | `page`；成功时另有 `signature` |

- 失败：`status:"failed"` + `error:{code}`，`code` ∈ `unavailable` \| `url_not_accessible` \| `url_not_allowed`。[C]
- `page` **不含网页正文**（`page` 只有 url/title/published_at）；正文只在 `signature` 里。[C]
- 引用：回答是 `message` item，`output_text` 通过 **`response.output_text.annotation.added`** 事件逐条下发 `url_citation` 注解；`start_index`/`end_index` 按 **Unicode 码点**计数，`title` 未知时为空字符串。[C]（注解事件名 C，注解体字段 C）
- 配图检索：图片搜索的 `kind` 为 `image_search`/`deep_image_search`，`queries` 为空数组，每条结果多一个 `image_url`（仅供展示，不保证可访问）。[C]

**F. 终点事件（逐字示例）** `[C]`

```jsonc
// event: response.completed  (sequence_number: 17)
{"type":"response.completed","response":{
  "id":"19460ef2-…","object":"response","created_at":1793084908,"status":"completed",
  "background":false,"completed_at":1793084909,"content_filters":null,"error":null,
  "incomplete_details":null,"instructions":null,"max_output_tokens":32,"max_tool_calls":null,
  "model":"deepseek-flash","moderation":null,
  "output":[{"type":"message","id":"7b65…","status":"completed",
             "content":[{"type":"output_text","annotations":[],"logprobs":[],"text":"Hello! 👋 How can I help you today?"}],
             "phase":"final_answer","role":"assistant"}],
  "parallel_tool_calls":true,"previous_response_id":null,"prompt_cache_key":null,
  "prompt_cache_retention":null,"reasoning":{"effort":"none","summary":null},
  "safety_identifier":null,"service_tier":"default","store":false,"temperature":1.0,
  "text":{"format":{"type":"text"},"verbosity":null},"tool_choice":"auto","tools":[],
  "top_logprobs":0,"top_p":1.0,"truncation":"disabled",
  "usage":{"input_tokens":7,
           "input_tokens_details":{"cached_tokens":0},
           "output_tokens":11,
           "output_tokens_details":{"reasoning_tokens":0},
           "total_tokens":18},
  "user":null,"metadata":{}},"sequence_number":17}
```

`usage` 完整字段（schema）`[C]`：

```jsonc
{
  "input_tokens": 3475,
  "input_tokens_details": {"cached_tokens": 512},           // ← 缓存命中
  "output_tokens": 54,
  "output_tokens_details": {"reasoning_tokens": 0,         // 思维链 token
                            "safety_tokens": 0},           // 仅 safety_check=high 时出现，已含在 output_tokens 内
  "total_tokens": 3529,
  "server_tool_use": {                                     // 三项全 0 时整个字段省略
    "tool_search": 1, "tool_fetch": 0, "tool_image_search": 0
  }
}
```

> `server_tool_use` 是**整轮累计值**，不是增量；“接口不会单独发送工具用量事件，初始响应事件中的 `usage` 为 `null`”。[C]

`response.incomplete`：`status:"incomplete"`，`incomplete_details.reason` ∈ `max_output_tokens` | `content_filter`。[C]
`response.failed`：`status:"failed"`，`error:{code,message}`，`error.code` 为 `server_error`（生成中途失败时 HTTP 仍是 200）。[C]

### 1.5 标题（title）`[C]`

- 请求：顶层 `"title": {"enabled": true}`（与 `tools`、`safety_check` 同级）。
- 位置：非流式 → 顶层 `title`；流式 → **终点事件里的 `response.title`**（`response.completed` 的 `response` 对象）。
- 原文：“回答结束后，响应最多等待标题 5 秒才结束。建议只在会话的第一次请求上开启”；“标题不计费”；拒答/出错时可能没有标题 → 自行兜底（取首条用户消息前 N 字）。
- 类型：string。

### 1.6 请求示例（可直接跑）`[C]`

```bash
curl --silent --show-error --max-time 60 "https://api.deepseek.com/responses" \
  --header "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
  --header "Content-Type: application/json" \
  --data '{
  "model": "deepseek-flash",
  "input": "Say hello.",
  "max_output_tokens": 32,
  "reasoning": {"effort": "none"},
  "stream": false
}'
```

### 1.7 坑（实现必看）

1. 终点事件里 `response.output[]` 是**全量**，可用它覆盖/校正增量拼装结果（自愈）。[I]
2. `output_text` 的 `annotations` 也在 `output_text.done` 里出现；引用角标要按码点切片，不是 UTF-16 码元。[C]
3. 上下文超限：`truncation` 不支持，超窗口直接 **400**，必须客户端裁剪。[C]
4. `input` 以 `assistant` 的 `message` 或 `reasoning` item 结尾 → **400**（不支持续写）。[C]
5. 声明联网工具后：`text.format != text`、`top_logprobs`、`previous_response_id`、`conversation` → 400；`input` 里出现 `item_reference` 或未知 item → 400。[C]
6. 并行工具调用始终开启，`parallel_tool_calls` 传了也被忽略。[C]

---

## 2. DeepSeek Search & Fetch API

### 2.1 端点 `[C]`

| API | Endpoint |
|---|---|
| Search | `POST https://api.deepseek.com/v1/tools/search` |
| Fetch | `POST https://api.deepseek.com/v1/tools/fetch` |

请求头：`Authorization: Bearer <key>`、`Content-Type: application/json`。原始 JSON API，与模型接口同一套鉴权。

### 2.2 Search 请求字段 `[C]`

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `query` | string | ✅ | — | 1–128 个 Unicode 字符，不能全空白，支持搜索语法 |
| `count` | integer | — | `10` | 返回条数 1–50（**不是** `max_results` / `top_k`） |
| `ori_question` | string | — | — | 触发搜索的用户原始问题，1–128 字符，帮助理解意图；`null` 视同未提供 |
| `localization` | string | — | `""` | 用于优先本地化结果的 IP 地址 |
| `need_content` | boolean | — | `false` | 是否在 `content` 返回正文；`false` 时 `content` 恒为空串 |

未知字段被忽略（`[C]`）。`summary`/`snippet` 长度由服务端决定：`snippet` 通常 100–200 字符（前端展示用），`summary` 通常 600–800 字符（喂模型用）——**没有长度参数**。

### 2.3 搜索语法（`query` 内联，原样透传）`[C]`

| 操作符 | 示例 | 说明 |
|---|---|---|
| `site:` | `DeepSeek site:github.com` | 限定站点；多个用空格 + `OR`：`site:github.com OR site:huggingface.co` |
| `-site:` | `DeepSeek -site:example.com` | 排除站点，多个空格分隔 |
| `-` | `DeepSeek -广告` | 排除含关键词网页 |
| `-"..."` | `DeepSeek -"release notes"` | 排除短语 |
| `"..."` | `DeepSeek "精确短语"` | 精确匹配 |
| `lang:` | `DeepSeek lang:zh,en` | 限定语言，逗号分隔 |
| `after:` | `after:2025` / `after:2025-01-01` | 发布日期下界 |
| `before:` | `before:2026` / `before:2026-06-01` | 发布日期上界 |

### 2.4 Search 响应 `[C]`

```json
{
  "results": [
    {
      "rerank_score": 2.4,
      "title": "DeepSeek V4 模型发布",
      "url": "https://example.com/deepseek-v4",
      "snippet": "短摘要（100–200 字符，前端展示用）",
      "summary": "长摘要（600–800 字符，给模型读）",
      "content": "网页正文，need_content=false 或正文缺失时为空字符串",
      "site_name": "Example News",
      "site_icon": "https://example.com/favicon.ico",
      "date": "2026-06-01T00:00:00+00:00",
      "authority": 3
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `rerank_score` | number | 0–3，综合相关性/权威性/时效性；**≥1.5 为优质结果** |
| `title` | string | 标题 |
| `url` | string | 链接 |
| `snippet` | string | 短摘要 |
| `summary` | string | 长摘要 |
| `content` | string | 正文，`need_content:false` 或缺失时为空串 |
| `site_name` | string \| null | 缺失为 `null` |
| `site_icon` | string \| null | 缺失为 `null` |
| `date` | string \| null | RFC 3339 UTC；未知为 `null` |
| `authority` | integer | 0–4（`-1` 未知）；**≥3 为极权威** |

无结果时返回空数组 `{"results": []}`，HTTP 200。

### 2.5 Fetch `[C]`

请求：`{"url": "<http(s) URL，≤8192 字符，含 host，不得带用户名/密码>"}`

响应：

```json
{ "title": "Example article", "content": "# Example article\n\nArticle content." }
```

`content` 是抓取后的 **Markdown** 正文；`title` 缺失为空字符串。

### 2.6 错误码 `[C]`

| HTTP | 含义 |
|---|---|
| 400 | 头/体不合法、JSON 错、字段值非法 |
| 401 | Key 缺失或无效 |
| 402 | 余额不足（充值后重试） |
| 403 | Fetch 被安全策略拒绝 |
| 404 | Fetch 拿不到可用网页内容（不可达/被拦/类型不支持/无可提取正文） |
| 408 | 读请求体超时（可重试） |
| 413 | 请求体超限 |
| 429 | 超过 QPS（可重试） |
| 500 / 504 | 服务端错误 / 下游超时（可重试） |

错误体（OpenAI 兼容，`param` 恒 `null`）：

```json
{"error":{"message":"'count' must be between 1 and 50","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}
```

除 408/429/5xx 与 402 外，其他 4xx 不要重试。

### 2.7 限速与计费 `[C]`

| API | QPS（账号粒度，与 Key 无关） | 价格 |
|---|---|---|
| Search | 100 | 5 元 / 1,000 次成功请求 |
| Fetch | 25 | 5 元 / 1,000 次成功请求 |

- 计费条件：HTTP 200 **且**有产出（Search 的 `results` 非空，Fetch 必须返回正文）。失败、无结果、超时不计费；`count` 不影响单价。
- Fetch 另受**目标域名**级 QPS 限制（超了也是 429）。

---

## 3. DeepSeek web tools + 多轮 signature

### 3.1 工具名与声明 `[C]`

服务端工具（Responses API，`tools` 数组）：

```json
{
  "model": "deepseek-flash",
  "input": "DeepSeek V4.1 有什么新功能？",
  "tools": [
    {"type": "deepseek_web_search"},
    {"type": "deepseek_read_url"}
  ],
  "safety_check": {"level": "high"},
  "stream": true
}
```

- 工具名就是 `deepseek_web_search` 与 `deepseek_read_url`（Responses API 只需 `type`，`name` 可省；Messages API 需 `{"type":"…","name":"…"}`）。[C]
- 能力映射：联网搜索 = `deepseek_web_search` + **关闭思考**；深度思考搜索 = `deepseek_web_search` + **开启思考**；阅读链接 = `deepseek_read_url`。[C]
- 官方建议：“请使用 `deepseek-flash` 模型。”（联网工具文档首段）

### 3.2 强制规则（违反即 400）`[C]`

> 原文：“`tool_choice` 不能指定 `deepseek_web_search` 或 `deepseek_read_url`，否则返回 `400`：是否搜索或阅读链接由模型判断。`tool_choice` 为 `none` 时关闭全部工具，包括阅读链接。”

- 声明联网工具时 `tool_choice: "required"` **按 `auto` 处理**（不报错，但别依赖）。[C]
- 不能与 `web_search` 同时声明；也不支持 `custom`、`namespace`、`tool_search`（→400）；其他无法识别的工具类型被忽略。[C]
- 声明了其他服务端工具 → 错误信息原文：``tools: other tools cannot be used together with `deepseek_web_search`, `deepseek_read_url`, `safety_check` or `title` yet``。
- 同一工具声明两次 → ``tools: `deepseek_web_search` can only be declared once``。
- 带 `allowed_domains` / `blocked_domains` / `user_location` → `` `allowed_domains` is not supported by `deepseek_web_search` ``。

### 3.3 自主搜索上限 `[C]`

- 深度思考搜索：“模型最多调用约 20 次工具后作答。”
- 阅读链接：只在**最后一条用户消息**里识别 URL，重复 URL 只算一个，**最多考虑前 10 个不同 URL**，由模型决定读哪些。
- 一轮 = 从一条用户消息到模型给出最终回答（对应一次请求）。开启思考且声明了 `deepseek_web_search` 时，本轮走深度思考搜索，**不单独阅读链接**。

### 3.4 多轮回传规则（本项目的关键）`[C]`

1. 每次请求携带完整历史，**把上一轮的 `output` item 原样放回 `input`，保留 `kind` 和 `signature`**。
2. 搜索结果、打开过的网页、之前轮次的思考**不会**进入后续轮次上下文，只保留回答正文。
3. 带联网工具块的历史消息可以发给**没有**声明这些工具的请求。
4. `read_link` 的网页正文由 `signature` 还原，拼到**该轮用户消息的末尾**；`signature` 无效时该网页不拼回，请求仍正常执行。
5. `url`/`title`/`data`/`published_at` 仅供展示，回传前改它们不影响结果；`signature` 必须原样。
6. 用过联网工具的回复**不能续写**（Messages 返回 400；Responses 侧本就不支持续写）。

可回传的 item 最小形状（Responses）`[I]`：直接把收到的 `web_search_call` item（含 `kind`、`action`、`page`、`signature`、`status`）作为 `input` 的一项。

### 3.5 用户可见文案的字段来源 `[C]`

| UI 元素 | 数据来源 |
|---|---|
| 搜索进度（“正在搜索…/搜索完成”） | `response.web_search_call.in_progress/searching/completed` |
| 搜索词 chip | `web_search_call.action.queries` |
| 来源卡片 | `action.sources[]` 的 `title`/`url`/`snippet`/`site_name`/`site_icon`/`published_at` |
| 打开的网页 | `web_search_call.page`（url/title/published_at，**无正文**） |
| 页内查找 | `action.type == "find_in_page"` + `action.pattern` |
| 失败态 | `status:"failed"` + `error.code` |
| 正文引用角标 | `response.output_text.annotation.added` 的 `url_citation`（start/end 按码点） |

---

## 4. Pricing & caching constants

### 4.1 模型与价格（元 / 百万 tokens）`[C]`

| | deepseek-flash | deepseek-v4-pro |
|---|---|---|
| 模型版本 | DeepSeek-V4.1-Flash-1017 | DeepSeek-V4-Pro-0813 |
| 上下文长度 | **1M** | **1M** |
| 最大输出 | **384K** | **384K** |
| 输入（缓存命中）空闲 / 高峰 | **0.02 / 0.04** | 0.15 / 0.30 |
| 输入（缓存未命中）空闲 / 高峰 | **1 / 2** | 4.5 / 9.0 |
| 输出 空闲 / 高峰 | **4 / 8** | 13.5 / 27.0 |
| 并发限制 | 2500 | 500 |

- 空闲价 = 高峰价的一半。**高峰时段**：北京时间周一至周五（不含中国法定节假日）**9:00–12:00、14:00–18:00**；其余（含周末、法定节假日全天）为空闲。[C]
- 旧名 `deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 仍可调用，由 V4.1-Flash-1017 服务并按 Flash 价计费。[C]
- 视觉：图像理解 flash 支持、v4-pro 不支持。[C]

### 4.2 缓存 `[C]`

- 上下文硬盘缓存**默认开启**，无需改代码；缓存命中数在 `usage.input_tokens_details.cached_tokens`（Responses）/ `prompt_cache_hit_tokens`（Chat Completions）。
- **没有公布固定 TTL**。原文：“缓存构建耗时为秒级。缓存不再使用后会自动被清空，时间一般为**几个小时到几天**”；“缓存系统是‘尽力而为’，不保证 100% 缓存命中”。
- 命中前提是**完整匹配“缓存前缀单元”**：请求结束位置（用户输入末尾、模型输出末尾）各落盘一个单元；检测到多次请求公共前缀时把该前缀落盘；长输入/输出按固定 token 间隔落盘。
  - 推论 `[I]`：多轮拼接时不要重排历史、不要动态改写 system 段、不要在中途插入临时消息，否则前缀单元断裂、缓存命中率骤降。
- 缓存只匹配输入前缀，输出仍重算，`temperature` 仍然生效。

### 4.3 服务端工具计费 `[C]`

- 自北京时间 **2026-11-18 12:00** 起，调用模型时触发的服务端搜索/抓取**工具调用本身不再计费**，只有 token 计费。
- 客户端直连 Search/Fetch API 仍按 §2.7 计费。
- 文件解析/OCR：1.5 元 / 1,000 页；TTS 3 元/万字符（限时 1.5）；ASR 0.78 元/小时（限时 0.39）。

---

## 5. HarmonyOS rcp streaming（exact API + skeleton）

文件：`...\hms\ets\api\@hms.collaboration.rcp.d.ts`（6109 行）、`...\hms\ets\kits\@kit.RemoteCommunicationKit.d.ts`。

### 5.1 导入（逐字）`[C]`

```ts
// kits\@kit.RemoteCommunicationKit.d.ts
import rcp from '@hms.collaboration.rcp';
import urpc from '@hms.collaboration.urpc';
export { rcp, urpc };
```

```ts
import { rcp } from '@kit.RemoteCommunicationKit';   // ← 项目里用这个
```

> 注意：源码里是 `export { rcp }`（具名），**不是 default**。`import rcp from ...` 只在 kit 内部成立。

### 5.2 关键签名（逐字）`[C]`

```ts
export type URLOrString = URL | string;                                     // L720
export type HttpMethod = 'GET' | 'POST' | 'HEAD' | 'PUT' | 'DELETE' | 'PATCH' | 'OPTIONS' | (string & NonNullable<unknown>);
export type RequestHeaders = { [k: string]: string | string[] | undefined; 'authorization'?: string; 'content-type'?: ContentType; /* … */ };
export type RawDataContent = string | ArrayBuffer | object;                  // L78
export type RequestContent = RawDataContent | Form | MultipartForm | GetDataCallback | UploadFromFile | UploadFromStream | INetworkInputQueue;
export type HttpVersion = '1.0' | '1.1' | '2' | '3' | 'unknown';             // L3044

export class Request {                                                       // L2661
  readonly id: string;
  url: URL;
  method: HttpMethod;               // 默认 'GET'
  headers?: RequestHeaders;
  content?: RequestContent;
  configuration?: Configuration;    // 覆盖会话级配置
  destination?: ResponseBodyDestination;   // since 5.0.0(12)
  connectOnly?: boolean;            // since 6.1.1(24)
  constructor(url: URLOrString, method?: HttpMethod, headers?: RequestHeaders,
              content?: RequestContent, cookies?: RequestCookies,
              transferRange?: TransferRange | TransferRange[], configuration?: Configuration);   // L2775
}

export interface Session {                                                   // L3527
  readonly id: string;
  fetch(request: Request): Promise<Response>;      // L3610，@permission ohos.permission.INTERNET
  get(url: URLOrString, destination?: ResponseBodyDestination): Promise<Response>;
  post(url: URLOrString, content?: RequestContent, destination?: ResponseBodyDestination): Promise<Response>;
  put(url: URLOrString, content?: RequestContent, destination?: ResponseBodyDestination): Promise<Response>;
  delete(url: URLOrString): Promise<Response>;
  cancel(requestToCancel?: Request | Request[]): void;   // 不传 = 取消会话内全部请求
  close(): void;
}

export function createSession(sessionConfiguration?: SessionConfiguration): Session;   // L4323
// 起始 5.1.0(18) 最多 1024 个 Session，用完务必 close()，否则 1007900994 Sessions number reached limit

export interface Response {                                                  // L3052
  readonly request: Request;
  readonly statusCode: number;
  readonly headers: ResponseHeaders;
  readonly body?: ArrayBuffer;          // 默认上限 50MB；超限必须用 onDataReceive 流式
  readonly httpVersion?: HttpVersion;   // since 5.0.0(12)
  readonly effectiveUrl?: URL;
  readonly debugInfo?: DebugInfo[];
  readonly timeInfo?: TimeInfo;
  readonly cookies?: ResponseCookie[];
  readonly reasonPhrase?: string;       // since 5.0.0(12)
  readonly cacheInfo?: CacheInfo;
  toString(): string | null;
  toJSON(): object | null;
  toJSON(param: json.ParseOptions): object | null;   // since 6.1.0(23)
}
```

### 5.3 流式回调（**位置是最大的坑**）`[C]`

```ts
export type OnDataReceive = (incomingData: ArrayBuffer, request?: Request) => number | void | Promise<void>;   // L2246
export type OnHeaderReceive = (headers: ResponseHeaders, request?: Request) => void;                            // L2279
export type OnDataEnd = (request?: Request) => void;                                                            // L2288
export type OnCanceled = (request?: Request) => void;                                                           // L2297
export type OnStatusCodeReceive = (statusCode: number, request?: Request) => void;                              // L2329
export type OnTimeInfo = (timeInfo: TimeInfo, request?: Request) => void;

export interface HttpEventsHandler {          // L2337
  onDataReceive?: OnDataReceive;
  onUploadProgress?: OnUploadProgress;
  onDownloadProgress?: OnDownloadProgress;
  onHeaderReceive?: OnHeaderReceive;
  onDataEnd?: OnDataEnd;
  onCanceled?: OnCanceled;
  onTimeInfo?: OnTimeInfo;              // since 5.0.3(15)
  onStatusCodeReceive?: OnStatusCodeReceive;   // since 6.0.0(20)
}
```

它挂在 **`TracingConfiguration`** 上（L1467），而 `TracingConfiguration` 属于 `Configuration.tracing`（L2127）：

```ts
export interface Configuration {
  transfer?: TransferConfiguration;
  tracing?: TracingConfiguration;     // ← httpEventsHandler 在这里
  proxy?: ProxyConfiguration;
  dns?: DnsConfiguration;
  security?: SecurityConfiguration;
  processing?: ProcessingConfiguration;
  cache?: ResponseCache;
}
```

所以两条路径：`request.configuration.tracing.httpEventsHandler` 或 `createSession({ requestConfiguration: { tracing: { httpEventsHandler } } })`。
`request.configuration` 会**替换**会话级配置（不是深合并）→ 如果 Request 上设了 configuration，会话里的 tracing 也要一起写。[I，由“will be used to replace the default or session-range configuration”推出]

`onDataReceive` 语义：`[C]` 原文“Callback triggered when a part of an HTTP response body is returned… Use this callback to receive data when the data size exceeds 50 MB. Then the **body** field of the returned Response object will no longer contain data.”
→ **一旦用了 `onDataReceive`，不要指望 `response.body` 里还有内容**（`[I]` 基于该 NOTE）。返回值类型是 `number | void | Promise<void>`，文档未说明 `number` 的含义（推测为“已消费字节数/流控”），**`[U]`：返回 `void` 是安全的**。

另一条等价通道（更简单，无 status/headers 回调）：`request.destination`

```ts
export type IncomingDataCallback = (incomingData: ArrayBuffer) => void | Promise<void>;   // L292
export type ResponseBodyDestination = 'array-buffer' | IncomingDataCallback | DownloadToFile | DownloadToStream | INetworkOutputQueue;
```

### 5.4 超时与 HTTP/2 `[C]`

```ts
export interface Timeout {          // L1010
  connectMs?: number;      // 默认 60000
  transferMs?: number;     // 默认 60000  ← 长回答必被截断，流式必须放大
  inactivityMs?: number;   // since 5.0.0(12)，默认“不限制”
}
export interface TransferConfiguration {   // L1319
  autoRedirect?: boolean;              // 默认 true
  maxAutoRedirects?: number;           // 默认 50
  timeout?: Timeout;
  assumesHTTP3Capable?: boolean;
  pathPreference?: 'auto' | 'cellular';
  serviceType?: ServiceType;           // 'default'|'background'|'realtimeVoice'|…|'browser'
  pausePolicy?: PausePolicy;
  tcp?: TcpConfiguration;
  connectionReusePolicy?: ConnectionReusePolicy;         // since 6.1.0(23)，默认 'naive'
  httpVersionSelectCallback?: HttpVersionSelectCallback; // since 26.0.0 ← 本项目 API 26 可用
  throwErrorWhenEnableCellularFailed?: boolean;
}
export type HttpVersionSelectCallback = (url: URL) => HttpVersion;   // L1310
```

**HTTP/2 明确路径**（按可靠性排序）：
1. `transfer.httpVersionSelectCallback = (): rcp.HttpVersion => '2'`（API 26 专有，强制 2）。
2. 不设置 → 由系统协商（HTTPS + ALPN 通常直接上 h2）；用 `response.httpVersion` 记录实际值。
3. `assumesHTTP3Capable: true` 只在确实要 HTTP/3 时用。

> `[U]`：`httpVersionSelectCallback` 在 API 26 d.ts 里存在，但“强制 '2' 后是否回退”未说明。生产上建议**不强制**，只在诊断日志里读 `response.httpVersion`，并在需要时开启。

### 5.5 SSE 流式 POST 骨架（ArkTS，可编译级）

```ts
import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/** SSE 增量解析器：把任意切分的字节流还原成 (event, data) 帧 */
export class SseParser {
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private buffer: string = '';
  private eventName: string = '';
  private dataLines: string[] = [];

  /** 传入一个 ArrayBuffer 分片，同步吐出解析出的事件 */
  push(chunk: ArrayBuffer, onEvent: (eventName: string, data: string) => void): void {
    this.buffer += this.decoder.decodeToString(new Uint8Array(chunk), { stream: true });
    let idx: number = this.buffer.indexOf('\n');
    while (idx >= 0) {
      let line: string = this.buffer.substring(0, idx);
      this.buffer = this.buffer.substring(idx + 1);
      if (line.endsWith('\r')) { line = line.substring(0, line.length - 1); }
      if (line.length === 0) {
        if (this.dataLines.length > 0) {
          onEvent(this.eventName, this.dataLines.join('\n'));
        }
        this.eventName = '';
        this.dataLines = [];
      } else if (!line.startsWith(':')) {          // 忽略 ": keep-alive" 注释行
        const colon: number = line.indexOf(':');
        const field: string = colon < 0 ? line : line.substring(0, colon);
        let value: string = colon < 0 ? '' : line.substring(colon + 1);
        if (value.startsWith(' ')) { value = value.substring(1); }
        if (field === 'event') { this.eventName = value; }
        else if (field === 'data') { this.dataLines.push(value); }
      }
      idx = this.buffer.indexOf('\n');
    }
  }
}

export class DeepSeekStreamer {
  private session: rcp.Session | null = null;
  private current: rcp.Request | null = null;

  /** 发起一次流式请求；返回的 Promise 在 response.completed/incomplete/failed 或流结束时 resolve */
  startStream(apiKey: string, bodyJson: string,
              onEvent: (eventName: string, data: string) => void): Promise<void> {
    const parser = new SseParser();          // 先建，回调里才可用
    this.session = rcp.createSession({
      headers: {
        'authorization': `Bearer ${apiKey}`,
        'content-type': 'application/json',
        'accept': 'text/event-stream'
      },
      requestConfiguration: {
        transfer: {
          // SSE 必须放大长传输窗口（默认 60000ms 会被腰斩）
          timeout: { connectMs: 15000, transferMs: 1800000, inactivityMs: 300000 },
          autoRedirect: true
        },
        tracing: {
          httpEventsHandler: {
            onDataReceive: (chunk: ArrayBuffer): void => {
              parser.push(chunk, onEvent);
            },
            onHeaderReceive: (headers: rcp.ResponseHeaders): void => {
              // 可用于断言 content-type: text/event-stream
            },
            onCanceled: (): void => { /* 用户中断 */ },
            onDataEnd: (): void => { /* 服务端关闭 */ }
          }
        }
      }
    });
    const request = new rcp.Request('https://api.deepseek.com/responses', 'POST',
                                    undefined, bodyJson);
    this.current = request;
    return this.session.fetch(request).then((resp: rcp.Response) => {
      // 注意：用 onDataReceive 时 resp.body 可能为空；这里只取状态码
      const code: number = resp.statusCode;
      if (code !== 200) {
        throw new Error(`HTTP ${code}`);
      }
    }).catch((err: BusinessError) => {
      throw new Error(`rcp error ${err.code}: ${err.message}`);
    });
  }

  cancel(): void {
    if (this.session !== null) {
      this.session.cancel(this.current ?? undefined);   // 触发 onCanceled
    }
  }

  close(): void {
    this.session?.close();
    this.session = null;
    this.current = null;
  }
}
```

要点：

- 必须 `flush` 语义由回调驱动；**不要**把 `await session.fetch()` 当作“流结束”——它在响应头到达/请求完成后就 resolve，真正的数据在回调里。[I，与 “onDataReceive 是分片回调” 一致]
- 请求体用**字符串**（`RawDataContent = string | ArrayBuffer | object`）；用 `object` 会走 JSON 序列化，ArkTS 里字段命名不受控，建议 `JSON.stringify` 后传字符串。[C/I]
- `TextDecoder.decodeToString(..., {stream:true})` 会缓存末尾不完整的多字节序列，**中文必需**。`decodeWithStream` 已 `@deprecated`（`@useinstead util.TextDecoder.decodeToString`）。[C]
- 取消：`session.cancel(request)`；`onCanceled` 回调里把 UI 状态置为“已停止”。[C]
- Session 上限 1024，页面退出务必 `close()`。[C]

### 5.6 权限与声明 `[C]`

```json5
// chat/src/main/module.json5 → module.requestPermissions
"requestPermissions": [
  { "name": "ohos.permission.INTERNET" }
]
```

`@permission ohos.permission.INTERNET` 出现在 `fetch/get/post/put/…` 的每一处 docblock；`createSession` 的 `@throws 401 - Parameter error` 与 `1007900994` 是唯一两个创建期错误。

### 5.7 常见错误码（摘自 `fetch` docblock）`[C]`

`1007900993 Session is closed` · `1007900992 Request is canceled` · `1007900089 max connection limit` · `1007900092 HTTP/2 framing error` · `1007900095 HTTP/3 error` · `1007900990 Out of memory` · `1007900201 Plaintext transmission is forbidden`（since 6.1.0(23)，**明文 HTTP 被禁**，本地调试也要 HTTPS 或用 socket）· `1007900991 response invalid` · `1007900998 Method not supported`。

---

## 6. HarmonyOS relationalStore + FTS5

文件：`...\openharmony\ets\api\@ohos.data.relationalStore.d.ts`（484 KB）。

### 6.1 导入与建库 `[C]`

```ts
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const config: relationalStore.StoreConfig = {
  name: 'chat.db',
  securityLevel: relationalStore.SecurityLevel.S1,   // 必填
  encrypt: false,          // 建库后不能直接改，需 rekeyEx
  // customDir?: string;   // ≤128 字节
  // rootDir?: string;     // since 18，只读打开
  // isReadOnly?: boolean; // since 12
  // allowRebuild?: boolean;  // since 12，异常时删库重建（危险）
  // persist?: boolean;    // since 18，false = 内存库（不支持加密/备份/跨进程）
  // tokenizer?: relationalStore.Tokenizer;   // since 17，FTS 分词器
};
const store: relationalStore.RdbStore =
  await relationalStore.getRdbStore(context as common.Context, config);
```

```ts
function getRdbStore(context: Context, config: StoreConfig): Promise<RdbStore>;       // L7497
function getRdbStoreSync(context: Context, config: StoreConfig): RdbStore;           // L7524
function deleteRdbStore(context: Context, config: StoreConfig): Promise<void>;       // L7631
```

`SecurityLevel`（L1066）`[C]`：`S1=1` 低（泄露影响轻微，如壁纸类非敏感系统数据）· `S2=2` 中（用户音视频、通话记录）· `S3=3` 高（健身、健康、位置）· `S4=4` 严重（认证凭据、金融数据）。
→ 聊天正文/密钥元数据建议 **S3**；纯 UI 偏好不要建库。

`StoreConfig.name` 注意：**同进程内不要创建两个同名库**，否则设备同步/云同步/静默访问/密钥备份会异常。[C]

### 6.2 增删改查 `[C]`

```ts
type ValueType = null | number | string | boolean | Uint8Array | Asset | Assets | Float32Array | bigint;  // L224
type ValuesBucket = Record<string, ValueType>;                                                              // L232

insert(table: string, values: ValuesBucket): Promise<number>;                          // 返回 rowId
insert(table: string, values: ValuesBucket, conflict: ConflictResolution): Promise<number>;
batchInsert(table: string, values: Array<ValuesBucket>): Promise<number>;              // 返回成功条数
batchInsertWithConflictResolution(table, values, conflict): Promise<number>;
update(values: ValuesBucket, predicates: RdbPredicates): Promise<number>;
delete(predicates: RdbPredicates): Promise<number>;
query(predicates: RdbPredicates, columns?: Array<string>): Promise<ResultSet>;
querySql(sql: string, bindArgs?: Array<ValueType>): Promise<ResultSet>;
executeSql(sql: string, bindArgs?: Array<ValueType>): Promise<void>;                   // L5218
```

官方写法（对象字面量显式标注为 `ValuesBucket` 即可，ArkTS 允许）`[C]`：

```ts
const bucket: relationalStore.ValuesBucket = {
  'session_id': sessionId,
  'role': 'user',
  'content': text,
  'created_at': Date.now()
};
await store.insert('message', bucket);
```

`ConflictResolution`（L1473）`[C]`：`ON_CONFLICT_NONE=0` · `ROLLBACK=1` · `ABORT=2` · `FAIL=3` · `IGNORE=4` · `ON_CONFLICT_REPLACE`（删除冲突旧行后插入）· `ON_CONFLICT_REPLACE` 系列批量时每次写 32766 个参数上限。

### 6.3 `RdbPredicates`（L2011）常用方法 `[C]`

```ts
equalTo(field: string, value: ValueType): RdbPredicates;
notEqualTo; beginWrap(); endWrap(); or(); and();
contains(field: string, value: string); beginsWith; endsWith;
isNull(field); isNotNull(field); like(field, value); glob(field, value);
between(field, low: ValueType, high: ValueType); notBetween;
greaterThan; lessThan; greaterThanOrEqualTo; lessThanOrEqualTo;
orderByAsc(field); orderByDesc(field); distinct();
limitAs(value: number); offsetAs(rowOffset: number);
groupBy(fields: Array<string>); indexedBy(field: string);
in(field: string, value: Array<ValueType>); notIn; notContains; notLike;
having(conditions: string, args?: Array<ValueType>);
```

默认用 `and()` 连接多条件；“**RdbPredicates 不能跨线程用 Sendable 传递**”。[C]

### 6.4 事务（推荐新接口）`[C]`

```ts
// RdbStore
createTransaction(options?: TransactionOptions): Promise<Transaction>;   // L6403, since 14
interface TransactionOptions { transactionType?: TransactionType; }      // 默认 DEFERRED

enum TransactionType { DEFERRED = 0, IMMEDIATE = 1, EXCLUSIVE = 2 }       // L1664

interface Transaction {                                                   // L6500
  insert(table: string, values: ValuesBucket, conflict?: ConflictResolution): Promise<number>;
  batchInsert(table: string, values: Array<ValuesBucket>): Promise<number>;
  update(values: ValuesBucket, predicates: RdbPredicates, conflict?: ConflictResolution): Promise<number>;
  delete(predicates: RdbPredicates): Promise<number>;
  query(predicates: RdbPredicates, columns?: Array<string>): Promise<ResultSet>;
  querySql(sql: string, args?: Array<ValueType>): Promise<ResultSet>;
  commit(): Promise<void>;      // 异步 API 执行完必须 commit，否则 SQL 可能丢失
  rollback(): Promise<void>;
}
```

旧接口仍在（`beginTransaction(): void` L5351、`commit(): void` L5409、`rollBack(): void` L5467、`commit(txId)/rollback(txId)`）——**新代码一律用 `createTransaction()`**，避免嵌套事务语义混乱。[I]

INSERT 消息 + 更新会话 `updated_at` 必须同事务，否则列表排序会抖动。[I]

### 6.5 ResultSet 遍历 `[C]`

```ts
interface ResultSet {                     // L2485
  columnNames: Array<string>;
  columnCount: number;
  rowCount: number;
  rowIndex: number;
  isAtFirstRow: boolean; isAtLastRow: boolean; isEnded: boolean;
  isStarted: boolean; isClosed: boolean;
  getColumnIndex(columnName: string): number;        // L2616
  getColumnName(columnIndex: number): string;
  getColumnType(columnIdentifier: number | string): Promise<ColumnType>;
  getString(columnIndex: number): string;
  getLong(columnIndex: number): number;
  getDouble(columnIndex: number): number;
  getBlob(columnIndex: number): Uint8Array;
  getValue(columnIndex: number): ValueType;
  getRow(): ValuesBucket;
  isColumnNull(columnIndex: number): boolean;
  goToFirstRow(): boolean;
  goToNextRow(): boolean;
  goTo(offset: number): boolean;
  close(): void;                                      // 必须调用
}
```

标准循环（不要缓存 `rowCount`，`ResultSet` 不实时刷新）`[C]`：

```ts
const rs = await store.query(predicates, ['id', 'role', 'content']);
try {
  const idIdx: number = rs.getColumnIndex('id');
  const roleIdx: number = rs.getColumnIndex('content');
  while (rs.goToNextRow()) {
    const id: number = rs.getLong(idIdx);
    const content: string = rs.getString(rs.getColumnIndex('content'));
    // …
  }
} finally {
  rs.close();
}
```

> 另有 `LiteResultSet`（since API 23，L3339 起）提供 `goToNextRow/getString/...`，是轻量只进结果集；本项目用普通 `ResultSet` 足够。

### 6.6 FTS —— 事实与必测项

**已确认（SDK）** `[C]`：

```ts
enum Tokenizer {                    // L709, since 17
  NONE_TOKENIZER = 0,               // 不用分词器
  ICU_TOKENIZER = 1,                // 支持中文与多语言，可设语言（zh_CN、tr_TR…）
  CUSTOM_TOKENIZER = 2              // since 18；中（简繁）英 + 阿拉伯数字；cut_mode=short_words
}
interface StoreConfig { /* … */ tokenizer?: Tokenizer; }        // L486
function isTokenizerSupported(tokenizer: Tokenizer): boolean;   // L7652
// StoreConfig.pluginLibs?: Array<string>  自定义分词动态库（L~"pluginLibs"）
```

**未确认（必须实测）** `[U]`：

- d.ts 中**没有** `fts5`/`FTS5` 字样，也没有 `CREATE VIRTUAL TABLE` 示例文本（`Tokenizer` 的注释里写着“The following is an example of the table creation statement…”，但示例代码块在 d.ts 中被裁掉了）。
- 因此“`CREATE VIRTUAL TABLE t USING fts5(content, tokenize = 'icu zh_CN')` 是否可用”**只能靠真机验证**。
- 事务/`executeSql` 能执行任意 DDL 是确定的，问题只在 SQLite 编译选项是否启用 FTS5。

**降级方案（不依赖 FTS5，零风险）** `[I]`：

- 建普通表 + `content` 列，用 `LIKE` 检索短词（`RdbPredicates.like('content', '%kw%')`）；中文按 2–3 字切分再 `OR` 拼接。
- 或维护一张 `token(text)` 倒排表，自建 n-gram（写入时同步维护，同事务）。
- 消息量到十万级再考虑上 FTS5，那时写一个 `isTokenizerSupported(ICU_TOKENIZER)` 探测 + DDL `try/catch` 回退即可。

其他相关：

- `backup(destName: string): Promise<void>`（L5559）/ `restore(srcName: string): Promise<void>`（L5619）；`version: number`（L3813）可读写，用来做 schema 迁移版本号。
- 加密库不支持备份/内存库不支持备份恢复（`persist:false` 的限制）。[C]

---

## 7. HarmonyOS Asset Store Kit

文件：`...\openharmony\ets\api\@ohos.security.asset.d.ts`（52 KB）。Kit：`@kit.AssetStoreKit`（`@file @kit AssetStoreKit`）。

### 7.1 关键类型 `[C]`

```ts
type AssetMap = Map<Tag, Value>;                 // L468 —— 是 Map，不是对象字面量
type Value = boolean | number | Uint8Array;      // L~480
```

```ts
function add(attributes: AssetMap): Promise<void>;                              // L58
function remove(query: AssetMap): Promise<void>;                                // L140
function update(query: AssetMap, attributesToUpdate: AssetMap): Promise<void>;  // L216
function query(query: AssetMap): Promise<Array<AssetMap>>;                      // L363
function preQuery(query: AssetMap): Promise<Uint8Array>;                        // L299（需用户认证时前置）
function postQuery(handle: AssetMap): Promise<void>;                            // L420
// 同步版：addSync / removeSync / updateSync / querySync / preQuerySync / postQuerySync
// 批量版（since 26.0.0）：batchAdd / batchRemove / batchUpdate / batchAddSync …，返回 BatchResult
```

`enum ReturnType`（L644）：`ALL = 0`（明文 + 属性，单条查询用）· `ATTRIBUTES = 1`（仅属性，多条查询用）。
`enum Accessibility`（L488）：`DEVICE_POWERED_ON = 0` · `DEVICE_FIRST_UNLOCKED = 1` · `DEVICE_UNLOCKED = 2`。
`enum AuthType`（L525）：`NONE = 0x00` · `ANY = 0xFF`。
`enum ConflictResolution`（L619）：`OVERWRITE = 0` · `THROW_ERROR = 1`。
`enum SyncType`：`NEVER = 0` · `THIS_DEVICE = 1<<0` · `TRUSTED_DEVICE = 1<<1` · `TRUSTED_ACCOUNT = 1<<2`。

`enum Tag`（L817）取值与**值类型**（TagType 编码在常量里，必须匹配）`[C]`：

| Tag | 值类型 | 说明 |
|---|---|---|
| `SECRET` | `Uint8Array` | 密文/密钥本体（必填） |
| `ALIAS` | `Uint8Array` | 别名（必填） |
| `ACCESSIBILITY` | `number` | `Accessibility` |
| `REQUIRE_PASSWORD_SET` | `boolean` | 需设锁屏密码 |
| `AUTH_TYPE` | `number` | `AuthType` |
| `AUTH_VALIDITY_PERIOD` | `number` | 认证有效期 |
| `AUTH_CHALLENGE` / `AUTH_TOKEN` | `Uint8Array` | 认证挑战/令牌 |
| `SYNC_TYPE` | `number` | `SyncType` |
| `IS_PERSISTENT` | `boolean` | **需 `ohos.permission.STORE_PERSISTENT_DATA`** |
| `DATA_LABEL_CRITICAL_1..4` / `DATA_LABEL_NORMAL_1..4` / `DATA_LABEL_NORMAL_LOCAL_1..4` | `Uint8Array` | 自定义标签 |
| `RETURN_TYPE` | `number` | `ReturnType` |
| `RETURN_LIMIT` / `RETURN_OFFSET` / `RETURN_ORDERED_BY` | `number` | 分页/排序 |
| `CONFLICT_RESOLUTION` | `number` | `ConflictResolution` |
| `UPDATE_TIME` | `Uint8Array` | 只读返回 |
| `OPERATION_TYPE` | `number` | `OperationType`（`NEED_SYNC`/`NEED_LOGOUT`） |
| `REQUIRE_ATTR_ENCRYPTED` | `boolean` | 属性也加密 |
| `GROUP_ID` | `Uint8Array` | 数据组 |
| `WRAP_TYPE` | `number` | `NEVER=0` / `TRUSTED_ACCOUNT=1` |

`enum ErrorCode`（L1086）`[C]`：`PERMISSION_DENIED=201` · `NOT_SYSTEM_APPLICATION=202` · `INVALID_ARGUMENT=401` · `SERVICE_UNAVAILABLE=24000001` · `NOT_FOUND=24000002` · `DUPLICATED=24000003` · `ACCESS_DENIED=24000004` · `STATUS_MISMATCH=24000005`（锁屏状态不匹配）· `OUT_OF_MEMORY=24000006` · `DATA_CORRUPTED=24000007` · `DATABASE_ERROR=24000008` · `CRYPTO_ERROR=24000009` · `IPC_ERROR=24000010` · `BMS_ERROR=24000011` · `ACCOUNT_ERROR=24000012` · `ACCESS_TOKEN_ERROR=24000013` · `FILE_OPERATION_ERROR=24000014` · `GET_SYSTEM_TIME_ERROR=24000015` · `LIMIT_EXCEEDED=24000016` · `UNSUPPORTED=24000017` · `PARAM_VERIFICATION_FAILED=24000018` · `INCONSISTENT_ATTRIBUTE=24000019`。

### 7.2 权限 / module.json5

- 应用访问**自己**的 asset 不需要权限；只有 `Tag.IS_PERSISTENT` 需要 `ohos.permission.STORE_PERSISTENT_DATA`。[C，`add()` docblock 首句]
- 没有 “SecurityLevel” 这类配置项；**不要**往 module.json5 里编造 asset 配置。[C，d.ts 全文无相关声明]
- 设备需已设锁屏密码，否则 `REQUIRE_PASSWORD_SET: true` / `Accessibility.DEVICE_UNLOCKED` 会报 `24000005`。[I]

### 7.3 骨架：putSecret / getSecret

```ts
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const encode = (s: string): Uint8Array => util.TextEncoder.create('utf-8').encodeInto(s);
const decode = (b: Uint8Array): string => util.TextDecoder.create('utf-8').decodeToString(b);

export async function putSecret(alias: string, value: string): Promise<void> {
  const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  attr.set(asset.Tag.SECRET, encode(value));
  attr.set(asset.Tag.ALIAS, encode(alias));
  attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  attr.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
  attr.set(asset.Tag.DATA_LABEL_NORMAL_1, encode('api_key'));
  attr.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
  try {
    await asset.add(attr);
  } catch (e) {
    const err = e as BusinessError;
    throw new Error(`asset.add failed: ${err.code}`);
  }
}

export async function getSecret(alias: string): Promise<string | null> {
  const q: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  q.set(asset.Tag.ALIAS, encode(alias));
  q.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  try {
    const res: Array<asset.AssetMap> = await asset.query(q);
    if (res.length === 0) { return null; }
    const secret = res[0].get(asset.Tag.SECRET);
    if (secret === undefined || typeof secret === 'boolean' || typeof secret === 'number') { return null; }
    return decode(secret);
  } catch (e) {
    const err = e as BusinessError;
    if (err.code === asset.ErrorCode.NOT_FOUND) { return null; }   // 24000002
    throw new Error(`asset.query failed: ${err.code}`);
  }
}

export async function removeSecret(alias: string): Promise<void> {
  const q: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  q.set(asset.Tag.ALIAS, encode(alias));
  await asset.remove(q);
}
```

坑：

1. **`AssetMap` 是 `Map`**，用 `.set()`；写对象字面量编译不过（`arkts-no-untyped-obj-literals` + 类型不匹配）。[C]
2. `query` 找不到时**抛 24000002，不返回空数组**（原文：“If no asset is found, an exception indicating that no asset is found is thrown instead of returning an empty query result list.”）。[C]
3. `value` 是联合类型，取 `SECRET` 后必须做类型收窄（如上）——`as Uint8Array` 直接断言也可，但收窄更安全。[C/I]
4. `update(query, attributesToUpdate)`：`query` 里放定位标签（`ALIAS`），`attributesToUpdate` 里放要改的值（`SECRET`）。[I]
5. `Accessibility.DEVICE_UNLOCKED` 会让后台/锁屏场景读不到，token 类建议 `DEVICE_FIRST_UNLOCKED`。[I]

---

## 8. LAN TCP server API

文件：`...\openharmony\ets\api\@ohos.net.socket.d.ts`（208 KB）。

### 8.1 签名 `[C]`

```ts
import { socket } from '@kit.NetworkKit';

function constructTCPSocketServerInstance(): TCPSocketServer;      // L115

export interface TCPSocketServer {                                 // L3263
  listen(address: NetAddress, callback: AsyncCallback<void>): void; // L3289  @permission ohos.permission.INTERNET
  listen(address: NetAddress): Promise<void>;                       // L3314  @permission ohos.permission.INTERNET
  close(): Promise<void>;                                           // L3336
  on(type: 'connect', callback: Callback<TCPSocketConnection>): void;  // L3447
  on(type: 'error', callback: ErrorCallback): void;                    // L3477
}

export interface TCPSocketConnection {                              // L3026
  send(options: TCPSendOptions, callback: AsyncCallback<void>): void;
  send(options: TCPSendOptions): Promise<void>;
  close(callback: AsyncCallback<void>): void;
  close(): Promise<void>;
  on(type: 'message', callback: Callback<SocketMessageInfo>): void;  // L3161
  on(type: 'close', callback: Callback<void>): void;                 // L3191
  on(type: 'error', callback: ErrorCallback): void;                  // L3217
}

export interface SocketMessageInfo {          // L3850
  message: ArrayBuffer;
  remoteInfo: SocketRemoteInfo;
}

// NetAddress 来自 @ohos.net.connection（socket 里是 export import NetAddress = connection.NetAddress）
export interface NetAddress { address: string; family?: number; port?: number; }
// family: 1 = IPv4（默认）, 2 = IPv6；port: 0–65535，默认 0
```

`listen` 语义（原文）：“The server uses this API to perform the **bind**, **listen**, and **accept** operations. If the **bind** operation fails, the system randomly allocates a port number.”
→ 想要固定端口就必须在 `listen` 后自己确认（读不到实际端口时用 `2303198 Address already in use` 判定失败并换端口）。`[U]`：`TCPSocketServer` 上没有 “获取实际端口” 的 API（本 d.ts 未提供），因此**固定端口 + 失败重试**是唯一可靠策略。

### 8.2 骨架（本地 LAN HTTP 编辑器）

```ts
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export class LanEditorServer {
  private server: socket.TCPSocketServer | null = null;

  async start(port: number,
              onHttpRequest: (conn: socket.TCPSocketConnection, raw: string) => void): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    this.server = server;
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      let acc: string = '';
      conn.on('message', (info: socket.SocketMessageInfo) => {
        acc += decoder.decodeToString(new Uint8Array(info.message), { stream: true });
        const headEnd: number = acc.indexOf('\r\n\r\n');
        if (headEnd >= 0) {
          // 交给上层解析 method / path / Content-Length / body
          onHttpRequest(conn, acc);
        }
      });
      conn.on('close', () => { /* 清理该连接状态 */ });
      conn.on('error', (err: BusinessError) => { /* 记录 err.code */ });
    });
    server.on('error', (err: BusinessError) => { /* 记录 err.code */ });
    // family: 1=IPv4, 2=IPv6；端口占用会抛 2303198（bind 失败时系统会随机分配端口）
    await server.listen({ address: '0.0.0.0', port: port, family: 1 });
  }

  async respond(conn: socket.TCPSocketConnection, body: string): Promise<void> {
    const bodyBytes: Uint8Array = util.TextEncoder.create('utf-8').encodeInto(body);
    const head: string = 'HTTP/1.1 200 OK\r\n'
      + 'Content-Type: text/html; charset=utf-8\r\n'
      + `Content-Length: ${bodyBytes.length}\r\n`
      + 'Connection: close\r\n\r\n';
    // send() 接受 string 或 ArrayBuffer：直接分两次发，避免再拼一次大字符串
    await conn.send({ data: head });
    await conn.send({ data: bodyBytes.buffer as ArrayBuffer });
    await conn.close();
  }

  async stop(): Promise<void> {
    await this.server?.close();
    this.server = null;
  }
}
```

`TCPSendOptions`（L1795）`[C]`：`data: string | ArrayBuffer`（必填）、`encoding?: string`（默认 UTF-8，可选 UTF-16BE/UTF-16LE/UTF-16/US-ASCII/ISO-8859-1）。

坑：

1. **同一 WLAN 才能访问**；`0.0.0.0` 绑定全部网卡。`[I]`
2. `listen` 失败端口会被系统随机分配 → 若必须固定端口，先 `try/catch` 2303198 再提示用户。`[C/I]`
3. 明文 HTTP/2 不需要；这里就是裸 TCP，自己拼 HTTP/1.1。`[C]`
4. 建议放在 worker/taskpool：“You are advised to call the APIs of this module in the worker thread or taskpool… Otherwise, the UI thread may be suspended.”（模块级 NOTE）`[C]`
5. 需要 `ohos.permission.INTERNET`；不涉及 `ohos.permission.GET_NETWORK_INFO`。`[C]`

---

## 9. preferences / live view / share kit

### 9.1 `@ohos.data.preferences` `[C]`

```ts
import { preferences } from '@kit.ArkData';

function getPreferences(context: Context, options: Options): Promise<Preferences>;   // L262
function getPreferencesSync(context: Context, options: Options): Preferences;        // L284
function deletePreferences(context: Context, options: Options): Promise<void>;       // L400

interface Options {                       // L134
  name: string;                           // 0 < len ≤ 255，不能含/以 "/" 结尾
  dataGroupId?: string | null | undefined;
  storageType?: StorageType | null | undefined;   // since 18：XML(0，默认) | GSKV
}
enum StorageType { XML = 0, GSKV }        // GSKV 实时落盘，无需 flush()

interface Preferences {
  get(key: string, defValue: ValueType): Promise<ValueType>;
  getSync(key: string, defValue: ValueType): ValueType;      // L683
  getAll(): Promise<Object>;  getAllSync(): Object;
  has(key: string): Promise<boolean>;  hasSync(key: string): boolean;
  put(key: string, value: ValueType): Promise<void>;  putSync(key: string, value: ValueType): void;
  delete(key: string): Promise<void>;  deleteSync(key: string): void;
  clear(): Promise<void>;  clearSync(): void;
  flush(): Promise<void>;  flushSync(): void;                 // XML 模式必须 flush 才落盘
  on(type: 'change', callback: Callback<string>): void;
  on(type: 'dataChange', keys: Array<string>, callback: Callback<Record<string, ValueType>>): void;
  off(/* 同上 */): void;
}
```

用途：UI 偏好、模型选择、温度、上次会话 id（**非密钥**）。`ValueType` 同 relationalStore（`null|number|string|boolean|Uint8Array` 等）。XML 模式 `put` 后必须 `flush()`；`GSKV` 模式不需要。[C]

### 9.2 实况窗 / Live View —— **SDK 中没有 `@ohos.app.ability.LiveView`** `[C]`

实测（grep 全 `api/` + `kits/`）：

- `@ohos.app.ability.LiveView.d.ts`、`@kit.ABilityKit` 中的 `liveView`：**不存在**。
- `LiveView` 字样只出现在 `@ohos.notificationManager.d.ts` 与 `notification/notificationContent.d.ts`（`NotificationSystemLiveViewContent`）。
- `liveForm` / `LiveForm` 出现在 `@ohos.app.form.LiveFormExtensionAbility.d.ts`、`@kit.FormKit.d.ts`、`@ohos.app.ability.common.d.ts`（`LiveFormExtensionContext`）、`@ohos.bundle.bundleManager.d.ts`、`@ohos.notificationManager.d.ts`。

真实可用类型 `[C]`：

```ts
// @kit.FormKit
import { LiveFormExtensionAbility, LiveFormInfo } from '@kit.FormKit';

export interface LiveFormInfo {          // @since 20
  formId: string;
  rect: formInfo.Rect;
  borderRadius: number;                  // 单位 vp，≥0
}
declare class LiveFormExtensionAbility extends ExtensionAbility {
  context: LiveFormExtensionContext;
  onLiveFormCreate(liveFormInfo: LiveFormInfo, session: UIExtensionContentSession): void;
  onLiveFormDestroy(liveFormInfo: LiveFormInfo): void;
}
```

```ts
// notification/notificationContent.d.ts L236（@since 11）
export interface NotificationSystemLiveViewContent extends NotificationBasicContent {
  typeCode: number;
  capsule?: NotificationCapsule;    // title ≤202 字节；icon 建议 128×128，像素总量 ≤192KB
  button?: NotificationButton;
  time?: NotificationTime;
  progress?: NotificationProgress;
}
// NotificationContent.systemLiveView?: NotificationSystemLiveViewContent   (L511)
```

原文限制（L225 起）：“Third-party applications are not supported to directly create this notification type. After the **system proxy** creates a system live view notification, a third-party application can publish a notification with the same ID to update the specified content.”

→ 结论：**ChatAnyWhere 不能自己做“实况窗”**。可做的替代：
(a) 通知进度（普通 `notificationManager.publish`，长任务“正在生成…”）；
(b) `LiveFormExtensionAbility`（交互卡片，需 `module.json5` 声明 `extensionAbilities` + form_config，成本高）；
(c) 应用内悬浮球/底部状态条。
本节建议按 (a)+(c) 实现，把 (b) 标为后续增强。

### 9.3 Share Kit 接收分享 `[C]`

```ts
// @ohos.app.ability.ShareExtensionAbility.d.ts（全文仅 1 个类，无自有成员）
import UIExtensionAbility from './@ohos.app.ability.UIExtensionAbility';
export default class ShareExtensionAbility extends UIExtensionAbility {}
```

- 定位（原文）：“By implementing ShareExtensionAbility, you can process content shared from other applications… your application will appear as an option in the system share panel.”
- `@since 10`、`@stagemodelonly`、`@syscap SystemCapability.Ability.AbilityRuntime.Core`。

Action 常量现状（**重要冲突**）`[C]`：

- `@ohos.app.ability.wantConstant`（stage 模型，本项目应使用）里 `enum Action` **只有** `ACTION_SEND_TO_DATA = 'ohos.want.action.sendToData'`。
- `ACTION_VIEW_DATA = 'ohos.want.action.viewData'` 只存在于 **FA 模型遗留文件** `@ohos.ability.wantConstant.d.ts`（`@deprecated since 9`）。
- → 在 .ets 里**不能**写 `wantConstant.Action.ACTION_VIEW_DATA`；用字符串字面量 `'ohos.want.action.viewData'`（skills.actions 里也是字符串）。

分享相关参数键（`@ohos.app.ability.wantConstant` 的 `Params` 枚举）`[C]`：

| 常量 | 字符串值 |
|---|---|
| `CONTENT_TITLE_KEY` | `ohos.extra.param.key.contentTitle` |
| `SHARE_ABSTRACT_KEY` | `ohos.extra.param.key.shareAbstract` |
| `SHARE_URL_KEY` | `ohos.extra.param.key.shareUrl` |
| `PARAMS_STREAM` | `ability.params.stream` |

接收侧要点：

```ts
// ShareExtensionAbility 子类里通过 want 取内容
import { Want } from '@kit.AbilityKit';
// this.want（UIExtensionAbility → 继承链提供）；文本在 want.parameters 的 'ability.want.params.TEXT' 等键，
// 类型/URI 列表在 want.type / want.uri
```

`[U]`：本 SDK 未声明“分享文本”的标准 key 名（无 `TEXT` 常量）；官方样例用 `want.parameters?.['ability.want.params.TEXT']` 与 `want.type`。**必须联调确认**（用 `JSON.stringify(want)` 打印一次即可定案）。

`module.json5` 声明形态（结构 `[I]`，字段名参照本项目已有 `extensionAbilities` 写法）：

```json5
"extensionAbilities": [
  {
    "name": "ShareReceiveAbility",
    "srcEntry": "./ets/sharereceive/ShareReceiveAbility.ets",
    "type": "share",
    "exported": true,
    "skills": [
      {
        "actions": ["ohos.want.action.viewData"],
        "uris": [{ "type": "text/plain" }]
      }
    ]
  }
]
```

> `type: "share"` 与 `skills.uris` 的精确取值未在本地 .d.ts 中验证（能力配置属 app 打包 schema，不在 SDK api 目录）→ `[U]`，以 DevEco 模板生成结果为准。

---

## 10. ArkUI bindSheet + bindContentCover + LazyForEach

文件：`...\openharmony\ets\component\common.d.ts`、`lazy_for_each.d.ts`。

### 10.1 签名 `[C]`

```ts
bindContentCover(isShow: boolean, builder: CustomBuilder, type?: ModalTransition): T;            // L21609
bindContentCover(isShow: boolean, builder: CustomBuilder, options?: ContentCoverOptions): T;     // L21628
bindSheet(isShow: boolean, builder: CustomBuilder, options?: SheetOptions): T;                   // L21649
```

- `isShow` 支持 `$$` 双向绑定（API 10+）与 `!!`（API 18+）：“Since API version 10, this parameter supports two-way binding through `$`… Since API version 18 … through `!!`”。
- `bindSheet` **不能**在 `attributeModifier` 内调用（原文 NOTE）。

```ts
declare enum SheetSize { MEDIUM = 0, LARGE = 1, FIT_CONTENT = 2 }      // L7947
declare enum SheetType { BOTTOM = 0, CENTER = 1, POPUP = 2, SIDE = 3, CONTENT_COVER = 4 }   // L11477
declare enum SheetMode { OVERLAY = 0, EMBEDDED = 1 }                   // L11538
declare interface SheetTitleOptions { title: ResourceStr; subtitle?: ResourceStr; }   // L11446
```

`SheetOptions extends BindOptions`（L11753）字段全量（32 项）`[C]`：

```ts
height?: SheetSize | Length;          dragBar?: boolean;              maskColor?: ResourceColor;
detents?: [(SheetSize | Length), (SheetSize | Length), (SheetSize | Length)?];   // 最多 3 档
blurStyle?: BlurStyle;                showClose?: boolean | Resource; preferType?: SheetType;
title?: SheetTitleOptions | CustomBuilder;
shouldDismiss?: (sheetDismiss: SheetDismiss) => void;
onWillDismiss?: Callback<DismissSheetAction>;
onWillSpringBackWhenDismiss?: Callback<SpringBackAction>;
enableOutsideInteractive?: boolean;   width?: Dimension;
borderWidth?; borderColor?; borderStyle?; shadow?;
onHeightDidChange?: Callback<number>;  mode?: SheetMode;
scrollSizeMode?: ScrollSizeMode;      onDetentsDidChange?: Callback<number>;
onWidthDidChange?: Callback<number>;  onTypeDidChange?: Callback<SheetType>;
uiContext?: UIContext;                keyboardAvoidMode?: SheetKeyboardAvoidMode;
enableHoverMode?: boolean;            hoverModeArea?: HoverModeAreaType;
effectEdge?: number;                  radius?: LengthMetrics | BorderRadiuses | LocalizedBorderRadiuses;
detentSelection?: SheetSize | Length; placement?: Placement;  placementOnTarget?: boolean;
```

用法（半模态设置面板）：

```ts
@State showSettings: boolean = false;

@Builder settingsSheet() {
  Column() { /* … */ }
    .width('100%')
    .padding(16)
}

// 在 build 的组件上：
Column() { /* … */ }
  .bindSheet(this.showSettings, this.settingsSheet(), {
    height: SheetSize.FIT_CONTENT,
    detents: [SheetSize.MEDIUM, SheetSize.LARGE],
    preferType: SheetType.BOTTOM,
    showClose: true,
    title: { title: '设置', subtitle: '模型与外观' },
    onWillDismiss: (action: DismissSheetAction) => { this.showSettings = false; }
  })
```

### 10.2 `LazyForEach` / `IDataSource` `[C]`

```ts
declare interface IDataSource {                                     // lazy_for_each.d.ts L804
  totalCount(): number;                                             // L815
  getData(index: number): any;                                      // L828
  registerDataChangeListener(listener: DataChangeListener): void;    // L839
  unregisterDataChangeListener(listener: DataChangeListener): void;  // L850
}

declare interface DataChangeListener {                              // L612
  onDataReloaded(): void;                                           // L623
  onDataAdd(index: number): void;                                   // 用这个（onDataAdded 已废弃）
  onDataMove(from: number, to: number): void;                       // onDataMoved 已废弃
  onDataDelete(index: number): void;                                // onDataDeleted 已废弃
  onDataChange(index: number): void;                                // onDataChanged 已废弃
  onDatasetChange(dataOperations: DataOperation[]): void;           // L793 批量操作
}
```

- `LazyForEach` 是 `syntaxComponents.paramsUICallback` 之一（见 ets-loader tsconfig），签名由编译器特判，不存在普通函数声明。`[C]`
- 同一 `LazyForEach` 内：用了 `onDataAdd` 就不要再混用 `onDatasetChange`。`[C]`
- `getData` 声明返回 `any` —— 实现时返回具体类型即可（官方样例即如此）；`any` 在**你的实现签名**里写会触犯 `arkts-no-any-unknown`，所以写成具体类。`[C/I]`

```ts
class MessageSource implements IDataSource {
  private items: ChatMessage[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.items.length; }
  getData(index: number): ChatMessage { return this.items[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) { this.listeners.splice(i, 1); }
  }
  push(msg: ChatMessage): void {
    this.items.push(msg);
    this.listeners.forEach((l: DataChangeListener) => l.onDataAdd(this.items.length - 1));
  }
  updateAt(index: number): void {
    this.listeners.forEach((l: DataChangeListener) => l.onDataChange(index));
  }
}
```

---

## 11. ArkTS 语言限制 + async iterables

### 11.1 规则来源（本机可查）`[C]`

`...\openharmony\ets\build-tools\ets-loader\node_modules\typescript\lib\typescript.js`

- `// src/linter/ArkTSLinter_1_0/CookBookMsg.ts`（第 155862 行起，151 条）
- `// src/linter/ArkTSLinter_1_1/CookBookMsg.ts`（第 159794 行起，184 条，含 Sendable 系列）

规则编号与文案是编译期诊断的一部分，可直接 grep `cookBookTag2[`。

### 11.2 大代码库必守（逐字引规则）`[C]`

| # | 规则文案（原样） | 实务 |
|---|---|---|
| 8 | `Use explicit types instead of "any", "unknown" (arkts-no-any-unknown)` | 禁 `any`/`unknown`；JSON 结果必须转成具体类型 |
| 30 | `Structural typing is not supported (arkts-no-structural-typing)` | 两个“形状相同”的接口不能互相赋值，必须显式 `implements`/`extends` |
| 38 | `Object literal must correspond to some explicitly declared class or interface (arkts-no-untyped-obj-literals)` | 字面量前必须有类型标注（`const x: Foo = {...}`） |
| 40 | `Object literals cannot be used as type declarations` | 不能拿 `{a:string}` 当类型 |
| 17 | `Indexed signatures are not supported` | 自己别写 `[k:string]: T`（用 `Record` 或 `Map`） |
| 99 | `It is possible to spread only arrays or classes derived from arrays into the rest parameter or array literals (arkts-no-spread)` | **对象展开 `{...a}` 不支持**；`[...arr]` 可以 |
| 80 | `"for .. in" is not supported` | 只能 `for..of` / `forEach` |
| 69 / 74 / 91 | `Destructuring assignment / variable declarations / parameter declarations are not supported` | 完全不用解构（含 `const {a} = obj`、`[a,b]=…`、函数参数解构） |
| 59 | `"delete" operator is not supported` | 用 `undefined` 赋值或重建对象 |
| 66 / 65 | `"in" operator is not supported` / `"instanceof" operator is partially supported` | 用 `Object.keys`/`instanceof` 限定引用类型 |
| 53 | `Only "as T" syntax is supported for type casts` | 不许 `<T>x` |
| 55 | `Unary operators "+", "-" and "~" work only on numbers` | `+"123"` 不合法 |
| 79 | `Type annotation in catch clause is not supported` | `catch (e)` 后 `const err = e as BusinessError` |
| 87 | `"throw" statements cannot accept values of arbitrary types` | 只抛 `Error`/`BusinessError` 类 |
| 90 | `Function return type inference is limited` | 每个函数都写返回类型 |
| 92 | `Nested functions are not supported` | 内部逻辑提到方法或箭头函数变量 |
| 93 | `Using "this" inside stand-alone functions is not supported` | 回调里用箭头函数捕获 `this` |
| 94 | **`Generator functions are not supported (arkts-no-generators)`** | `function*`、`async function*`、`yield` 全部不可用 |
| 46 | `Use arrow functions instead of function expressions` | `function(){}` → `() => {}` |
| 71 | `The comma operator "," is supported only in "for" loops` | — |
| 142 | `"as const" assertions are not supported` | 用 `enum` 或 `readonly` |
| 138 | `Some of utility types are not supported` | `Partial`/`Pick`/`Omit` 等部分不可用；`Record` 可用 |
| 145 / 146 | `Strict type checking is enforced` / `Switching off type checks with in-place comments is not allowed` | **不能** `// @ts-ignore` |
| 148 | `No decorators except ArkUI decorators are currently allowed` | 只有 `@Component`/`@State`… 系可用 |
| 150 | `"import" statements after other statements are not allowed` | import 全放文件头 |
| 151 | `Usage of "ESObject" type is restricted` | 互操作用 `ESObject`，但仅限 `ts` 互操作场景 |
| 184 | `The object literal is ambiguity, the type of 1.2 cannot exist (arkts-no-ambiguity-obj-literal)` | 字面量歧义（1.1/1.2 双模）要显式标注 |

另有 `arkts-limited-stdlib`（#144）：`Object.assign`、`Reflect`、`Proxy`、`Symbol` 等大批标准库能力受限，`Function.apply/bind/call` 单独禁（#140/#152）。→ 不要写“运行时反射/动态属性”的框架代码。

### 11.3 `JSON.parse` 的正确写法 `[C]/[I]`

`lib.es5.d.ts`：`parse(text: string, reviver?: ...): any` → 直接使用会触犯 #8。

```ts
// 1) 先声明模型（class 或 interface，全部字段可空性显式）
interface SseEnvelope {
  type: string;
  sequence_number?: number;
  delta?: string;
  item_id?: string;
  response?: ResponseBody;
}

// 2) 断言，再逐字段取；不要解构、不要 for..in
const env: SseEnvelope = JSON.parse(data) as SseEnvelope;
const t: string = env.type;
if (t === 'response.output_text.delta' && env.delta !== undefined) {
  append(env.delta);
}

// 3) 数组同理
const items: ResponseInputItem[] = JSON.parse(arrText) as ResponseInputItem[];
for (const it of items) { /* … */ }
```

- `[I]`：断言不做运行时校验。可选字段一律 `?` + `!== undefined` 判断；服务端新增字段不会报错，缺字段会得到 `undefined`（**不会**抛异常）。
- 需要严格校验时用 `@ohos.util.json`（`json.parse` 带 `ParseOptions`，见 `rcp.Response.toJSON(param: json.ParseOptions)` 的引用），但本项目**不建议**引入额外解析层。

### 11.4 async iterables / `for await` —— 结论：不可用 `[C]`

证据链：

1. `arkts-no-generators`：`Generator functions are not supported`（1_0 与 1_1 两套 linter 都有，#94）。→ 写不出 `async function*`。
2. 全 SDK grep：`AsyncIterable` / `AsyncIterator` / `Symbol.asyncIterator` 在 `api/`、`component/`、`arkts/` **0 命中**。→ 没有任何 SDK API 返回可 `for await` 的对象。
3. `arkts-no-symbol`（#2）：`Symbol()` API 不支持 → 无法自己实现 `[Symbol.asyncIterator]`。
4. `ets-loader/tsconfig.json`：`"target": "es2021"`、`"lib": ["es2021"]` → **类型库层面** `AsyncIterable` 类型是存在的（只影响类型检查，不影响上述 3 条禁令）。

结论：`for await (const x of stream)` **不要出现在设计里**。尽管 TS 层面语法可能被接受（`[U]` 未实测），你无法产出符合规范的 async iterable，且 `arkts-no-generators` 会直接拒绝生成器语法。

**推荐替代接口（本项目采用）**：

```ts
export interface ChatStreamSink {
  onReasoningDelta(text: string): void;
  onTextDelta(text: string): void;
  onToolCall(call: ToolCall): void;
  onSearchState(state: SearchState): void;
  onUsage(usage: TokenUsage): void;
  onTitle(title: string): void;
  onError(err: ChatError): void;
  onDone(stopReason: StopReason): void;
}

export interface ChatStreamHandle {
  cancel(): void;
  readonly done: Promise<void>;      // 仅用于“等结束”，不用于取数据
}
```

即：**Promise 表示生命周期，回调表示数据**。这与 rcp 的 `onDataReceive` 模型天然一致，也避免 ArkTS 缺少 `AsyncIterable` 的硬约束。

---

## 12. Unconfirmed / conflicts

| # | 项 | 状态 | 处理建议 |
|---|---|---|---|
| 1 | `response.reasoning_text.delta` / `.done` 的 JSON 字段（`content_index`/`output_index` 是否存在） | 事件名 `[C]`，载荷 `[U]` | 首联调打印原始 `data`；解析器对缺失字段容忍 |
| 2 | `response.web_search_call.in_progress/searching/completed` 的 `data` 载荷 | `[U]` | 只用 `output_item.added/done` 驱动 UI，三件套只当“进度心跳” |
| 3 | `response.function_call_arguments.delta/done` 字段名 | 名称 `[C]`，载荷 `[U]` | 同上；`function_call` 全量在 `output_item.done` 里一定有 |
| 4 | Responses API 的 `: keep-alive` 注释帧 | `[U]`（Messages 文档明确有，Responses 未逐字说） | SSE 解析器按规范忽略 `:` 行，零成本兼容 |
| 5 | `response.title` 是否也会在 `response.incomplete` 出现 | `[U]` | 三个终点事件都尝试读 `response.title` |
| 6 | `web_search`（内置）与 `deepseek_web_search` 的事件差异（`searching` 是否只对 `web_search` 发） | `[U]` | 不区分，统一按 kind 渲染；`web_search` 仅 v4-pro 且本项目不用 |
| 7 | `deepseek_read_url` 在 Responses API 是否必须写 `name` | `[I]`（指南示例只写 `type`） | 只写 `type`；若要 400 再补 `name` |
| 8 | Responses API 联网工具的自主调用上限是否也 ~20 次 | `[I]`（同一引擎，Messages 文档给的 20 次） | UI 上给 20 次上限的软提示，不做硬限 |
| 9 | `onDataReceive` 返回 `number` 的语义 | `[U]` | 一律 `return void` |
| 10 | 使用 `onDataReceive` 后 `response.body` 是否严格为空 | `[I]`（由 NOTE 推出） | 只用 `statusCode`/`headers`，不读 `body` |
| 11 | `rcp` 强制 HTTP/2 的稳定性（`httpVersionSelectCallback`） | 签名 `[C]`（API 26），行为 `[U]` | 默认不强制，仅记录 `response.httpVersion` |
| 12 | `rcp` 明文 HTTP：`1007900201 Plaintext transmission is forbidden`（6.1.0(23)） | `[C]` 存在该错误码 | 本地 LAN HTTP 编辑请走 `@ohos.net.socket`，不要用 rcp |
| 13 | FTS5 是否启用（`CREATE VIRTUAL TABLE ... USING fts5`） | `[U]`，SDK 仅暴露 `Tokenizer`/`isTokenizerSupported` | 先按 LIKE/倒排表实现，写一个探测 + 回退 |
| 14 | `LazyForEach` 的 `IDataSource.getData(): any` 与 `arkts-no-any-unknown` 是否冲突 | `[C]` 声明是 `any`；实现返回具体类型是官方写法 | 实现签名写具体类，别写 `any` |
| 15 | 实况窗 | **明确结论：SDK 无 `@ohos.app.ability.LiveView`** | 用通知 / `LiveFormExtensionAbility` / 应用内 UI |
| 16 | `wantConstant.Action.ACTION_VIEW_DATA` | **明确冲突**：stage 侧无此常量，仅 FA 遗留（已废弃） | 用字符串 `'ohos.want.action.viewData'` |
| 17 | 分享文本的标准 `want.parameters` key | `[U]` | 联调时打印 `want` 定案 |
| 18 | `ShareExtensionAbility` 的 `module.json5` `type: "share"` 与 `skills.uris` 精确取值 | `[U]`（打包 schema 不在 SDK api 目录） | 以 DevEco 新建模板产出为准 |
| 19 | `transferMs: 0` 是否表示“无限制” | `[U]` | 写大值（1800000）+ `inactivityMs`，不要写 0 |
| 20 | DeepSeek 缓存 TTL 具体秒数 | `[U]`（原文“几个小时到几天”，尽力而为） | 不设计“依赖 TTL”的逻辑 |

### 已解决的蓝图疑点（供交叉核对）

- “**没有 `[DONE]` 终止符**” → **正确**。原文：“最后一个事件是 `response.completed` / `response.incomplete` / `response.failed`（没有 `data: [DONE]` 消息）”。
- “**标题走 `response.title`**” → **正确**（流式读终点事件的 `response.title`；非流式读顶层 `title`）。
- “**`usage.input_tokens_details.cached_tokens`**” → **正确**（另有 `output_tokens_details.reasoning_tokens`、`usage.server_tool_use`）。
- “**`signature` 必须原样回传**” → **正确**（`read_link` 成功时才有；改 `url/title/published_at` 无影响，改 `signature` 则网页丢失）。
- “**`tool_choice` 不能强制联网工具**” → **正确**（400，错误文案见 §3.2）。

### chat-demo 兼容性（历史导出格式 v3）`[C]`

来源：`chat-demo` 仓库 `src/services/chat/history/format.ts` 与 `history/README.md`
（`https://cdn.jsdelivr.net/gh/deepseek-ai/chat-demo@main/src/services/chat/history/format.ts`）。

- **注意**：chat-demo 客户端用的是 **Messages API（Anthropic 格式）**，不是 Responses API（其块类型为 `thinking_delta`/`signature_delta`/`message_stop`/`server_tool_use`）。所以只能兼容“**归档格式**”，不能照搬其 wire 解析。
- ZIP 文件名：`deepseek_data-日期.zip`；`export_format_version: 3`；**`manifest.json` 必须是第一个条目**。
- 条目顺序：

```
manifest.json
chat_sessions/{session_id}.json              每条会话一个（含消息树）
chat_session_index.json                     会话索引
chat_sessions/{session_id}_files/{file_id}_{file_name}    全部图片原件
```

- `manifest.json`：`{ "export_format_version": 3 }`（仅此一字段）。
- `chat_session_index.json` 数组项：`{ id, title: string|null, pinned: boolean, message_count: number, inserted_at, updated_at }`。
- 会话文件：`{ id, title: string|null, pinned: boolean, current_message_id: number, inserted_at, updated_at, messages: ChatMessage[] }`。
- `ChatMessage`：`{ id: number, parent_id: number|null, role: 'USER'|'ASSISTANT', status, thinking_enabled: boolean, search_enabled: boolean, accumulated_token_usage: number, inserted_at, fragments: Fragment[] }`。
- `ChatMessageStatus`：`WIP` | `FINISHED` | `CONTENT_FILTER` | `FAILED` | `INCOMPLETE` | `CONTEXT_LENGTH_EXCEEDED` | `TIMEOUT`。
- `Fragment` 判别联合（`type` 字段）：
  `REQUEST{content}` · `RESPONSE{content}` · `THINK{content, elapsed_secs: number|null}` · `TEMPLATE_RESPONSE{content}` · `TIP{content, style:'INFO'|'WARNING'|'CAUTION'}` · `CONTENT_RISK{content, style}` · `PARTIAL_FILE_READ{ratio:0-100}` · `TOOL_SEARCH{queries, results[], status?, stage_id?, group_id?}` · `TOOL_OPEN{status, url, title, snippet?, site_name?, published_at, …}` · `TOOL_FIND{status:'WIP'|'FINISHED'|'NO_RESULT'|'FAILED', pattern?, …}` · `READ_LINK{results:[{url?, title?, signature}]}` · `FILE{files: FileEntry[]}` · `TOOL_IMAGE_SEARCH{status, image_indexes?, results[]}`。
- `SearchResult`：`{ url, title, snippet, published_at: string|null, site_name: string|null, site_icon? }`；`FileEntry`：`{ id, file_name, file_size, token_usage: number|null, inserted_at, export_path: string|null, is_image, width, height }`。
- 时间格式：UTC RFC 3339、`Z` 结尾、小数秒精度不固定。
- 校验规则：`parent_id` 必须**小于**自身 `id`；角色交替；根是 `USER`；`current_message_id` 决定当前分支，其他节点默认选中 **id 最大的子消息**。
- ZIP：单卷 ZIP32，STORE/DEFLATE（导出用 STORE）；**不支持 ZIP64、加密、分卷、非 UTF-8 的非 ASCII 文件名**；条目名按 NFC 比较。
- 不保存：API Key、应用设置、非当前分支选择、用量明细、结构化错误详情、思考签名、原工具调用 ID、`latestReminder` 快照。

对 ChatAnyWhere 的落地建议 `[I]`：本地库字段直接镜像上面的命名（`parent_id` / `current_message_id` / `status` / `fragments` 判别联合），这样导出/导入只需一层 JSON 映射；但**上游请求仍用 Responses API 的 `input` item 形状**，两套模型在仓储层做转换，不要混用。
