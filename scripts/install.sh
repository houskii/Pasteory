#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_SOURCE="$PROJECT_DIR/dist/Pasteory.app"
APP_TARGET="/Applications/Pasteory.app"

[[ -d "$APP_SOURCE" ]] || "$PROJECT_DIR/scripts/build_app.sh"
"$PROJECT_DIR/scripts/verify_signing.sh" "$APP_SOURCE" >/dev/null
production_processes=$(pgrep -f '^/Applications/Pasteory\.app/Contents/MacOS/Pasteory($| )' || true)
if [[ -n "$production_processes" ]]; then
  for production_pid in ${(f)production_processes}; do kill "$production_pid" 2>/dev/null || true; done
fi
rm -rf "$APP_TARGET"
ditto "$APP_SOURCE" "$APP_TARGET"
"$PROJECT_DIR/scripts/verify_signing.sh" "$APP_TARGET" >/dev/null
if [[ ${PASTEORY_SKIP_EXISTING_MAINTENANCE:-0} == 1 ]]; then
  open "$APP_TARGET" --args --skip-existing-maintenance
else
  open "$APP_TARGET"
fi
echo "$APP_TARGET"
