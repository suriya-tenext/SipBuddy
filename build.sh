#!/bin/zsh
# Builds SipBuddy.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/SipBuddy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SipBuddy "$APP/Contents/MacOS/SipBuddy"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>in.tenext.sipbuddy</string>
    <key>CFBundleName</key><string>SipBuddy</string>
    <key>CFBundleDisplayName</key><string>SipBuddy</string>
    <key>CFBundleExecutable</key><string>SipBuddy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
ditto -c -k --keepParent "$APP" build/SipBuddy-macOS.zip
echo "Built $APP — run: open $APP"
