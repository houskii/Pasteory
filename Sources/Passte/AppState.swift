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
        quickPresentationID = UUID()
        await refreshQuick(resetSelection: true)
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
        do { collections = try await repository.collections() } catch { show(error) }
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

    func toggleFavorite(_ clip: Clip) {
        var value = clip; value.isFavorite.toggle(); value.updatedAt = Date(); update(value)
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
        let rules = smart ? SmartRuleSet(mode: .all, conditions: []) : nil
        let collection = ClipCollection(name: name, kind: smart ? .smart : .normal, sortOrder: collections.count, ruleSet: rules)
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

    func saveCollection(_ collection: ClipCollection) async {
        do { try SmartRuleEngine().validate(collection.ruleSet ?? SmartRuleSet()); try await repository.saveCollection(collection); await refreshCollections() }
        catch { show(error) }
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
}
