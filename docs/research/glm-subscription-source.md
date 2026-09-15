# GLM 套餐订阅记录(有效期)数据源调研

> 来源:#52 定稿期间对 CN base 的**只读 GET 探针**(本机 GLM Coding Pro 账户,探测值已脱敏)。
> 本文件转写该实测的形状与口径,供解析层回归对照;不含任何密钥、订单号、客户号、协议号与金额原文。
> 调研日期:2026-09-15(账户实测数据即日)

## 结论

- `GET https://open.bigmodel.cn/api/biz/subscription/list` 返回该账户的**订阅记录**:有效期区间 `valid`、状态 `status`、是否自动续订 `autoRenew`、商品名 `productName`,以及周期计数等诊断字段。
- 凭据与套餐额度端点**同一把 API key**:`Authorization: <裸 key>`(实测裸 header 与 `Bearer` 前缀均 200);GET 无查询参数。
- **按协议一条记录、周期就地递增**:本机跨两次付费期只有一条记录,`currentPeriod` 递增、`valid` 起点随之推后——即续订后**同一字段自动推后**,「套餐哪天断」可由 `valid` 末端派生,不需要本地累计历史。
- **非官方文档接口**(不在 api-catalog;智谱官方用量插件未使用它)→ 解析层按「分片独立失败、静默退化」处理:取不到就是「无有效期信息」,额度窗与近 7 天消耗照常。
- 响应同时携带**账单元数据**(订单号/客户号/协议号/金额类字段):本产品只落派生字段,**原文不进快照 raw**——这是对既有「raw 未知字段不丢」原则的明示例外(见 CONTEXT「raw 原文」)。

## 端点规格

统一请求形态(与 `glm-coding-usage-source.md` 同一 base、同一凭据):

```
Host:    https://open.bigmodel.cn        (CN / 本项目固定)
Method:  GET /api/biz/subscription/list
Headers: Authorization: <api-key>        # 原始值,无 Bearer;实测加 Bearer 前缀亦 200
         Accept-Language: en-US,en
```

实测响应(Pro 账户,值已脱敏):

```json
{"code":200,"msg":"Operation successful","data":[
  {"productName":"GLM Coding Pro",
   "status":"VALID",
   "valid":"2026-09-15 10:00:00-2026-10-15 10:00:00",
   "autoRenew":0,
   "currentPeriod":2,
   "billingCycle":"monthly",
   "version":"V3",
   "「订单号/客户号/协议号/金额类字段」":"(实测存在,不落盘、不上屏、不进本文件)"}
 ],"success":true}
```

字段语义(实测):

| 字段 | 语义 |
|---|---|
| `data[]` | 订阅记录数组;实测按协议一条(跨付费期不新增条目) |
| `valid` | 有效期区间串 `yyyy-MM-dd HH:mm:ss-yyyy-MM-dd HH:mm:ss`,**北京时间 +08:00**,不带时区后缀 |
| `status` | 订阅状态原值,实测 `VALID`;其它取值未知 → 只作展示与诊断,**判定不使用** |
| `autoRenew` | 是否自动续订,实测 `0`(数字 0/1)。本机为关闭 —— 到期后不会自动续订 |
| `productName` | 商品名,实测 `GLM Coding Pro` |
| `currentPeriod` / `billingCycle` / `version` | 周期计数 / 计费周期 / 记录版本:实测诊断字段,**不落盘**(不属派生字段白名单) |
| 订单 / 客户 / 协议 / 金额类字段 | 账单元数据:一概不落盘、不上屏(白名单例外) |

> fixture 说明:`ParserFixtures.glmSubscription` 用 `orderNo` / `customerId` / `agreementNo` / `payAmount`
> 作上述账单元数据字段的**形状示意**(实测字段名未逐字记录);白名单测试断言这些字段不进入
> `PlanValidity`、不进 raw、不进缓存文件。

## 解析口径(定稿)

- **时区**:有效期串按 +08:00 解读(不依赖系统时区;展示端同样固定 +08:00,否则跨时区机器上「有效期至」会差一天)。
- **定宽**:串长 39(`19 + "-" + 19`);首尾空白先裁掉(空白不属语义),其余定宽不符、无法解析、
  末端不晚于起刻 → 退回「无有效期信息」而**不报错**。
  将来若返回带时区后缀的形态,容错扩在 `GLMParser.periodBounds(of:)`(本期不做)。
- **多条记录**:取**覆盖 now 的那条**(起刻含、末端不含);都不覆盖则取**末端最晚者**——断供后仍露出最近一期,交给到期判定(到期 = `now >= validUntil`,纯派生)。
- **只透传**:`status` / `autoRenew` / `productName` 原样落 `PlanValidity`,不改写、不推断。
  `autoRenew` 只认实测的 0/1(布尔 JSON 亦归此路);其它取值一律 nil(展示「续订未知」,不猜成 true)。
- **静默退化**:分片缺失/失败、HTTP 非 200、业务错误体、`data` 非数组、无记录 → 快照 `planValidity = nil`,
  卡片不渲染有效期行,该卡其它字段与今天完全一致。
- **落盘粒度**:快照只留 有效期起止 + `status` + `autoRenew` + `productName`;该字段是后加的**可空字段**,
  旧缓存文件(无此键)读出为「无有效期信息」,**不升** `SnapshotFileCodec.currentVersion`。

## 到期判定的含义(供 #54 及其后续票引用)

- `valid` 末端即**套餐到期时刻**;`autoRenew = 0` 说明到期是排定事件而非故障。
- 到期是**派生量**(`now >= validUntil`)、不是存储的布尔:GLM 侧续订后 `valid` 自动推后,界面据此**自动翻回**,无需任何手动恢复。
- 本轮**未**实测「到期后额度端点(`quota/limit`)的形态」——本设计不依赖它;若它表现为报错,已有「到期优先于加载失败」兜底(#54)。

## 不适用:Kimi 侧没有对应来源

- `GET https://api.kimi.com/coding/v1/me` 响应里**没有任何有效期字段**。
- 网页端会员接口 `POST https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats`
  (Connect RPC;GET 返回 405)只认**网页登录 token**:携带 API key 实测 401 `invalid user token`。
- 另测 8 个候选 `/coding/v1/{subscription,membership,plan,quota,…}` 路径 → 全部 404。

结论:App **不可能**自动得知 Kimi 的到期;Kimi 侧只能用户手动标记(#52 决议),本期不为该网页接口预留抽象。

## 缺口与风险

1. **非正式接口**:不在公开 API 目录,官方用量插件未使用 → schema 可能变更;失败只退化成「无有效期信息」,不牵连其它数据。
2. **`status` 枚举未知**(实测只见过 `VALID`)→ 判定只用 `valid` 末端 + now;`status` / `autoRenew` 仅展示与诊断。
3. **`valid` 为北京时间且无时区后缀** → 将来若带后缀需扩容错(同上)。
4. **账单元数据同响应下发** → 解析层白名单(只取派生字段)是硬约束,新增字段须先确认不属账单类。

## 来源

- 实测探针:#52 定稿期间对本机 GLM Coding Pro 账户的 `open.bigmodel.cn/api/biz/subscription/list` 只读 GET
  (裸 header 与 Bearer 各一次,均 200;凭据仅进程内存,未回显)——一手事实来源。
- 同 base 同凭据的额度/用量端点形状见 `docs/research/glm-coding-usage-source.md`。
- 决议轨迹见 GitHub issue #52(定稿)与 #53(本票:分片接入 + raw 白名单)。
