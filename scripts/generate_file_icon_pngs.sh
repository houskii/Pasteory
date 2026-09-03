#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
SVG_DIR="$PROJECT_DIR/docs/file-icons"
PNG_DIR="$PROJECT_DIR/Resources/FileIcons"

mkdir -p "$PNG_DIR"
find "$PNG_DIR" -maxdepth 1 -type f -name '*.png' -delete

for icon in "$SVG_DIR"/*.svg; do
  case "$icon" in
    */catalog.svg|*/size-preview.svg) continue ;;
  esac
  name=${icon:t:r}
  sips -s format png -z 128 128 "$icon" --out "$PNG_DIR/$name.png" >/dev/null
done

count=$(find "$PNG_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')
[[ "$count" == "49" ]] || {
  echo "文件图标数量错误：预期 49，实际 $count" >&2
  exit 1
}

echo "generated_file_icon_pngs=$count"
echo "output=$PNG_DIR"
