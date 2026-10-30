#!/bin/bash
# Build Aura (release) and package it as Aura.app.
# Run on a Mac: ./scripts/package-app.sh
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="Aura.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Aura" "$APP/Contents/MacOS/Aura"
cp "Assets/AuraLogo.png" "$APP/Contents/Resources/AuraLogo.png"
cp "Assets/AuraLyricsMascot.png" "$APP/Contents/Resources/AuraLyricsMascot.png"

# App icon (.icns) from the same logo, via the standard macOS tools.
ICONSET="$APP/Contents/Resources/Aura.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
    sips -z $size $size "Assets/AuraLogo.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    if [ "$size" != "1024" ]; then
        double=$((size * 2))
        sips -z $double $double "Assets/AuraLogo.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Aura.icns"
rm -rf "$ICONSET"

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
    <key>CFBundleIconFile</key>
    <string>Aura</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Aura membaca daftar tab Google Chrome untuk menemukan tab YouTube Music yang sedang memutar, supaya cover lagu bisa ditampilkan tanpa ekstensi.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Aura checks which Bluetooth devices are already connected, to show a connect/disconnect alert. It does not scan for or discover new devices.</string>
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
