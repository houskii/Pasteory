#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Passte.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LOCAL_SIGNING_DIR="$HOME/Library/Application Support/Passte/Signing"
LOCAL_SIGNING_KEYCHAIN="$LOCAL_SIGNING_DIR/PassteBuild.keychain-db"
LOCAL_SIGNING_PASSWORD_FILE="$LOCAL_SIGNING_DIR/keychain-password"
CODESIGN_KEYCHAIN_ARGS=()
if [[ -n ${PASSTE_SIGN_IDENTITY:-} ]]; then
  SIGN_IDENTITY=$PASSTE_SIGN_IDENTITY
elif [[ -f "$LOCAL_SIGNING_KEYCHAIN" && -f "$LOCAL_SIGNING_PASSWORD_FILE" ]]; then
  LOCAL_SIGNING_PASSWORD=$(<"$LOCAL_SIGNING_PASSWORD_FILE")
  security unlock-keychain -p "$LOCAL_SIGNING_PASSWORD" "$LOCAL_SIGNING_KEYCHAIN"
  SIGN_IDENTITY=$(security find-identity -v -p codesigning "$LOCAL_SIGNING_KEYCHAIN" | awk '/Passte Local Build/{print $2; exit}')
  [[ -n "$SIGN_IDENTITY" ]] || { echo "Passte Local Build 签名身份不可用" >&2; exit 1; }
  CODESIGN_KEYCHAIN_ARGS=(--keychain "$LOCAL_SIGNING_KEYCHAIN")
else
  SIGN_IDENTITY="-"
fi

arch -arm64 /usr/bin/swift build --package-path "$PROJECT_DIR" -c release --arch arm64
BIN_DIR=$(arch -arm64 /usr/bin/swift build --package-path "$PROJECT_DIR" -c release --arch arm64 --show-bin-path)

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
ditto "$BIN_DIR/Passte" "$MACOS_DIR/Passte"
ditto "$PROJECT_DIR/Config/Info.plist" "$CONTENTS_DIR/Info.plist"

ICON_WORK=$(mktemp -d)
trap 'rm -rf "$ICON_WORK"' EXIT
mkdir -p "$ICON_WORK/AppIcon.iconset"
arch -arm64 /usr/bin/swift "$PROJECT_DIR/scripts/generate_icon.swift" "$ICON_WORK/AppIcon-1024.png"
for entry in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  dimensions=${entry%% *}
  filename=${entry#* }
  sips -z "$dimensions" "$dimensions" "$ICON_WORK/AppIcon-1024.png" --out "$ICON_WORK/AppIcon.iconset/$filename" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$RESOURCES_DIR/AppIcon.icns"

codesign --force --deep --sign "$SIGN_IDENTITY" "${CODESIGN_KEYCHAIN_ARGS[@]}" "$APP_DIR"
echo "$APP_DIR"
