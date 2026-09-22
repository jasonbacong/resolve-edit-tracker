#!/bin/bash
# Build Resolve Edit Tracker and assemble a double-clickable .app bundle.
#   ./make_app.sh          -> dist/Resolve Edit Tracker.app
#   ./make_app.sh --zip    -> also dist/ResolveEditTracker-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Resolve Edit Tracker"
EXECUTABLE="ResolveEditTracker"
BUNDLE_ID="com.jasongrech.resolveedittracker"
VERSION="${APP_VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"

RELEASE_BIN=".build/release/${EXECUTABLE}"
DIST="dist/${APP_NAME}.app"

echo "==> swift build -c release  (v${VERSION})"
swift build -c release

echo "==> Assembling ${DIST}"
rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Resources"

cp "$RELEASE_BIN" "$DIST/Contents/MacOS/${EXECUTABLE}"
chmod +x "$DIST/Contents/MacOS/${EXECUTABLE}"

if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$DIST/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  ICON_KEY=""
fi

cat > "$DIST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>Reads the open project and composition in After Effects so your time is recorded against the right one.</string>
  ${ICON_KEY}
</dict>
</plist>
PLIST

printf 'APPL????' > "$DIST/Contents/PkgInfo"

# Strip stray extended attributes before signing so the zip stays clean.
xattr -cr "$DIST" 2>/dev/null || true

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$DIST" 2>/dev/null || codesign --force --deep --sign - "$DIST"

if [ "${1:-}" = "--zip" ]; then
  ZIP="dist/${EXECUTABLE}-${VERSION}.zip"
  echo "==> Zipping ${ZIP}"
  rm -f "$ZIP"
  ( cd dist && ditto -c -k --keepParent "${APP_NAME}.app" "$(basename "$ZIP")" )
  echo "Built: $DIST"
  echo "Zip:   $ZIP"
else
  echo "Built: $DIST"
fi
