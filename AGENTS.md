## Agent skills

### Issue tracker

Issues and specs live as GitHub issues, operated via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical roles mapped to default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: one `CONTEXT.md` at the root, ADRs in `docs/adr/`. See `docs/agents/domain.md`.

## Build & test

本机无 Xcode(仅 CLT):系统 SwiftPM 5.8 无法运行(PlatformPath 查找失败),且没有 XCTest 框架。构建与测试一律用 swift.org 独立工具链:

```sh
export PATH="$HOME/linker-shim:$PATH"
SWIFT=~/Library/Developer/Toolchains/swift-6.1.3-RELEASE.xctoolchain/usr/bin/swift
$SWIFT build   # 一条命令构建 core + App
$SWIFT test    # 跑 UsageMonitorCore 与 UsageMonitorApp 两组测试
```

- `~/linker-shim/ld`:CLT 14.2 的 ld 不认识 `-no_warn_duplicate_libraries`,shim 负责剥掉该参数再转发。
- 测试框架用 Swift Testing(`import Testing`),不要 `import XCTest`——无 Xcode 就没有该模块。
- 别装 6.3+ 工具链:其宿主工具要求 macOS 14,本机是 macOS 13。swiftly 在本机(x86_64 macOS 13)会崩,不要用。
- `UsageMonitorAppTests` 只放 App 壳的最小冒烟:Keychain 适配器对真实 Security 框架(独立 service,不碰生产凭据)。策略逻辑(含凭据写入的 trim/空值/失败文案)仍在 `UsageMonitorCore` 内、由 `UsageMonitorCoreTests` 覆盖。呈现层常量/纯逻辑(只在 App target 存在、下放 Core 反而污染分层的,如三态色调色板的 WCAG 锚点与亮度阶梯)也在此组单测。

## UI 形态检查(无 Xcode)

SwiftUI Previews 只在 Xcode 里可用,本机没有。DEBUG 构建内置离屏渲染,把真实视图渲染成 PNG 并跑 Vision OCR 打印可见文案:

```sh
$SWIFT build
.build/debug/UsageMonitor --render-previews /tmp/um-previews
```

产物覆盖 popover(popover 各焦点 + 全新安装/错误/正常/偏低/临界/刷新中,浅色 + 深色)、设置窗口(通用 + 登录开关两态 + 三种凭据形态 + 保存成功 + 钥匙串失败横幅)、菜单栏图标全态(绿/黄/红数字 + 灰「—」 + DeepSeek-only 彩色「—」与 DeepSeek 临界×窗口 65% 的口径乙形态)。
OCR 输出用于核对文案与布局(该手段已发现过标签页顺序、SF Symbol 缺失、汇总条文案挂错行等问题);
PNG 供人工验收对照 `prototype/*` 分支形态。发布构建不含该入口(仅 `#if DEBUG`)。

验证 Keychain 失败路径(红横幅 + 失败不清空输入):DEBUG 构建加 `--simulate-keychain-failure` 启动,
保存任意一家的凭据即可看到错误码 -34018 的红色横幅;读取照常,不动真实钥匙串内容。

## 真实链路冒烟(DEBUG)

策略逻辑已由 `swift test`(虚拟时钟 + 假件)覆盖;以下入口用**真实适配器 → 三家真实端点 → 解析归一化 → 原子落盘**验证数据链路(仅 DEBUG 构建):

```sh
# 凭据优先取环境变量(仅进程内存,永不回显),缺者回落 Keychain:
export SMOKE_DEEPSEEK=…   # DeepSeek API key
export SMOKE_KIMI=…       # Kimi for Coding 整段 token
export SMOKE_GLM=…        # GLM 裸 key

.build/debug/UsageMonitor --smoke-fetch          # 启动先发缓存 → 新鲜刷新 → 落盘回读;连跑两次即验「杀 App 重启先显旧数据」
.build/debug/UsageMonitor --smoke-poll 5 3       # 真实时钟短周期轮询(AppModel 真实循环;验收 30 分钟策略的缩比验证)
.build/debug/UsageMonitor --smoke-auth deepseek  # 假凭据 → 真实 401 → 重试一次 → 凭据失效事件
.build/debug/UsageMonitor --smoke-outage glm     # 不可路由地址真实超时 ×3 轮 → 加载失败 → 恢复;单家失败不牵连他者
.build/debug/UsageMonitor --smoke-login-item    # 真实 LaunchAgent 写删 + launchctl 即时加载/卸载(冒烟专用 label + /usr/bin/true,无残留;验收「开关即时生效 + plist 指向可执行文件」,#22)
```

- 输出只含归一化字段与脱敏失败描述:不含凭据原文、不含 raw;失败路径不写缓存、不写钥匙串(只读冒烟)。
- 落盘回读按秒级容差比对(iso8601 落盘舍去亚秒精度)。
- 防 App Nap(`beginActivity(.background)`)在常驻路径生效;长挂 1 小时图标仍更新的浸泡验证需人工。
