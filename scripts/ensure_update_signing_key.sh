#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
SPARKLE_TOOLS=${PASTEORY_SPARKLE_TOOLS:-"$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"}
KEY_ACCOUNT="app.pasteory.Pasteory.updates"
PUBLIC_KEY_FILE="$PROJECT_DIR/Config/UpdatePublicKey.txt"

if [[ -n ${PASTEORY_UPDATE_PUBLIC_KEY:-} ]]; then
  print -r -- "$PASTEORY_UPDATE_PUBLIC_KEY"
elif [[ -f "$PUBLIC_KEY_FILE" ]]; then
  tr -d '[:space:]' < "$PUBLIC_KEY_FILE"
else
  [[ -x "$SPARKLE_TOOLS/generate_keys" ]] || {
    echo "找不到 Sparkle generate_keys；请先 swift package resolve 或指定 PASTEORY_SPARKLE_TOOLS。" >&2
    exit 1
  }
  # Never replace an existing key. The private key stays in the publisher's login Keychain.
  if ! "$SPARKLE_TOOLS/generate_keys" --account "$KEY_ACCOUNT" -p 2>/dev/null; then
    "$SPARKLE_TOOLS/generate_keys" --account "$KEY_ACCOUNT" >&2
    "$SPARKLE_TOOLS/generate_keys" --account "$KEY_ACCOUNT" -p
  fi
fi
