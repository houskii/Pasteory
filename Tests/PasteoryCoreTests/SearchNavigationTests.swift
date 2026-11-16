import Foundation
import Combine
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

@Test @MainActor func clearingTheCurrentAIGroupReturnsBothViewsToAValidScope() async throws {
    try await withSearchState { state, repository in
        let clip = try searchClip("Selected group cleanup", timestamp: 300); try await repository.save(clip)
        let id = UUID(); var draft = AIChangeSet(); draft.clipRevisions[clip.id] = clip.aiRevision
        draft.commands = [.init(kind: .createGroup, targetID: id, name: "Selected", definition: "Visible prompt"), .init(kind: .addItems, targetID: id, clipIDs: [clip.id])]
        try await repository.applyAIChangeSet(draft)
        await state.refreshCollections(); try await state.intelligence.reload()
        state.switchGroupView(.ai); await state.waitForGroupView()
        state.quickScope = .collection(id); state.libraryFilter = .collection(id)
        await state.refreshQuick(); await state.refreshLibrary()
        state.switchGroupView(.common); await state.waitForGroupView()
        state.quickScope = .collection(id); state.libraryFilter = .collection(id)
        let selection = AIGroupSelection(groups: [try #require(state.intelligence.state.groups[id])])
        #expect(await state.intelligence.cleanupGroups(selection))
        await state.organizationApplied(automatically: false)
        #expect(state.quickScope == .all && state.libraryFilter == .all)
        #expect(state.quickClips.map(\.id) == [clip.id] && state.clips.map(\.id) == [clip.id])
        state.switchGroupView(.ai); await state.waitForGroupView()
        #expect(state.quickScope == .all && state.libraryFilter == .all)
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

@Test @MainActor func listsLoadOneHundredThenAppendWithoutResettingSelectionAndSearchTheWholeLibrary() async throws {
    try await withSearchState { state, repository in
        var clips = try (0..<241).map { try searchClip("Paging commonneedle sample \($0)", timestamp: Double(1000 + $0)) }
        clips[0].title = "commonneedle"
        try await repository.saveBatch(clips)
        await state.refreshQuick(); await state.refreshLibrary()
        #expect(state.quickClips.count == 100 && state.clips.count == 100)
        #expect(state.quickHasMore && state.libraryHasMore)
        state.quickSelectionID = state.quickClips[50].id; state.selectedClipID = state.clips[50].id
        let quickSelection = state.quickSelectionID, librarySelection = state.selectedClipID
        let quickReset = state.quickListResetID, libraryReset = state.libraryListResetID
        await state.loadMoreQuick(); await state.loadMoreLibrary()
        #expect(state.quickClips.count == 200 && state.clips.count == 200)
        await state.loadMoreQuick(); await state.loadMoreLibrary()
        #expect(state.quickClips.count == 241 && state.clips.count == 241)
        #expect(Set(state.quickClips.map(\.id)).count == 241)
        #expect(Set(state.clips.map(\.id)).count == 241)
        #expect(!state.quickHasMore && !state.libraryHasMore)
        #expect(state.quickSelectionID == quickSelection && state.selectedClipID == librarySelection)
        #expect(state.quickListResetID == quickReset && state.libraryListResetID == libraryReset)
        state.quickQuery = "commonneedle"; state.libraryQuery = "commonneedle"
        await state.refreshQuick(); await state.refreshLibrary()
        #expect(state.quickClips.count == 100 && state.clips.count == 100)
        #expect(state.quickClips.first?.id == clips[0].id && state.clips.first?.id == clips[0].id)
        #expect(state.quickSelectionID == state.quickNumberedClips.first?.id)
        #expect(state.selectedClipID == state.libraryListEntries.first.flatMap { entry -> UUID? in
            if case .clip(let clip, _) = entry.content { return clip.id }; return nil
        })
        await state.loadMoreQuick(); await state.loadMoreLibrary()
        #expect(state.quickClips.count == 200 && state.clips.count == 200)
        state.quickQuery = "sample 1"; await state.refreshQuick()
        #expect(state.quickClips.count == 100 && state.quickHasMore)
        await state.loadMoreQuick()
        #expect(state.quickClips.count == 111 && !state.quickHasMore)
    }
}

@Test @MainActor func smartGroupPaginationEvaluatesOlderCandidatesBeforeSlicingResults() async throws {
    try await withSearchState { state, repository in
        let clips = try (0..<230).map { try searchClip($0 < 120 ? "needle older \($0)" : "recent other \($0)", timestamp: Double(1000 + $0)) }
        try await repository.saveBatch(clips)
        let rules = SmartRuleSet(mode: .all, conditions: [SmartCondition(field: .body, operation: .contains, value: "needle")])
        let collection = ClipCollection(name: "Older matches", kind: .smart, sortOrder: 0, ruleSet: rules)
        try await repository.saveCollection(collection); await state.refreshCollections()
        state.quickScope = .collection(collection.id); state.libraryFilter = .collection(collection.id)
        await state.refreshQuick(); await state.refreshLibrary()
        #expect(state.quickClips.count == 100 && state.clips.count == 100)
        #expect(state.quickClips.allSatisfy { $0.previewText.contains("needle") })
        await state.loadMoreQuick(); await state.loadMoreLibrary()
        #expect(state.quickClips.count == 120 && state.clips.count == 120)
        #expect(!state.quickHasMore && !state.libraryHasMore)
    }
}

@Test @MainActor func groupProfilesRestoreSelectionsBeyondTheFirstPage() async throws {
    try await withSearchState { state, repository in
        let clips = try (0..<220).map { try searchClip("Profile paging \($0)", timestamp: Double(1000 + $0)) }
        try await repository.saveBatch(clips); await state.refreshQuick(); await state.refreshLibrary()
        await state.loadMoreQuick(); await state.loadMoreLibrary()
        let selected = state.quickClips[170].id
        state.quickSelectionID = selected; state.selectedClipID = selected
        state.quickScrollAnchor = .clip(selected); state.libraryScrollAnchor = .clip(selected)
        state.switchGroupView(.ai); await state.waitForGroupView()
        state.quickScope = .ungrouped; state.libraryFilter = .ungrouped
        await state.refreshQuick(); await state.refreshLibrary()
        #expect(state.quickClips.count == 100)
        state.switchGroupView(.common); await state.waitForGroupView()
        #expect(state.quickClips.count == 200 && state.clips.count == 200)
        #expect(state.quickSelectionID == selected && state.selectedClipID == selected)
        #expect(state.quickScrollAnchor == .clip(selected) && state.libraryScrollAnchor == .clip(selected))
    }
}

@Test @MainActor func panelPreparationResetsTheFirstPageBeforePresentationAndScrollTrackingDoesNotRedrawCards() async throws {
    try await withSearchState { state, repository in
        let clips = try (0..<220).map { try searchClip("Opening panel \($0)", timestamp: Double(1000 + $0)) }
        try await repository.saveBatch(clips); await state.refreshQuick(); await state.loadMoreQuick()
        state.quickSelectionID = state.quickClips[170].id
        var invalidations = 0
        let observation = state.objectWillChange.sink { invalidations += 1 }
        state.quickScrollAnchor = .clip(clips[0].id); state.libraryScrollAnchor = .clip(clips[1].id)
        #expect(invalidations == 0)
        observation.cancel()
        let presentation = state.quickPresentationID
        await state.prepareQuickPanel()
        #expect(state.quickClips.count == 100 && state.quickHasMore)
        #expect(state.quickSelectionID == clips.last?.id)
        #expect(state.quickScrollAnchor == nil && state.quickPresentationID != presentation)
        state.quickQuery = "Opening panel 219"; await state.refreshQuick()
        let capture = PasteboardCapture(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data("A new unrelated copy".utf8))])],
                                       source: .init(appName: "Tests", confidence: .high))
        await state.accept(capture)
        #expect(state.quickClips.count == 1 && state.quickClips.first?.id == clips.last?.id)
        state.quickQuery = ""; await state.prepareQuickPanel()
        #expect(state.quickClips.count == 100)
        #expect(state.quickSelectedClip?.previewText == "A new unrelated copy")
    }
}

