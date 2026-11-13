#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
cd "${SCRIPT_DIR:h}"
phase="检查发布条件"
trap 'print -u2 "Beta 发布失败：$phase"' ZERR

notes=${1:-}
[[ -s "$notes" && "$(git branch --show-current)" == "main" ]]
[[ "$(git remote get-url --push origin)" =~ '^((git@github\.com:)|(https://github\.com/))houskii/Pasteory(\.git)?$' ]]
git diff --quiet
[[ -z "$(git ls-files --others --exclude-standard)" ]]
git diff --cached --check
git fetch origin main --tags
git merge-base --is-ancestor origin/main HEAD
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Config/Info.plist)
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build" =~ '^[0-9]+$' ]]
tag="v$version"
[[ -z "$(git tag --list "$tag")" ]]
remote_tag=$(git ls-remote --tags origin "refs/tags/$tag")
[[ -z "$remote_tag" ]]
old_plist=$(git show origin/main:Config/Info.plist)
old_version=$(print -r -- "$old_plist" | plutil -extract CFBundleShortVersionString raw -o - -)
old_build=$(print -r -- "$old_plist" | plutil -extract CFBundleVersion raw -o - -)
# PRs may merge the version bump before the publisher Mac builds the release.
# In that case compare against the latest reachable release tag, never the same source version.
if [[ "$version" == "$old_version" ]]; then
  [[ "$build" == "$old_build" ]]
  previous_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main 2>/dev/null || true)
  if [[ -n "$previous_tag" ]]; then
    previous_plist=$(git show "$previous_tag:Config/Info.plist")
    old_version=$(print -r -- "$previous_plist" | plutil -extract CFBundleShortVersionString raw -o - -)
    old_build=$(print -r -- "$previous_plist" | plutil -extract CFBundleVersion raw -o - -)
  else
    old_version=0.0.0
    old_build=0
  fi
fi
autoload -Uz is-at-least
[[ "$version" != "$old_version" && "$build" -gt "$old_build" ]]
is-at-least "$old_version" "$version"

phase="运行测试和签名打包"
make test
PASTEORY_BUILD_VARIANT=production PASTEORY_BUILD_CONFIGURATION=release make verify
dmg="Pasteory-$version-arm64.dmg"
phase="准备签名更新索引"
python3 "$SCRIPT_DIR/prepare_update.py" --tag "$tag" --notes "$notes" --dmg "dist/$dmg"
phase="安装已验证的 App"
PASTEORY_SKIP_EXISTING_MAINTENANCE=1 "$SCRIPT_DIR/install.sh"

phase="提交源码和最新安装包"
cp "dist/$dmg" "release/beta/$dmg"
cp dist/update/appcast.xml "release/beta/appcast-$version.xml"
for previous in release/beta/Pasteory-*-arm64.dmg(N); do
  if [[ "$previous" != "release/beta/$dmg" ]]; then git rm -- "$previous"; fi
done
git add -- "release/beta/$dmg" "release/beta/appcast-$version.xml"
git diff --cached --check
git commit -m "Release Pasteory $version"
git tag -a "$tag" -F "$notes"
phase="推送源码和标签"
git push --atomic origin HEAD:refs/heads/main "refs/tags/$tag"

phase="等待 GitHub Release 并核对下载"
download=$(mktemp -d)
trap 'rm -rf "$download"' EXIT
base="https://github.com/houskii/Pasteory/releases/download/$tag"
for attempt in {1..60}; do
  if curl -fsSL --max-time 20 "$base/$dmg.sha256" -o "$download/$dmg.sha256" 2>/dev/null; then break; fi
  sleep 5
done
[[ -s "$download/$dmg.sha256" ]]
curl -fsSL --max-time 60 "$base/$dmg" -o "$download/$dmg"
(cd "$download" && shasum -a 256 -c "$dmg.sha256")
cmp "release/beta/$dmg" "$download/$dmg"
phase="核对签名更新索引"
curl -fsSL --max-time 30 "$base/appcast-$version.xml" -o "$download/appcast.xml"
cmp "release/beta/appcast-$version.xml" "$download/appcast.xml"
for attempt in {1..60}; do
  git fetch origin main
  git show origin/main:release/beta/appcast.xml > "$download/current-appcast.xml"
  if cmp -s "$download/appcast.xml" "$download/current-appcast.xml"; then break; fi
  sleep 5
done
cmp "$download/appcast.xml" "$download/current-appcast.xml"
git merge --ff-only origin/main
print "https://github.com/houskii/Pasteory/releases/tag/$tag"
