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
    <key>NSAppleEventsUsageDescription</key>
    <string>Aura membaca daftar tab Google Chrome untuk menemukan tab YouTube Music yang sedang memutar, supaya cover lagu bisa ditampilkan tanpa ekstensi.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the bundle is self-consistent (local builds are not
# quarantined, so no notarization is needed for personal use).
codesign --force --deep --sign - "$APP" || true

# Distributable disk image: the .app plus a shortcut to /Applications,
# so installing is a drag-and-drop. hdiutil ships with macOS.
DMG_STAGING=".dmg-staging"
rm -rf "$DMG_STAGING" "Aura.dmg"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "Aura Island" -srcfolder "$DMG_STAGING" -ov -format UDZO "Aura.dmg"
rm -rf "$DMG_STAGING"

echo "Done: ./$APP and ./Aura.dmg — open the DMG and drag Aura to Applications."
