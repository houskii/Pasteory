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

@Test @MainActor func groupProfilesRestoreSearchSelectionAndScrollAnchorsWithoutAIRequests() async throws {
    try await withSearchState { state, repository in
        let a = try searchClip("alpha", timestamp: 300), b = try searchClip("beta", timestamp: 200)
        try await repository.saveBatch([a, b]); await state.refreshQuick(); await state.refreshLibrary()
        state.quickSelectionID = b.id; state.selectedClipID = b.id
        state.quickScrollAnchor = .clip(b.id); state.libraryScrollAnchor = .clip(b.id)
        state.switchGroupView(.ai); await state.waitForGroupView()
        state.quickScope = .ungrouped; state.libraryFilter = .ungrouped
        await state.refreshQuick(); await state.refreshLibrary()
        state.quickSelectionID = a.id; state.quickScrollAnchor = .clip(a.id)
        state.switchGroupView(.common); await state.waitForGroupView()
        #expect(state.quickScope == .all && state.libraryFilter == .all)
        #expect(state.quickSelectionID == b.id && state.selectedClipID == b.id)
        #expect(state.quickScrollAnchor == .clip(b.id) && state.libraryScrollAnchor == .clip(b.id))
        state.switchGroupView(.ai); await state.waitForGroupView()
        #expect(state.quickScope == .ungrouped && state.libraryFilter == .ungrouped)
        #expect(state.quickSelectionID == a.id && state.quickScrollAnchor == .clip(a.id))
        #expect(try await repository.aiState().usage.isEmpty)
    }
}

@Test @MainActor func commonViewShowsThreeAIRecommendationsAndKeepsManualGroupsSeparate() async throws {
    try await withSearchState { state, repository in
        let clips = try (0..<8).map { try searchClip("Topic source \($0)", timestamp: Double(100 + $0)) }
        try await repository.saveBatch(clips)
        for (index, clip) in clips.enumerated() {
            let id = UUID(); var draft = AIChangeSet(); draft.clipRevisions[clip.id] = clip.aiRevision
            draft.commands = [.init(kind: .createGroup, targetID: id, name: "Topic \(index)", definition: "Definition \(index)"), .init(kind: .addItems, targetID: id, clipIDs: [clip.id])]
            try await repository.applyAIChangeSet(draft)
        }
        let manual = ClipCollection(name: "Manual", kind: .normal, sortOrder: 9)
        try await repository.saveCollection(manual)
        await state.refreshCollections(); try await state.intelligence.reload(); state.intelligence.refreshRecommendations()
        #expect(state.recommendedAICollections.count == 3)
        #expect(state.quickTabs.count == 5)
        #expect(state.quickTabs.contains { $0.scope == .collection(manual.id) })
        state.switchGroupView(.ai); await state.waitForGroupView()
        #expect(state.quickTabs.count == 9)
        #expect(!state.quickTabs.contains { $0.scope == .collection(manual.id) })
        #expect(await state.navigateGroup(.profile(.minimal), quick: true))
        #expect(state.quickTabs.map(\.scope) == [.all])
        #expect(state.settings.groupSidebarWidth == 0)
    }
}

@Test @MainActor func backgroundOrganizationDefersRemovingAnUngroupedItemBeingRead() async throws {
    try await withSearchState { state, repository in
        let clip = try searchClip("A synthetic item being read", timestamp: 200)
        try await repository.save(clip)
        state.quickScope = .ungrouped; state.libraryFilter = .ungrouped
        await state.refreshQuick(); await state.refreshLibrary()
        state.quickSelectionID = clip.id; state.selectedClipID = clip.id
        let id = UUID(); var draft = AIChangeSet(); draft.clipRevisions[clip.id] = clip.aiRevision
        draft.commands = [.init(kind: .createGroup, targetID: id, name: "Reading", definition: "Synthetic source"), .init(kind: .addItems, targetID: id, clipIDs: [clip.id])]
        try await repository.applyAIChangeSet(draft)
        await state.organizationApplied(automatically: true)
        #expect(state.quickSelectionID == clip.id && state.selectedClipID == clip.id)
        #expect(state.quickClips.map(\.id) == [clip.id] && state.clips.map(\.id) == [clip.id])
        #expect(state.organizationResultsWaiting)
        await state.showOrganizationResults()
        #expect(state.quickClips.isEmpty && state.clips.isEmpty)
        #expect(!state.organizationResultsWaiting)
    }
}

