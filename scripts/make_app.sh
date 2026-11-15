#!/bin/zsh
# Assemble the distributable FileVault.app bundle.
#
# 用法: ./scripts/make_app.sh <版本> [构建号]
#
# 环境变量（可选）:
#   PRODUCT_NAME      应用名（默认 FileVault；改名时与 AppBrand.swift 一起改）
#   BUNDLE_ID         CFBundleIdentifier（默认 com.filevault.FileVault）
#   CODESIGN_IDENTITY Developer ID 证书名，例如 "Developer ID Application: Your Name (TEAMID)"；
#                     未设置时回退 ad-hoc 签名（仅本地验证，对外分发不可用）
#   NOTARY_PROFILE    notarytool 钥匙串 profile 名；设置后自动提交公证并 staple
set -e
cd "$(dirname "$0")/.."

APP_VERSION="${1:?用法: ./scripts/make_app.sh <版本> [构建号]}"
BUILD_NUMBER="${2:-$APP_VERSION}"
PRODUCT_NAME="${PRODUCT_NAME:-FileVault}"
BUNDLE_ID="${BUNDLE_ID:-com.filevault.FileVault}"
BINARY="FileVaultApp"
APP="build/${PRODUCT_NAME}.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build -c release
cp ".build/release/${BINARY}" "$APP/Contents/MacOS/${BINARY}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${PRODUCT_NAME}</string>
    <key>CFBundleDisplayName</key><string>${PRODUCT_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>${BINARY}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array><string>zh-Hans</string><string>en</string></array>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 ${PRODUCT_NAME}</string>
</dict>
</plist>
PLIST
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Localisations (v3.4.0): zh-Hans literals are the keys, en.lproj holds English.
if [ -d "Sources/FileVaultApp/Resources" ]; then
  for lproj in Sources/FileVaultApp/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
  done
fi

# 签名：正式分发必须用 Developer ID；ad-hoc 仅供本地自测。
if [ -n "${CODESIGN_IDENTITY}" ]; then
  echo "签名：${CODESIGN_IDENTITY}"
  codesign --force --deep --options runtime --timestamp -s "${CODESIGN_IDENTITY}" "$APP"
else
  echo "签名：ad-hoc（本地验证；对外分发请设置 CODESIGN_IDENTITY）"
  codesign --force --deep -s - "$APP" 2>/dev/null || codesign --force -s - "$APP"
fi

codesign --verify --deep --strict "$APP" && echo "签名校验通过"

# 公证：需要先执行一次
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-specific-password>
if [ -n "${NOTARY_PROFILE}" ]; then
  echo "公证：${NOTARY_PROFILE}"
  NOTARIZE_ZIP="build/${PRODUCT_NAME}-notarize.zip"
  ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
  xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "$APP"
  rm -f "$NOTARIZE_ZIP"
  spctl -a -vv "$APP" || echo "⚠️ spctl 未通过（确认 Developer ID 证书与公证状态）"
fi

echo "APP at $APP (版本 $APP_VERSION，构建 $BUILD_NUMBER)"
