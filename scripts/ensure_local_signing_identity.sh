#!/bin/zsh
set -euo pipefail
SIGNING_PHASE="初始化本地开发代码签名身份"
trap 'print -u2 "Pasteory 本地开发签名失败：$SIGNING_PHASE"' ZERR

SIGNING_DIR="$HOME/Library/Application Support/Pasteory/Signing"
BUILD_KEYCHAIN="$SIGNING_DIR/PasteoryBuild.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
RECOVERY_IDENTITY="$SIGNING_DIR/PasteoryLocalBuild.p12"
RECOVERY_CERTIFICATE="$SIGNING_DIR/PasteoryLocalBuild.pem"
IDENTITY_HASH_FILE="$SIGNING_DIR/identity-sha1"
IDENTITY_NAME="Pasteory Local Build"

umask 077
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

fail() {
  echo "Pasteory 本地开发签名初始化失败：$1" >&2
  exit 1
}

identity_hash() {
  security find-identity -v -p codesigning "$BUILD_KEYCHAIN" 2>/dev/null \
    | awk -v name="$IDENTITY_NAME" 'index($0, name) { print $2; exit }'
}

configure_keychain() {
  SIGNING_PHASE="解锁构建钥匙串"
  local password=$1
  security unlock-keychain -p "$password" "$BUILD_KEYCHAIN"
  security set-keychain-settings -lut 21600 "$BUILD_KEYCHAIN"
}

import_recovery_identity() {
  SIGNING_PHASE="导入稳定签名身份"
  local password=$1
  [[ -f "$RECOVERY_IDENTITY" && -f "$RECOVERY_CERTIFICATE" ]] \
    || fail "本地钥匙串缺少签名身份，且恢复文件不完整。请保留 $SIGNING_DIR 后人工检查。"
  security import "$RECOVERY_IDENTITY" -k "$BUILD_KEYCHAIN" -P "$password" -A >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$password" "$BUILD_KEYCHAIN" >/dev/null
  SIGNING_PHASE="设置信任的代码签名证书"
  if [[ ${GITHUB_ACTIONS:-false} == true ]]; then
    # The hosted runner is ephemeral. Admin trust avoids an unattended GUI prompt.
    print -u2 "Pasteory CI：配置临时构建证书信任"
    sudo -n security add-trusted-cert -d -r trustRoot -p codeSign \
      -k /Library/Keychains/System.keychain "$RECOVERY_CERTIFICATE" >/dev/null
  else
    security add-trusted-cert \
      -r trustRoot -p codeSign \
      -k "$BUILD_KEYCHAIN" "$RECOVERY_CERTIFICATE" >/dev/null
  fi
}

create_identity() {
  SIGNING_PHASE="创建稳定代码签名证书"
  if [[ ${GITHUB_ACTIONS:-false} == true ]]; then print -u2 "Pasteory CI：创建临时构建证书"; fi
  local password=$1
  local certificate_work
  certificate_work=$(mktemp -d /tmp/pasteory-signing.XXXXXX)
  trap "find '$certificate_work' -type f -delete 2>/dev/null || true; rmdir '$certificate_work' 2>/dev/null || true" EXIT

  openssl req \
    -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -subj '/CN=Pasteory Local Build/O=Pasteory' \
    -addext 'basicConstraints=critical,CA:false' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=critical,codeSigning' \
    -keyout "$certificate_work/private-key.pem" \
    -out "$certificate_work/certificate.pem" >/dev/null 2>&1
  openssl pkcs12 \
    -export -legacy \
    -inkey "$certificate_work/private-key.pem" \
    -in "$certificate_work/certificate.pem" \
    -name "$IDENTITY_NAME" \
    -out "$certificate_work/identity.p12" \
    -passout "pass:$password" >/dev/null 2>&1

  install -m 600 "$certificate_work/identity.p12" "$RECOVERY_IDENTITY"
  install -m 600 "$certificate_work/certificate.pem" "$RECOVERY_CERTIFICATE"
  security create-keychain -p "$password" "$BUILD_KEYCHAIN"
  configure_keychain "$password"
  import_recovery_identity "$password"
  find "$certificate_work" -type f -delete
  rmdir "$certificate_work"
  trap - EXIT
}

if [[ ! -f "$PASSWORD_FILE" ]]; then
  if [[ -e "$BUILD_KEYCHAIN" || -e "$RECOVERY_IDENTITY" || -e "$RECOVERY_CERTIFICATE" || -e "$IDENTITY_HASH_FILE" ]]; then
    fail "签名目录处于不完整状态，未自动轮换证书。请保留 $SIGNING_DIR 后人工检查。"
  fi
  openssl rand -hex 32 > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
fi

BUILD_PASSWORD=$(<"$PASSWORD_FILE")
[[ -n "$BUILD_PASSWORD" ]] || fail "钥匙串密码文件为空。"

if [[ ! -f "$BUILD_KEYCHAIN" ]]; then
  if [[ -f "$RECOVERY_IDENTITY" && -f "$RECOVERY_CERTIFICATE" ]]; then
    security create-keychain -p "$BUILD_PASSWORD" "$BUILD_KEYCHAIN"
    configure_keychain "$BUILD_PASSWORD"
    import_recovery_identity "$BUILD_PASSWORD"
  elif [[ ! -e "$RECOVERY_IDENTITY" && ! -e "$RECOVERY_CERTIFICATE" && ! -e "$IDENTITY_HASH_FILE" ]]; then
    create_identity "$BUILD_PASSWORD"
  else
    fail "钥匙串缺失，且恢复文件不完整。未自动生成新证书，以免辅助功能授权再次失效。"
  fi
else
  configure_keychain "$BUILD_PASSWORD"
fi

IDENTITY_HASH=$(identity_hash)
if [[ -z "$IDENTITY_HASH" && -f "$RECOVERY_IDENTITY" && -f "$RECOVERY_CERTIFICATE" ]]; then
  import_recovery_identity "$BUILD_PASSWORD"
  IDENTITY_HASH=$(identity_hash)
fi
[[ -n "$IDENTITY_HASH" ]] || fail "钥匙串中找不到 $IDENTITY_NAME。"

if [[ -f "$IDENTITY_HASH_FILE" ]]; then
  EXPECTED_HASH=$(<"$IDENTITY_HASH_FILE")
  [[ "$IDENTITY_HASH" == "$EXPECTED_HASH" ]] \
    || fail "签名证书指纹发生变化。已拒绝构建，避免覆盖现有辅助功能授权。"
else
  print -rn -- "$IDENTITY_HASH" > "$IDENTITY_HASH_FILE"
  chmod 600 "$IDENTITY_HASH_FILE"
fi

chmod 600 "$PASSWORD_FILE" "$RECOVERY_IDENTITY" "$RECOVERY_CERTIFICATE" "$IDENTITY_HASH_FILE" "$BUILD_KEYCHAIN"
if [[ ${GITHUB_ACTIONS:-false} == true ]]; then
  # Keep both the code-signing key and Sparkle's test key in this unlocked CI keychain.
  security default-keychain -d user -s "$BUILD_KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$BUILD_KEYCHAIN" >/dev/null
fi
print -r -- "$IDENTITY_HASH"
