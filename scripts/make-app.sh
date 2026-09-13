#!/bin/bash
# 把 SwiftPM 产物包成最小 .app bundle:菜单栏 App 需要 bundle id 才能用本地通知与登录自启。
#
# 用法:scripts/make-app.sh [debug|release]
# 产物:build/用量监视器.app(有自签证书时用稳定身份签名,否则 ad-hoc;仅供本机使用)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT="${SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.1.3-RELEASE.xctoolchain/usr/bin/swift}"
export PATH="$HOME/linker-shim:$PATH"

cd "$ROOT"
"$SWIFT" build -c "$CONFIG" --product UsageMonitor

BIN_DIR="$("$SWIFT" build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/用量监视器.app"
ICON="$ROOT/scripts/icon/AppIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/UsageMonitor" "$APP/Contents/MacOS/UsageMonitor"
# 应用图标(#49,原型 A 菜单栏窗格):生成器 scripts/icon/generate.swift 重跑可全套重出。
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

# ad-hoc 签名回落。优先用自签稳定身份(见 scripts/make-signing-cert.sh,#50):
# ad-hoc 的 cdhash 随每次重打包漂移,钥匙串 ACL 视新构建为新 App,首启读凭据就弹
# login keychain 密码框;证书身份锚定跨构建稳定,「始终允许」一次即永久。
SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
  | awk -v name="UsageMonitor-dev" 'index($0, "\"" name "\"") { sub(/^ *[0-9]+\) +/, ""); print $1; exit }')"
if [ -n "$SIGNING_IDENTITY" ]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
  echo "签名:稳定身份 UsageMonitor-dev"
else
  codesign --force --deep --sign - "$APP"
  echo "签名:ad-hoc(无稳定身份;建议跑一次 scripts/make-signing-cert.sh,消除每次重打包后首启弹钥匙串密码框)"
fi

echo "已生成:$APP"
echo "运行:open \"$APP\"(首次会弹通知授权;登录自启默认开启,可在设置窗口「通用」关闭)"
