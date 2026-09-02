#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
PRODUCTION_APP="$PROJECT_DIR/dist/Pasteory.app"
QA_APP="$PROJECT_DIR/dist/Pasteory-QA.app"

[[ -d "$PRODUCTION_APP" ]] || "$SCRIPT_DIR/build_app.sh" >/dev/null
[[ -d "$QA_APP" ]] || "$SCRIPT_DIR/build_qa_app.sh" >/dev/null

production_plist="$PRODUCTION_APP/Contents/Info.plist"
qa_plist="$QA_APP/Contents/Info.plist"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

[[ "$(plist_value "$production_plist" CFBundleIdentifier)" == "app.pasteory.Pasteory" ]]
[[ "$(plist_value "$qa_plist" CFBundleIdentifier)" == "app.pasteory.Pasteory.qa" ]]
[[ "$(plist_value "$production_plist" CFBundleDisplayName)" == "Pasteory" ]]
[[ "$(plist_value "$qa_plist" CFBundleDisplayName)" == "Pasteory QA" ]]
[[ "$(plist_value "$production_plist" PasteoryBuildVariant)" == "production" ]]
[[ "$(plist_value "$qa_plist" PasteoryBuildVariant)" == "qa" ]]
[[ "$(plist_value "$production_plist" PasteoryApplicationSupportDirectory)" == "Pasteory" ]]
[[ "$(plist_value "$qa_plist" PasteoryApplicationSupportDirectory)" == "Pasteory QA" ]]
[[ "$(plist_value "$production_plist" PasteoryNativeMessagingHostName)" == "app.pasteory.web_context" ]]
[[ "$(plist_value "$qa_plist" PasteoryNativeMessagingHostName)" == "app.pasteory.qa.web_context" ]]
[[ "$(plist_value "$production_plist" PasteoryChromeIntegrationEnabled)" == "true" ]]
[[ "$(plist_value "$qa_plist" PasteoryChromeIntegrationEnabled)" == "false" ]]

"$SCRIPT_DIR/verify_signing.sh" "$PRODUCTION_APP" "app.pasteory.Pasteory" >/dev/null
"$SCRIPT_DIR/verify_signing.sh" "$QA_APP" "app.pasteory.Pasteory.qa" >/dev/null

production_requirement=$(codesign -d -r- "$PRODUCTION_APP" 2>&1)
qa_requirement=$(codesign -d -r- "$QA_APP" 2>&1)
[[ "$production_requirement" == *'identifier "app.pasteory.Pasteory"'* ]]
[[ "$qa_requirement" == *'identifier "app.pasteory.Pasteory.qa"'* ]]
[[ "$production_requirement" != "$qa_requirement" ]]

echo "Pasteory 正式包与 QA 包身份隔离验证通过"
