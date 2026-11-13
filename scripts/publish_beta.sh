#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
version_from_plist() {
  python3 -c 'import plistlib; print(plistlib.load(open("Config/Info.plist","rb"))["CFBundleShortVersionString"])'
}
tag=${1:-}
if [[ -z "$tag" ]]; then
  if [[ ${GITHUB_REF_TYPE:-} == tag ]]; then
    tag=$GITHUB_REF_NAME
  else
    tag="v$(version_from_plist)"
    if ! git show-ref --verify --quiet "refs/tags/$tag"; then
      echo "No release tag $tag yet."
      exit 0
    fi
  fi
fi
git checkout --detach "refs/tags/$tag"
version=$(version_from_plist)
[[ "$tag" == "v$version" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
git fetch origin main
git merge-base --is-ancestor HEAD origin/main
dmg="Pasteory-$version-arm64.dmg"
[[ "$(find release/beta -maxdepth 1 -name '*.dmg' -print)" == "release/beta/$dmg" ]]
working=$(mktemp -d)
trap 'rm -rf "$working"' EXIT
(cd release/beta && shasum -a 256 "$dmg") > "$working/$dmg.sha256"
appcast="release/beta/appcast-$version.xml"
assets=("release/beta/$dmg" "$working/$dmg.sha256")
if [[ -f "$appcast" ]]; then assets+=("$appcast"); fi
if gh release view "$tag" --json assets --jq '.assets[].name' > "$working/existing-names"; then
  # Retry may add missing assets, but must never replace a published byte.
  mkdir "$working/existing"
  for asset in "${assets[@]}"; do
    name=$(basename "$asset")
    if grep -Fxq "$name" "$working/existing-names"; then
      gh release download "$tag" --pattern "$name" --dir "$working/existing"
      cmp "$asset" "$working/existing/$name"
    else
      gh release upload "$tag" "$asset"
    fi
  done
else
  gh release create "$tag" "${assets[@]}" --verify-tag --notes-from-tag \
    --title "Pasteory $version Beta" --prerelease
fi
# Read back every asset before advertising the update.
mkdir "$working/verified"
for asset in "${assets[@]}"; do
  name=$(basename "$asset")
  gh release download "$tag" --pattern "$name" --dir "$working/verified"
  cmp "$asset" "$working/verified/$name"
done
(cd "$working/verified" && shasum -a 256 -c "$dmg.sha256")
if [[ -f "$appcast" ]]; then
  cp "$appcast" "$working/signed-appcast.xml"
  git fetch origin main
  git switch -C publish-update-feed origin/main
  if [[ "$(version_from_plist)" != "$version" ]]; then
    echo "A newer source version is present; keeping its update feed."
    exit 0
  fi
  if ! cmp -s "$working/signed-appcast.xml" release/beta/appcast.xml; then
    cp "$working/signed-appcast.xml" release/beta/appcast.xml
    git add release/beta/appcast.xml
    git -c user.name='github-actions[bot]' \
      -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
      commit -m "Publish signed update feed for $version"
    git -c 'credential.helper=!gh auth git-credential' push origin HEAD:main
  fi
fi
