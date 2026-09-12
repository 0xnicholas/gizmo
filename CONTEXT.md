# 用量监视器

本仓库的「用量监视器」是一个私人 macOS 菜单栏应用,聚合展示 DeepSeek、Kimi for Coding、GLM Coding Plan 三家的套餐与用量信息。本文件记录该领域(而非 SwiftUI 实现)的词汇。

**provider 数据源**:
一个被跟踪的用量来源。当前枚举:DeepSeek、Kimi for Coding、GLM Coding Plan。数据层按 provider 各自适配拉取,统一产出快照。
_Avoid_: 平台、厂商、账号

**plan 套餐**:
provider 侧的订阅/购买档位元信息,如 GLM 的档位(pro)、Kimi 的会员等级与域。只读展示,不参与计算。
_Avoid_: 计划、档位(「档位」仅作套餐内 level 字段的展示名)

**snapshot 用量快照**:
一次刷新后,某 provider 全部用量信息的归一化视图。结构:`meta` + `windows[]` + `balances[]` + `raw`(原始响应原文)。
_Avoid_: 状态对象、模型

**quotaWindow 额度窗口**:
有时间边界、会周期重置的额度容器:limit / used / remaining / resetAt / kind。kind 区分「套餐窗口」(GLM 5 小时窗、7 天窗与 MCP 月度窗、Kimi 周窗)与「频限窗口」(Kimi 300 分钟滚动窗)。窗口是剩余额度与健康状态的最小计算单位。
_Avoid_: 配额、限额

**rateLimit 频限**:
provider 对请求速率/并发的限制。凡以「窗口 + 重置时间」表达的频限,一律建模为 kind=rateLimit 的额度窗口;纯固定上限(如并发数)放 meta,不建窗口。频限窗不参与 status 判定;卡片上归次级区单行展示,其重置时刻的文案称「容量恢复」(区别于套餐窗的「重置」——滚动窗是容量随时间滑出,不是额度重置)。

**usage 用量**:
额度窗口内已消耗的量(窗口 used 字段),或时序接口求和的消耗量。与金额无关。
_Avoid_: 消费、消费金额、积分(积分/会话数是具体窗口的额度单位,见 unit)

**unit 额度单位**:
各窗口计数所用的单位(积分、请求数等)。原样透传展示,不做跨源换算。
_Avoid_: 点数、额度(「额度」指 limit 总量,不是单位)

**remaining 剩余**:
窗口内尚未消耗的量(limit − used),展示与状态判定均基于它。

**balance 余额**:
无窗口、无重置语义的资金型条目:type(充值/赠送/钱包)、amount、currency。DeepSeek 的余额与 Kimi 的 booster 钱包落这里。余额不参与窗口状态计算。

**rollingUsage 近 7 天消耗**:
自然滚动 7 天的累计消耗量,「本周用量」的唯一口径;与「7 天窗」的窗口剩余是两个口径。只在 provider 有直接用量数据源时提供(GLM 由官方时序接口求和);无直接来源的 provider 不显示该值,也不做本地估算。
_Avoid_: 本周用量、周用量(文案统一「近 7 天」)、近 7 天用量(旧文案,已弃)、估算

**status 健康状态**:
由快照推导的 provider 级状态:normal / low / critical。规则:取该 provider 全部 plan-window 类额度窗口剩余百分比的最低值(rate-limit 频限窗不参与,仅卡片展示);无窗口的 provider(DeepSeek)单独按余额档位规则(金额分界参数化)。阈值参数化(默认分界见「图标汇总口径与阈值取值」决议),UI 只消费不计算。

**credential 凭据**:
provider 侧的访问凭证:DeepSeek 的 API key、Kimi for Coding 的 token、GLM Coding Plan 的 API key。用户在本 app 的设置界面配置,app 不依赖任何外部登录态;值只在进程内存在,由数据层消费,UI 只感知「已配置 / 缺失 / 失效」状态、不感知值。凭据失效是 provider 可用性问题,不参与 status 的用量语义。
_Avoid_: 密钥、令牌、登录态、pi 凭据

**loginItem 登录自启**:
随用户登录自动启动 App 的产品行为:仅对打包形态的 App 默认开启(裸可执行文件不自动安装),设置窗口「通用」分组提供开关;用户成功拨动过开关即视为表态,默认逻辑此后不再自动改写。「退出用量监视器」只结束本次运行,不改自启状态。
_Avoid_: 开机启动、后台服务、SMAppService(正式分发时的迁移备选,非当前机制)
