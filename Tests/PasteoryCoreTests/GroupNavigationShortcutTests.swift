import Carbon
import Foundation
import Testing
@testable import Pasteory

@MainActor
private func withGroupShortcutSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
    let suite = "PasteoryGroupShortcuts.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(AppSettings(defaults: defaults), defaults)
}

@Test @MainActor func groupShortcutsSelectItemsAndDoNotSwitchProfiles() throws {
    try withGroupShortcutSettings { settings, _ in
        let codes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, action) in GroupNavigationAction.groups.enumerated() {
            #expect(settings.groupNavigationAction(keyCode: codes[index], modifiers: UInt32(optionKey)) == action)
            #expect(settings.quickAction(keyCode: codes[index], modifiers: UInt32(optionKey)) == nil)
        }
        for (index, profile) in GroupViewProfile.allCases.enumerated() {
            #expect(settings.groupNavigationAction(keyCode: codes[index], modifiers: UInt32(controlKey | optionKey)) == .profile(profile))
        }
        #expect(settings.groupNavigationAction(keyCode: 50, modifiers: UInt32(optionKey)) == .allContent)
        #expect(settings.groupNavigationAction(keyCode: 29, modifiers: UInt32(optionKey)) == nil)
        #expect(settings.groupNavigationAction(keyCode: 50, modifiers: UInt32(optionKey | shiftKey)) == nil)
        #expect(settings.groupNavigationAction(keyCode: 18, modifiers: UInt32(cmdKey)) == nil)
    }
}

@Test @MainActor func groupShortcutsPersistOverridesClearingAndReset() throws {
    try withGroupShortcutSettings { settings, defaults in
        let shortcut = PasteoryShortcut(keyCode: 17, modifiers: UInt32(controlKey | optionKey | shiftKey))
        #expect(settings.setGroupNavigationShortcut(shortcut, for: .group1) == nil)
        let profileShortcut = PasteoryShortcut(keyCode: 31, modifiers: UInt32(controlKey | optionKey))
        #expect(settings.setGroupNavigationShortcut(profileShortcut, for: .profile(.ai)) == nil)
        settings.clearGroupNavigationShortcut(for: .group2)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.groupNavigationAction(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) == .group1)
        #expect(reloaded.groupNavigationAction(keyCode: profileShortcut.keyCode, modifiers: profileShortcut.modifiers) == .profile(.ai))
        #expect(reloaded.groupNavigationShortcuts.overrides["profile.ai"] == profileShortcut)
        #expect(reloaded.groupNavigationAction(keyCode: 19, modifiers: UInt32(optionKey)) == nil)
        #expect(reloaded.groupNavigationAction(keyCode: 19, modifiers: UInt32(controlKey | optionKey)) == nil)
        #expect(reloaded.groupNavigationHint(for: .group2) == nil)
        reloaded.resetAllShortcuts()
        #expect(reloaded.groupNavigationAction(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) == nil)
        #expect(reloaded.groupNavigationAction(keyCode: 18, modifiers: UInt32(optionKey)) == .group1)
        #expect(reloaded.groupNavigationAction(keyCode: 19, modifiers: UInt32(optionKey)) == .group2)
        #expect(reloaded.groupNavigationAction(keyCode: 19, modifiers: UInt32(controlKey | optionKey)) == .profile(.ai))
    }
}

@Test @MainActor func groupShortcutConflictsAreRejectedInBothDirections() throws {
    try withGroupShortcutSettings { settings, _ in
        let group1 = try #require(GroupNavigationAction.group1.defaultShortcut)
        let group2 = try #require(GroupNavigationAction.group2.defaultShortcut)
        #expect(settings.setGroupNavigationShortcut(.init(keyCode: 3, modifiers: UInt32(cmdKey)), for: .group1) != nil)
        #expect(settings.setGroupNavigationShortcut(group2, for: .group1) != nil)
        let global = try #require(settings.globalShortcut)
        #expect(settings.setGroupNavigationShortcut(global, for: .group1) != nil)
        #expect(settings.setGroupNavigationShortcut(.init(keyCode: 18, modifiers: UInt32(cmdKey)), for: .group1) != nil)
        #expect(settings.setGroupNavigationShortcut(.init(keyCode: 18, modifiers: 0), for: .group1) != nil)
        #expect(settings.setQuickShortcut(group1, for: .togglePinned) != nil)
        #expect(settings.globalShortcutConflict(keyCode: 18, modifiers: UInt32(optionKey)) != nil)
        settings.clearGroupNavigationShortcut(for: .group1)
        #expect(settings.setQuickShortcut(group1, for: .togglePinned) == nil)
    }
}

@Test @MainActor func newGroupDefaultsPreservePreviouslyAssignedActions() throws {
    try withGroupShortcutSettings { _, defaults in
        let shortcut = try #require(GroupNavigationAction.group1.defaultShortcut)
        defaults.set(try JSONEncoder().encode([QuickPanelAction.togglePinned.rawValue: shortcut]), forKey: "quickActionShortcuts")
        let migrated = AppSettings(defaults: defaults)
        #expect(migrated.quickAction(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) == .togglePinned)
        #expect(migrated.groupNavigationAction(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) == nil)
        #expect(AppSettings(defaults: defaults).groupNavigationHint(for: .group1) == nil)
    }
}
