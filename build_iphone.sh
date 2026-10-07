#!/bin/zsh
# 把 PadTerm 编译并安装到已连接的 iPhone
# 用法：./build_iphone.sh
set -e
cd "$(dirname "$0")"

UDID="00008120-0014509A2E82201E"   # iPhone 15 Plus

echo "== 1/3 生成工程 =="
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate >/dev/null 2>&1; fi

echo "== 2/3 编译（自动签名）=="
xcodebuild \
  -project PadTerm.xcodeproj \
  -scheme PadTerm \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath build/DerivedDataIOS \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=GHC9TSYAYD \
  build

APP="build/DerivedDataIOS/Build/Products/Debug-iphoneos/PadTerm.app"
[ -d "$APP" ] || { echo "未找到产物：$APP"; exit 1; }

echo "== 3/3 安装并重启到 iPhone =="
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" --terminate-existing com.padterm.PadTerm
echo "✅ 完成（已强制重启 App）"
