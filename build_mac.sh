#!/bin/zsh
# 把 PadTerm 编译为 Mac Catalyst 应用并安装到 /Applications
# 用法：./build_mac.sh
set -e
cd "$(dirname "$0")"

xcodebuild \
  -project PadTerm.xcodeproj \
  -scheme PadTerm \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/DerivedDataCatalyst \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP="build/DerivedDataCatalyst/Build/Products/Debug-maccatalyst/PadTerm.app"
if [ ! -d "$APP" ]; then
  echo "未找到构建产物：$APP"
  exit 1
fi

rm -rf /Applications/PadTerm.app
ditto "$APP" /Applications/PadTerm.app
xattr -cr /Applications/PadTerm.app

# 本地 ad-hoc 重签名并显式声明网络权限：
# 未带 com.apple.security.network.client 的 Catalyst App 访问局域网会被系统拦截（connect 返回 ENETDOWN / 网络不可用）
codesign --force --deep --sign - \
  --entitlements PadTerm/PadTerm.entitlements \
  /Applications/PadTerm.app

# 注册到 LaunchServices，让 App 出现在「系统设置 → 隐私与安全性 → 本地网络」中（Mac Catalyst 的 bundle id 带 maccatalyst. 前缀）
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -R -f /Applications/PadTerm.app 2>/dev/null || true

echo "✅ 已安装：/Applications/PadTerm.app"
