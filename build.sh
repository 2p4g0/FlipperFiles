#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64
BIN=".build/arm64-apple-macosx/release/FlipperFiles"
APP="FlipperFiles.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FlipperFiles"
cp Tools/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FlipperFiles</string>
  <key>CFBundleDisplayName</key><string>FlipperFiles</string>
  <key>CFBundleIdentifier</key><string>com.local.flipperfiles</string>
  <key>CFBundleExecutable</key><string>FlipperFiles</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign -s - --force --deep "$APP"
echo "OK: $(pwd)/$APP"
