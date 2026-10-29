#!/bin/bash
# Builds YACW.app (menu bar app, ad-hoc signed) and dist/yacw-<version>.zip for a GitHub release.
# Notifications require a bundle. Environment overrides: VERSION (default 0.1.0), BUNDLE_ID (default local.yacw).
# No binaries are versioned: YACW.app and dist/ are git-ignored.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUNDLE_ID="${BUNDLE_ID:-local.yacw}"

swift build -c release --product YACWApp
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="YACW.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/YACWApp" "$APP/Contents/MacOS/YACW"
# SwiftPM resource bundle (pricing.json); Bundle.module looks for it in Contents/Resources.
cp -R "$BIN_DIR"/yacw_YACWCore.bundle "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>YACW</string>
    <key>CFBundleDisplayName</key><string>YACW</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>YACW</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature (no Developer ID): Gatekeeper asks for confirmation on first open (right click > Open).
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p dist
ZIP="dist/yacw-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "OK: $(pwd)/$APP  (abrir com: open $APP)"
echo "ZIP: $(pwd)/$ZIP"
