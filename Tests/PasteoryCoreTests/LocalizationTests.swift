import Foundation
import Testing
@testable import PasteoryCore
@testable import Pasteory

@Test func localizedLabelsSwitchWithoutChangingModelValues() throws {
    let descriptor = try #require(FileIconResolver.fileType(assetName: "generic"))
    let fileExtension = try #require(FileIconResolver.allFileExtensions.first { $0.fileExtension == "txt" })
    L10n.$languageOverride.withValue(.english) {
        #expect(ClipKind.text.displayName == "Text")
        #expect(SettingsDestination.general.title == "General")
        #expect(QuickPanelAction.openLibrary.title == "Open Library in Settings")
        #expect(descriptor.displayName == "Other Files")
        #expect(fileExtension.displayName == "Plain Text")
    }
    L10n.$languageOverride.withValue(.simplifiedChinese) {
        #expect(ClipKind.text.displayName == "文字")
        #expect(SettingsDestination.general.title == "通用")
        #expect(QuickPanelAction.openLibrary.title == "打开设置中的资料库")
        #expect(descriptor.displayName == "其他文件")
        #expect(fileExtension.displayName == "纯文本")
    }
    #expect(ClipKind.text.rawValue == "text")
    #expect(descriptor.assetName == "generic")
}

@Test func localizationPreservesInterpolatedUserContent() {
    let userText = "用户原文 {1} 🌈\n{0}"
    L10n.$languageOverride.withValue(.english) {
        #expect(L10n.tr("标题已更新为“\(userText)”") == "Title updated to “\(userText)”")
        #expect(L10n.tr("当前版本 \("0.1.31")（Build \(36)）") == "Current version 0.1.31 (Build 36)")
    }
    L10n.$languageOverride.withValue(.simplifiedChinese) {
        #expect(L10n.tr("标题已更新为“\(userText)”") == "标题已更新为“\(userText)”")
    }
    #expect(L10n.render("{1} / {0} / {9}", arguments: [userText, "second"]) == "second / \(userText) / {9}")
}

@Test func localizationCatalogHasMatchingPlaceholdersAndEnglishLabels() throws {
    let expression = try NSRegularExpression(pattern: #"\{\d+\}"#)
    func placeholders(_ value: String) -> [String] {
        expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .map { String(value[Range($0.range, in: value)!]) }.sorted()
    }
    #expect(L10n.english.count > 800)
    for (key, value) in L10n.english {
        #expect(!value.isEmpty, "Empty translation: \(key)")
        #expect(placeholders(key) == placeholders(value), "Mismatched placeholders: \(key)")
        #expect(value.range(of: #"[\u3400-\u9FFF]"#, options: .regularExpression) == nil, "Untranslated English label: \(key)")
    }
}

@Test @MainActor func languageDefaultsToEnglishAndPersistsAcrossLaunches() throws {
    let suite = "app.pasteory.tests.language.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // The first-launch default does not depend on the operating system language.
    defaults.set(["zh-Hans"], forKey: "AppleLanguages")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.appLanguage == .english)
    settings.appLanguage = .simplifiedChinese
    #expect(AppSettings(defaults: defaults).appLanguage == .simplifiedChinese)
    #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
    settings.appLanguage = .english
    #expect(AppSettings(defaults: defaults).appLanguage == .english)
    defaults.set("unsupported", forKey: "appLanguage")
    #expect(AppSettings(defaults: defaults).appLanguage == .english)
}
