#!/bin/bash
# 把 SwiftPM 产物包成最小 .app bundle:菜单栏 App 需要 bundle id 才能用本地通知与登录自启。
#
# 用法:scripts/make-app.sh [debug|release]
# 产物:build/用量监视器.app(ad-hoc 签名;不做公证,仅供本机使用)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT="${SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.1.3-RELEASE.xctoolchain/usr/bin/swift}"
export PATH="$HOME/linker-shim:$PATH"

cd "$ROOT"
"$SWIFT" build -c "$CONFIG" --product UsageMonitor

BIN_DIR="$("$SWIFT" build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/用量监视器.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/UsageMonitor" "$APP/Contents/MacOS/UsageMonitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.nicholasli.usagemonitor</string>
    <key>CFBundleName</key>
    <string>用量监视器</string>
    <key>CFBundleDisplayName</key>
    <string>用量监视器</string>
    <key>CFBundleExecutable</key>
    <string>UsageMonitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# ad-hoc 签名:UNUserNotificationCenter 与钥匙串都需要稳定的代码身份。
codesign --force --deep --sign - "$APP"

echo "已生成:$APP"
echo "运行:open \"$APP\"(首次会弹通知授权;登录自启默认开启,可在设置窗口「通用」关闭)"
