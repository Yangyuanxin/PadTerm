#!/bin/zsh
# 打 Release 包（Archive）并导出 App Store 用的 IPA
# 用法：./build_appstore.sh
# 导出成功后用 Xcode → Organizer 或 Transporter 上传；本脚本不做上传（需要 App Store Connect 凭据）。
set -e
cd "$(dirname "$0")"

echo "== 1/3 生成工程 =="
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate >/dev/null 2>&1; fi

echo "== 2/3 Archive =="
rm -rf build/PadTerm.xcarchive
xcodebuild \
  -project PadTerm.xcodeproj \
  -scheme PadTerm \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath build/PadTerm.xcarchive \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=GHC9TSYAYD \
  archive

echo "== 3/3 导出 IPA =="
cat > build/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>GHC9TSYAYD</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
PLIST

rm -rf build/Export
xcodebuild -exportArchive \
  -archivePath build/PadTerm.xcarchive \
  -exportPath build/Export \
  -exportOptionsPlist build/ExportOptions.plist \
  -allowProvisioningUpdates

echo "✅ 完成：build/Export/PadTerm.ipa"
