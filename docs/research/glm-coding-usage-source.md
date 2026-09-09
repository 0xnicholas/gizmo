# GLM Coding Plan 用量数据源调研

> 调研日期:2026-09-09(账户实测数据即日)
> 调研范围:本机 `~/.pi/agent/auth.json` 中 `zai-coding-cn` 条目对应的 GLM Coding Plan 套餐(CN 区,实测档位 **Pro**)
> 方法:官方文档 + 智谱官方 Claude Code 插件源码 + 只读 GET 探针(凭据仅在进程内存中使用,全文无任何密钥原文)

## 结论

GLM Coding Plan 的**额度(剩余/已用)、周期用量明细(逐时/逐日 tokens 与调用数)、MCP 工具用量**都可以通过一组 monitor REST 端点程序化查询。该组端点**未被正式文档收录**(`/well-known/api-catalog` 404),但被智谱官方插件 `glm-plan-usage`(仓库 `zai-org/zai-coding-plugins`,经 docs.bigmodel.cn 用量查询插件页发布)与第三方生态实际使用,是事实标准。

凭据即套餐 API Key 本身:HTTP 头 `Authorization: <key>`(**无 Bearer 前缀**),与模型调用共用同一把 key。

- 本机条目形态:`{"type": "api_key", "key": "<49 字符>"}`——是静态 API key,**无 token 刷新需求**。
- 三个端点:额度快照(无参)、模型用量时序、MCP 工具用量时序(后两者需 `startTime`/`endTime`)。
- 同一 key 在 CN(`open.bigmodel.cn`)与 INTL(`api.z.ai`)两个 base 上**实测均返回 200 且数据一致**;但套餐受地区规则约束(风控、限流),产品应固定使用 CN base。

## 端点规格

统一请求形态(GET,来源:官方 `query-usage.mjs` + 实测确认):

```
Host:    https://open.bigmodel.cn        (CN / 本项目采用)
         https://api.z.ai                 (INTL)
Headers: Authorization: <api-key>         # 原始值,无 Bearer
         Accept-Language: en-US,en
         Content-Type: application/json
```

### 1. 额度快照 — `GET /api/monitor/usage/quota/limit`

无查询参数。实测响应(Pro 账户,CN base):

```json
{"code":200,"msg":"Operation successful","data":{
  "limits":[
    {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":641,
     "remaining":11358,"percentage":5,"nextResetTime":1788937420709},
    {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":60000,"currentValue":44070,
     "remaining":15929,"percentage":73,"nextResetTime":1789177578997}
  ],
  "level":"pro"},
 "success":true}
```

字段语义(实测 + 官方脚本 `processQuotaLimit` 对照):

| 字段 | 语义 |
|---|---|
| `limits[].type` | 额度类型。实测 CN Pro 为 `CREDIT_LIMIT`(两行);智谱官方 intl 插件文档还映射过 `TOKENS_LIMIT`(→"Token usage(5 Hour)")与 `TIME_LIMIT`(→"MCP usage(1 Month)")。**schema 在演进,解析须按 type 分支并容错未知类型** |
| `limits[].usage` | 该窗口**额度总量**(实测 Pro:第 1 行 12,000 = 5 小时积分;第 2 行 60,000 = 周积分;与官方「套餐概览」Pro 档 12,000/60,000 完全一致) |
| `limits[].currentValue` | 窗口内**已消耗积分**(5h 行 641;周行 44,070) |
| `limits[].remaining` | 剩余积分(currentValue + remaining ≈ usage) |
| `limits[].percentage` | 已消耗百分比(641/12,000≈5.3%→`5`;44,070/60,000≈73.5%→`73`) |
| `limits[].nextResetTime` | 下次窗口重置时刻,epoch **毫秒**。实测换算:5h 行 → `2026-09-09 15:03`(动态滚动);周行 → `2026-09-12 09:46`(订阅 7 天周期锚点,非自然周) |
| `limits[].unit` / `number` | 窗口编码(第 1 行 unit=3&number=5 → 5 小时;第 2 行 unit=6&number=1 → 周) |
| `data.level` | 套餐档位,实测 `pro`(另有 `lite` / `max`?) |

### 2. 模型用量时序 — `GET /api/monitor/usage/model-usage`

