import AppKit
import Combine
import PasteoryCore

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

enum AppStatusKind {
    case info, warning, error
}

private actor ClipClassificationPipeline {
    func makeClip(from capture: PasteboardCapture) -> Clip? {
        ClipClassifier.makeClip(from: capture)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var quickClips: [Clip] = []
    @Published var collections: [ClipCollection] = []
    @Published var libraryFilter: ClipFilter = .all
    @Published var libraryQuery = ""
    @Published var quickQuery = ""
    @Published var quickSearchFocused = false
    @Published var quickScope: QuickScope = .all
    @Published var quickPresentationID = UUID()
    @Published var quickPanelPinned = false
    @Published var quickCommandKeyDown = false
    @Published var quickDayCount = 0
    @Published var quickWeekCount = 0
    @Published var requestedCollectionEditorID: UUID?
    @Published var selectedClipID: UUID?
    @Published var quickSelectionID: UUID?
    var quickHoveredClipID: UUID?
    @Published var quickMetadataEditorActive = false
    @Published var quickMetadataEditorOpenRequestID: UUID?
    @Published var quickMetadataEditorCommitRequestID: UUID?
    @Published var quickMetadataEditorDismissRequestID: UUID?
    @Published var quickCollectionPickerActive = false
    @Published var quickCollectionPickerOpenRequestID: UUID?
    @Published var quickCollectionPickerDismissRequestID: UUID?
    @Published var statusMessage: String?
    @Published var statusKind: AppStatusKind = .info
    @Published var isBusy = false
    @Published var linkFailureGroups: [LinkFailureGroup] = []
    @Published var resolvedLinkResources: [ResolvedLinkSummary] = []
    @Published var fallbackRules: [URLFallbackRule] = []
    @Published var linkResolutionBusyRouteKeys = Set<String>()
    @Published var linkResolutionBusyResourceIDs = Set<UUID>()

    let settings: AppSettings
    let repository: any ClipRepository
    let attachments: AttachmentStore
    let archive: ArchiveService
    let backup: BackupService
    let linkResolutionService: LinkResolutionService
    private let authenticatedLinkResolver: AuthenticatedLinkResolver
    private var quickSearchTask: Task<Void, Never>?
    private var librarySearchTask: Task<Void, Never>?
    private var statusDismissTask: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?
    private let classificationPipeline = ClipClassificationPipeline()

    init(
        repository: any ClipRepository,
        attachments: AttachmentStore,
        archive: ArchiveService,
        backup: BackupService,
        settings: AppSettings,
        linkResolutionService: LinkResolutionService
    ) {
        self.repository = repository
        self.attachments = attachments
        self.archive = archive
        self.backup = backup
        self.settings = settings
        self.linkResolutionService = linkResolutionService
        self.authenticatedLinkResolver = AuthenticatedLinkResolver()
        self.settingsObservation = settings.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
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
        await refreshQuickStats()
        await refreshLinkResolutionData()
        Task.detached(priority: .utility) { [archive] in _ = try? await archive.run() }
        Task { [weak self] in await self?.prepareExistingLinkFallbacks() }
    }

    func accept(_ capture: PasteboardCapture) async {
        guard var clip = await classificationPipeline.makeClip(from: capture),
              !clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            clip = try await attachments.externalize(clip)
            let stored = try await repository.saveCaptured(clip, context: capture.sourceContext)
            quickClips.removeAll { $0.id == stored.id }
            quickClips.insert(stored, at: 0)
            if quickClips.count > 500 { quickClips.removeLast(quickClips.count - 500) }
            quickClips = SearchRanker.rank(quickClips, query: quickQuery)
            await refreshLibrary()
            await refreshQuickStats()
            if try await repository.activeClipCount() > RetentionPolicy.default.maximumHotClips {
                Task.detached(priority: .utility) { [archive] in _ = try? await archive.run() }
            }
            Task { [weak self, linkResolutionService] in
                await linkResolutionService.resolve(clip: stored, allowNetwork: false)
                guard let self else { return }
                await self.refreshLibrary()
                await self.refreshQuick()
                await self.refreshLinkResolutionData()
                guard self.settings.linkResolutionEnabled else { return }
                await linkResolutionService.resolve(clip: stored, allowNetwork: true)
                await self.resolveUsingAuthenticatedSessionIfAvailable(stored)
                await self.refreshLibrary()
                await self.refreshQuick()
                await self.refreshLinkResolutionData()
            }
        } catch { show(error) }
    }

    func refreshLinkResolutionData() async {
        do {
            async let groups = repository.unresolvedLinkGroups(limit: 500)
            async let resolved = repository.resolvedLinkResources(limit: 500)
            async let rules = repository.userFallbackRules()
            linkFailureGroups = try await groups
            resolvedLinkResources = try await resolved
            fallbackRules = try await rules
        } catch { show(error) }
    }

    private func prepareExistingLinkFallbacks() async {
        do {
            let links = try await repository.list(filter: .kind(.link), query: "", limit: 10_000)
            for clip in links { await linkResolutionService.resolve(clip: clip, allowNetwork: false) }
            await refreshLibrary()
            await refreshQuick()
            await refreshLinkResolutionData()
        } catch { show(error) }
    }

    func retryLinkResolution(_ group: LinkFailureGroup) {
        guard !linkResolutionBusyRouteKeys.contains(group.routeSignature.key) else { return }
        linkResolutionBusyRouteKeys.insert(group.routeSignature.key)
        Task { [weak self, linkResolutionService] in
            await linkResolutionService.retry(group: group)
            guard let self else { return }
            self.linkResolutionBusyRouteKeys.remove(group.routeSignature.key)
            await self.refreshLibrary()
            await self.refreshQuick()
            await self.refreshLinkResolutionData()
        }
    }

    func reparseResolvedLink(_ summary: ResolvedLinkSummary) {
        let resource = summary.resource
        guard !linkResolutionBusyResourceIDs.contains(resource.id) else { return }
        linkResolutionBusyResourceIDs.insert(resource.id)
        Task { [weak self, linkResolutionService] in
            guard let self else { return }
            defer { self.linkResolutionBusyResourceIDs.remove(resource.id) }
            let previousTitle = resource.resolvedTitle

            if let site = LinkAuthenticationSite.matching(host: resource.host),
               LinkAuthenticationSession.lastUpdatedAt(site) != nil,
               let url = URLFallbackEngine.normalizedWebURL(resource.normalizedURL) {
                do {
                    let snapshot = try await self.authenticatedLinkResolver.resolve(url: url)
                    await linkResolutionService.recordAuthenticatedResult(resource: resource, snapshot: snapshot)
                } catch {
                    await linkResolutionService.recordAuthenticatedFailure(
                        resource: resource,
                        errorCode: "webkit_navigation_failed"
                    )
                }
            } else {
                await linkResolutionService.retry(resource: resource)
            }

            let latest = try? await self.repository.linkResource(normalizedURL: resource.normalizedURL)
            await self.refreshLibrary()
            await self.refreshQuick()
            await self.refreshLinkResolutionData()
            guard let latest else {
                self.presentStatus("重新解析完成，但无法读取最新结果", kind: .warning)
                return
            }
            if latest.requestState == .resolved, let title = latest.resolvedTitle {
                if title == previousTitle {
                    self.presentStatus("重新解析完成，标题没有变化")
                } else {
                    self.presentStatus("标题已更新为“\(title)”")
                }
            } else {
                self.presentStatus("重新解析失败，已保留上一次成功标题", kind: .warning)
            }
        }
    }

    func retryAuthenticatedLinkResolution(_ group: LinkFailureGroup) async {
        let routeKey = group.routeSignature.key
        guard !linkResolutionBusyRouteKeys.contains(routeKey) else { return }
        guard LinkAuthenticationSite.matching(host: group.routeSignature.host) != nil else {
            presentStatus("当前网站还没有登录会话适配器", kind: .warning)
            return
        }
        linkResolutionBusyRouteKeys.insert(routeKey)
        defer { linkResolutionBusyRouteKeys.remove(routeKey) }
        do {
            let resources = try await repository.unresolvedLinkResources(routeKey: routeKey)
            var resolvedCount = 0
            for resource in resources {
                guard let url = URLFallbackEngine.normalizedWebURL(resource.normalizedURL) else { continue }
                do {
                    let snapshot = try await authenticatedLinkResolver.resolve(url: url)
                    await linkResolutionService.recordAuthenticatedResult(resource: resource, snapshot: snapshot)
                    resolvedCount += 1
                } catch {
                    await linkResolutionService.recordAuthenticatedFailure(
                        resource: resource,
                        errorCode: "webkit_navigation_failed"
                    )
                }
            }
            await refreshLibrary()
            await refreshQuick()
            await refreshLinkResolutionData()
            if resolvedCount > 0 {
                presentStatus("已使用登录会话重新解析 \(resolvedCount) 个链接")
            } else {
                presentStatus("登录会话未能加载当前链接", kind: .warning)
            }
        } catch { show(error) }
    }

    func retryAuthenticatedLinkResolutions(for site: LinkAuthenticationSite) async {
        do {
            let groups = try await repository.unresolvedLinkGroups(limit: 500)
                .filter { site.matches(host: $0.routeSignature.host) }
            guard !groups.isEmpty else {
                presentStatus("\(site.title) 登录会话已保存，没有待重试链接")
                return
            }
            for group in groups {
                await retryAuthenticatedLinkResolution(group)
            }
        } catch { show(error) }
    }

    private func resolveUsingAuthenticatedSessionIfAvailable(_ clip: Clip) async {
        guard let url = URLFallbackEngine.normalizedWebURL(clip.previewText),
              let site = LinkAuthenticationSite.matching(host: url.host ?? ""),
              LinkAuthenticationSession.lastUpdatedAt(site) != nil else { return }
        do {
            guard let resource = try await repository.linkResource(normalizedURL: url.absoluteString),
                  resource.requestState.needsAttention else { return }
            let snapshot = try await authenticatedLinkResolver.resolve(url: url)
            await linkResolutionService.recordAuthenticatedResult(resource: resource, snapshot: snapshot)
        } catch {
            if let resource = try? await repository.linkResource(normalizedURL: url.absoluteString) {
                await linkResolutionService.recordAuthenticatedFailure(
                    resource: resource,
                    errorCode: "webkit_navigation_failed"
                )
            }
        }
    }

    func addManualLink(_ rawValue: String, mode: ManualLinkResolutionMode) async -> Bool {
        guard let url = URLFallbackEngine.normalizedWebURL(rawValue) else {
            presentStatus("请输入合法的 HTTP 或 HTTPS 链接", kind: .error)
            return false
        }
        let data = Data(url.absoluteString.utf8)
        guard let clip = await classificationPipeline.makeClip(from: PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [
                CapturedRepresentation(uti: "public.url", data: data),
                CapturedRepresentation(uti: "public.utf8-plain-text", data: data)
            ])],
            source: ClipSource(
                appName: PasteoryRuntimeIdentity.current.displayName,
                bundleIdentifier: PasteoryRuntimeIdentity.current.bundleIdentifier,
                confidence: .high
            )
        )) else {
            presentStatus("无法创建链接记录", kind: .error)
            return false
        }
        do {
            let stored = try await repository.saveCaptured(clip)
            await linkResolutionService.resolve(clip: stored, allowNetwork: false, force: true)
            switch mode {
            case .saveOnly:
                break
            case .anonymous:
                await linkResolutionService.resolve(clip: stored, allowNetwork: true, force: true)
            case .authenticated:
                guard LinkAuthenticationSite.matching(host: url.host ?? "") != nil,
                      let resource = try await repository.linkResource(normalizedURL: url.absoluteString) else {
                    presentStatus("当前网站还没有可用的登录会话", kind: .warning)
                    return false
                }
                do {
                    let snapshot = try await authenticatedLinkResolver.resolve(url: url)
                    await linkResolutionService.recordAuthenticatedResult(resource: resource, snapshot: snapshot)
                } catch {
                    await linkResolutionService.recordAuthenticatedFailure(
                        resource: resource,
                        errorCode: "webkit_navigation_failed"
                    )
                    presentStatus("登录会话未能加载这个链接", kind: .warning)
                }
            }
            libraryFilter = .all
            selectedClipID = stored.id
            await refreshLibrary()
            await refreshQuick()
            await refreshQuickStats()
            await refreshLinkResolutionData()
            presentStatus("链接已添加到资料库")
            return true
        } catch {
            show(error)
            return false
        }
    }

    func createFallbackRule(for group: LinkFailureGroup, name: String, titleTemplate: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedTitle.isEmpty else {
            presentStatus("规则名称和标题不能为空", kind: .error)
            return false
        }
        let rule = URLFallbackEngine.suggestedRule(for: group, name: trimmedName, titleTemplate: trimmedTitle)
        do {
            try await repository.saveFallbackRule(rule)
            await refreshLibrary()
            await refreshQuick()
            await refreshLinkResolutionData()
            presentStatus("兜底规则已保存，并已回填现有链接")
            return true
        } catch {
            show(error)
            return false
        }
    }

    func saveFallbackRule(_ rule: URLFallbackRule) async -> Bool {
        var value = rule
        value.updatedAt = Date()
        do {
            try await repository.saveFallbackRule(value)
            await refreshLibrary()
            await refreshQuick()
            await refreshLinkResolutionData()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func removeFallbackRule(_ rule: URLFallbackRule) async {
        do {
            try await repository.removeFallbackRule(id: rule.id)
            await refreshLibrary()
            await refreshQuick()
            await refreshLinkResolutionData()
            presentStatus("兜底规则已移除")
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
        await refreshQuickStats()
        quickPresentationID = UUID()
    }

    func refreshQuickStats(now: Date = Date()) async {
        do {
            async let day = repository.recentClipCount(since: now.addingTimeInterval(-86_400))
            async let week = repository.recentClipCount(since: now.addingTimeInterval(-7 * 86_400))
            quickDayCount = try await day
            quickWeekCount = try await week
        } catch { show(error) }
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
        Task { await refreshQuick(); await refreshLibrary() }
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

    func captureEvents(for clip: Clip, limit: Int = 20) async -> [ClipCaptureEvent] {
        do { return try await repository.captureEvents(for: clip.id, limit: limit) }
        catch { show(error); return [] }
    }

    func moveToTrash(_ clip: Clip) {
        var value = clip; value.deletedAt = Date(); value.updatedAt = Date(); update(value)
        Task { await refreshLibrary(); await refreshQuick(); await refreshQuickStats() }
    }

    func restore(_ clip: Clip) {
        var value = clip; value.deletedAt = nil; value.updatedAt = Date(); update(value)
        Task { await refreshLibrary(); await refreshQuick(); await refreshQuickStats() }
    }

    func permanentlyDelete(_ clip: Clip) async {
        do { try await repository.removePermanently(id: clip.id); await refreshLibrary(); await refreshQuick(); await refreshQuickStats() }
        catch { show(error) }
    }

    @discardableResult
    func addCollection(name: String, smart: Bool) async -> ClipCollection? {
        if let message = collectionNameValidationMessage(name) { presentStatus(message, kind: .error); return nil }
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
            source: ClipSource(
                appName: PasteoryRuntimeIdentity.current.displayName,
                bundleIdentifier: PasteoryRuntimeIdentity.current.bundleIdentifier,
                confidence: .high
            ),
            previewText: text,
            contentHash: UUID().uuidString,
            byteSize: data.count,
            items: [ClipItem(order: 0, representations: [ClipRepresentation(uti: "public.utf8-plain-text", storage: .inline(data))])]
        )
        do {
            try await repository.save(clip)
            libraryFilter = .all; selectedClipID = clip.id
            await refreshLibrary(); await refreshQuick(); await refreshQuickStats()
            return clip
        } catch { show(error); return nil }
    }

    func updateManualText(_ value: String) {
        mutateSelected { clip in
            guard clip.source.bundleIdentifier == PasteoryRuntimeIdentity.current.bundleIdentifier else { return }
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
        if let message = collectionNameValidationMessage(collection.name, excluding: collection.id) { presentStatus(message, kind: .error); return false }
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
        do { let count = try await archive.run(); presentStatus(count > 0 ? "已归档 \(count) 条内容" : "当前没有需要归档的内容"); await refreshLibrary(); await refreshQuick(); await refreshQuickStats() }
        catch { show(error) }
    }

    func exportBackup(to url: URL) async {
        isBusy = true; defer { isBusy = false }
        do { try await backup.export(to: url); presentStatus("备份已导出") }
        catch { show(error) }
    }

    func importBackup(from url: URL) async {
        isBusy = true; defer { isBusy = false }
        do { let count = try await backup.importBackup(from: url); presentStatus("已导入 \(count) 条内容"); await refreshLibrary(); await refreshQuick(); await refreshQuickStats() }
        catch { show(error) }
    }

    func show(_ error: Error) { presentStatus(error.localizedDescription, kind: .error, dismissAfter: 5) }

    func presentStatus(_ message: String, kind: AppStatusKind = .info, dismissAfter seconds: Double = 3) {
        statusDismissTask?.cancel()
        statusMessage = message
        statusKind = kind
        guard seconds > 0 else { return }
        statusDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.statusMessage == message else { return }
            self?.statusMessage = nil
        }
    }

    func clearStatus() {
        statusDismissTask?.cancel()
        statusMessage = nil
    }

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
