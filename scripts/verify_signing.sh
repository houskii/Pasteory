#!/bin/zsh
set -euo pipefail

APP_DIR=${1:-}
EXPECTED_IDENTIFIER=${2:-app.pasteory.Pasteory}

[[ -n "$APP_DIR" && -d "$APP_DIR" ]] || {
  echo "用法：$0 /path/to/Pasteory.app [bundle-identifier]" >&2
  exit 2
}

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
SIGNING_DETAILS=$(codesign -dvv "$APP_DIR" 2>&1)
DESIGNATED_REQUIREMENT=$(codesign -dr - "$APP_DIR" 2>&1)
IDENTIFIER=$(print -r -- "$SIGNING_DETAILS" | awk -F= '/^Identifier=/{print $2; exit}')
AUTHORITY=$(print -r -- "$SIGNING_DETAILS" | awk -F= '/^Authority=/{print $2; exit}')

[[ "$IDENTIFIER" == "$EXPECTED_IDENTIFIER" ]] || {
  echo "签名校验失败：Bundle ID 为 $IDENTIFIER，预期为 $EXPECTED_IDENTIFIER。" >&2
  exit 1
}
[[ -n "$AUTHORITY" ]] || {
  echo "签名校验失败：没有证书签名 Authority，疑似使用了 ad-hoc 签名。" >&2
  exit 1
}
if print -r -- "$SIGNING_DETAILS" | grep -Eq 'Signature=adhoc|flags=.*adhoc'; then
  echo "签名校验失败：检测到 ad-hoc 签名。" >&2
  exit 1
fi
if print -r -- "$DESIGNATED_REQUIREMENT" | grep -Fq '# designated => cdhash'; then
  echo "签名校验失败：Designated Requirement 绑定了单次构建 cdhash，更新后授权无法复用。" >&2
  exit 1
fi

echo "stable_signing_authority=$AUTHORITY"
echo "stable_signing_identifier=$IDENTIFIER"
