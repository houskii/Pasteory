import AppKit
import PasteoryCore

struct AggregationDraft: Identifiable, Equatable {
    let id = UUID()
    var aggregationID: UUID?
    var memberClipIDs: [UUID]
    var title: String
    var note: String
    var origin: AggregationOrigin

    var isEditing: Bool { aggregationID != nil }
}

enum AggregationListEntryID: Hashable {
    case aggregation(UUID)
    case clip(UUID)
    case member(aggregationID: UUID, clipID: UUID)
}

struct AggregationListEntry: Identifiable {
    enum Content {
        case aggregation(ClipAggregation)
        case clip(Clip, parentAggregationID: UUID?)
    }

    let content: Content
    let isFirstChild: Bool
    let isLastChild: Bool

    init(content: Content, isFirstChild: Bool = false, isLastChild: Bool = false) {
        self.content = content
        self.isFirstChild = isFirstChild
        self.isLastChild = isLastChild
    }

    var id: AggregationListEntryID {
        switch content {
        case .aggregation(let aggregation): .aggregation(aggregation.id)
        case .clip(let clip, let parentID):
            if let parentID { .member(aggregationID: parentID, clipID: clip.id) }
            else { .clip(clip.id) }
        }
    }
}

extension AppState {
    var quickListEntries: [AggregationListEntry] {
        aggregationEntries(
            clips: quickClips,
            query: quickQuery,
            expanded: quickExpandedAggregationIDs,
            parentInScope: quickAggregationIsInOwnScope,
            showAllMembersForParent: quickAggregationShowsAllMembers
        )
    }

    var libraryListEntries: [AggregationListEntry] {
        aggregationEntries(
            clips: clips,
            query: libraryQuery,
            expanded: libraryExpandedAggregationIDs,
            parentInScope: libraryAggregationIsInOwnScope,
            showAllMembersForParent: libraryAggregationShowsAllMembers
        )
    }

    var quickNumberedClips: [Clip] {
        quickListEntries.compactMap { entry in
            guard case .clip(let clip, nil) = entry.content else { return nil }
            return clip
        }
    }

    var quickAggregationEditorActive: Bool { quickAggregationDraft != nil }

    var quickTopLevelResultCount: Int {
        quickListEntries.reduce(into: 0) { count, entry in
            switch entry.content {
            case .aggregation: count += 1
            case .clip(_, let parentID) where parentID == nil: count += 1
            case .clip: break
            }
        }
    }

    var libraryTopLevelResultCount: Int {
        libraryListEntries.reduce(into: 0) { count, entry in
            switch entry.content {
            case .aggregation: count += 1
            case .clip(_, let parentID) where parentID == nil: count += 1
            case .clip: break
            }
        }
    }

    var quickCanAggregateCurrentResults: Bool {
        aggregationCandidateCount(clips: quickClips, query: quickQuery) >= 2
    }

    var libraryCanAggregateCurrentResults: Bool {
        aggregationCandidateCount(clips: clips, query: libraryQuery) >= 2
    }

    func refreshAggregations() async {
        do {
            let loaded = try await repository.aggregations()
            let memberIDs = loaded.flatMap(\.memberClipIDs)
            let all = try await repository.clips(ids: memberIDs).filter { $0.deletedAt == nil }
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            aggregations = loaded
            aggregationMembers = Dictionary(uniqueKeysWithValues: loaded.map { aggregation in
                (aggregation.id, aggregation.memberClipIDs.compactMap { byID[$0] })
            })
            let validIDs = Set(loaded.map(\.id))
            quickExpandedAggregationIDs.formIntersection(validIDs)
            libraryExpandedAggregationIDs.formIntersection(validIDs)
            if let id = quickSelectedAggregationID, !validIDs.contains(id) { quickSelectedAggregationID = nil }
            if let id = selectedAggregationID, !validIDs.contains(id) { selectedAggregationID = nil }
        } catch { show(error) }
    }

    func selectQuickEntry(_ entry: AggregationListEntry) {
        switch entry.content {
        case .aggregation(let aggregation):
            quickSelectedAggregationID = aggregation.id
            quickSelectionID = nil
        case .clip(let clip, let parentID):
            quickSelectedAggregationID = nil
            quickSelectionID = clip.id
            if let parentID { quickLastSelectedChildIDs[parentID] = clip.id }
        }
    }

