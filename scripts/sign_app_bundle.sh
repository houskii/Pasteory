#!/bin/zsh
set -euo pipefail

APP_DIR=$1
SIGN_IDENTITY=$2
SIGN_KEYCHAIN=${3:-}
typeset -a SIGN_ARGS
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
[[ -z "$SIGN_KEYCHAIN" ]] || SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || { echo "缺少 Sparkle.framework" >&2; exit 1; }

# Sign Mach-O code, nested bundle envelopes, the framework and finally the host app.
# Preserve the helper entitlements shipped by Sparkle; do not rely on --deep re-signing.
while IFS= read -r -d '' code; do
  if file -b "$code" | grep -q 'Mach-O'; then
    codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements --options runtime "$code"
  fi
done < <(find "$FRAMEWORK/Versions" -type f -print0)
while IFS= read -r -d '' bundle; do
  codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements --options runtime "$bundle"
done < <(find "$FRAMEWORK/Versions" -depth -type d \( -name '*.xpc' -o -name '*.app' \) -print0)
codesign "${SIGN_ARGS[@]}" --options runtime "$FRAMEWORK"
codesign "${SIGN_ARGS[@]}" "$APP_DIR"
