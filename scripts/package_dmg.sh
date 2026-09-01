#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/Passte.app"
DMG_PATH="$PROJECT_DIR/dist/Passte-0.1.1-arm64.dmg"

[[ -d "$APP_DIR" ]] || "$PROJECT_DIR/scripts/build_app.sh"
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/Passte.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "Passte 0.1.1" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
echo "$DMG_PATH"
