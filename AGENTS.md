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
$SWIFT test    # 跑 UsageMonitorCore 测试
```

- `~/linker-shim/ld`:CLT 14.2 的 ld 不认识 `-no_warn_duplicate_libraries`,shim 负责剥掉该参数再转发。
- 测试框架用 Swift Testing(`import Testing`),不要 `import XCTest`——无 Xcode 就没有该模块。
- 别装 6.3+ 工具链:其宿主工具要求 macOS 14,本机是 macOS 13。swiftly 在本机(x86_64 macOS 13)会崩,不要用。

## UI 形态检查(无 Xcode)

SwiftUI Previews 只在 Xcode 里可用,本机没有。DEBUG 构建内置离屏渲染,把真实视图渲染成 PNG 并跑 Vision OCR 打印可见文案:

```sh
$SWIFT build
.build/debug/UsageMonitor --render-previews /tmp/um-previews
```

产物覆盖 popover(popover 各焦点/全新安装/错误态,浅色 + 深色)、设置窗口(通用 + 三种凭据形态)、菜单栏图标。
OCR 输出用于核对文案与布局(该手段已发现过标签页顺序、SF Symbol 缺失、汇总条文案挂错行等问题);
PNG 供人工验收对照 `prototype/*` 分支形态。发布构建不含该入口(仅 `#if DEBUG`)。
