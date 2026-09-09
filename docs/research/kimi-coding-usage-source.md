# 调研:Kimi for Coding 用量数据源(Kimi Code 后端)

> wayfinder 地图「用量监视器」研究票之一。仓库 `0xnicholas/gizmo`。
> 调研方式:反读官方 Kimi CLI(v0.41.0,`~/.kimi-code/bin/kimi` 内嵌 JS 客户端源码)+ 用本机既有凭据做只读 GET 实测(2026-09-09)。
> **本文件不含任何密钥/令牌原文;所有请求仅在进程内存中使用凭据。**

## 结论

- Kimi for Coding 的后端主机是 **`api.kimi.com`**(不是 `api.moonshot.cn`/`platform.moonshot.cn`)。
- **额度/用量/频限查询端点公开可用**:
  - `GET https://api.kimi.com/coding/v1/usages` —— 一次性返回全部额度窗口(每日会话配额、滚动窗口频限、并行上限、充值钱包与月充值限额)。
  - `GET https://api.kimi.com/coding/v1/me` —— 账户资料(昵称/档位/域/region),用于展示计划元信息。
- 认证:`Authorization: Bearer <token>`,`Accept: application/json`,超时建议 ≤8s。凭据可直接复用 **pi 登录态** `~/.pi/agent/auth.json` 的 `kimi-coding` 条目(实测类型为 `api_key`,作为 Bearer 打 `/usages` 返回 200)。
- 「剩余额度、本周用量、频限明细」:**用量窗口按「当前周期剩余」给出**,服务端**不提供历史消费曲线**;「本周用量」需要本地记账累计(把每次拉到的窗口用量归档推算,或记录自己的请求),不是现成的字段。
- 实测值(2026-09-09,账户为 `REGION_CN` / `LEVEL_INTERMEDIATE` / `DOMAIN_NEXUS`,购买型 `TYPE_PURCHASE`):
  - `usage`:日窗口 `limit=100, used=98, remaining=2`,reset 时间 `2026-09-10T08:24:54Z`(约每日固定时刻重置)。
  - `limits[0]`:滚动 **300 分钟**窗口 `limit=100, used=10, remaining=90`。
  - `parallel.limit=20`(并发会话上限)。
  - `boosterWallet`:CNY,月充值限额 `¥100`(10000 分),月已用 `¥0`;booster 余额以固定点整数表示(`FIXED_POINT_CENTS = 1e6`,即 `amount/1_000_000` = 货币单位)。

## 端点规格

### 1) 用量汇总 `GET {base}/usages`

- 路径:`https://api.kimi.com/coding/v1/usages`
- base 可被环境变量覆盖:`KIMI_CODE_BASE_URL`(官方 CLI 也读它;默认见上)。
- 请求头:`Authorization: Bearer <accessToken>`、`Accept: application/json`。
- 返回(HTTP 200,JSON,顶层键实测):`user` / `usage` / `limits` / `parallel` / `totalQuota` / `authentication` / `subType` / `boosterWallet` / `domain` / `version`。

