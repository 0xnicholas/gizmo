# 调研:DeepSeek 用量数据源规格

> 方式:官方文档([DeepSeek API Docs](https://api-docs.deepseek.com))为主源 + 本机真实凭据只读探测 + 社区交叉印证。研究票:「DeepSeek 用量数据源调研」(#2)。无任何密钥/令牌值出现在本文件与 issue 中。

## 结论

- **剩余额度(余额):官方公开 API 可用**,`GET https://api.deepseek.com/user/balance`,Bearer API key 认证,**已实测 HTTP 200 通过**。返回充值/赠送/总余额与可用状态。这是「用量监视器」DeepSeek 侧唯一**稳定官方**的数据来源。
- **用量历史(本周用量/明细):官方没有公开的用量统计 API**。平台前端(`platform.deepseek.com`)内部端点(如 `/api/v0/usage/amount`、`/api/v0/usage/cost`、`/api/v0/usage/by_api_key/*`)能按天/按模型给 token 与消费,但需要**网页登录会话**,不是 API key。社区有多个开源工具抓包使用(见下),但属非官方、易随前端改版失效。
- **频限:官方现行口径是「账户级并发上限」,不是 RPM/TPD 令牌制限额**。超限回 HTTP 429。响应头是否带 `retry-after` 仅有第三方资料提及,未在官方文档确认。
- **额度周期:DeepSeek 是按 token 预付费扣款,没有「套餐周期/每周配额」概念**。"本周用量"在官方 API 侧无定义 → 要么本地记账,要么走平台内部接口/人工看板。
- 凭据形态:`~/.pi/agent/auth.json` 的 `deepseek` 条目为 **API key 型**(`type: api_key` + `key`,前缀 `sk-`),**无刷新机制**,长期有效。

## 端点规格

### 1. 查询余额(官方,已实测)

- URL:`GET https://api.deepseek.com/user/balance`
- 认证:HTTP 头 `Authorization: Bearer <DEEPSEEK_API_KEY>`
- 实测结果:HTTP 200;响应头**无**任何 `x-ratelimit-*`/`rate`/`limit` 类头
- 响应 JSON 字段(官方 schema,值均为 string):

| 字段 | 类型 | 含义 |
|---|---|---|
| `is_available` | boolean | 余额是否足以发起 API 调用 |
| `balance_infos[]` | array | 按币种列表(CNY / USD) |
| `balance_infos[].currency` | string | `CNY` \| `USD` |
| `balance_infos[].total_balance` | string | 可用总余额(= 充值 + 赠送) |
| `balance_infos[].granted_balance` | string | 未过期的赠送余额 |
| `balance_infos[].topped_up_balance` | string | 充值余额 |

- 请求示例(令牌为占位符):

```bash
curl https://api.deepseek.com/user/balance \
  -H "Authorization: Bearer <DEEPSEEK_API_KEY>"
```

- 来源:https://api-docs.deepseek.com/api/get-user-balance

### 2. 用量历史 / 明细(非官方,平台内部接口)

官方无此公开 API;社区工具(`CodexBar` 类需求)抓包平台前端得到以下内部端点(需**网页登录态 Cookie**,非 Bearer API key):

- `GET https://platform.deepseek.com/api/v0/usage/amount` — token 用量(按日/按模型)
- `GET https://platform.deepseek.com/api/v0/usage/cost` — 消费金额
- `GET https://platform.deepseek.com/api/v0/usage/by_api_key/{amount,cost}` — 按 API key 筛选

来源(均第三方,仅供参考,非官方承诺):
- deepseek-ai/awesome-deepseek-integration issue #654(请求官方提供聚合用量 API):https://github.com/deepseek-ai/awesome-deepseek-integration/issues/654
- AzureHalcyon/dsh-deepseek-usage README:https://github.com/AzureHalcyon/dsh-deepseek-usage
- Huasecc/dsh-usage README:https://github.com/Huasecc/dsh-usage

> 建议:对「用量监视器」,该端点群**不进 v1** —— 依赖网页会话且无稳定性承诺。

### 3. 频限语义(官方)

官方「Rate Limit」页现以**账户级并发上限**为准(非 RPM/TPD):

| 模型 | 并发上限 |
|---|---|
| `deepseek-v4-pro` | 500 |
| `deepseek-v4-flash` | 2500 |
| `deepseek-v4-flash-vision-exp` | 2500 |

- 并发以「请求发出到响应完成」计;超出即回 `HTTP 429 Rate Limit Reached`;并发按账户计算(与用哪个 key 无关)。
- 来源:https://api-docs.deepseek.com/quick_start/rate_limit
- 第三方资料称 429 响应带 `retry-after` 头(未在官方文档确认,实现时以探测为准):https://theneuralbase.com/deepseek-api/learn/advanced/fallback-configuration/

错误码语义(官方):429=发太快;另有 402 Insufficient Balance(余额耗尽)—— 与余额端点的 `is_available: false` 对应。来源:https://api-docs.deepseek.com/quick_start/error_codes

## 凭据形态(auth.json)

`~/.pi/agent/auth.json` → `deepseek`:

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | string | 固定 `"api_key"` |
| `key` | string | API key(前缀 `sk-`),直接作为 `Authorization: Bearer` 用 |

- **无 refresh/token 有效期机制**,无需刷新;平台侧吊销前长期有效。
- 读取层可直接读该条目喂给余额端点。

## 额度与周期口径

- 计费:预付费、按 token 扣款;没有订阅「套餐」「每周额度」概念。
- 「本周用量」可行口径(供「统一用量数据模型」票参考):
  1. **本地记账**:记录本机(pi 等)发出的 DeepSeek 调用(会话日志里有每次 completion 的 usage 字段),自行按周累计 —— 干净、官方允许,但只统计本机流量;
  2. 平台内部接口/看板(网页会话,仅人工查看);
  3. 平台 Web 登录态 + 内部端点(非官方,不建议 v1 采用)。
- 余额两个子字段语义不同:充值余额 vs 赠送余额(可能有过期时间),展示时可拆分。

## 频限暴露方式

- 官方**:无查询型接口**,只有行为型:超过并发上限时 chat/completions 类请求返回 429;余额/用量端点不返回任何限流头。
- 频限文档值是静态表(并发数),可直接内置展示;要「实时频限明细」只能靠**本地记录自身 API 调用**时捕获的 429/耗时情况。
- 429 是否带 `retry-after`:待 v1 实测确认(第三方称有)。

## 缺口与风险

1. **无官方用量历史** = 「本周用量」无法纯官方实现;本地记账方案只覆盖本机发生的调用。
2. 平台内部 `/api/v0/usage/*` 依赖网页会话且非官方,**易碎**,仅作远期选项。
3. 余额数值为 string(非数字),需解析;多币种(CNY/USD)并存时按 `currency` 拆分。
4. 免费赠送余额(`granted_balance`)有「未过期」限定,UI 可提示或忽略。
5. 429 的 `retry-after` 头、平台内部端点的请求签名/参数,均属未在官方文档确认项,后续实现时再实测。
