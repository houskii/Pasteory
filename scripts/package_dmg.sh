#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/Pasteory.app"

[[ -d "$APP_DIR" ]] || "$PROJECT_DIR/scripts/build_app.sh"
"$PROJECT_DIR/scripts/verify_signing.sh" "$APP_DIR" >/dev/null
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
DMG_PATH="$PROJECT_DIR/dist/Pasteory-$VERSION-arm64.dmg"
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/Pasteory.app"
ln -s /Applications "$STAGING_DIR/Applications"
python3 "$SCRIPT_DIR/prepare_first_launch.py" --app "$APP_DIR" --destination "$STAGING_DIR"
rm -f "$DMG_PATH"
hdiutil create -volname "Pasteory $VERSION" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
echo "$DMG_PATH"
