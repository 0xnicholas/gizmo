# 调研:三家「控制台 ↗」链接目标 URL

> wayfinder 地图「用量监视器」研究票之一。仓库 `0xnicholas/gizmo`。研究票:「控制台链接目标调研」(issue #10)。调研日期:2026-09-09。方式:官方文档/帮助中心为锚 + 多源独立佐证 + 直接 HTTP 可达性验证。无任何凭据参与。

## 结论

| Provider | 控制台链接(登录后) | 佐证强度 |
| --- | --- | --- |
| **DeepSeek** | `https://platform.deepseek.com/usage`(开放平台用量页) | 官方文档未收录网页路径;社区多个用量工具一致指向 |
| **Kimi for Coding**(现名 **Kimi Code**) | `https://www.kimi.com/code/console`(Kimi Code 控制台:剩余额度/频限/API Key/登录设备) | **官方文档超链锚定**(主源) |
| **GLM Coding Plan**(个人版) | `https://bigmodel.cn/coding-plan/personal/overview`(个人编程套餐·套餐概览) | **官方文档超链锚定**(主源) |

三家均为**登录后可见**的网页;控制台链接由 app 在用户已登录的浏览器里打开即可,无需任何接口调用。

## 逐家明细

### 1. DeepSeek — https://platform.deepseek.com/usage

- 官方开放平台 `platform.deepseek.com` 的「用量」页,展示余额/按日消费/分模型 token 等(即上一研究票发现的平台内部端点 `/api/v0/usage/*` 所服务的页面,需网页登录会话)。
- **官方 API 文档未收录该网页路径**(api-docs 只有接口文档)。路径佐证来自多个**独立社区工具一致引用**:
  - `Huasecc/dsh-usage` README:「所见即平台用量页(platform.deepseek.com/usage)的数据」——https://github.com/Huasecc/dsh-usage
  - `YAOAORAN/deepseek-usage-plus`(官方用量页增强插件)README:「安装后访问 DeepSeek 用量页面 https://platform.deepseek.com/usage」——https://github.com/YAOAORAN/deepseek-usage-plus
- 可达性:HTTP 200(登录墙/SPA,`<title>DeepSeek</title>`)。注意该站 SPA 对任意路径回 200,HTTP 状态不能证明路由存在;路径有效性以上述多源一致引用为准。
- 备选入口:平台首页 https://platform.deepseek.com(登录后左侧导航进入用量页);API Key 管理 https://platform.deepseek.com/api_keys。
- 若担心路径随前端改版:实现时可让链接指向首页,或登录态内打开后由平台导航;鉴于多源一致 + 工具在持续维护(2026 仍更新),用 `/usage` 直链。

### 2. Kimi for Coding(Kimi Code)— https://www.kimi.com/code/console

- 官方 Kimi Code 文档「会员权益」页写明:登录 [Kimi Code 控制台](https://www.kimi.com/code/console) 可查看**剩余额度与频限状态、管理 API Key 和登录设备**。主源:https://www.kimi.com/code/docs/kimi-code/membership
- 品牌说明:Kimi for Coding 已并入 **Kimi Code**(Kimi 会员权益中的开发者服务),与本次 map 的 `kimi-coding` provider / `api.kimi.com/coding/v1` 后端同源(开放平台另指 `platform.kimi.com`,与订阅套餐是两套计费,勿混)。
- 备选:「我的额度」页(网页端 Kimi 订阅额度,含加油包):https://www.kimi.com/membership/subscription?tab=quota —— 同一官方文档「查询用量」一节并列给出,可作为 Kimi Code 控制台之外的第二入口。
- 可达性:HTTP 200,官方域 SPA(登录后内容)。

### 3. GLM Coding Plan(个人版)— https://bigmodel.cn/coding-plan/personal/overview

- 官方「快速开始」文档步骤 3 明确超链:个人版套餐用户通过 [个人编程套餐 > 套餐概览](https://bigmodel.cn/coding-plan/personal/overview) 新建 API Key。主源:https://docs.bigmodel.cn/cn/coding-plan/quick-start
- 「使用须知/套餐概览/FAQ」文档反复提到控制台内的「套餐概览(续订开关)」「用量统计(额度消耗进度)」「财务-费用账单(明细)」——这些是同一控制台区域的分页,**官方未发布独立的用量统计 URL**,链接指向套餐概览主入口即可,登录后左侧导航可达各分页。文档佐证:https://docs.bigmodel.cn/cn/coding-plan/usage-notes 、https://docs.bigmodel.cn/cn/coding-plan/overview 、https://docs.bigmodel.cn/cn/coding-plan/faq
- 本 map 实测账户为 CN 区个人 Pro → 用个人版入口;团队版成员入口为 https://bigmodel.cn/coding-plan?z_plan=team(官方同页给出,本 app 不需要)。
- 可达性:HTTP 200,官方域 SPA(登录后内容)。

## 对「用量监视器」的含义

- 卡片/焦点面板「控制台 ↗」目标按上表三家 URL;均为用户浏览器会话内打开,无鉴权传递。
- 三家网页均在登录墙后,「打开控制台」是否可用取决于用户系统默认浏览器的登录态——app 不做内嵌 WebView 登录(与凭据自管、无登录流程的既定方向一致)。
- 若有 provider 前端改版导致直链失效,页面仍有登录后首页兜底;无需代码改动即可降级为首页(URL 集中在一处常量即可)。
