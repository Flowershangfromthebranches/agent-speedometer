#!/bin/bash
# 构建并打包 AgentPulse：
#   dist/AgentPulse.app            可直接双击运行
#   dist/AgentPulse-<版本>.dmg     拖入“应用程序”即可安装
# 用法：scripts/build-app.sh [--install]   （--install 会额外复制到 /Applications）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.3"

# 当前开发者目录是 Command Line Tools 时（其 SwiftPM 可能损坏），仅对本脚本改用完整 Xcode。
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]] && xcode-select -p | grep -q CommandLineTools; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcrun swift build -c release
BIN="$(xcrun swift build -c release --show-bin-path)/AgentPulse"

WORK=.build/package
APP=dist/AgentPulse.app
STAGED_APP="$WORK/AgentPulse.app"
# Finder may cache a generic icon if it sees a partially assembled .app. Keep
# the published app intact until its replacement is complete and signed.
rm -rf "$WORK"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" dist
cp "$BIN" "$STAGED_APP/Contents/MacOS/AgentPulse"

# 应用图标
xcrun swift scripts/make-icon.swift "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$STAGED_APP/Contents/Resources/AppIcon.icns"

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentPulse</string>
  <key>CFBundleDisplayName</key><string>AgentPulse</string>
  <key>CFBundleIdentifier</key><string>local.agentpulse</string>
  <key>CFBundleExecutable</key><string>AgentPulse</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>本地只读日志查看工具</string>
</dict>
</plist>
PLIST

# 本地临时签名（ad-hoc），未做 Apple 公证
codesign --force --sign - "$STAGED_APP" >/dev/null

# Swap complete bundles atomically on the same volume, then refresh only this
# app's Launch Services entry; no global icon-cache reset or Finder restart.
xcrun swift scripts/publish-app.swift "$STAGED_APP" "$APP"
touch "$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP"
fi

# DMG：包含 App 和“应用程序”快捷方式
DMG="dist/AgentPulse-${VERSION}.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "AgentPulse" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "已生成 $APP"
echo "已生成 $DMG"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x AgentPulse 2>/dev/null || true
  rm -rf /Applications/AgentPulse.app
  cp -R "$APP" /Applications/
  echo "已安装到 /Applications/AgentPulse.app"
fi
