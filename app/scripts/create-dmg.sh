#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."   # app/
# Creates app/build/Valkey.app.zip and app/build/Valkey.dmg from the Release build.
# Usage: app/scripts/create-dmg.sh
DMG="build/Valkey.dmg"
ZIP="build/Valkey.app.zip"

echo "→ Building Release (universal)..."
xcodebuild -project Valkey.xcodeproj -configuration Release -scheme Valkey \
  -derivedDataPath build/DerivedData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build 2>&1 | tail -20

APP="build/DerivedData/Build/Products/Release/Valkey.app"
echo "→ App at: $APP"
[ -d "$APP" ] || { echo "Valkey.app not found"; exit 1; }
# Xcode signs the app and the embedded valkey binaries; just verify.
codesign --verify --deep --strict --verbose=2 "$APP"

echo "→ Creating zip..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "  created $ZIP ($(du -h "$ZIP" | cut -f1))"

echo "→ Creating DMG..."
rm -f "$DMG"
# Use hdiutil: copy app + Applications symlink
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Valkey" -srcfolder "$STAGE" -ov -format UDZO "$DMG" 2>&1 | tail -5
echo "  created $DMG ($(du -h "$DMG" | cut -f1))"

echo ""
echo "Done. Install: open $ZIP  then drag Valkey.app to /Applications"
echo "DMG: open $DMG"
