#!/bin/bash
# Builds the Mac app in release mode and packages it into AndroidConnect.app
# Run from the project root: bash build_mac.sh

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
MAC_SRC="$PROJECT_ROOT/MacApp"
APP_BUNDLE="$PROJECT_ROOT/AndroidConnect.app"
BINARY="$APP_BUNDLE/Contents/MacOS/AndroidConnect"

echo "Building Android Connect for Mac (release)…"
cd "$MAC_SRC"
swift build -c release 2>&1

echo ""
echo "Copying binary into app bundle…"
cp ".build/release/AndroidConnect" "$BINARY"
chmod +x "$BINARY"

echo "Copying app icon…"
RESOURCES="$APP_BUNDLE/Contents/Resources"
mkdir -p "$RESOURCES"
cp "$MAC_SRC/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

echo "Ad-hoc signing…"
codesign --force --deep --sign - "$APP_BUNDLE"

# Force Finder to refresh icon cache
touch "$APP_BUNDLE"

echo ""
echo "✓ Build complete!"
echo "  Bundle: $APP_BUNDLE"
echo ""
echo "  → Run:    open $APP_BUNDLE"
echo "  → Or drag AndroidConnect.app to /Applications"