查询参数(格式与窗口规则来自官方脚本 + 实测):

```
?startTime=<yyyy-MM-dd HH:mm:ss  url-encoded>&endTime=<同上>
```

- 时间格式为 `%Y-%m-%d %H:%M:%S`;endTime 建议取「当前小时 59:59:999」。
- 窗口粒度自适应:短窗(≈24h)返回 **hourly** 桶(实测 25 个桶);8~31 天窗口返回 **daily** 桶(实测 31 天 OK、32 天与 40 天报业务错 `code:500 "time range exceeds limit"`)。

实测响应结构(hourly,CN):

```json
{"code":200,"data":{
  "x_time": ["2026-09-08 10:00", "…每小时一格…", "2026-09-09 10:00"],
  "modelCallCount": [0,245,246,80,…],        // 每小时调用数
  "tokensUsage":    [0,31955836,…],           // 每小时 tokens
  "totalUsage": {"totalModelCallCount":847,"totalTokensUsage":136558059,
    "modelSummaryList":[{"modelName":"GLM-5.3","totalTokens":136558059,"sortOrder":1}]},
  "modelDataList":[{"modelName":"GLM-5.3","sortOrder":1,"tokensUsage":[…],"totalTokens":136558059}],
  "granularity":"hourly"},
 "success":true}
```

要点:
- 按模型的拆分在 `modelDataList`/`modelSummaryList`(实测仅 GLM-5.3)。
- 8 天实测总量 598M tokens / 4,626 次调用(daily 粒度)。
- **注意**:桶值只有「总 tokens」一个数字,**没有 input/cached/output 拆分**,也没有高峰/非高峰标记 → 无法用官方抵扣系数精确换算成积分(见「缺口与风险」)。

### 3. MCP 工具用量时序 — `GET /api/monitor/usage/tool-usage`

与 model-usage 同参数同窗口规则。实测响应:

```json
{"code":200,"data":{
  "x_time": […逐小时…],
  "networkSearchCount":[…], "webReadMcpCount":[…], "zreadMcpCount":[…],
  "totalUsage":{"totalNetworkSearchCount":0,"totalWebReadMcpCount":0,
    "totalZreadMcpCount":0,"totalSearchMcpCount":0,
    "toolDetails":[],"toolSummaryList":[]},
  "granularity":"hourly"},
 "success":true}
```

### 错误形态

- HTTP 非 200:官方脚本处理 401/403(认证)、429(限流)、5xx;响应体可能携带 `code/msg/success` 业务错误。
- 业务错误示例(窗口超限):HTTP 200 + `{"code":500,"msg":"Parameter validation failed: incorrect time format or time range exceeds limit","success":false}`。

## 凭据形态(供「凭据读取层」票引用)

`~/.pi/agent/auth.json` → `zai-coding-cn`:

```json
{ "type": "api_key", "key": "<49 字符静态字符串>" }
```

- 是套餐 API Key(在 bigmodel「个人编程套餐 → 套餐概览」新建),**不是 OAuth/session token,无过期刷新机制**。
- 同一 key 同时是模型调用凭据:CN 模型端点 `https://open.bigmodel.cn/api/coding/paas/v4`(OpenAI 协议)、`/api/anthropic`(Anthropic 协议)等(来源:套餐快速开始文档)。读取层按 `type=="api_key"` 分支即可;不做任何刷新。
- 该 key 在 INTL base(`api.z.ai`)实测同样可用——产品层固定 CN 即可,勿跨区使用以免触发风控。

## 额度与周期口径

来源:docs.bigmodel.cn「套餐概览」官方表 + 实测字段对照。

| 档位 | 每 5 小时积分 | 每周积分 |
|---|---|---|
| Lite | 2,000 | 10,000 |
| **Pro(实测本账户)** | **12,000** | **60,000** |
| Max | 28,000 | 140,000 |

刷新规则(官方):
- **5 小时积分:动态滚动**——某笔请求消耗的额度在「该请求发生后 5 小时」刷新;因此没有固定重置时刻(但 `nextResetTime` 字段给出当前最近一次重置时间点,可直接展示「X 小时 Y 分后重置」)。
- **周积分:自下单时刻起每 7 天刷新**(非自然周)。实测 nextResetTime `2026-09-12 09:46` 印证「锚点=下单时刻」。
- 额度耗尽后需等待下一 5 小时周期,**系统不会扣其他资源包/账户余额**。