    func selectLibraryEntry(_ entry: AggregationListEntry) {
        switch entry.content {
        case .aggregation(let aggregation):
            selectedAggregationID = aggregation.id
            selectedClipID = nil
        case .clip(let clip, let parentID):
            selectedAggregationID = nil
            selectedClipID = clip.id
            if let parentID { libraryLastSelectedChildIDs[parentID] = clip.id }
        }
    }

    func toggleQuickAggregation(_ id: UUID, selectChild: Bool = false) {
        if quickExpandedAggregationIDs.contains(id), !selectChild {
            quickExpandedAggregationIDs.remove(id)
            quickSelectedAggregationID = id
            quickSelectionID = nil
            return
        }
        quickExpandedAggregationIDs.insert(id)
        guard selectChild else { return }
        let members = aggregationMembers[id] ?? []
        let preferred = quickLastSelectedChildIDs[id].flatMap { selected in members.first { $0.id == selected } }
        if let clip = preferred ?? members.first {
            quickSelectedAggregationID = nil
            quickSelectionID = clip.id
            quickLastSelectedChildIDs[id] = clip.id
        }
    }

    func toggleLibraryAggregation(_ id: UUID, selectChild: Bool = false) {
        if libraryExpandedAggregationIDs.contains(id), !selectChild {
            libraryExpandedAggregationIDs.remove(id)
            selectedAggregationID = id
            selectedClipID = nil
            return
        }
        libraryExpandedAggregationIDs.insert(id)
        guard selectChild else { return }
        let visibleMembers = libraryListEntries.compactMap { entry -> Clip? in
            guard case .clip(let clip, let parentID) = entry.content, parentID == id else { return nil }
            return clip
        }
        let preferred = libraryLastSelectedChildIDs[id].flatMap { selected in visibleMembers.first { $0.id == selected } }
        if let clip = preferred ?? visibleMembers.first {
            selectedAggregationID = nil
            selectedClipID = clip.id
            libraryLastSelectedChildIDs[id] = clip.id
        }
    }

    func expandSelectedQuickAggregation() {
        guard let aggregation = quickSelectedAggregation else { return }
        toggleQuickAggregation(aggregation.id, selectChild: true)
    }

    func collapseSelectedQuickAggregation() {
        if let aggregation = quickSelectedAggregation {
            quickExpandedAggregationIDs.remove(aggregation.id)
            return
        }
        guard let clipID = quickSelectionID,
              let entry = quickListEntries.first(where: {
                  guard case .clip(let clip, let parentID) = $0.content else { return false }
                  return clip.id == clipID && parentID != nil
              }),
              case .clip(_, let parentID) = entry.content,
              let parentID else { return }
        quickLastSelectedChildIDs[parentID] = clipID
        quickExpandedAggregationIDs.remove(parentID)
        quickSelectedAggregationID = parentID
        quickSelectionID = nil
    }

    func expandSelectedLibraryAggregation() {
        guard let aggregation = selectedAggregation else { return }
        toggleLibraryAggregation(aggregation.id, selectChild: true)
    }

    func collapseSelectedLibraryAggregation() {
        if let aggregation = selectedAggregation {
            libraryExpandedAggregationIDs.remove(aggregation.id)
            return
        }
        guard let clipID = selectedClipID,
              let entry = libraryListEntries.first(where: {
                  guard case .clip(let clip, let parentID) = $0.content else { return false }
                  return clip.id == clipID && parentID != nil
              }),
              case .clip(_, let parentID) = entry.content,
              let parentID else { return }
        libraryLastSelectedChildIDs[parentID] = clipID
        libraryExpandedAggregationIDs.remove(parentID)
        selectedAggregationID = parentID
        selectedClipID = nil
    }

