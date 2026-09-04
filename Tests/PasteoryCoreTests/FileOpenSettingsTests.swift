import Foundation
import Testing
@testable import Pasteory
@testable import PasteoryCore

@MainActor
@Test func customExtensionRuleTakesPriorityOverBuiltInFileTypeRule() {
    let suiteName = "FileOpenSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)

    settings.addFileOpenRule()
    let builtInID = settings.fileOpenRules[0].id
    settings.updateFileOpenRuleCatalogExtension(
        id: builtInID,
        descriptor: FileIconResolver.fileExtension("hap")!
    )
    var builtIn = settings.fileOpenRules[0]
    builtIn.bundleIdentifier = "built-in-app"
    settings.updateFileOpenRule(builtIn)

    settings.addCustomFileOpenRule()
    let customID = settings.fileOpenRules.last!.id
    settings.updateFileOpenRuleExtension(id: customID, fileExtension: "hap")
    var custom = settings.fileOpenRules.last!
    custom.bundleIdentifier = "custom-app"
    settings.updateFileOpenRule(custom)

    #expect(settings.fileOpenRule(fileName: "demo.hap", uti: nil)?.bundleIdentifier == "custom-app")
    #expect(settings.fileOpenRule(fileName: "demo.hsp", uti: nil) == nil)
}

@MainActor
@Test func updatingCommandPreservesTypedSpaces() {
    let suiteName = "FileOpenCommandTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.addFileOpenRule()
    let id = settings.fileOpenRules[0].id

    settings.updateFileOpenRuleCommand(id: id, command: "open -a Xcode \"$file\"")

    #expect(settings.fileOpenRules[0].command == "open -a Xcode \"$file\"")
}

@MainActor
@Test func storedFileTypeRuleMigratesToOneRepresentativeExtension() throws {
    let suiteName = "FileOpenMigrationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let stored = FileOpenRule(matchKind: .fileType, fileType: "swift", command: "tool \"$file\"")
    defaults.set(try JSONEncoder().encode([stored]), forKey: "fileOpenRules")

    let settings = AppSettings(defaults: defaults)

    #expect(settings.fileOpenRules[0].matchKind == .catalogExtension)
    #expect(settings.fileOpenRules[0].normalizedFileExtension == "swift")
    #expect(settings.fileOpenRule(fileName: "Demo.swift", uti: nil) != nil)
    #expect(settings.fileOpenRule(fileName: "Demo.swiftinterface", uti: nil) == nil)
}
