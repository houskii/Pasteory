import Foundation
import PasteoryCore
import Testing
@testable import Pasteory

@Test func metadataEditorTabsThroughTitleNoteAndCollections() {
    #expect(QuickMetadataEditorNavigation.nextField(
        from: .title,
        backwards: false,
        hasCollections: true
    ) == .note)
    #expect(QuickMetadataEditorNavigation.nextField(
        from: .note,
        backwards: false,
        hasCollections: true
    ) == .collections)
    #expect(QuickMetadataEditorNavigation.nextField(
        from: .collections,
        backwards: false,
        hasCollections: true
    ) == .title)
    #expect(QuickMetadataEditorNavigation.nextField(
        from: .title,
        backwards: true,
        hasCollections: true
    ) == .collections)
}

@Test func metadataEditorSkipsCollectionsWhenNoneExist() {
    #expect(QuickMetadataEditorNavigation.nextField(
        from: .title,
        backwards: false,
        hasCollections: false
    ) == .note)
    #expect(QuickMetadataEditorNavigation.nextField(
        from: .note,
        backwards: false,
        hasCollections: false
    ) == .title)
    #expect(QuickMetadataEditorNavigation.nextField(
        from: .title,
        backwards: true,
        hasCollections: false
    ) == .note)
}

@Test func metadataEditorMovesAndTogglesCollectionSelection() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let ids = [first, second, third]

    #expect(QuickMetadataEditorNavigation.nextCollection(in: ids, currentID: nil, offset: 1) == first)
    #expect(QuickMetadataEditorNavigation.nextCollection(in: ids, currentID: first, offset: 1) == second)
    #expect(QuickMetadataEditorNavigation.nextCollection(in: ids, currentID: third, offset: 1) == third)
    #expect(QuickMetadataEditorNavigation.nextCollection(in: ids, currentID: second, offset: -1) == first)

    let selected = QuickMetadataEditorNavigation.toggled(second, in: [first])
    #expect(selected == [first, second])
    #expect(QuickMetadataEditorNavigation.toggled(first, in: selected) == [second])
}

@Test func metadataEditorRoutesKeyboardCommandsByFocusedArea() {
    func action(
        _ keyCode: UInt16,
        field: QuickMetadataEditorField,
        command: Bool = false,
        shift: Bool = false,
        hasMarkedText: Bool = false
    ) -> QuickMetadataEditorKeyboardAction {
        QuickMetadataEditorNavigation.keyboardAction(
            keyCode: keyCode,
            command: command,
            shift: shift,
            option: false,
            control: false,
            focusedField: field,
            hasMarkedText: hasMarkedText
        )
    }

    #expect(action(48, field: .title) == .moveFocus(backwards: false))
    #expect(action(48, field: .note, shift: true) == .moveFocus(backwards: true))
    #expect(action(125, field: .collections) == .moveCollection(offset: 1))
    #expect(action(126, field: .collections) == .moveCollection(offset: -1))
    #expect(action(49, field: .collections) == .toggleCollection)
    #expect(action(125, field: .note) == .passThrough)
    #expect(action(36, field: .note) == .commit)
    #expect(action(36, field: .note, hasMarkedText: true) == .passThrough)
    #expect(action(53, field: .collections) == .dismiss)
    #expect(action(13, field: .title, command: true) == .dismiss)
}

@Test @MainActor func metadataEditorDismissClearsTheOwningClip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryMetadataEditorState-\(UUID().uuidString)")
    let directories = try AppDirectories(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let suiteName = "PasteoryMetadataEditorState.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults, logsDirectory: directories.logs)
    let state = AppState(
        repository: repository,
        attachments: AttachmentStore(directories: directories),
        archive: ArchiveService(repository: repository, directories: directories),
        backup: BackupService(repository: repository, directories: directories),
        storageAnalyticsService: StorageAnalyticsService(repository: repository, directories: directories),
        settings: settings,
        linkResolutionService: LinkResolutionService(repository: repository)
    )
    let firstClipID = UUID()
    let secondClipID = UUID()

    state.presentQuickMetadataEditor(for: firstClipID, initialField: .title)
    #expect(state.quickSelectionID == firstClipID)
    #expect(state.quickMetadataEditorClipID == firstClipID)
    state.dismissQuickMetadataEditor()
    #expect(state.quickMetadataEditorClipID == nil)

    state.presentQuickMetadataEditor(for: secondClipID, initialField: .collections)
    #expect(state.quickSelectionID == secondClipID)
    #expect(state.quickMetadataEditorClipID == secondClipID)
    #expect(state.quickMetadataEditorInitialField == .collections)
}