    func handleQuickClipTap(_ clip: Clip, parentAggregationID: UUID?, modifiers: NSEvent.ModifierFlags) {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        if quickMultiSelectActive || normalized.contains(.command) || normalized.contains(.shift) {
            if !quickMultiSelectActive {
                quickMultiSelectActive = true
                quickMultiSelectionIDs.removeAll()
                if normalized.contains(.shift) { quickMultiSelectionAnchorID = quickSelectionID }
            }
            if normalized.contains(.shift), let anchor = quickMultiSelectionAnchorID {
                let ids = quickListEntries.compactMap { entry -> UUID? in
                    guard case .clip(let value, _) = entry.content else { return nil }
                    return value.id
                }
                if let first = ids.firstIndex(of: anchor), let last = ids.firstIndex(of: clip.id) {
                    for id in ids[min(first, last)...max(first, last)] { quickMultiSelectionIDs.insert(id) }
                }
            } else if quickMultiSelectionIDs.contains(clip.id) {
                quickMultiSelectionIDs.remove(clip.id)
            } else {
                quickMultiSelectionIDs.insert(clip.id)
            }
            quickMultiSelectionAnchorID = clip.id
        }
        quickSelectedAggregationID = nil
        quickSelectionID = clip.id
        if let parentAggregationID { quickLastSelectedChildIDs[parentAggregationID] = clip.id }
    }

    func toggleQuickCurrentMultiSelection() {
        guard let id = quickSelectionID else { return }
        if !quickMultiSelectActive { quickMultiSelectActive = true }
        if quickMultiSelectionIDs.contains(id) { quickMultiSelectionIDs.remove(id) }
        else { quickMultiSelectionIDs.insert(id) }
        quickMultiSelectionAnchorID = id
    }

    func exitQuickMultiSelect() {
        quickMultiSelectActive = false
        quickMultiSelectionIDs.removeAll()
        quickMultiSelectionAnchorID = nil
    }

    func prepareQuickAggregation() async {
        if let aggregation = quickSelectedAggregation {
            quickAggregationDraft = AggregationDraft(
                aggregationID: aggregation.id,
                memberClipIDs: aggregation.memberClipIDs,
                title: aggregation.title,
                note: aggregation.note,
                origin: aggregation.origin
            )
            return
        }

        if quickMultiSelectActive {
            guard quickMultiSelectionIDs.count >= 2 else {
                presentStatus("至少需要两项不同内容才能创建聚合", kind: .warning)
                return
            }
            var seen = Set<UUID>()
            let order = quickListEntries.compactMap { entry -> UUID? in
                guard case .clip(let clip, _) = entry.content,
                      quickMultiSelectionIDs.contains(clip.id),
                      seen.insert(clip.id).inserted else { return nil }
                return clip.id
            }
            presentAggregationDraft(memberIDs: order, title: "新建聚合", origin: .manual)
            return
        }

        let query = quickQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            do {
                var candidates = try await aggregationSearchCandidates(query: query)
                for aggregation in aggregations where aggregationMatchesText(aggregation, query: query) {
                    candidates.append(contentsOf: aggregation.memberClipIDs)
                }
                presentAggregationDraft(
                    memberIDs: candidates,
                    title: "\(String(query.prefix(60))) 相关内容",
                    origin: .search(query: query)
                )
            } catch { show(error) }
            return
        }

