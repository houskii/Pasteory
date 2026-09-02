#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/Pasteory.app"
PLIST="$APP_DIR/Contents/Info.plist"
BINARY="$APP_DIR/Contents/MacOS/Pasteory"

[[ -d "$APP_DIR" ]] || "$PROJECT_DIR/scripts/build_app.sh"
EXPECTED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Config/Info.plist")
EXPECTED_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/Config/Info.plist")
DMG_PATH="$PROJECT_DIR/dist/Pasteory-$EXPECTED_VERSION-arm64.dmg"
[[ -f "$DMG_PATH" ]] || "$PROJECT_DIR/scripts/package_dmg.sh"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "app.pasteory.Pasteory" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == "$EXPECTED_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" == "$EXPECTED_BUILD" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" == "14.0" ]]
[[ "$(lipo -archs "$BINARY")" == "arm64" ]]
[[ -f "$APP_DIR/Contents/Resources/MenuBarIcon.png" ]]
[[ -f "$APP_DIR/Contents/Resources/MenuBarIcon@2x.png" ]]
[[ "$(sips -g pixelWidth "$APP_DIR/Contents/Resources/MenuBarIcon.png" | awk '/pixelWidth/{print $2}')" == "18" ]]
[[ "$(sips -g pixelWidth "$APP_DIR/Contents/Resources/MenuBarIcon@2x.png" | awk '/pixelWidth/{print $2}')" == "36" ]]
[[ "$(sips -g hasAlpha "$APP_DIR/Contents/Resources/MenuBarIcon.png" | awk '/hasAlpha/{print $2}')" == "yes" ]]
[[ "$(sips -g hasAlpha "$APP_DIR/Contents/Resources/MenuBarIcon@2x.png" | awk '/hasAlpha/{print $2}')" == "yes" ]]
"$PROJECT_DIR/scripts/verify_signing.sh" "$APP_DIR"
hdiutil verify "$DMG_PATH"
file "$BINARY"
echo "Pasteory.app 与 DMG 验证通过"
