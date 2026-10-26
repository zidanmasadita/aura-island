#!/bin/bash
# Build Aura (release) and package it as Aura.app.
# Run on a Mac: ./scripts/package-app.sh
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="Aura.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/Aura" "$APP/Contents/MacOS/Aura"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Aura</string>
    <key>CFBundleIdentifier</key>
    <string>com.aura.island</string>
    <key>CFBundleName</key>
    <string>Aura Island</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the bundle is self-consistent (local builds are not
# quarantined, so no notarization is needed for personal use).
codesign --force --deep --sign - "$APP" || true

echo "Done: ./$APP — double-click to run, or drag it to /Applications."
