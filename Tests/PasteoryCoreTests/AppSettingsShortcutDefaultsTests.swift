import Foundation
import Testing
@testable import Pasteory

@MainActor
@Test func freshInstallAndResetUseTheCurrentShortcutConfiguration() throws {
    let suiteName = "app.pasteory.tests.shortcuts.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = AppSettings(defaults: defaults)
    #expect(settings.globalShortcut == PasteoryShortcut(keyCode: 9, modifiers: 768))

    let expected: [QuickPanelAction: PasteoryShortcut] = [
        .openSelected: PasteoryShortcut(keyCode: 49, modifiers: 0),
        .toggleSearch: PasteoryShortcut(keyCode: 3, modifiers: 256),
        .directPaste: PasteoryShortcut(keyCode: 36, modifiers: 0),
        .copyOnly: PasteoryShortcut(keyCode: 8, modifiers: 256),
        .plainTextPaste: PasteoryShortcut(keyCode: 36, modifiers: 2_048),
        .plainTextCopy: PasteoryShortcut(keyCode: 8, modifiers: 2_304),
        .toggleFavorite: PasteoryShortcut(keyCode: 3, modifiers: 768),
        .togglePinned: PasteoryShortcut(keyCode: 17, modifiers: 256),
        .editMetadata: PasteoryShortcut(keyCode: 14, modifiers: 256),
        .setCollection: PasteoryShortcut(keyCode: 5, modifiers: 256),
        .createCollection: PasteoryShortcut(keyCode: 45, modifiers: 768),
        .aggregateContent: PasteoryShortcut(keyCode: 11, modifiers: 256),
        .expandAggregation: PasteoryShortcut(keyCode: 125, modifiers: 256),
        .collapseAggregation: PasteoryShortcut(keyCode: 126, modifiers: 256),
        .moveToTrash: PasteoryShortcut(keyCode: 51, modifiers: 256),
        .openLibrary: PasteoryShortcut(keyCode: 37, modifiers: 256),
        .openSettings: PasteoryShortcut(keyCode: 43, modifiers: 256),
        .closePanel: PasteoryShortcut(keyCode: 13, modifiers: 256)
    ]
    for (action, shortcut) in expected {
        #expect(settings.quickShortcut(for: action) == shortcut)
    }
    #expect(settings.quickAction(keyCode: 5, modifiers: 256) == .setCollection)
    #expect(settings.quickAction(keyCode: 14, modifiers: 256) == .editMetadata)
    #expect(settings.quickAction(keyCode: 45, modifiers: 768) == .createCollection)

    settings.setGlobalShortcut(PasteoryShortcut(keyCode: 0, modifiers: 768))
    _ = settings.setQuickShortcut(PasteoryShortcut(keyCode: 1, modifiers: 256), for: .editMetadata)
    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.globalShortcut == PasteoryShortcut(keyCode: 0, modifiers: 768))
    #expect(reloaded.quickShortcut(for: .editMetadata) == PasteoryShortcut(keyCode: 1, modifiers: 256))

    reloaded.resetAllShortcuts()
    #expect(reloaded.globalShortcut == PasteoryShortcut(keyCode: 9, modifiers: 768))
    for (action, shortcut) in expected {
        #expect(reloaded.quickShortcut(for: action) == shortcut)
    }
}

@MainActor
@Test func newlyAddedCreateCollectionShortcutDoesNotReplaceAnExistingAssignment() throws {
    let suiteName = "app.pasteory.tests.create-collection-shortcut.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let existing = [
        QuickPanelAction.togglePinned.rawValue: PasteoryShortcut(keyCode: 45, modifiers: 768)
    ]
    defaults.set(try JSONEncoder().encode(existing), forKey: "quickActionShortcuts")

    let settings = AppSettings(defaults: defaults)
    #expect(settings.quickShortcut(for: .togglePinned) == PasteoryShortcut(keyCode: 45, modifiers: 768))
    #expect(settings.quickShortcut(for: .createCollection) == nil)
}