| 字段 | 类型 | 含义 | 实测样例 |
| --- | --- | --- | --- |
| `usage.limit` / `usage.used` / `usage.remaining` | string(int) | 主配额窗口:上限/已用/剩余(计数单位,会话/请求数) | `"100" / "98" / "2"` |
| `usage.resetTime` | RFC3339 | 主窗口重置时间 | `2026-09-10T08:24:54Z` |
| `limits[].window.duration` + `.timeUnit` | int + enum | 频限窗口长度;`timeUnit ∈ TIME_UNIT_MINUTE/HOUR/DAY/WEEK` | `300` + `TIME_UNIT_MINUTE` |
| `limits[].detail.used/limit/remaining/resetTime` | string(int)/RFC3339 | 该频限窗口用量 | `"10"/"100"/"90"/2026-09-09T06:24:54Z` |
| `parallel.limit` | string(int) | 并发上限 | `"20"` |
| `totalQuota` | object | 总配额(当前账户为空 `{}`) | — |
| `authentication.method` / `.scope` | enum | `METHOD_API_KEY` / `FEATURE_CODING` | — |
| `subType` | enum | `TYPE_PURCHASE` 等(购买/订阅类型) | `TYPE_PURCHASE` |
| `user.userId/region/membership.level/businessId` | string | 用户/会员域;`membership.level` 如 `LEVEL_INTERMEDIATE` | — |
| `boosterWallet.status` | enum | `STATUS_ACTIVE` 等 | — |
| `boosterWallet.balance.amount` / `.amountLeft` | string(int) 固定点 | booster(充值)钱包余额;`amountLeft` 可能缺省 | `"2500000000"`(≈2500) |
| `boosterWallet.balance.unit` / `.type` / `.periodStart` / `.periodEnd` | string | `UNIT_CURRENCY` / `BOOSTER`;生效区间 | — |
| `boosterWallet.monthlyChargeLimit.priceInCents`+`.currency` | string(int)+string | 月充值限额 | `"10000"` / `CNY` |
| `boosterWallet.monthlyUsed` | 同上 | 本月已充值消费 | `"0"` / `CNY` |
| `boosterWallet.allowTopup` / `topupLimit` / `autoRefillCharge` / `autoRefillThreshold` | bool / 金额 | 充值/自动续充配置 | — |
| `domain` / `version` | enum/string | `DOMAIN_NEXUS` / `GOODS_VERSION_V1` | — |

参考实现(官方 CLI 内嵌源码中的解析逻辑):

- URL 拼接:`managedUsageUrl(base) = ${base}/usages`;`managedUserInfoUrl(base) = ${base}/me`。
- 归一化:`usage` 无 window 字段时默认视为 `{duration:1, unit:"week"}`;`window.timeUnit` 归一化为 minute/hour/day/week(分钟≥60 且整除时折算为小时)。
- `extra_usage/boosterWallet` 解析口径:`fixedPointToCents(v)=v/1e6`;monthlyUsed/limit 取 `priceInCents` 整数值即分。
- 超时 8s;失败处理见下文「错误与频限」。

### 2) 账户资料 `GET {base}/me`

- 返回:顶层键 `user_id / global_id / nickname / avatar / phone / status / region / user_level / user_level_name / domain / domain_name / created_time / last_login_time`。
- 实测:`status=USER_STATUS_NORMAL`,`region=REGION_CN`,`user_level=25`,`user_level_name="Allegretto"`,`domain_name=DOMAIN_NEXUS`。`user_level_name` 可作「计划档位名」展示素材。

## 凭据形态

| 来源 | 位置 | 类型 | 说明 |
| --- | --- | --- | --- |
| **pi 登录态(推荐复用)** | `~/.pi/agent/auth.json` → `kimi-coding` | `{type:"api_key", key:"<72 字符,无点>"}` | pi 的 `kimi-coding` provider 认证方式为 `apiKey`(env key `KIMI_API_KEY`),实测该 key 可直接作 Bearer 调 `/usages`。无刷新机制:失效后需重新 `/login kimi-coding` |
| Kimi CLI 托管 OAuth | `~/.kimi-code/oauth/kimi-code`(旧版 `~/.kimi/credentials/oauth/kimi-code`) | OAuth 令牌(access+refresh+expires_in) | OAuth 主机默认 `https://auth.kimi.com`(env `KIMI_OAUTH_HOST`),client_id `17e5f671-d194-4dfb-9706-5516cb48c098`,device-code 流;`ensureFresh` 会自动刷新 |

- pi 侧模型定义(来源 `@earendil-works/pi-coding-agent/dist/bundle/.../chunk-*.js`):`kimi-coding` provider `baseUrl: "https://api.kimi.com/coding"`,模型 `kimi-for-coding`(Kimi K2.7 Code)等,anthropic-messages API。与本调研的 `api.kimi.com/coding/v1` 同源,`/v1` 由 API 风格后缀区分(OpenAI 兼容路径 `/v1/...`)。
- 凭据只读复用要点:应用每次拉取时现读 auth.json(不缓存到本地文件),key 不做任何回显/落盘/进日志;401 → 提示「凭据失效,请重新 `pi /login kimi-coding`」。

