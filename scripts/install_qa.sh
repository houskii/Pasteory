#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_SOURCE="$PROJECT_DIR/dist/Pasteory-QA.app"
APP_TARGET="/Applications/Pasteory QA.app"

[[ -d "$APP_SOURCE" ]] || "$SCRIPT_DIR/build_qa_app.sh"
"$SCRIPT_DIR/verify_signing.sh" "$APP_SOURCE" "app.pasteory.Pasteory.qa" >/dev/null

qa_processes=$(pgrep -f '^/Applications/Pasteory QA\.app/Contents/MacOS/Pasteory$' || true)
if [[ -n "$qa_processes" ]]; then
  for qa_pid in ${(f)qa_processes}; do kill "$qa_pid" 2>/dev/null || true; done
fi

rm -rf "$APP_TARGET"
ditto "$APP_SOURCE" "$APP_TARGET"
"$SCRIPT_DIR/verify_signing.sh" "$APP_TARGET" "app.pasteory.Pasteory.qa" >/dev/null
echo "$APP_TARGET"
