#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_SOURCE="$PROJECT_DIR/dist/Pasteory.app"
APP_TARGET="/Applications/Pasteory.app"

[[ -d "$APP_SOURCE" ]] || "$PROJECT_DIR/scripts/build_app.sh"
"$PROJECT_DIR/scripts/verify_signing.sh" "$APP_SOURCE" >/dev/null
pkill -x Pasteory 2>/dev/null || true
rm -rf "$APP_TARGET"
ditto "$APP_SOURCE" "$APP_TARGET"
"$PROJECT_DIR/scripts/verify_signing.sh" "$APP_TARGET" >/dev/null
open "$APP_TARGET"
echo "$APP_TARGET"