@Test @MainActor func ungroupedFilterDoesNotConsumeGroupNavigationPositions() async throws {
    try await withSearchState { state, repository in
        var first = try searchClip("First group source", timestamp: 300)
        var second = try searchClip("Second group source", timestamp: 200)
        let ungrouped = try searchClip("Ungrouped source", timestamp: 100)
        try await repository.saveBatch([first, second, ungrouped])
        let a = ClipCollection(name: "First", kind: .normal, sortOrder: 0)
        let b = ClipCollection(name: "Second", kind: .normal, sortOrder: 1)
        try await repository.saveCollection(a); try await repository.saveCollection(b)
        first.collectionIDs = [a.id]; second.collectionIDs = [b.id]
        try await repository.save(first); try await repository.save(second)
        await state.refreshCollections(); await state.refreshQuick()
        #expect(state.quickTabs.map(\.scope) == [.all, .collection(a.id), .collection(b.id)])
        await state.moveQuickScope(by: 1)
        #expect(state.quickScope == .collection(a.id))
        #expect(state.quickClips.map(\.id) == [first.id])
        await state.moveQuickScope(by: 1)
        #expect(state.quickScope == .collection(b.id))
        await state.moveQuickScope(by: 1)
        #expect(state.quickScope == .all)
        state.quickScope = .ungrouped; await state.refreshQuick()
        #expect(state.quickClips.count == 3) // Manual membership does not assign an AI theme.
        #expect(await state.navigateGroup(.group2, quick: true))
        #expect(state.quickScope == .collection(b.id))
        #expect(state.quickClips.map(\.id) == [second.id])
        #expect(!(await state.navigateGroup(.group9, quick: true)))
        #expect(state.quickScope == .collection(b.id))
        #expect(await state.navigateGroup(.group1, quick: false))
        #expect(state.libraryFilter == .collection(a.id))
        #expect(state.clips.map(\.id) == [first.id])
        #expect(await state.navigateGroup(.allContent, quick: true))
        #expect(state.quickClips.count == 3)
        #expect(state.settings.groupPresentation.profile == .common)
        state.switchGroupView(.minimal); await state.waitForGroupView()
        #expect(state.settings.groupPresentation.profile == .minimal)
        #expect(!(await state.navigateGroup(.group1, quick: true)))
        #expect(try await repository.aiState().usage.isEmpty)
    }
}

@Test @MainActor func groupNewContentBadgeTracksAddedMembersAndSurvivesReload() async throws {
    try await withSearchState { state, repository in
        let a = try searchClip("Previously grouped material", timestamp: 300)
        let b = try searchClip("Newly grouped material", timestamp: 200)
        try await repository.saveBatch([a, b])
        let id = UUID()
        var draft = AIChangeSet(); draft.clipRevisions[a.id] = a.aiRevision
        draft.commands = [.init(kind: .createGroup, targetID: id, name: "Updates", definition: "Synthetic group"),
                          .init(kind: .addItems, targetID: id, clipIDs: [a.id])]
        try await repository.applyAIChangeSet(draft)
        try await state.intelligence.reload()
        #expect(state.intelligence.newGroupContentCount(id) == 0) // Historical content starts as seen.
        #expect(try await repository.aiState().automation.viewedGroupMembers?[id] == [a.id])
        var addition = AIChangeSet(); addition.clipRevisions[b.id] = b.aiRevision
        addition.groupRevisions[id] = try #require(state.intelligence.state.groups[id]).revision
        addition.commands = [.init(kind: .addItems, targetID: id, clipIDs: [b.id])]
        try await repository.applyAIChangeSet(addition)
        try await state.intelligence.reload()
        #expect(state.intelligence.newGroupContentCount(id) == 1)
        try await repository.updateAIState { $0.groups[id]?.overview = "An overview update is not a new member." }
        try await state.intelligence.reload()
        #expect(state.intelligence.newGroupContentCount(id) == 1)
        state.intelligence.groupOpened(id); await state.intelligence.waitUntilIdle()
        try await state.intelligence.reload()
        #expect(state.intelligence.newGroupContentCount(id) == 0)
        #expect(try await repository.aiState().automation.viewedGroupMembers?[id] == [a.id, b.id])
        #expect(try await repository.clip(id: a.id)?.lastUsedAt == a.lastUsedAt)
        #expect(try await repository.clip(id: b.id)?.lastUsedAt == b.lastUsedAt)
        #expect(try await repository.aiState().usage.isEmpty)
    }
}

@Test @MainActor func switchingSidebarSidePreservesContentNavigationAndGroupOrder() async throws {
    try await withSearchState { state, repository in
        let clip = try searchClip("Sidebar positioning sample", timestamp: 300)
        try await repository.save(clip); await state.refreshQuick(); await state.refreshLibrary()
        state.quickQuery = "positioning"; state.libraryQuery = "sample"
        state.quickSelectionID = clip.id; state.selectedClipID = clip.id
        state.quickScrollAnchor = .clip(clip.id); state.libraryScrollAnchor = .clip(clip.id)
        let scopes = state.quickTabs.map(\.scope)
        for position in [QuickTabLayout.right, .left] {
            state.settings.quickTabLayout = position
            #expect(state.settings.groupSidebarWidth == 224)
            #expect(state.quickQuery == "positioning" && state.libraryQuery == "sample")
            #expect(state.quickSelectionID == clip.id && state.selectedClipID == clip.id)
            #expect(state.quickScrollAnchor == .clip(clip.id) && state.libraryScrollAnchor == .clip(clip.id))
            #expect(state.quickTabs.map(\.scope) == scopes)
        }
        state.settings.groupPresentation.profile = .minimal
        #expect(state.settings.groupSidebarWidth == 0)
        #expect(try await repository.aiState().usage.isEmpty)
    }
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
