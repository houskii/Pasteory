#!/bin/zsh
set -euo pipefail
BUILD_PHASE="读取构建配置"
trap 'print -u2 "Pasteory 构建失败：$BUILD_PHASE"' ZERR

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DIST_DIR="$PROJECT_DIR/dist"
BUILD_VARIANT=${PASTEORY_BUILD_VARIANT:-production}
case "$BUILD_VARIANT" in
  production)
    APP_FILE_NAME="Pasteory"
    APP_DISPLAY_NAME="Pasteory"
    APP_BUNDLE_IDENTIFIER="app.pasteory.Pasteory"
    APP_SUPPORT_DIRECTORY="Pasteory"
    NATIVE_MESSAGING_HOST="app.pasteory.web_context"
    CHROME_INTEGRATION_ENABLED=true
    BUILD_CONFIGURATION=${PASTEORY_BUILD_CONFIGURATION:-release}
    ;;
  qa)
    APP_FILE_NAME="Pasteory-QA"
    APP_DISPLAY_NAME="Pasteory QA"
    APP_BUNDLE_IDENTIFIER="app.pasteory.Pasteory.qa"
    APP_SUPPORT_DIRECTORY="Pasteory QA"
    NATIVE_MESSAGING_HOST="app.pasteory.qa.web_context"
    CHROME_INTEGRATION_ENABLED=false
    BUILD_CONFIGURATION=${PASTEORY_BUILD_CONFIGURATION:-debug}
    ;;
  *)
    echo "未知的 PASTEORY_BUILD_VARIANT：$BUILD_VARIANT（仅支持 production 或 qa）。" >&2
    exit 1
    ;;
esac
APP_DIR="$DIST_DIR/$APP_FILE_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LOCAL_SIGNING_DIR="$HOME/Library/Application Support/Pasteory/Signing"
LOCAL_SIGNING_KEYCHAIN="$LOCAL_SIGNING_DIR/PasteoryBuild.keychain-db"
LOCAL_SIGNING_PASSWORD_FILE="$LOCAL_SIGNING_DIR/keychain-password"
USE_LOCAL_SIGNING_KEYCHAIN=false
BUILD_PHASE="初始化稳定代码签名身份"
if [[ -n ${PASTEORY_SIGN_IDENTITY:-} ]]; then
  [[ "$PASTEORY_SIGN_IDENTITY" != "-" ]] || {
    echo "PASTEORY_SIGN_IDENTITY 不允许使用 ad-hoc 身份 '-'。" >&2
    exit 1
  }
  SIGN_IDENTITY=$PASTEORY_SIGN_IDENTITY
else
  SIGN_IDENTITY=$($SCRIPT_DIR/ensure_local_signing_identity.sh)
  [[ -f "$LOCAL_SIGNING_KEYCHAIN" && -f "$LOCAL_SIGNING_PASSWORD_FILE" ]] || {
    echo "Pasteory 稳定签名身份初始化后文件仍不完整。" >&2
    exit 1
  }
  LOCAL_SIGNING_PASSWORD=$(<"$LOCAL_SIGNING_PASSWORD_FILE")
  USE_LOCAL_SIGNING_KEYCHAIN=true
fi

