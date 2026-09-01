#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_SOURCE="$PROJECT_DIR/dist/Passte.app"
APP_TARGET="/Applications/Passte.app"

[[ -d "$APP_SOURCE" ]] || "$PROJECT_DIR/scripts/build_app.sh"
pkill -x Passte 2>/dev/null || true
rm -rf "$APP_TARGET"
ditto "$APP_SOURCE" "$APP_TARGET"
open "$APP_TARGET"
echo "$APP_TARGET"
