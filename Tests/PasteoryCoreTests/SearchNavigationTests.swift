import Foundation
import PasteoryCore
import PasteoryAI
import Testing
@testable import Pasteory

@MainActor
private func withSearchState(
    _ body: @MainActor (AppState, SQLiteClipRepository) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PasteorySearchNavigation-\(UUID().uuidString)", isDirectory: true)
    let directories = try AppDirectories(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let suiteName = "PasteorySearchNavigation.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        repository: repository,
        attachments: AttachmentStore(directories: directories),
        archive: ArchiveService(repository: repository, directories: directories),
        backup: BackupService(repository: repository, directories: directories),
        storageAnalyticsService: StorageAnalyticsService(repository: repository, directories: directories),
        settings: AppSettings(defaults: defaults, logsDirectory: directories.logs),
        linkResolutionService: LinkResolutionService(repository: repository)
    )
    try await body(state, repository)
}

private func searchClip(_ text: String, timestamp: TimeInterval) throws -> Clip {
    try #require(ClipClassifier.makeClip(from: PasteboardCapture(
        items: [CapturedItem(order: 0, representations: [
            CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))
        ])],
        source: ClipSource(appName: "Search Tests", bundleIdentifier: "test.search", confidence: .high),
        capturedAt: Date(timeIntervalSince1970: timestamp)
    )))
}

@Test @MainActor func startupWithoutMaintenanceLoadsPersistedAIGroups() async throws {
    try await withSearchState { state, repository in
        let clip = try searchClip("Saved AI topic member", timestamp: 200)
        try await repository.saveBatch([clip])
        let groupID = UUID()
        var draft = AIChangeSet()
        draft.clipRevisions = [clip.id: clip.aiRevision]
        draft.commands = [
            AICommand(kind: .createGroup, targetID: groupID, name: "Saved topic", definition: "A persisted topic"),
            AICommand(kind: .addItems, targetID: groupID, clipIDs: [clip.id])
        ]
        try await repository.applyAIChangeSet(draft)

        await state.bootstrap(processExistingClips: false)

        #expect(state.intelligence.state.groups[groupID]?.memberIDs == [clip.id])
        #expect(state.intelligence.clipIndex[clip.id]?.collectionIDs == [groupID])
        #expect(state.intelligence.state.usage.isEmpty)
        #expect(!state.intelligence.running)
        #expect(try await repository.clip(id: clip.id)?.isArchived == false)
    }
}

@Test @MainActor func quickSearchSelectsFirstVisibleResultWhenPreviousSelectionStillMatches() async throws {
    try await withSearchState { state, repository in
        let newer = try searchClip("needle newer", timestamp: 200)
        let older = try searchClip("needle older", timestamp: 100)
        try await repository.saveBatch([newer, older])
        await state.refreshQuick()
        state.quickSelectionID = older.id

        state.quickQuery = "needle"
        await state.refreshQuick(debounce: true)

        #expect(state.quickListEntries.first?.id == .clip(newer.id))
        #expect(state.quickSelectionID == newer.id)
        #expect(state.quickSelectedAggregationID == nil)
    }
}

@Test @MainActor func quickSearchUsesDisplayedOrderInsteadOfRawSearchRank() async throws {
    try await withSearchState { state, repository in
        let exact = try searchClip("needle", timestamp: 100)
        let newer = try searchClip("needle newer", timestamp: 200)
        let unrelated = try searchClip("unrelated", timestamp: 300)
        try await repository.saveBatch([exact, newer, unrelated])
        await state.refreshQuick()

        state.quickQuery = "needle"
        await state.refreshQuick()

        #expect(state.quickClips.first?.id == exact.id)
        #expect(state.quickListEntries.first?.id == .clip(newer.id))
        #expect(state.quickSelectionID == newer.id)
    }
}

@Test(arguments: [false, true])
@MainActor func quickSearchSelectsTopAggregationInsteadOfMatchingChild(resetSelection: Bool) async throws {
    try await withSearchState { state, repository in
        let first = try searchClip("needle first", timestamp: 100)
        let second = try searchClip("needle second", timestamp: 200)
        try await repository.saveBatch([first, second])
        let aggregation = try await repository.saveAggregation(ClipAggregation(
            title: "Needle collection",
            isPinned: true,
            memberClipIDs: [first.id, second.id]
        ))
        await state.refreshAggregations()
        await state.refreshQuick()
        state.quickSelectedAggregationID = nil
        state.quickSelectionID = second.id

        state.quickQuery = "needle"
        await state.refreshQuick(resetSelection: resetSelection)

        #expect(state.quickListEntries.first?.id == .aggregation(aggregation.id))
        #expect(state.quickSelectedAggregationID == aggregation.id)
        #expect(state.quickSelectionID == nil)
    }
}

