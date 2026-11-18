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
set -euo pipefail
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
# The icon is a generated artifact (build/ is gitignored), so a clean clone has
# no AppIcon.icns. Generate it on demand instead of failing the whole packaging
# step; if generation is impossible (no GUI session), ship without an icon but
# say so loudly (v4.2.26).
if [ ! -f build/AppIcon.icns ]; then
  echo "build/AppIcon.icns 不存在，正在生成…"
  mkdir -p build
  # make_icon.swift emits a PNG; convert it to a real multi-size .icns via
  # iconutil — naming PNG bytes .icns relied on ImageIO leniency and scaled
  # poorly at small Dock sizes (v4.2.27).
  if swift scripts/make_icon.swift build/AppIcon-1024.png; then
    rm -rf build/AppIcon.iconset
    mkdir -p build/AppIcon.iconset
    for spec in "16 32" "32 64" "128 256" "256 512" "512 1024"; do
      # zsh does NOT word-split unquoted expansions (SH_WORD_SPLIT off), so
      # `set -- $spec` produced ONE argument and every sips call got empty
      # sizes — the iconset stayed empty and every build silently fell back
      # to the single-resolution PNG-as-icns that this loop was supposed to
      # replace (v4.2.28). `read` splits the two numbers in both zsh and bash.
      read -r point pixel <<< "$spec"
      sips -z "$pixel" "$pixel" --resampleWidth "$pixel" build/AppIcon-1024.png \
        --out "build/AppIcon.iconset/icon_${point}x${point}@2x.png" >/dev/null 2>&1 || true
    done
    if iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns 2>/dev/null; then
      rm -rf build/AppIcon.iconset build/AppIcon-1024.png
    else
      echo "⚠️ iconutil 转换失败；使用单分辨率 PNG 兜底" >&2
      cp build/AppIcon-1024.png build/AppIcon.icns
      rm -f build/AppIcon-1024.png
    fi
  else
    echo "⚠️ 未能生成 AppIcon.icns（可能没有图形会话）；将不带图标打包" >&2
  fi
fi
if [ -f build/AppIcon.icns ]; then
  cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "⚠️ Info.plist 引用了 AppIcon.icns，但该文件不存在" >&2
fi
# Localisations (v3.4.0): zh-Hans literals are the keys, en.lproj holds English.
if [ -d "Sources/FileVaultApp/Resources" ]; then
  for lproj in Sources/FileVaultApp/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
  done
fi

# 内嵌 git（FR-01 首选策略）：有 build/vendor/git 就塞进 Resources/git，
# 用户首次启动零下载、零联网、不需要 Xcode/Homebrew。
# 生成方式：./scripts/vendor-git.sh --arch all（见 docs/07-Git自动安装与镜像源.md）
VENDOR_ARCH="$( [ "$(uname -m)" = "arm64" ] && echo arm64 || echo x64 )"
if [ -d "build/vendor/git/${VENDOR_ARCH}/bin" ]; then
  mkdir -p "$APP/Contents/Resources/git"
  cp -R "build/vendor/git/${VENDOR_ARCH}/." "$APP/Contents/Resources/git/"
  echo "内嵌 git：build/vendor/git/${VENDOR_ARCH}（首次启动零下载）"
else
  echo "⚠️ 未内嵌 git（可执行 ./scripts/vendor-git.sh）；首次启动将按镜像列表下载"
fi

# 签名：正式分发必须用 Developer ID；ad-hoc 仅供本地自测。
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "签名：${CODESIGN_IDENTITY}"
  codesign --force --deep --options runtime --timestamp -s "${CODESIGN_IDENTITY}" "$APP"
else
  echo "签名：ad-hoc（本地验证；对外分发请设置 CODESIGN_IDENTITY）"
  codesign --force --deep -s - "$APP" 2>/dev/null || codesign --force -s - "$APP"
fi
if [ -n "${CODESIGN_IDENTITY:-}" ] && [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "⚠️ 已用 Developer ID 签名但未公证（设置 NOTARY_PROFILE 才会提交公证并 staple）" >&2
fi

codesign --verify --deep --strict "$APP" && echo "签名校验通过"

# 公证：需要先执行一次
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-specific-password>
if [ -n "${NOTARY_PROFILE:-}" ]; then
  if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo "✗ 设置了 NOTARY_PROFILE 但没有 CODESIGN_IDENTITY：公证必须使用 Developer ID 签名" >&2
    exit 1
  fi
  echo "公证：${NOTARY_PROFILE}"
  NOTARIZE_ZIP="build/${PRODUCT_NAME}-notarize.zip"
  ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
  # Always remove the intermediate zip, even when notarization fails (it used
  # to be left behind on failures, v4.2.26).
  if ! xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "${NOTARY_PROFILE}" --wait; then
    rm -f "$NOTARIZE_ZIP"
    echo "✗ 公证失败（检查 NOTARY_PROFILE 与 Apple 账号凭据）" >&2
    exit 1
  fi
  rm -f "$NOTARIZE_ZIP"
  xcrun stapler staple "$APP"
  # Fail the build: shipping a package Gatekeeper rejects is worse than a red CI.
  spctl -a -vv "$APP" || { echo "✗ spctl 未通过（确认 Developer ID 证书与公证状态）" >&2; exit 1; }
fi

echo "APP at $APP (版本 $APP_VERSION，构建 $BUILD_NUMBER)"
