#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/Passte.app"
DMG_PATH="$PROJECT_DIR/dist/Passte-0.1.0-arm64.dmg"
PLIST="$APP_DIR/Contents/Info.plist"
BINARY="$APP_DIR/Contents/MacOS/Passte"

[[ -d "$APP_DIR" ]] || "$PROJECT_DIR/scripts/build_app.sh"
[[ -f "$DMG_PATH" ]] || "$PROJECT_DIR/scripts/package_dmg.sh"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "app.passte.Passte" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == "0.1.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" == "1" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" == "14.0" ]]
[[ "$(lipo -archs "$BINARY")" == "arm64" ]]
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
hdiutil verify "$DMG_PATH"
file "$BINARY"
echo "Passte.app 与 DMG 验证通过"