@Test @MainActor func quickSearchClearsSelectionWhenNothingMatches() async throws {
    try await withSearchState { state, repository in
        let first = try searchClip("history first", timestamp: 100)
        let second = try searchClip("history second", timestamp: 200)
        try await repository.saveBatch([first, second])
        let aggregation = try await repository.saveAggregation(ClipAggregation(
            title: "History collection",
            memberClipIDs: [first.id, second.id]
        ))
        await state.refreshAggregations()
        await state.refreshQuick()
        state.quickSelectedAggregationID = aggregation.id
        state.quickSelectionID = nil

        state.quickQuery = "missing"
        await state.refreshQuick()

        #expect(state.quickListEntries.isEmpty)
        #expect(state.quickSelectionID == nil)
        #expect(state.quickSelectedAggregationID == nil)
    }
}

@Test @MainActor func quickSearchRefinementAndClearingSelectFirstVisibleEntry() async throws {
    try await withSearchState { state, repository in
        let newer = try searchClip("needle newer", timestamp: 300)
        let partial = try searchClip("need partial", timestamp: 200)
        let older = try searchClip("needle older", timestamp: 100)
        try await repository.saveBatch([newer, partial, older])
        state.quickQuery = "need"
        await state.refreshQuick()
        state.quickSelectionID = older.id

        state.quickQuery = "needle"
        await state.refreshQuick()
        #expect(state.quickSelectionID == newer.id)

        state.quickSelectionID = older.id
        state.quickQuery = ""
        await state.refreshQuick()
        #expect(state.quickSelectionID == newer.id)
    }
}

@Test @MainActor func quickBackgroundRefreshPreservesCurrentSelection() async throws {
    try await withSearchState { state, repository in
        let newer = try searchClip("needle newer", timestamp: 200)
        let older = try searchClip("needle older", timestamp: 100)
        try await repository.saveBatch([newer, older])
        state.quickQuery = "needle"
        await state.refreshQuick()
        state.quickSelectionID = older.id
        let resetID = state.quickListResetID

        await state.refreshQuick()

        #expect(state.quickSelectionID == older.id)
        #expect(state.quickListResetID == resetID)
    }
}

@Test @MainActor func quickSearchRequestsTopEvenWhenFirstSelectionDoesNotChange() async throws {
    try await withSearchState { state, repository in
        let first = try searchClip("needle first", timestamp: 200)
        let second = try searchClip("needle second", timestamp: 100)
        try await repository.saveBatch([first, second])
        await state.refreshQuick()
        #expect(state.quickSelectionID == first.id)
        let resetID = state.quickListResetID

        state.quickQuery = "needle"
        await state.refreshQuick()

        #expect(state.quickSelectionID == first.id)
        #expect(state.quickListResetID != resetID)
    }
}

@Test @MainActor func quickSearchStillResetsWhenBackgroundRefreshCancelsDebounce() async throws {
    try await withSearchState { state, repository in
        let newer = try searchClip("needle newer", timestamp: 200)
        let older = try searchClip("needle older", timestamp: 100)
        try await repository.saveBatch([newer, older])
        await state.refreshQuick()
        state.quickSelectionID = older.id
        state.quickQuery = "needle"
        let search = Task { await state.refreshQuick(debounce: true) }
        try await Task.sleep(for: .milliseconds(20))

        await state.refreshQuick()
        await search.value

        #expect(state.quickSelectionID == newer.id)
    }
}

@Test @MainActor func librarySearchResetsSelectionButBackgroundRefreshPreservesIt() async throws {
    try await withSearchState { state, repository in
        let newer = try searchClip("needle newer", timestamp: 200)
        let older = try searchClip("needle older", timestamp: 100)
        try await repository.saveBatch([newer, older])
        await state.refreshLibrary()
        state.selectedClipID = older.id
        let initialResetID = state.libraryListResetID

        state.libraryQuery = "needle"
        await state.refreshLibrary()
        #expect(state.selectedClipID == newer.id)
        #expect(state.libraryListResetID != initialResetID)

        state.selectedClipID = older.id
        let searchResetID = state.libraryListResetID
        await state.refreshLibrary()
        #expect(state.selectedClipID == older.id)
        #expect(state.libraryListResetID == searchResetID)

        state.libraryQuery = ""
        await state.refreshLibrary()
        #expect(state.selectedClipID == newer.id)
        #expect(state.libraryListResetID != searchResetID)
    }
}

@Test @MainActor func librarySearchSelectsTitleOnlyAggregationWithoutMatchingClips() async throws {
    try await withSearchState { state, repository in
        let first = try searchClip("history first", timestamp: 100)
        let second = try searchClip("history second", timestamp: 200)
        let unrelated = try searchClip("unrelated", timestamp: 300)
        try await repository.saveBatch([first, second, unrelated])
        let aggregation = try await repository.saveAggregation(ClipAggregation(
            title: "Needle collection",
            memberClipIDs: [first.id, second.id]
        ))
        await state.refreshAggregations()
        await state.refreshLibrary()
        state.selectedAggregationID = nil
        state.selectedClipID = unrelated.id

        state.libraryQuery = "needle"
        await state.refreshLibrary()

        #expect(state.clips.isEmpty)
        #expect(state.libraryListEntries.first?.id == .aggregation(aggregation.id))
        #expect(state.selectedAggregationID == aggregation.id)
        #expect(state.selectedClipID == nil)
    }
}
