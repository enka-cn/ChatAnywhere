/**
 * 内置示例技能（L1 声明式，首次启动播种，幂等）。
 *
 * 为什么是 L1：不依赖任何端侧脚本沙箱，导入即可用；网络访问严格走白名单。
 * 需要 DeepSeek 密钥的技能通过 `{{secret:deepseek.apiKey}}` 占位符取密钥，
 * 清单里不会出现明文 Key（红线：密钥只进 Asset Store Kit）。
 *
 * 纯数据文件（零平台依赖），可被创造室与逻辑测试直接引用。
 */

/**
 * 「技术文档联网清洗」（L1）：调用 DeepSeek 独立 Search API，按站点白/黑名单组装查询。
 * 需要先在「设置」里保存 DeepSeek 密钥。
 */
export function builtinWebSearchJson(): string {
  return `{
  "id": "tech_doc_search",
  "version": "1.0.0",
  "name": "技术文档联网清洗",
  "description": "联网检索技术资料，自动按允许/屏蔽站点过滤，并给出可直接引用的摘要。",
  "tier": "L1_DECLARATIVE",
  "enabled": true,
  "author": "builtin",
  "configSchema": [
    { "key": "count", "label": "结果条数", "type": "number", "defaultValueJson": "10", "min": 1, "max": 50, "hint": "一次返回多少条搜索结果" },
    { "key": "needContent", "label": "同时取正文", "type": "boolean", "defaultValueJson": "false", "hint": "打开后单次消耗的 Token 会明显变多" },
    { "key": "outputFormat", "label": "输出格式", "type": "enum", "defaultValueJson": "\\"summary\\"", "options": ["summary", "markdown", "bullets"], "hint": "摘要 / Markdown / 要点列表" },
    { "key": "blockedSites", "label": "屏蔽站点", "type": "string_list", "defaultValueJson": "[]", "hint": "这些站点的结果会被排除，例如 bilibili.com" },
    { "key": "allowedSites", "label": "限定站点", "type": "string_list", "defaultValueJson": "[]", "hint": "只检索这些站点，留空表示不限" },
    { "key": "focus", "label": "补充检索条件", "type": "string", "defaultValueJson": "\\"\\"", "hint": "可填 site: 或 after: 等检索语法" }
  ],
  "toolSchemaJson": "{\\"name\\":\\"search_tech_docs\\",\\"description\\":\\"联网检索技术资料，返回标题、链接、摘要与来源站点。需要 DeepSeek 密钥。\\",\\"parameters\\":{\\"type\\":\\"object\\",\\"properties\\":{\\"query\\":{\\"type\\":\\"string\\",\\"description\\":\\"要检索的问题或关键词\\"},\\"focus\\":{\\"type\\":\\"string\\",\\"description\\":\\"可选的补充检索条件\\"}},\\"required\\":[\\"query\\"]}}",
  "promptSnippet": "检索到外部资料时：优先引用原文链接并在句末标注来源编号；同一事实尽量给出两个来源；无法确认的内容要明确说明「未找到可靠来源」。",
  "runtimePayload": {
    "httpTemplate": {
      "method": "POST",
      "urlTemplate": "https://api.deepseek.com/v1/tools/search",
      "headersJson": "{\\"Content-Type\\":\\"application/json\\",\\"Authorization\\":\\"Bearer {{secret:deepseek.apiKey}}\\"}",
      "bodyTemplate": "{\\"query\\":\\"{{input.query}}{{config.allowedSites|include_sites}}{{config.blockedSites|exclude_sites}}\\",\\"count\\":{{config.count}},\\"need_content\\":{{config.needContent}}}",
      "responsePath": "results",
      "timeoutMs": 20000
    },
    "allowedDomains": ["api.deepseek.com"]
  }
}`;
}

/**
 * 「网页正文抽取」（L1）：调用 DeepSeek 独立 Fetch API，把链接清洗成 Markdown 正文。
 * 需要先在「设置」里保存 DeepSeek 密钥。
 */
export function builtinWebExtractJson(): string {
  return `{
  "id": "web_article_extract",
  "version": "1.0.0",
  "name": "网页正文抽取",
  "description": "把一个网页链接抓取并清洗成 Markdown 正文，便于总结与引用。",
  "tier": "L1_DECLARATIVE",
  "enabled": true,
  "author": "builtin",
  "configSchema": [
    { "key": "maxChars", "label": "最多保留字数", "type": "number", "defaultValueJson": "6000", "min": 500, "max": 20000, "hint": "正文过长时会被截断，避免撑爆上下文" }
  ],
  "toolSchemaJson": "{\\"name\\":\\"extract_web_article\\",\\"description\\":\\"抓取指定网页并返回 Markdown 正文。需要 DeepSeek 密钥。\\",\\"parameters\\":{\\"type\\":\\"object\\",\\"properties\\":{\\"url\\":{\\"type\\":\\"string\\",\\"description\\":\\"要抓取的网页链接（http/https）\\"}},\\"required\\":[\\"url\\"]}}",
  "promptSnippet": "引用网页正文时先概括结构，再给出关键段落；正文被截断时说明只读到了前面部分。",
  "runtimePayload": {
    "httpTemplate": {
      "method": "POST",
      "urlTemplate": "https://api.deepseek.com/v1/tools/fetch",
      "headersJson": "{\\"Content-Type\\":\\"application/json\\",\\"Authorization\\":\\"Bearer {{secret:deepseek.apiKey}}\\"}",
      "bodyTemplate": "{\\"url\\":\\"{{input.url}}\\"}",
      "responsePath": "content",
      "timeoutMs": 20000
    },
    "allowedDomains": ["api.deepseek.com"]
  }
}`;
}