## 额度与周期口径

- **主配额窗口(`usage`)**:按次计数(会话/请求),含 `limit/used/remaining/resetTime`;实测为每日窗口、在约每日同一 UTC 时刻重置(2026-09-09 观测到 resetTime = 次日 `08:24:54Z`)。窗口定义随账户/套餐而异,应用应展示 `resetTime` 而非硬编码「按天」。
- **频限窗口(`limits[]`)**:长度由 `window{duration,timeUnit}` 给出(实测 300 分钟滚动窗口),滚动窗口语义(used/remaining 随请求持续滑移),`resetTime` 为当前窗口过期时间。
- **「本周用量」**:服务端**不提供**历史区间消费。可行口径:(a) 展示当前主窗口用量+剩余(「今日/本窗口」);(b) 「本周」由应用本地记账:把每次拉到的 `usage.remaining` 变化或自己的请求日志累计 7 天(自然周对齐需本地定起点)。**这是数据模型票的一个输入:本周列可能需要本地记账 fallback。**
- 金额类字段为分(`priceInCents`);booster 余额为固定点(`/1e6`)。币种跟随 `boosterWallet`(实测 CNY)。

## 频限暴露方式

- **预知**:`/usages` 直接给出各窗口 `remaining`(请求数维度),以及 `parallel.limit`(并发上限)。应用可在命中 429 前预警。
- **实时**:超额请求返回 HTTP 429;错误体解析口径(官方 CLI `readApiErrorMessage`)为:顶层直取 `error_description / message / detail`,嵌套 `message / error_description / detail / code / type`。
- CLI 对 `/usages` 的 401/404 文案:401 → `Authorization failed... (try /login)`;404 → `Usage endpoint not available. Try Kimi For Coding.`(即非套餐账户无此端点)。

## 缺口与风险

- **无历史/周报表端点**:「本周用量」需本地记账推算(见上)。
- **凭据变更敏感**:auth.json 的 kimi-coding key 在重新 `/login` 后会更换;旧 key 立即失效(401)。读取层应每次现读、并把 401 映射为「需要重新登录」提示,而非当作后端故障。
- **内部端点风险**:`/usages`、`/me` 未见于公开文档(platform.moonshot.cn 文档体系不覆盖 coding 后端),依赖官方 CLI 的既有实现与实测确认,属**事实标准但非合同接口**;接口可能随 CLI 版本演进而变(建议在读取层集中封装、单一改点,并周期性用 CLI 回归验证)。
- **只读约束**:GET 为只读,不产生消费;注意避免高频轮询触发 429(对本端点是请求数而非金额计价,仍应克制)。
- **区域**:账户 `REGION_CN` 亦可访问 `api.kimi.com`(本机实测);若未来出现区域分流,读取层需支持 base URL 覆盖。

## 来源

- 官方 Kimi CLI v0.41.0 二进制内嵌客户端源码(`~/.kimi-code/bin/kimi`,字符串/上下文提取;内含 `packages/oauth/src/managed-usage.ts` 等构建产物):URL 拼装、字段解析、OAuth 主机、client_id。
- Kimi CLI 配置文件(`~/.kimi/config.toml`):`managed:kimi-code` provider `type=kimi`,`base_url=https://api.kimi.com/coding/v1`,oauth storage `oauth/kimi-code`。
- pi 安装产物(`@earendil-works/pi-coding-agent/dist/...`):`kimi-coding` provider `baseUrl=https://api.kimi.com/coding`、apiKey 认证、模型映射。
- 实测(本机,2026-09-09,凭据仅进程内存):`GET api.kimi.com/coding/v1/usages`→200(字段见上);`GET api.kimi.com/coding/v1/me`→200。
- 本票:github.com/0xnicholas/gizmo issue「Kimi for Coding 用量数据源调研」。
