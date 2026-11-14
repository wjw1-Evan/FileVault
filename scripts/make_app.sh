#!/bin/zsh
# Assemble the distributable FileVault.app bundle (release build).
set -e
cd "$(dirname "$0")/.."

APP_VERSION="${1:-1.1.0}"
APP="build/FileVault.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build -c release
cp .build/release/FileVaultApp "$APP/Contents/MacOS/FileVaultApp"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FileVault</string>
    <key>CFBundleDisplayName</key><string>FileVault</string>
    <key>CFBundleIdentifier</key><string>com.filevault.FileVault</string>
    <key>CFBundleVersion</key><string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>FileVaultApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 FileVault</string>
</dict>
</plist>
PLIST
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP" 2>/dev/null || codesign --force -s - "$APP"
echo "APP at $APP"