/**
 * 「汇率换算」（L1）：开放汇率接口，无需密钥，适合演示技能调用闭环。
 */
export function builtinFxRateJson(): string {
  return `{
  "id": "fx_rate_convert",
  "version": "1.0.0",
  "name": "汇率换算",
  "description": "查询两种货币之间的实时汇率并换算金额，数据来自公开汇率接口。",
  "tier": "L1_DECLARATIVE",
  "enabled": true,
  "author": "builtin",
  "configSchema": [
    { "key": "decimals", "label": "保留小数位", "type": "number", "defaultValueJson": "2", "min": 0, "max": 6, "hint": "换算结果的精度" }
  ],
  "toolSchemaJson": "{\\"name\\":\\"convert_currency\\",\\"description\\":\\"查询实时汇率并换算货币金额。\\",\\"parameters\\":{\\"type\\":\\"object\\",\\"properties\\":{\\"from\\":{\\"type\\":\\"string\\",\\"description\\":\\"源货币代码，如 USD\\"},\\"to\\":{\\"type\\":\\"string\\",\\"description\\":\\"目标货币代码，如 CNY\\"},\\"amount\\":{\\"type\\":\\"number\\",\\"description\\":\\"要换算的金额\\"}},\\"required\\":[\\"from\\",\\"to\\"]}}",
  "promptSnippet": "给出汇率时说明数据更新时间与来源接口；金额换算结果保留用户配置的小数位。",
  "runtimePayload": {
    "httpTemplate": {
      "method": "GET",
      "urlTemplate": "https://open.er-api.com/v6/latest/{{input.from}}",
      "responsePath": "rates",
      "timeoutMs": 15000
    },
    "allowedDomains": ["open.er-api.com"]
  }
}`;
}

/**
 * 「实时天气」（L1）：Open-Meteo 公开接口，无需密钥。
 */
export function builtinWeatherJson(): string {
  return `{
  "id": "weather_now",
  "version": "1.0.0",
  "name": "实时天气",
  "description": "按经纬度查询当前气温、湿度与天气状况，数据来自公开气象接口。",
  "tier": "L1_DECLARATIVE",
  "enabled": true,
  "author": "builtin",
  "configSchema": [
    { "key": "units", "label": "温度单位", "type": "enum", "defaultValueJson": "\\"celsius\\"", "options": ["celsius", "fahrenheit"], "hint": "摄氏度 / 华氏度" }
  ],
  "toolSchemaJson": "{\\"name\\":\\"query_weather\\",\\"description\\":\\"查询指定经纬度的当前天气。\\",\\"parameters\\":{\\"type\\":\\"object\\",\\"properties\\":{\\"latitude\\":{\\"type\\":\\"number\\",\\"description\\":\\"纬度，如 39.9\\"},\\"longitude\\":{\\"type\\":\\"number\\",\\"description\\":\\"经度，如 116.4\\"}},\\"required\\":[\\"latitude\\",\\"longitude\\"]}}",
  "promptSnippet": "回答天气时说明查询坐标与时间，并提醒数据为当前时刻的实时观测。",
  "runtimePayload": {
    "httpTemplate": {
      "method": "GET",
      "urlTemplate": "https://api.open-meteo.com/v1/forecast?latitude={{input.latitude}}&longitude={{input.longitude}}&current=temperature_2m,relative_humidity_2m,weather_code&timezone=auto&temperature_unit={{config.units}}",
      "responsePath": "current",
      "timeoutMs": 15000
    },
    "allowedDomains": ["api.open-meteo.com"]
  }
}`;
}

/** 全部内置技能清单 JSON（顺序与 id 列表一致：按 skill id 字典序，便于人工核对与稳定播种）。 */
export function builtinSkillJsonList(): string[] {
  return [
    builtinFxRateJson(),
    builtinWebSearchJson(),
    builtinWeatherJson(),
    builtinWebExtractJson()
  ];
}

/** 内置技能 id 列表（按字典序，需与 builtinSkillJsonList 顺序一一对应）。 */
export function builtinSkillIds(): string[] {
  return ['fx_rate_convert', 'tech_doc_search', 'weather_now', 'web_article_extract'];
}