        guard let id = quickSelectionID else {
            presentStatus("请先选择内容", kind: .warning)
            return
        }
        quickMultiSelectActive = true
        quickMultiSelectionIDs = [id]
        quickMultiSelectionAnchorID = id
        presentStatus("已进入多选；至少再选择一项内容")
    }

    func saveQuickAggregation(title: String, note: String, memberIDs: [UUID]? = nil) async {
        guard let draft = quickAggregationDraft else { return }
        let now = Date()
        let previous = draft.aggregationID.flatMap { id in aggregations.first { $0.id == id } }
        var value = previous ?? ClipAggregation(
            title: title,
            note: note,
            memberClipIDs: memberIDs ?? draft.memberClipIDs,
            origin: draft.origin
        )
        value.title = title
        value.note = note
        value.memberClipIDs = memberIDs ?? draft.memberClipIDs
        value.origin = draft.origin
        value.updatedAt = now
        do {
            let saved = try await repository.saveAggregation(value)
            quickAggregationDraft = nil
            quickAggregationCommitRequestID = nil
            quickAggregationDismissRequestID = nil
            exitQuickMultiSelect()
            if previous == nil { undoableAggregation = saved }
            quickQuery = ""
            quickSearchFocused = false
            await refreshQuick(resetSelection: false)
            await refreshLibrary()
            await refreshAggregations()
            quickSelectedAggregationID = saved.id
            quickSelectionID = nil
            presentStatus(previous == nil ? "已聚合 \(saved.memberClipIDs.count) 项内容" : "聚合信息已更新")
        } catch { show(error) }
    }

    func dismissQuickAggregationDraft() {
        quickAggregationDraft = nil
        quickAggregationCommitRequestID = nil
        quickAggregationDismissRequestID = nil
    }

    func removeAggregation(_ aggregation: ClipAggregation) async {
        do {
            try await repository.removeAggregation(id: aggregation.id)
            await refreshAggregations()
            presentStatus("聚合已删除，原内容已保留")
        } catch { show(error) }
    }

    func toggleAggregationFavorite(_ aggregation: ClipAggregation) async {
        var value = aggregation
        value.isFavorite.toggle()
        value.updatedAt = Date()
        await saveAggregationState(value)
    }

    func toggleAggregationPinned(_ aggregation: ClipAggregation) async {
        var value = aggregation
        value.isPinned.toggle()
        value.updatedAt = Date()
        await saveAggregationState(value)
    }

    func toggleAggregationCollection(_ collection: ClipCollection, aggregation: ClipAggregation) async {
        guard collection.kind == .normal else { return }
        var value = aggregation
        if value.collectionIDs.contains(collection.id) { value.collectionIDs.remove(collection.id) }
        else { value.collectionIDs.insert(collection.id) }
        value.updatedAt = Date()
        await saveAggregationState(value)
    }

    func toggleFavoriteForAllMembers(of aggregation: ClipAggregation) async {
        let members = aggregationMembers[aggregation.id] ?? []
        let newValue = !members.allSatisfy(\.isFavorite)
        await updateAllMembers(of: aggregation) { $0.isFavorite = newValue }
    }

    func togglePinnedForAllMembers(of aggregation: ClipAggregation) async {
        let members = aggregationMembers[aggregation.id] ?? []
        let newValue = !members.allSatisfy(\.isPinned)
        await updateAllMembers(of: aggregation) { $0.isPinned = newValue }
    }

    func toggleCollectionForAllMembers(_ collection: ClipCollection, aggregation: ClipAggregation) async {
        guard collection.kind == .normal else { return }
        let members = aggregationMembers[aggregation.id] ?? []
        let shouldAdd = !members.allSatisfy { $0.collectionIDs.contains(collection.id) }
        await updateAllMembers(of: aggregation) { clip in
            if shouldAdd { clip.collectionIDs.insert(collection.id) }
            else { clip.collectionIDs.remove(collection.id) }
        }
    }

    func removeClip(_ clipID: UUID, from aggregation: ClipAggregation) async {
        var value = aggregation
        value.memberClipIDs.removeAll { $0 == clipID }
        value.updatedAt = Date()
        if value.memberClipIDs.count < 2 {
            await removeAggregation(aggregation)
            presentStatus("成员不足两项，聚合已解散；原内容已保留")
            return
        }
        await saveAggregationState(value)
        presentStatus("已移出当前聚合，原内容已保留")
    }

    private func updateAllMembers(
        of aggregation: ClipAggregation,
        mutation: (inout Clip) -> Void
    ) async {
        var members = aggregationMembers[aggregation.id] ?? []
        let now = Date()
        for index in members.indices {
            mutation(&members[index])
            members[index].updatedAt = now
        }
        do {
            try await repository.saveBatch(members)
            for member in members { replaceLocal(member) }
            await refreshQuick()
            await refreshLibrary()
            await refreshAggregations()
            presentStatus("已整理全部成员")
        } catch { show(error) }
    }

    private func saveAggregationState(_ value: ClipAggregation) async {
        do {
            _ = try await repository.saveAggregation(value)
            await refreshAggregations()
        } catch { show(error) }
    }

    func undoLastAggregation() async {
        guard let value = undoableAggregation else { return }
        undoableAggregation = nil
        await removeAggregation(value)
    }

    func makeLibraryAggregationDraft() async -> AggregationDraft? {
        if let aggregation = selectedAggregation {
            return AggregationDraft(
                aggregationID: aggregation.id,
                memberClipIDs: aggregation.memberClipIDs,
                title: aggregation.title,
                note: aggregation.note,
                origin: aggregation.origin
            )
        }
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            presentStatus("请先搜索需要聚合的内容", kind: .warning)
            return nil
        }
        do {
            var candidates = try await aggregationLibrarySearchCandidates(query: query)
            for aggregation in aggregations where aggregationMatchesText(aggregation, query: query) {
                candidates.append(contentsOf: aggregation.memberClipIDs)
            }
            var seen = Set<UUID>()
            let unique = candidates.filter { seen.insert($0).inserted }
            guard unique.count >= 2 else {
                presentStatus("至少需要两项不同内容才能创建聚合", kind: .warning)
                return nil
            }
            return AggregationDraft(
                aggregationID: nil,
                memberClipIDs: unique,
                title: "\(String(query.prefix(60))) 相关内容",
                note: "",
                origin: .search(query: query)
            )
        } catch {
            show(error)
            return nil
        }
    }

    func saveLibraryAggregation(_ draft: AggregationDraft, title: String, note: String) async -> Bool {
        let previous = draft.aggregationID.flatMap { id in aggregations.first { $0.id == id } }
        var value = previous ?? ClipAggregation(
            title: title,
            note: note,
            memberClipIDs: draft.memberClipIDs,
            origin: draft.origin
        )
        value.title = title
        value.note = note
        value.memberClipIDs = draft.memberClipIDs
        value.updatedAt = Date()
        do {
            let saved = try await repository.saveAggregation(value)
            libraryQuery = ""
            await refreshLibrary()
            await refreshQuick()
            await refreshAggregations()
            selectedAggregationID = saved.id
            selectedClipID = nil
            presentStatus(previous == nil ? "已聚合 \(saved.memberClipIDs.count) 项内容" : "聚合信息已更新")
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func presentAggregationDraft(memberIDs: [UUID], title: String, origin: AggregationOrigin) {
        var seen = Set<UUID>()
        let unique = memberIDs.filter { seen.insert($0).inserted }
        guard unique.count >= 2 else {
            presentStatus("至少需要两项不同内容才能创建聚合", kind: .warning)
            return
        }
        quickAggregationDraft = AggregationDraft(
            aggregationID: nil,
            memberClipIDs: unique,
            title: title,
            note: "",
            origin: origin
        )
    }

    private func aggregationSearchCandidates(query: String) async throws -> [UUID] {
        let candidates: [Clip]
        switch quickScope {
        case .all:
            candidates = try await repository.list(filter: .all, query: query, limit: 100_000)
        case .favorite:
            candidates = try await repository.list(filter: .favorite, query: query, limit: 100_000)
        case .collection(let id):
            if let collection = collections.first(where: { $0.id == id }),
               collection.kind == .smart,
               let rules = collection.ruleSet {
                let matches = try await repository.list(filter: .all, query: query, limit: 100_000)
                candidates = try matches.filter { try SmartRuleEngine().matches($0, ruleSet: rules) }
            } else {
                candidates = try await repository.list(filter: .collection(id), query: query, limit: 100_000)
            }
        }
        return candidates.map(\.id)
    }

    private func aggregationLibrarySearchCandidates(query: String) async throws -> [UUID] {
        let candidates: [Clip]
        if case .collection(let id) = libraryFilter,
           let collection = collections.first(where: { $0.id == id }),
           collection.kind == .smart,
           let rules = collection.ruleSet {
            let matches = try await repository.list(filter: .all, query: query, limit: 100_000)
            candidates = try matches.filter { try SmartRuleEngine().matches($0, ruleSet: rules) }
        } else {
            candidates = try await repository.list(filter: libraryFilter, query: query, limit: 100_000)
        }
        return candidates.map(\.id)
    }

    private func aggregationEntries(
        clips candidates: [Clip],
        query: String,
        expanded: Set<UUID>,
        parentInScope: (ClipAggregation) -> Bool,
        showAllMembersForParent: (ClipAggregation) -> Bool
    ) -> [AggregationListEntry] {
        struct TopLevel {
            let entry: AggregationListEntry
            let pinned: Bool
            let date: Date
            let children: [Clip]
        }

        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let candidateIDs = Set(candidateByID.keys)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var suppressed = Set<UUID>()
        var top = [TopLevel]()

        for aggregation in aggregations {
            let allMembers = aggregationMembers[aggregation.id] ?? []
            let matchingMembers = allMembers.filter { candidateIDs.contains($0.id) }
            let titleMatches = !trimmed.isEmpty && aggregationMatchesText(aggregation, query: trimmed)
            let ownScopeMatch = parentInScope(aggregation)
            let visible = trimmed.isEmpty
                ? ownScopeMatch || !matchingMembers.isEmpty
                : (ownScopeMatch && titleMatches) || !matchingMembers.isEmpty
            guard visible else { continue }
            suppressed.formUnion(matchingMembers.map(\.id))
            let children: [Clip]
            if trimmed.isEmpty {
                let available = ownScopeMatch && showAllMembersForParent(aggregation) ? allMembers : matchingMembers
                children = expanded.contains(aggregation.id) ? available : []
            }
            else { children = matchingMembers }
            let latest = allMembers.map(\.lastUsedAt).max() ?? aggregation.updatedAt
            top.append(TopLevel(
                entry: AggregationListEntry(content: .aggregation(aggregation)),
                pinned: aggregation.isPinned,
                date: max(latest, aggregation.updatedAt),
                children: children
            ))
        }

        for clip in candidates where !suppressed.contains(clip.id) {
            top.append(TopLevel(
                entry: AggregationListEntry(content: .clip(clip, parentAggregationID: nil)),
                pinned: clip.isPinned,
                date: clip.lastUsedAt,
                children: []
            ))
        }

        top.sort {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            return $0.date > $1.date
        }

        var result = [AggregationListEntry]()
        for value in top {
            result.append(value.entry)
            guard case .aggregation(let aggregation) = value.entry.content else { continue }
            result.append(contentsOf: value.children.enumerated().map { index, clip in
                AggregationListEntry(
                    content: .clip(clip, parentAggregationID: aggregation.id),
                    isFirstChild: index == 0,
                    isLastChild: index == value.children.count - 1
                )
            })
        }
        return result
    }

    private func aggregationMatchesText(_ aggregation: ClipAggregation, query: String) -> Bool {
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return aggregation.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(folded)
            || aggregation.note.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(folded)
    }

    private func aggregationCandidateCount(clips: [Clip], query: String) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var ids = Set(clips.map(\.id))
        if !trimmed.isEmpty {
            for aggregation in aggregations where aggregationMatchesText(aggregation, query: trimmed) {
                ids.formUnion(aggregation.memberClipIDs)
            }
        }
        return ids.count
    }

    private func quickAggregationIsInOwnScope(_ aggregation: ClipAggregation) -> Bool {
        switch quickScope {
        case .all: true
        case .favorite: aggregation.isFavorite
        case .collection(let id): aggregation.collectionIDs.contains(id)
        }
    }

    private func quickAggregationShowsAllMembers(_ aggregation: ClipAggregation) -> Bool {
        switch quickScope {
        case .all: false
        case .favorite: aggregation.isFavorite
        case .collection(let id): aggregation.collectionIDs.contains(id)
        }
    }

    private func libraryAggregationIsInOwnScope(_ aggregation: ClipAggregation) -> Bool {
        switch libraryFilter {
        case .all, .recent: true
        case .favorite: aggregation.isFavorite
        case .collection(let id): aggregation.collectionIDs.contains(id)
        case .archived, .trash, .kind: false
        }
    }

    private func libraryAggregationShowsAllMembers(_ aggregation: ClipAggregation) -> Bool {
        switch libraryFilter {
        case .favorite: aggregation.isFavorite
        case .collection(let id): aggregation.collectionIDs.contains(id)
        case .all, .recent, .archived, .trash, .kind: false
        }
    }
}
