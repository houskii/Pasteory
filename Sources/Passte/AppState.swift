import AppKit
import Combine
import PassteCore

enum QuickScope: Hashable {
    case all
    case favorite
    case collection(UUID)
}

struct QuickTab: Identifiable, Hashable {
    let scope: QuickScope
    let title: String
    let symbol: String
    var id: QuickScope { scope }
}

@MainActor
final class AppState: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var quickClips: [Clip] = []
    @Published var collections: [ClipCollection] = []
    @Published var libraryFilter: ClipFilter = .all
    @Published var libraryQuery = ""
    @Published var quickQuery = ""
    @Published var quickScope: QuickScope = .all
    @Published var quickPresentationID = UUID()
    @Published var quickPanelPinned = false
    @Published var quickCommandKeyDown = false
    @Published var requestedCollectionEditorID: UUID?
    @Published var selectedClipID: UUID?
    @Published var quickSelectionID: UUID?
    @Published var statusMessage: String?
    @Published var isBusy = false

    let settings: AppSettings
    let repository: any ClipRepository
    let attachments: AttachmentStore
    let archive: ArchiveService
    let backup: BackupService
    private var quickSearchTask: Task<Void, Never>?
    private var librarySearchTask: Task<Void, Never>?

    init(repository: any ClipRepository, attachments: AttachmentStore, archive: ArchiveService, backup: BackupService, settings: AppSettings) {
        self.repository = repository
        self.attachments = attachments
        self.archive = archive
        self.backup = backup
        self.settings = settings
    }

    var selectedClip: Clip? { clips.first(where: { $0.id == selectedClipID }) ?? quickClips.first(where: { $0.id == selectedClipID }) }
    var quickSelectedClip: Clip? { quickClips.first(where: { $0.id == quickSelectionID }) }
    var quickTabs: [QuickTab] {
        [QuickTab(scope: .all, title: "全部", symbol: "clock")] + collections.map {
            QuickTab(scope: .collection($0.id), title: $0.name, symbol: $0.kind == .smart ? "sparkles" : "folder")
        }
    }

    func bootstrap() async {
        await refreshCollections()
        await refreshLibrary()
        await refreshQuick()
        Task.detached(priority: .utility) { [archive] in _ = try? await archive.run() }
    }

    func accept(_ capture: PasteboardCapture) async {
        guard var clip = ClipClassifier.makeClip(from: capture), !clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            clip = try await attachments.externalize(clip)
            let stored = try await repository.saveCaptured(clip)
            quickClips.removeAll { $0.id == stored.id }
            quickClips.insert(stored, at: 0)
            if quickClips.count > 500 { quickClips.removeLast(quickClips.count - 500) }
            await refreshLibrary()
            if try await repository.activeClipCount() > RetentionPolicy.default.maximumHotClips {
                Task.detached(priority: .utility) { [archive] in _ = try? await archive.run() }
            }
        } catch { show(error) }
    }

    func refreshQuick(debounce: Bool = false, resetSelection: Bool = false) async {
        quickSearchTask?.cancel()
        let query = quickQuery, scope = quickScope
        quickSearchTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled, let self else { return }
            do {
                let result: [Clip]
                switch scope {
                case .all:
                    result = try await repository.list(filter: .all, query: query, limit: 500)
                case .favorite:
                    result = try await repository.list(filter: .favorite, query: query, limit: 500)
                case .collection(let id):
                    if let collection = collections.first(where: { $0.id == id }), collection.kind == .smart, let rules = collection.ruleSet {
                        let candidates = try await repository.list(filter: .all, query: query, limit: 10_000)
                        result = try candidates.filter { try SmartRuleEngine().matches($0, ruleSet: rules) }
                    } else {
                        result = try await repository.list(filter: .collection(id), query: query, limit: 500)
                    }
                }
                guard !Task.isCancelled else { return }
                quickClips = SearchRanker.rank(result, query: query)
                if resetSelection || !quickClips.contains(where: { $0.id == quickSelectionID }) { quickSelectionID = quickClips.first?.id }
            } catch { show(error) }
        }
        await quickSearchTask?.value
    }

    func prepareQuickPanel() async {
        await refreshCollections()
        await refreshQuick(resetSelection: true)
        quickPresentationID = UUID()
    }

    func moveQuickSelection(by offset: Int) {
        guard !quickClips.isEmpty else { quickSelectionID = nil; return }
        let current = quickClips.firstIndex(where: { $0.id == quickSelectionID }) ?? 0
        let next = min(max(current + offset, 0), quickClips.count - 1)
        quickSelectionID = quickClips[next].id
#if DEBUG
        print("quick-selection-index=\(next)")
#endif
    }

    func moveQuickScope(by offset: Int) async {
        let tabs = quickTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(where: { $0.scope == quickScope }) ?? 0
        let next = min(max(current + offset, 0), tabs.count - 1)
        guard tabs[next].scope != quickScope else { return }
        quickScope = tabs[next].scope
#if DEBUG
        print("quick-scope-index=\(next)")
#endif
        quickPresentationID = UUID()
        await refreshQuick(resetSelection: true)
    }

    func refreshLibrary(debounce: Bool = false) async {
        librarySearchTask?.cancel()
        let query = libraryQuery, filter = libraryFilter
        librarySearchTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled, let self else { return }
            do {
                let result: [Clip]
                if case .collection(let id) = filter,
                   let collection = collections.first(where: { $0.id == id }), collection.kind == .smart,
                   let ruleSet = collection.ruleSet {
                    let candidates = try await repository.list(filter: .all, query: query, limit: 100_000)
                    result = try candidates.filter { try SmartRuleEngine().matches($0, ruleSet: ruleSet) }
                } else {
                    result = try await repository.list(filter: filter, query: query, limit: query.isEmpty ? 10_000 : 500)
                }
                guard !Task.isCancelled else { return }
                clips = SearchRanker.rank(result, query: query)
                if !clips.contains(where: { $0.id == selectedClipID }) { selectedClipID = clips.first?.id }
            } catch { show(error) }
        }
        await librarySearchTask?.value
    }

    func refreshCollections() async {
        do {
            let loaded = try await repository.collections()
            let reservedNames = Set(loaded.map { canonicalCollectionName($0.name) })
            var usedNames = Set<String>()
            var normalized = [ClipCollection]()
            for original in loaded {
                var collection = original
                let base = String(collection.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                let safeBase = base.isEmpty ? "未命名分组" : base
                var candidate = safeBase
                var suffix = 2
                while usedNames.contains(canonicalCollectionName(candidate)) {
                    repeat {
                        let suffixText = " \(suffix)"
                        candidate = String(safeBase.prefix(max(1, 40 - suffixText.count))) + suffixText
                        suffix += 1
                    } while usedNames.contains(canonicalCollectionName(candidate)) || reservedNames.contains(canonicalCollectionName(candidate))
                }
                collection.name = candidate
                if collection.kind == .smart, let rules = collection.ruleSet {
                    collection.ruleSet = normalizedLegacyRules(rules)
                }
                usedNames.insert(canonicalCollectionName(candidate))
                if collection != original { try await repository.saveCollection(collection) }
                normalized.append(collection)
            }
            collections = normalized.sorted { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.sortOrder < rhs.sortOrder
            }
        } catch { show(error) }
    }

    func update(_ clip: Clip) {
        replaceLocal(clip)
        Task {
            do { try await repository.save(clip) }
            catch { show(error) }
        }
    }

    func mutateSelected(_ mutation: (inout Clip) -> Void) {
        guard var clip = selectedClip else { return }
        mutation(&clip); clip.updatedAt = Date(); update(clip)
    }

    func mutate(_ clip: Clip, _ mutation: (inout Clip) -> Void) {
        var value = clip
        mutation(&value)
        value.updatedAt = Date()
        update(value)
    }

    func toggleFavorite(_ clip: Clip) {
        var value = clip; value.isFavorite.toggle(); value.updatedAt = Date(); update(value)
    }

    func togglePinned(_ clip: Clip) {
        mutate(clip) { $0.isPinned.toggle() }
    }

    func toggleCollection(_ collection: ClipCollection, for clip: Clip) {
        guard collection.kind == .normal else { return }
        mutate(clip) { value in
            if value.collectionIDs.contains(collection.id) { value.collectionIDs.remove(collection.id) }
            else { value.collectionIDs.insert(collection.id) }
        }
    }

    func updateMetadata(for clip: Clip, title: String, note: String) {
        mutate(clip) { value in
            value.title = String(title.prefix(120))
            value.note = String(note.prefix(4_000))
        }
    }

    func moveToTrash(_ clip: Clip) {
        var value = clip; value.deletedAt = Date(); value.updatedAt = Date(); update(value)
        Task { await refreshLibrary(); await refreshQuick() }
    }

    func restore(_ clip: Clip) {
        var value = clip; value.deletedAt = nil; value.updatedAt = Date(); update(value)
        Task { await refreshLibrary(); await refreshQuick() }
    }

    func permanentlyDelete(_ clip: Clip) async {
        do { try await repository.removePermanently(id: clip.id); await refreshLibrary(); await refreshQuick() }
        catch { show(error) }
    }

    @discardableResult
    func addCollection(name: String, smart: Bool) async -> ClipCollection? {
        if let message = collectionNameValidationMessage(name) { statusMessage = message; return nil }
        let rules = smart ? SmartRuleSet(mode: .all, conditions: []) : nil
        let collection = ClipCollection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: smart ? .smart : .normal, sortOrder: collections.count, ruleSet: rules)
        do { try await repository.saveCollection(collection); await refreshCollections(); return collection }
        catch { show(error); return nil }
    }

    @discardableResult
    func createManualTextClip() async -> Clip? {
        let text = "新建文本剪辑"
        let data = Data(text.utf8)
        let clip = Clip(
            primaryKind: .text,
            source: ClipSource(appName: "Passte", bundleIdentifier: "app.passte.Passte", confidence: .high),
            previewText: text,
            contentHash: UUID().uuidString,
            byteSize: data.count,
            items: [ClipItem(order: 0, representations: [ClipRepresentation(uti: "public.utf8-plain-text", storage: .inline(data))])]
        )
        do {
            try await repository.save(clip)
            libraryFilter = .all; selectedClipID = clip.id
            await refreshLibrary(); await refreshQuick()
            return clip
        } catch { show(error); return nil }
    }

    func updateManualText(_ value: String) {
        mutateSelected { clip in
            guard clip.source.bundleIdentifier == "app.passte.Passte" else { return }
            let data = Data(value.utf8)
            clip.previewText = value
            clip.byteSize = data.count
            clip.contentHash = UUID().uuidString
            if clip.items.isEmpty { clip.items = [ClipItem(order: 0, representations: [])] }
            if let index = clip.items[0].representations.firstIndex(where: { $0.uti == "public.utf8-plain-text" }) {
                clip.items[0].representations[index].storage = .inline(data)
            } else {
                clip.items[0].representations.append(ClipRepresentation(uti: "public.utf8-plain-text", storage: .inline(data)))
            }
        }
    }

    @discardableResult
    func saveCollection(_ collection: ClipCollection) async -> Bool {
        if let message = collectionNameValidationMessage(collection.name, excluding: collection.id) { statusMessage = message; return false }
        var value = collection
        value.name = collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if value.kind == .smart { try SmartRuleEngine().validate(value.ruleSet ?? SmartRuleSet()) }
            try await repository.saveCollection(value)
            await refreshCollections()
            await refreshQuick()
            return true
        } catch { show(error); return false }
    }

    func deleteCollection(_ collection: ClipCollection) async {
        do {
            for var clip in try await repository.allClips() where clip.collectionIDs.contains(collection.id) {
                clip.collectionIDs.remove(collection.id)
                try await repository.save(clip)
            }
            try await repository.removeCollection(id: collection.id)
            if libraryFilter == .collection(collection.id) { libraryFilter = .all }
            if quickScope == .collection(collection.id) { quickScope = .all }
            await refreshCollections()
            await refreshLibrary()
            await refreshQuick(resetSelection: true)
        } catch { show(error) }
    }

    func reorderCollections(kind: CollectionKind, fromOffsets: IndexSet, toOffset: Int) async {
        var target = collections.filter { $0.kind == kind }
        let moving = fromOffsets.sorted().compactMap { target.indices.contains($0) ? target[$0] : nil }
        for index in fromOffsets.sorted(by: >) where target.indices.contains(index) { target.remove(at: index) }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let destination = min(max(toOffset - removedBeforeDestination, 0), target.count)
        target.insert(contentsOf: moving, at: destination)
        var normal = kind == .normal ? target : collections.filter { $0.kind == .normal }
        var smart = kind == .smart ? target : collections.filter { $0.kind == .smart }
        if kind != .normal { normal.sort { $0.sortOrder < $1.sortOrder } }
        if kind != .smart { smart.sort { $0.sortOrder < $1.sortOrder } }
        let ordered = normal + smart
        do {
            for (index, var collection) in ordered.enumerated() {
                collection.sortOrder = index
                try await repository.saveCollection(collection)
            }
            await refreshCollections()
        } catch { show(error) }
    }

    func moveCollection(id: UUID, before targetID: UUID) async {
        guard id != targetID,
              let source = collections.first(where: { $0.id == id }),
              let target = collections.first(where: { $0.id == targetID }),
              source.kind == target.kind else { return }
        var sameKind = collections.filter { $0.kind == source.kind }
        guard let sourceIndex = sameKind.firstIndex(where: { $0.id == id }) else { return }
        let moved = sameKind.remove(at: sourceIndex)
        guard let targetIndex = sameKind.firstIndex(where: { $0.id == targetID }) else { return }
        sameKind.insert(moved, at: targetIndex)
        let normal = source.kind == .normal ? sameKind : collections.filter { $0.kind == .normal }.sorted { $0.sortOrder < $1.sortOrder }
        let smart = source.kind == .smart ? sameKind : collections.filter { $0.kind == .smart }.sorted { $0.sortOrder < $1.sortOrder }
        do {
            for (index, var collection) in (normal + smart).enumerated() {
                collection.sortOrder = index
                try await repository.saveCollection(collection)
            }
            await refreshCollections()
        } catch { show(error) }
    }

    func collectionNameValidationMessage(_ name: String, excluding id: UUID? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "请输入分组名称" }
        if trimmed.count > 40 { return "分组名称最多 40 个字符" }
        let key = canonicalCollectionName(trimmed)
        if collections.contains(where: { $0.id != id && canonicalCollectionName($0.name) == key }) { return "分组名称已经存在" }
        return nil
    }

    func smartRuleCandidates() async -> [Clip] {
        do { return try await repository.list(filter: .all, query: "", limit: 100_000) }
        catch { show(error); return [] }
    }

    func runArchive() async {
        isBusy = true; defer { isBusy = false }
        do { let count = try await archive.run(); statusMessage = count > 0 ? "已归档 \(count) 条内容" : "当前没有需要归档的内容"; await refreshLibrary(); await refreshQuick() }
        catch { show(error) }
    }

    func exportBackup(to url: URL) async {
        isBusy = true; defer { isBusy = false }
        do { try await backup.export(to: url); statusMessage = "备份已导出" }
        catch { show(error) }
    }

    func importBackup(from url: URL) async {
        isBusy = true; defer { isBusy = false }
        do { let count = try await backup.importBackup(from: url); statusMessage = "已导入 \(count) 条内容"; await refreshLibrary(); await refreshQuick() }
        catch { show(error) }
    }

    func show(_ error: Error) { statusMessage = error.localizedDescription }

    private func replaceLocal(_ clip: Clip) {
        if let index = clips.firstIndex(where: { $0.id == clip.id }) { clips[index] = clip }
        if let index = quickClips.firstIndex(where: { $0.id == clip.id }) { quickClips[index] = clip }
    }

    private func canonicalCollectionName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func normalizedLegacyRules(_ rules: SmartRuleSet) -> SmartRuleSet {
        let conditions = rules.conditions.map { condition in
            guard !condition.field.supportedOperators.contains(condition.operation) else { return condition }
            var value = condition
            value.operation = condition.field.supportedOperators[0]
            switch condition.field {
            case .sourceConfidence, .kind, .priority, .favorite:
                value.value = condition.field.defaultValue
            default:
                if value.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.value = condition.field.defaultValue }
            }
            return value
        }
        return SmartRuleSet(mode: rules.mode, conditions: conditions)
    }
}
