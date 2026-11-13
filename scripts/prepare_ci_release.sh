#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
[[ ${GITHUB_ACTIONS:-} == true && $(uname -s) == Darwin ]]
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/Info.plist)
[[ ${PASTEORY_RELEASE_VERSION:-} == "$version" ]]
public_certificate="$PWD/Config/SigningRecovery.crt"
signing_directory="$HOME/Library/Application Support/Pasteory/Signing"
update_key="$RUNNER_TEMP/pasteory-update-key"
archive="release/signing/recovery-$version.cms"

if [[ -f Config/UpdatePublicKey.txt ]]; then
  # Existing update clients need the same key. Restoration is optional on the first release.
  previous_archive=$(cat Config/SigningRecoveryArchive.txt)
  [[ "$previous_archive" == release/signing/recovery-*.cms && "$previous_archive" != *..* ]]
  [[ -n ${PASTEORY_RECOVERY_PRIVATE_KEY:-} && -f "$previous_archive" ]] || {
    echo 'To reuse the published signing keys, configure PASTEORY_RECOVERY_PRIVATE_KEY with the saved recovery PEM.' >&2
    exit 1
  }
  recovery_key="$RUNNER_TEMP/pasteory-recovery-private.pem"
  printf '%s\n' "$PASTEORY_RECOVERY_PRIVATE_KEY" > "$recovery_key"
  python3 scripts/signing_recovery.py restore --certificate "$public_certificate" \
    --private-key "$recovery_key" --encrypted "$previous_archive" \
    --signing-directory "$signing_directory" --update-key "$update_key" \
    --update-public-key Config/UpdatePublicKey.txt
  rm "$recovery_key"
fi
./scripts/ensure_local_signing_identity.sh >/dev/null
swift package resolve
tools="$PWD/.build/artifacts/sparkle/Sparkle/bin"
account=app.pasteory.Pasteory.updates
if [[ ! -f "$update_key" ]]; then
  "$tools/generate_keys" --account "$account" >/dev/null
  "$tools/generate_keys" --account "$account" -x "$update_key" >/dev/null
  "$tools/generate_keys" --account "$account" -p > Config/UpdatePublicKey.txt
fi
public_key=$(tr -d '[:space:]' < Config/UpdatePublicKey.txt)
# The key file avoids a first-access Keychain GUI prompt in unattended signing.
wrapper="$RUNNER_TEMP/pasteory-release-tools"
mkdir -p "$wrapper"
cat > "$wrapper/generate_keys" <<'KEY_TOOL'
#!/bin/bash
printf '%s\n' "$PASTEORY_UPDATE_PUBLIC_KEY"
KEY_TOOL
cat > "$wrapper/sign_update" <<'SIGN_TOOL'
#!/bin/bash
exec "$PASTEORY_RELEASE_SIGN_UPDATE" --ed-key-file "$PASTEORY_RELEASE_UPDATE_KEY" "$@"
SIGN_TOOL
chmod 700 "$wrapper/generate_keys" "$wrapper/sign_update"
{
  printf 'PASTEORY_UPDATE_PUBLIC_KEY=%s\n' "$public_key"
  printf 'PASTEORY_RELEASE_UPDATE_KEY=%s\n' "$update_key"
  printf 'PASTEORY_RELEASE_SIGN_UPDATE=%s\n' "$tools/sign_update"
  printf 'PASTEORY_SPARKLE_TOOLS=%s\n' "$wrapper"
} >> "$GITHUB_ENV"
python3 scripts/signing_recovery.py seal --certificate "$public_certificate" \
  --encrypted "$archive" --version "$version" \
  --signing-directory "$signing_directory" --update-key "$update_key" \
  --update-public-key Config/UpdatePublicKey.txt
printf '%s\n' "$archive" > Config/SigningRecoveryArchive.txt
git add Config/UpdatePublicKey.txt Config/SigningRecoveryArchive.txt "$archive"
echo 'Prepared local development signing and encrypted recovery archive.'
