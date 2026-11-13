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
    --debug-disable-monitor --debug-disable-hotkey --debug-readme-seed \
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

capture quick-panel-en --debug-language=en --debug-show-quick-window
capture quick-panel-zh --debug-language=zh-Hans --debug-show-quick-window
capture library-en --debug-language=en --debug-open-library --debug-settings-wide
capture library-zh --debug-language=zh-Hans --debug-open-library --debug-settings-wide
capture settings-language-en --debug-language=en --debug-open-settings
capture settings-language-zh --debug-language=zh-Hans --debug-open-settings
capture switched-to-zh --debug-language=en --debug-switch-language=zh-Hans --debug-show-quick-window
capture switched-to-en --debug-language=zh-Hans --debug-switch-language=en --debug-show-quick-window
capture settings-shortcuts-en --debug-language=en --debug-open-settings --debug-settings-shortcuts
capture settings-links-en --debug-language=en --debug-open-settings --debug-settings-links
capture update-amber --debug-show-quick-window --debug-update-available --debug-theme=blue
capture update-cyan-narrow --debug-show-quick-window --debug-update-available --debug-theme=orange --debug-panel-narrow
capture update-cyan-dark --debug-show-quick-window --debug-update-available --debug-theme=orange --debug-dark
capture settings-library-wide --debug-open-library --debug-settings-wide
capture settings-library-narrow --debug-open-library --debug-settings-narrow
capture settings-about --debug-open-settings --debug-settings-about
capture settings-ai-zh --debug-language=zh-Hans --debug-open-settings --debug-settings-ai
capture settings-ai-en --debug-language=en --debug-open-settings --debug-settings-ai
capture settings-ai-lifecycle-zh --debug-language=zh-Hans --debug-open-settings --debug-settings-ai --debug-ai-lifecycle
capture settings-ai-analysis-zh --debug-language=zh-Hans --debug-open-settings --debug-settings-ai --debug-ai-analysis
capture settings-ai-usage-zh --debug-language=zh-Hans --debug-open-settings --debug-settings-ai --debug-ai-usage --debug-ai-seed
capture library-ai-zh --debug-language=zh-Hans --debug-open-library --debug-settings-wide --debug-ai-seed
capture update-confirmation-zh --debug-language=zh-Hans --debug-update-available --debug-open-update
capture update-confirmation --debug-update-available --debug-open-update

# A runner's small virtual display must not silently turn both cases into the same layout.
wide_width=$(sips -g pixelWidth "$OUTPUT_DIR/settings-library-wide.png" | awk '/pixelWidth/{print $2}')
narrow_width=$(sips -g pixelWidth "$OUTPUT_DIR/settings-library-narrow.png" | awk '/pixelWidth/{print $2}')
[[ "$wide_width" == 1360 || "$wide_width" == 2720 ]]
[[ "$narrow_width" == 1120 || "$narrow_width" == 2240 ]]

# Verify an already visible UI switches language, including AppKit menus, without changing demo content.
python3 - "$OUTPUT_DIR" <<'PYTHON'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name, language, text, menu, title in [
    ("switched-to-zh", "zh-Hans", "文字", "编辑", "Ideas worth keeping"),
    ("switched-to-en", "en", "Text", "Edit", "值得留下的灵感"),
]:
    metadata = json.loads((root / (name + ".png.json")).read_text())
    assert metadata["language"] == language, metadata
    assert metadata["textLabel"] == text, metadata
    assert metadata["editMenuTitle"] == menu, metadata
    assert title in metadata["sampleTitles"], metadata
print("Live language switching and original demo titles verified in both directions.")
PYTHON
