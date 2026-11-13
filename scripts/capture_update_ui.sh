#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
BIN_DIR=$(swift build --package-path "$PROJECT_DIR" --show-bin-path)
APP_EXECUTABLE="$PROJECT_DIR/dist/Pasteory-QA.app/Contents/MacOS/Pasteory"
[[ -x "$APP_EXECUTABLE" ]] || APP_EXECUTABLE="$BIN_DIR/Pasteory"
OUTPUT_DIR=${1:-"$PROJECT_DIR/dist/ui-qa"}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=${OUTPUT_DIR:A}

capture() {
  local name=$1
  shift
  local data_root
  data_root=$(mktemp -d "${TMPDIR:-/tmp}/pasteory-update-ui.XXXXXX")
  local screenshot="$OUTPUT_DIR/$name.png"
  "$APP_EXECUTABLE" --debug-data-root "$data_root" --debug-ui-qa \
    --debug-disable-monitor --debug-disable-hotkey --debug-seed \
    --debug-snapshot-path "$screenshot" "$@" > "$OUTPUT_DIR/$name.log" 2>&1 &
  local app_pid=$!
  local succeeded=false
  for attempt in {1..30}; do
    if [[ -s "$screenshot" ]]; then succeeded=true; break; fi
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 1
  done
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  if [[ "$succeeded" != true ]]; then
    cat "$OUTPUT_DIR/$name.log" >&2
    echo "未生成验收截图：$name" >&2
    return 1
  fi
}

capture update-amber --debug-show-quick-window --debug-update-available --debug-theme=blue
capture update-cyan-narrow --debug-show-quick-window --debug-update-available --debug-theme=orange --debug-panel-narrow
capture update-cyan-dark --debug-show-quick-window --debug-update-available --debug-theme=orange --debug-dark
capture settings-library-wide --debug-open-library --debug-settings-wide
capture settings-library-narrow --debug-open-library --debug-settings-narrow
capture settings-about --debug-open-settings --debug-settings-about
capture update-confirmation --debug-update-available --debug-open-update