@Test @MainActor func restoringAnEmptyProfileStillLoadsTheFirstPageAfterContentIsAdded() async throws {
    try await withSearchState { state, repository in
        await state.refreshQuick(); await state.refreshLibrary()
        state.switchGroupView(.ai); await state.waitForGroupView()
        state.quickScope = .favorite; state.libraryFilter = .favorite
        await state.refreshQuick(); await state.refreshLibrary()
        let clip = try searchClip("Added while an empty group was selected", timestamp: 1000)
        try await repository.save(clip)
        state.switchGroupView(.common); await state.waitForGroupView()
        #expect(state.quickClips.map(\.id) == [clip.id] && state.clips.map(\.id) == [clip.id])
        #expect(!state.quickHasMore && !state.libraryHasMore)
    }
}

@Test @MainActor func openingAnUnchangedPreparedPanelDoesNotPublishOrReloadMetadata() async throws {
    try await withSearchState { state, repository in
        let clip = try searchClip("Ready before opening", timestamp: 1000)
        try await repository.save(clip); await state.refreshQuick()
        let reset = state.quickListResetID, presentation = state.quickPresentationID
        var invalidations = 0
        let observation = state.objectWillChange.sink { invalidations += 1 }; defer { observation.cancel() }
        await state.prepareQuickPanel(); await state.prepareQuickPanel()
        #expect(invalidations == 0)
        #expect(state.quickListResetID == reset && state.quickPresentationID == presentation)
        #expect(state.quickSelectionID == clip.id)
    }
}

@Test @MainActor func capturedContentReachesTheMemoryListBeforeABusyDatabaseAndReconcilesItsIdentity() async throws {
    try await withSearchState { state, repository in
        let text = "A copied item already stored outside the initial page"
        var original = try searchClip(text, timestamp: 1000)
        original.title = "Saved title"; original.note = "Human note"
        try await repository.save(original)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached {
            try await repository.updateAIState { _ in entered.signal(); release.wait() }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { entered.wait(); continuation.resume() }
        }
        defer { release.signal() }
        state.setQuickCapturePending(true)
        let capture = PasteboardCapture(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data(text.utf8))])],
                                       source: .init(appName: "Tests", confidence: .high))
        let acceptance = Task { await state.accept(capture) }
        for _ in 0..<300 {
            if state.quickClips.first?.previewText == text { break }
            try await Task.sleep(for: .milliseconds(3))
        }
        let display = state.quickClips.first
        #expect(display?.previewText == text)
        #expect(!state.quickCapturePending)
        release.signal(); try await blocker.value; await acceptance.value
        #expect(state.quickClips.first?.id == original.id)
        #expect(state.quickClips.first?.title == "Saved title" && state.quickClips.first?.note == "Human note")
        if let display { #expect(await state.recordPaste(display)) }
        let stored = try #require(await repository.clip(id: original.id))
        #expect(stored.copyCount == 2 && stored.recordedPasteCount == 1)
        #expect(try await repository.activeClipCount() == 1)
    }
}