codesign_with_local_keychain() {
  (
    set -euo pipefail

    local keychain
    local default_keychain
    local -a restore_keychains
    local -a signing_keychains
    restore_keychains=()

    while IFS= read -r keychain; do
      keychain=${keychain#*\"}
      keychain=${keychain%\"*}
      [[ -n "$keychain" && -e "$keychain" ]] || continue
      [[ "$keychain" != "$LOCAL_SIGNING_KEYCHAIN" ]] || continue
      if (( ${restore_keychains[(Ie)$keychain]} == 0 )); then
        restore_keychains+=("$keychain")
      fi
    done < <(security list-keychains -d user)

    if (( ${#restore_keychains} == 0 )); then
      default_keychain=$(security default-keychain -d user)
      default_keychain=${default_keychain#*\"}
      default_keychain=${default_keychain%\"*}
      [[ -n "$default_keychain" && -e "$default_keychain" ]] || {
        echo "找不到可恢复的用户默认钥匙串，已拒绝临时修改搜索列表。" >&2
        exit 1
      }
      restore_keychains+=("$default_keychain")
    fi

    signing_keychains=("${restore_keychains[@]}")
    if (( ${signing_keychains[(Ie)$LOCAL_SIGNING_KEYCHAIN]} == 0 )); then
      signing_keychains+=("$LOCAL_SIGNING_KEYCHAIN")
    fi
    restore_user_keychain_search_list() {
      security list-keychains -d user -s "${restore_keychains[@]}" >/dev/null
    }
    trap restore_user_keychain_search_list EXIT

    security list-keychains -d user -s "${signing_keychains[@]}"
    security unlock-keychain -p "$LOCAL_SIGNING_PASSWORD" "$LOCAL_SIGNING_KEYCHAIN"
    "$SCRIPT_DIR/sign_app_bundle.sh" "$APP_DIR" "$SIGN_IDENTITY" "$LOCAL_SIGNING_KEYCHAIN"
  )
}

BUILD_PHASE="编译 Swift 应用"
arch -arm64 /usr/bin/swift build --package-path "$PROJECT_DIR" -c "$BUILD_CONFIGURATION" --arch arm64
BIN_DIR=$(arch -arm64 /usr/bin/swift build --package-path "$PROJECT_DIR" -c "$BUILD_CONFIGURATION" --arch arm64 --show-bin-path)

BUILD_PHASE="组装应用与 Sparkle 框架"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
ditto "$BIN_DIR/Pasteory" "$MACOS_DIR/Pasteory"
[[ -d "$BIN_DIR/Pasteory_PasteoryCore.bundle" ]] || { echo "Missing localization resource bundle" >&2; exit 1; }
ditto "$BIN_DIR/Pasteory_PasteoryCore.bundle" "$RESOURCES_DIR/Pasteory_PasteoryCore.bundle"
ditto "$PROJECT_DIR/Config/Localizations" "$RESOURCES_DIR"
ditto "$PROJECT_DIR/Config/Info.plist" "$CONTENTS_DIR/Info.plist"
SPARKLE_FRAMEWORK="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "找不到 SwiftPM Sparkle.framework 产物。" >&2; exit 1; }
mkdir -p "$CONTENTS_DIR/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
BUILD_PHASE="配置更新公钥"
UPDATE_PUBLIC_KEY=$("$SCRIPT_DIR/ensure_update_signing_key.sh")
[[ ${#UPDATE_PUBLIC_KEY} == 44 && "$(print -rn -- "$UPDATE_PUBLIC_KEY" | base64 -D | wc -c | tr -d ' ')" == 32 ]] \
  || { echo "更新公钥格式无效。" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $UPDATE_PUBLIC_KEY" "$CONTENTS_DIR/Info.plist"
if [[ "$BUILD_VARIANT" == qa ]]; then
  /usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$CONTENTS_DIR/Info.plist"
fi
ditto "$PROJECT_DIR/ChromeExtension" "$RESOURCES_DIR/ChromeExtension"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_DISPLAY_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_DISPLAY_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_IDENTIFIER" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PasteoryBuildVariant $BUILD_VARIANT" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PasteoryApplicationSupportDirectory $APP_SUPPORT_DIRECTORY" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PasteoryNativeMessagingHostName $NATIVE_MESSAGING_HOST" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PasteoryChromeIntegrationEnabled $CHROME_INTEGRATION_ENABLED" "$CONTENTS_DIR/Info.plist"

BUILD_PHASE="生成和复制应用资源"
SOURCE_APP_ICONS_DIR="$RESOURCES_DIR/SourceAppIcons"
mkdir -p "$SOURCE_APP_ICONS_DIR"
SOURCE_APP_ICON_SPECS=(
  "chrome.icns|/Applications/Google Chrome.app/Contents/Resources/app.icns"
  "wechat.icns|/Applications/WeChat.app/Contents/Resources/AppIcon.icns"
  "lark.icns|/Applications/Lark.app/Contents/Resources/app.icns"
)
for spec in "${SOURCE_APP_ICON_SPECS[@]}"; do
  target_name=${spec%%|*}
  source_path=${spec#*|}
  if [[ -f "$source_path" ]]; then
    ditto "$source_path" "$SOURCE_APP_ICONS_DIR/$target_name"
  else
    echo "未找到来源应用图标：$source_path" >&2
  fi
done

FILE_ICONS_SOURCE_DIR="$PROJECT_DIR/Resources/FileIcons"
FILE_ICONS_TARGET_DIR="$RESOURCES_DIR/FileIcons"
[[ -d "$FILE_ICONS_SOURCE_DIR" ]] || { echo "文件图标资源目录缺失：$FILE_ICONS_SOURCE_DIR" >&2; exit 1; }
ditto "$FILE_ICONS_SOURCE_DIR" "$FILE_ICONS_TARGET_DIR"
FILE_ICON_COUNT=$(find "$FILE_ICONS_TARGET_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')
[[ "$FILE_ICON_COUNT" == "49" ]] || { echo "文件图标数量错误：预期 49，实际 $FILE_ICON_COUNT" >&2; exit 1; }

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

arch -arm64 /usr/bin/swift "$PROJECT_DIR/scripts/generate_menu_bar_icon.swift" \
  "$RESOURCES_DIR/MenuBarIcon.png" \
  "$RESOURCES_DIR/MenuBarIcon@2x.png"
arch -arm64 /usr/bin/swift "$PROJECT_DIR/scripts/verify_menu_bar_icon.swift" \
  "$RESOURCES_DIR/MenuBarIcon.png" \
  "$RESOURCES_DIR/MenuBarIcon@2x.png" >/dev/null

[[ -x "$MACOS_DIR/Pasteory" ]] || { echo "应用可执行文件在签名前丢失：$MACOS_DIR/Pasteory" >&2; exit 1; }
[[ -f "$CONTENTS_DIR/Info.plist" ]] || { echo "Info.plist 在签名前丢失：$CONTENTS_DIR/Info.plist" >&2; exit 1; }
[[ -d "$RESOURCES_DIR/ChromeExtension" ]] || { echo "Chrome 扩展资源在签名前丢失：$RESOURCES_DIR/ChromeExtension" >&2; exit 1; }
[[ -d "$RESOURCES_DIR/FileIcons" ]] || { echo "文件图标资源在签名前丢失：$RESOURCES_DIR/FileIcons" >&2; exit 1; }
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

BUILD_PHASE="签名应用与更新辅助程序"
if [[ "$USE_LOCAL_SIGNING_KEYCHAIN" == true ]]; then
  codesign_with_local_keychain
else
  "$SCRIPT_DIR/sign_app_bundle.sh" "$APP_DIR" "$SIGN_IDENTITY"
fi
BUILD_PHASE="验证应用签名"
"$SCRIPT_DIR/verify_signing.sh" "$APP_DIR" "$APP_BUNDLE_IDENTIFIER" >/dev/null
echo "$APP_DIR"
