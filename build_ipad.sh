#!/bin/zsh
# 把 PadTerm 编译并安装到已连接的 iPad
# 用法：./build_ipad.sh
set -e
cd "$(dirname "$0")"

UDID="00008132-000668A12660C01C"

echo "== 1/3 生成工程 =="
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate >/dev/null 2>&1; fi

echo "== 2/3 编译（自动签名）=="
xcodebuild \
  -project PadTerm.xcodeproj \
  -scheme PadTerm \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath build/DerivedDataiOS \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=GHC9TSYAYD \
  build

APP="build/DerivedDataiOS/Build/Products/Debug-iphoneos/PadTerm.app"
[ -d "$APP" ] || { echo "未找到产物：$APP"; exit 1; }

echo "== 3/3 安装并重启到 iPad =="
xcrun devicectl device install app --device "$UDID" "$APP"
# 关键：安装不会替换正在运行的进程；必须 --terminate-existing 才会真正加载新代码。
# （此前用 processes+pid 的方式在新版 devicectl 上取不到 pid，导致一直在唤起旧进程）
xcrun devicectl device process launch --device "$UDID" --terminate-existing com.padterm.PadTerm
echo "✅ 完成（已强制重启 App）"
