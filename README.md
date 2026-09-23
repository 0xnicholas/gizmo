# 用量监视器

私人 macOS 菜单栏 App:把 **DeepSeek**、**Kimi for Coding**、**GLM Coding Plan** 三家的套餐与用量收在一处——菜单栏一眼看 Kimi,popover 看三家细节,临界 / 凭据 / 到期会自己出声。纯本机运行,凭据只进系统钥匙串。

## 它长什么样

- **菜单栏图标**:恒为 **Kimi 一家**的用量——数字 = Kimi 最紧套餐窗(现实里只有「周窗口」)的剩余 %,颜色随 Kimi 自身状态;他者更紧也不改图标。没有数字时灰「—」,来历由 VoiceOver / tooltip 那行说明讲清(未配置 / 凭据失效 / 读取失败 / 到期 / 尚无数据);数据过旧时数字降透明度,说明里补「数据较旧(最后成功 HH:mm)」。
- **popover**:顶部「全局最紧」总览条(三家中最紧的窗 + 全局最差 + 「已到期:」行)、三家 tab 速览、逐家焦点卡(套餐窗口、Kimi 频限滚动窗、余额 / 钱包、近 7 天消耗、套餐有效期与到期态)。
- **通知**:用量跨入临界、凭据失效、套餐到期三类(前 3 天 / 当天 / 续订恢复);popover 或设置窗口在前台时不弹横幅也不响,只进通知中心。
- **设置**:逐家凭据、登录自启开关、通知授权状态。

## 环境要求

- macOS 13 或更新。
- **本机无 Xcode**:构建与测试走 swift.org 独立工具链 6.1.3(6.3+ 的宿主工具要求 macOS 14,装不上;swiftly 在这台机器上会崩)。
- `~/linker-shim/ld`:CLT 的 `ld` 不认 `-no_warn_duplicate_libraries`,shim 剥掉该参数再转发。
- 测试框架是 **Swift Testing**(无 Xcode 就没有 XCTest 模块,不要 `import XCTest`)。

## 构建与测试

```sh
export PATH="$HOME/linker-shim:$PATH"
SWIFT=~/Library/Developer/Toolchains/swift-6.1.3-RELEASE.xctoolchain/usr/bin/swift

$SWIFT build      # 一条命令构建 core + App
$SWIFT test       # UsageMonitorCoreTests 与 UsageMonitorAppTests 两组
```

打包成菜单栏 App(菜单栏 App 要有 bundle 身份才用得上本地通知与登录自启):

```sh
scripts/make-app.sh            # release;产物 build/用量监视器.app
scripts/make-app.sh debug      # DEBUG 构建(含下面所有验收入口)
open build/用量监视器.app
```

只想快速看一眼改动时也可以直接 `$SWIFT run UsageMonitor`(裸可执行文件没有 bundle 身份:本地通知不生效,登录自启不会默认开启——开关仍可在设置里拨)。

首次读取既有凭据会弹一次 login keychain 授权框:点「始终允许」即永久(或在设置里重存一次)。想让这个授权跨重新打包稳定,先跑一次 `scripts/make-signing-cert.sh` 建自签证书,`make-app.sh` 会优先用它签名;证书不存在则回落 ad-hoc——ad-hoc 的 cdhash 每次重打包都漂移,钥匙串会把新构建当成新 App。

## 首次使用

1. 打开 popover →「开始配置」(未配置时)或设置窗口,在三家页面粘贴凭据:DeepSeek API key(`sk-` 开头,作 Bearer 用)、Kimi for Coding 访问 token(整段复制)、GLM 套餐 API key(裸 key)。值只在进程内使用,存本机钥匙串(service `com.nicholasli.usagemonitor.credentials`,account = provider 键名),不落日志、不进快照。
2. 保存后立即刷新;此后每 30 分钟后台轮询三家,打开 popover 与手动刷新即时生效。单家连续失败 3 轮(≈90 分钟)显示「加载失败」,不牵连他者。
3. 快照缓存在 `~/Library/Application Support/用量监视器/snapshots.json`(单份、无历史):重启先显旧数据再刷新。

## 开发期验收入口(仅 DEBUG 构建)

| 入口 | 干什么 |
|---|---|
| `--render-previews <目录>` | 离屏渲染全部界面形态成 PNG + Vision OCR 打印可见文案(本机没有 Xcode Previews);覆盖 popover 各态、设置窗口各态、菜单栏图标全态,浅色 + 深色 |
| `--smoke-fetch` | 真实适配器 → 三家真实端点 → 解析归一化 → 原子落盘 → 回读;连跑两次即验「杀 App 重启先显旧数据」 |
| `--smoke-poll <秒> <轮数>` | 真实时钟短周期轮询(30 分钟策略的缩比验证) |
| `--smoke-auth <provider>` | 假凭据 → 真实 401 → 重试一次 → 凭据失效事件 |
| `--smoke-outage <provider>` | 不可路由地址真实超时 ×3 轮 → 加载失败 → 恢复;单家失败不牵连他者 |
| `--smoke-login-item` | 真实 LaunchAgent 写删 + `launchctl` 即时加载 / 卸载(冒烟专用 label,无残留) |
| `--simulate-keychain-failure` | 保存凭据时注入钥匙串写入失败(-34018 红横幅),读取照常,不动真实钥匙串内容 |
| `--debug-test-notifications <秒>` | 每 N 秒轮转发一条测试通知(用量临界 / 即将到期 / 已到期 / 已恢复);需打包后运行 |

冒烟凭据优先取环境变量(仅进程内存,永不回显),缺者回落钥匙串:`SMOKE_DEEPSEEK`、`SMOKE_KIMI`、`SMOKE_GLM`。

## 代码地图

```
Sources/UsageMonitorCore/   # 领域与策略:快照、解析、status 推导、到期判定、通知文案(不依赖 AppKit)
Sources/UsageMonitor/       # App 壳:AppModel、SwiftUI 视图、适配器(钥匙串 / 文件缓存 / 通知 / LaunchAgent)
Tests/…CoreTests/           # 虚拟时钟 + 假件的策略测试
Tests/…AppTests/            # 呈现层纯逻辑 + 适配器最小冒烟
```

- 领域词汇(provider / 快照 / 额度窗口 / 余额 / 到期 / 凭据 / 登录自启…)见 `CONTEXT.md`——写代码、起名、开 issue 都用那里的词。
- 三家数据来源的实测笔记在 `docs/research/`;UX 决议与后续修订在 `docs/specs/`;issue 流程与构建 / 验收约定见 `AGENTS.md`。

## 许可

MIT,见 `LICENSE`。