积分抵扣(官方):`模型消耗积分 = (输入 tokens×Input系数 + 缓存命中×Cached系数 + 输出×Output系数) / 10000`;MCP 消耗 = 调用次数×Output 系数。GLM-5.3:6.9/1.7/24;GLM-5.3-Flash:2.3/0.56/8。非高峰时段按基础积分 50% 抵扣。**系数与折扣会随定价调整,勿硬编码用于换算展示**(只展示 API 已给的 `currentValue`/`percentage`)。

### 「本周用量」的可行定义(供「统一用量数据模型」票)

- **套餐周期用量**(5h / 7d 已耗积分):直接读 `quota/limit` 的 `currentValue` + `remaining`——零计算。
- **自然周(周一 0 点起)token 用量**:用 `model-usage`,请求 `startTime=本周一 00:00:00`、`endTime=now`,得到 daily 桶,累加 `tokensUsage`(实测可行)。也可精确取当天的 hourly 桶。
- **自然周积分**:无法精确得出(周周期不从自然周对齐;5h 动态窗口跨自然周边界;tokens 桶缺输入/输出拆分与峰谷标记)。若产品需要,只能本地按天累计 `quota/limit` 快照做近似。
- 建议产品展示口径:**套餐周周期积分进度(权威)+ 自然周 tokens/调用数(估算)**。

## 频限(rate limit)暴露方式

- **没有数值型频限查询接口**。官方口径(z.ai usage-policy / bigmodel 使用须知):速率按**并发数**限制,与档位挂钩,平台动态调整,原则 **Max > Pro > Lite**;推荐并发项目数 Lite=1、Pro=1~2、Max=2+。
- 模型调用频限的实际表现:HTTP 429;套餐额度耗尽时服务端提示等待下一 5 小时周期(不会转扣其他余额)。
- monitor 端点自身频限未知且未文档化。官方脚本 10s 超时、无重试、遇 4xx/5xx 直接报错 → **轮询节奏应保守**:额度快照建议 ≥60s 一次,失败指数退避;显示旧快照 + 手动刷新兜底(落入「刷新与缓存策略」票)。

## 缺口与风险

1. **非正式接口**:端点不在公开 API 目录(api-catalog 404);官方插件在用但 schema 已观察到演进(官方脚本仍映射 `TOKENS_LIMIT`/`TIME_LIMIT`,实测返回 `CREDIT_LIMIT`)。解析层必须容错,未知 `type` 保留原字段不崩溃。
2. **周周期 ≠ 自然周**:周积分锚定订阅时刻,「本周用量」须明确口径,不能拿 7 天周期进度冒充自然周。
3. **tokens 桶无法精确换算积分**:缺 input/cached/output 拆分与峰谷标记;积分抵扣系数随定价变化。
4. **凭据即额度钥匙**:auth.json 里的 key 直接决定展示的账号与档位;换套餐/过期后 `quota/limit` 行为需实测确认(未见官方说明)。
5. **合规**:套餐限定官方支持工具使用,任何形式的代理/中转违反使用须知;本产品仅个人本机展示用途,只做只读 GET,不转发模型流量,风险低但仍应仅在订阅人本人机器使用。

## 来源

- 实测探针:2026-09-09 对 CN 与 INTL base 的 3 端点只读 GET(quota/limit 两次、model-usage 多窗口、tool-usage 一次)——一手事实来源。
- 智谱官方插件仓库(端点/参数/响应处理的权威实现):https://github.com/zai-org/zai-coding-plugins (`plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs`),文档页 https://docs.bigmodel.cn/cn/coding-plan/extension/usage-query-plugin
- 套餐额度/周期/抵扣系数(官方):https://docs.bigmodel.cn/cn/coding-plan/overview
- 并发/账号规范(官方):https://docs.bigmodel.cn/cn/coding-plan/usage-notes ;intl 版 https://docs.z.ai/devpack/usage-policy
- 端点佐证(第三方):https://github.com/timrichardson/opencode-glm-quota ;https://pypi.org/project/zai-quota/ ;https://github.com/farion1231/cc-switch/discussions/1038
