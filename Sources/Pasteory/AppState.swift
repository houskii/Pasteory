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
    @Published private(set) var quickTextActionRunning = false
    @Published var quickScope: QuickScope = .all
    @Published var quickPresentationID = UUID()
    @Published private(set) var quickListResetID = UUID()
    @Published private(set) var libraryListResetID = UUID()
    @Published var quickPanelPinned = false
    @Published var quickCommandKeyDown = false
    @Published var quickDayCount = 0
    @Published var quickWeekCount = 0
    @Published var requestedCollectionEditorID: UUID?
    @Published var selectedClipID: UUID?
    @Published var quickSelectionID: UUID?
    @Published var aggregations: [ClipAggregation] = []
    @Published var aggregationMembers: [UUID: [Clip]] = [:]
    @Published var quickExpandedAggregationIDs = Set<UUID>()
    @Published var libraryExpandedAggregationIDs = Set<UUID>()
    @Published var quickLastSelectedChildIDs: [UUID: UUID] = [:]
    @Published var libraryLastSelectedChildIDs: [UUID: UUID] = [:]
    @Published var quickSelectedAggregationID: UUID?
    @Published var selectedAggregationID: UUID?
    @Published var libraryAggregationDraft: AggregationDraft?
    @Published var quickMultiSelectActive = false
    @Published var quickMultiSelectionIDs = Set<UUID>()
    @Published var quickMultiSelectionAnchorID: UUID?
    @Published var quickAggregationDraft: AggregationDraft?
    @Published var quickAggregationCommitRequestID: UUID?
    @Published var quickAggregationDismissRequestID: UUID?
    @Published var undoableAggregation: ClipAggregation?
    var quickHoveredClipID: UUID?
    @Published var quickMetadataEditorActive = false
    @Published var quickMetadataEditorClipID: UUID?
    @Published var quickMetadataEditorCommitRequestID: UUID?
    @Published var quickMetadataEditorDismissRequestID: UUID?
    @Published var quickMetadataEditorInitialField: QuickMetadataEditorField = .title
    @Published var quickMetadataEditorFocusedField: QuickMetadataEditorField = .title
    @Published var quickMetadataEditorKeyCommand: QuickMetadataEditorKeyCommand?
    @Published var quickCollectionPickerActive = false
    @Published var quickCollectionPickerOpenRequestID: UUID?
    @Published var quickCollectionPickerDismissRequestID: UUID?
    @Published var quickNewNormalCollectionActive = false
    @Published var quickCollectionManagerActive = false
    @Published var statusMessage: String?
    @Published var statusKind: AppStatusKind = .info
    @Published var isBusy = false
    @Published var linkFailureGroups: [LinkFailureGroup] = []
    @Published var resolvedLinkResources: [ResolvedLinkSummary] = []
    @Published var fallbackRules: [URLFallbackRule] = []
    @Published var linkResolutionBusyRouteKeys = Set<String>()
    @Published var linkResolutionBusyResourceIDs = Set<UUID>()
    @Published var storageAnalyticsSnapshot: StorageAnalyticsSnapshot?
    @Published var storageAnalyticsLoading = false

    let settings: AppSettings
    let repository: any ClipRepository
    let attachments: AttachmentStore
    let quickTextActions: QuickTextActionCoordinator
    let quickActionsMenu = QuickActionMenuController()
    let archive: ArchiveService
    let backup: BackupService
    let storageAnalyticsService: StorageAnalyticsService
    let webCacheMaintenance: WebCacheMaintenance
    let linkResolutionService: LinkResolutionService
    private let authenticatedLinkResolver: AuthenticatedLinkResolver
    private var quickSearchTask: Task<Void, Never>?
    private var librarySearchTask: Task<Void, Never>?
    private var appliedQuickQuery = ""
    private var appliedQuickScope: QuickScope = .all
    private var appliedLibraryQuery = ""
    private var appliedLibraryFilter: ClipFilter = .all
    private var statusDismissTask: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?
    private var storageAnalyticsRequest = UUID()
    private var storageAnalyticsRequestedPeriod: StorageAnalyticsPeriod?
    private let classificationPipeline = ClipClassificationPipeline()

    init(
        repository: any ClipRepository,
        attachments: AttachmentStore,
        archive: ArchiveService,
        backup: BackupService,
        storageAnalyticsService: StorageAnalyticsService,
        settings: AppSettings,
        linkResolutionService: LinkResolutionService
    ) {
        self.repository = repository
        self.attachments = attachments
        self.quickTextActions = QuickTextActionCoordinator(repository: repository, attachments: attachments)
        self.archive = archive
        self.backup = backup
        self.storageAnalyticsService = storageAnalyticsService
        self.settings = settings
        self.linkResolutionService = linkResolutionService
        let cache = WebCacheMaintenance(settings: settings, measure: {
            await storageAnalyticsService.webKitNetworkCacheBytes()
        }, clear: LinkWebKitConfiguration.clearNetworkCache)
        self.webCacheMaintenance = cache
        self.authenticatedLinkResolver = AuthenticatedLinkResolver(cache: cache)
        cache.onCleared = { [weak self] in
            guard let self, let period = self.storageAnalyticsRequestedPeriod else { return }
            Task { await self.refreshStorageAnalytics(period: period) }
        }
        self.settingsObservation = settings.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    var selectedClip: Clip? { clips.first(where: { $0.id == selectedClipID }) ?? quickClips.first(where: { $0.id == selectedClipID }) }
    var quickSelectedClip: Clip? { quickClips.first(where: { $0.id == quickSelectionID }) }
    var selectedAggregation: ClipAggregation? { aggregations.first { $0.id == selectedAggregationID } }
    var quickSelectedAggregation: ClipAggregation? { aggregations.first { $0.id == quickSelectedAggregationID } }
    var quickTabs: [QuickTab] {
        [QuickTab(scope: .all, title: L10n.tr("全部"), symbol: "clock")] + collections.map {
            QuickTab(scope: .collection($0.id), title: $0.name, symbol: $0.kind == .smart ? "sparkles" : "folder")
        }
    }

    func bootstrap(processExistingClips: Bool = true) async {
        if processExistingClips {
            do {
                let merged = try await repository.consolidateDuplicateClips()
                if merged > 0 { presentStatus(L10n.tr("已合并 \(merged) 条重复内容")) }
            } catch { show(error) }
        }
        await refreshCollections()
        await refreshLibrary()
        await refreshQuick()
        await refreshAggregations()
        await refreshQuickStats()
        await refreshLinkResolutionData()
        guard processExistingClips else { return }
        Task.detached(priority: .utility) { [archive] in _ = try? await archive.run() }
        Task { [weak self] in
            await self?.prepareExistingLinkFallbacks()
            await self?.refreshRecentLinkCaches()
        }
    }

    func performQuickTextAction(_ action: QuickTextAction, input: String, sourceClip: Clip?) async throws -> QuickTextActionCoordinator.Result {
        let result = try await quickTextActions.perform(action, input: input, sourceClip: sourceClip)
        replaceLocal(result.clip)
        await refreshLibrary()
        await refreshQuick()
        await refreshQuickStats()
        presentStatus(L10n.tr("已复制转换结果并加入资料库"))
        return result
    }

    func presentQuickActions(for clip: Clip?, scope: QuickActionMenuScope, in window: NSWindow?) {
        guard let clip, let window else {
            presentStatus(L10n.tr("请先选择要转换的内容"), kind: .warning)
            return
        }
        guard !quickTextActionRunning else { return }
        quickActionsMenu.present(for: clip, scope: scope, in: window) { action in
            self.runQuickTextAction(action, for: clip)
        }
    }

    func runQuickTextAction(_ action: QuickTextAction, for clip: Clip?) {
        guard let clip else { presentStatus(L10n.tr("请先选择要转换的内容"), kind: .warning); return }
        guard !quickTextActionRunning else { return }
        quickTextActionRunning = true
        Task {
            defer { quickTextActionRunning = false }
            do {
                let input = try await ClipTextReader.read(clip, attachments: attachments)
                _ = try await performQuickTextAction(action, input: input, sourceClip: clip)
            } catch { show(error) }
        }
    }

    func accept(_ capture: PasteboardCapture) async {
        guard let clip = await classificationPipeline.makeClip(from: capture),
              !clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let stored = try await repository.saveCaptured(clip, context: capture.sourceContext)
            replaceLocal(stored)
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

    private func refreshRecentLinkCaches() async {
        guard settings.linkResolutionEnabled else { return }
        let activity = webCacheMaintenance.beginActivity()
        defer { webCacheMaintenance.endActivity(activity) }
        do {
            let recent = try await repository.list(filter: .all, query: "", limit: LinkCacheRefreshPolicy.scanLimit)
            for clip in LinkCacheRefreshPolicy.maintenanceCandidates(from: recent) {
                await linkResolutionService.resolve(clip: clip, allowNetwork: true)
                await resolveUsingAuthenticatedSessionIfAvailable(clip)
            }
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

            if let url = URLFallbackEngine.normalizedWebURL(resource.normalizedURL),
               let target = LinkAuthenticationTarget.matching(url: url, customRules: settings.authenticatedLinkRules),
               LinkAuthenticationSession.lastUpdatedAt(target) != nil {
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
                self.presentStatus(L10n.tr("重新解析完成，但无法读取最新结果"), kind: .warning)
                return
            }
            if latest.requestState == .resolved, let title = latest.resolvedTitle {
                if title == previousTitle {
                    self.presentStatus(L10n.tr("重新解析完成，标题没有变化"))
                } else {
                    self.presentStatus(L10n.tr("标题已更新为“\(title)”"))
                }
            } else {
                self.presentStatus(L10n.tr("重新解析失败，已保留上一次成功标题"), kind: .warning)
            }
        }
    }

    func retryAuthenticatedLinkResolution(
        _ group: LinkFailureGroup,
        using requestedTarget: LinkAuthenticationTarget? = nil
    ) async {
        let routeKey = group.routeSignature.key
        guard !linkResolutionBusyRouteKeys.contains(routeKey) else { return }
        let sampleURL = URLFallbackEngine.normalizedWebURL(group.sampleURL)
        let target = requestedTarget ?? sampleURL.flatMap {
            LinkAuthenticationTarget.matching(url: $0, customRules: settings.authenticatedLinkRules)
        }
        guard let target else {
            presentStatus(L10n.tr("当前链接还没有匹配的登录解析规则"), kind: .warning)
            return
        }
        linkResolutionBusyRouteKeys.insert(routeKey)
        defer { linkResolutionBusyRouteKeys.remove(routeKey) }
        let activity = webCacheMaintenance.beginActivity()
        defer { webCacheMaintenance.endActivity(activity) }
        do {
            let resources = try await repository.unresolvedLinkResources(routeKey: routeKey)
            var resolvedCount = 0
            for resource in resources {
                guard let url = URLFallbackEngine.normalizedWebURL(resource.normalizedURL), target.matches(url) else { continue }
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
                presentStatus(L10n.tr("已使用登录会话重新解析 \(resolvedCount) 个链接"))
            } else {
                presentStatus(L10n.tr("登录会话未能加载当前链接"), kind: .warning)
            }
        } catch { show(error) }
    }

    func retryAuthenticatedLinkResolutions(for target: LinkAuthenticationTarget) async {
        let activity = webCacheMaintenance.beginActivity()
        defer { webCacheMaintenance.endActivity(activity) }
        do {
            let groups = try await repository.unresolvedLinkGroups(limit: 500)
                .filter {
                    guard let url = URLFallbackEngine.normalizedWebURL($0.sampleURL) else { return false }
                    return target.matches(url)
                }
            guard !groups.isEmpty else {
                presentStatus(L10n.tr("\(target.title) 登录会话已保存，没有待重试链接"))
                return
            }
            for group in groups {
                await retryAuthenticatedLinkResolution(group, using: target)
            }
        } catch { show(error) }
    }

    private func resolveUsingAuthenticatedSessionIfAvailable(_ clip: Clip) async {
        guard let url = URLFallbackEngine.normalizedWebURL(clip.previewText),
              let target = LinkAuthenticationTarget.matching(url: url, customRules: settings.authenticatedLinkRules),
              LinkAuthenticationSession.lastUpdatedAt(target) != nil else { return }
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

    func addAuthenticatedLinkRule(
        name: String,
        pattern: String,
        startURL: String
    ) -> LinkAuthenticationTarget? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPattern = AuthenticatedLinkPattern.normalized(pattern)
        guard !trimmedName.isEmpty else {
            presentStatus(L10n.tr("规则名称不能为空"), kind: .error)
            return nil
        }
        if let message = AuthenticatedLinkPattern.validationError(normalizedPattern) {
            presentStatus(message, kind: .error)
            return nil
        }
        guard let loginURL = URLFallbackEngine.normalizedWebURL(startURL) else {
            presentStatus(L10n.tr("登录入口必须是合法的 HTTP 或 HTTPS 地址"), kind: .error)
            return nil
        }
        guard !settings.authenticatedLinkRules.contains(where: { $0.pattern == normalizedPattern }) else {
            presentStatus(L10n.tr("相同的登录解析规则已经存在"), kind: .warning)
            return nil
        }
        let rule = AuthenticatedLinkRule(
            name: trimmedName,
            pattern: normalizedPattern,
            startURL: loginURL.absoluteString
        )
        settings.saveAuthenticatedLinkRule(rule)
        presentStatus(L10n.tr("登录解析规则已添加"))
        return .custom(rule)
    }

    func removeAuthenticatedLinkRule(_ rule: AuthenticatedLinkRule) {
        let target = LinkAuthenticationTarget.custom(rule)
        settings.removeAuthenticatedLinkRule(id: rule.id)
        LinkAuthenticationSession.clear(target)
        presentStatus(L10n.tr("登录解析规则已移除"))
    }

    func createFallbackRule(for group: LinkFailureGroup, name: String, titleTemplate: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedTitle.isEmpty else {
            presentStatus(L10n.tr("规则名称和标题不能为空"), kind: .error)
            return false
        }
        let rule = URLFallbackEngine.suggestedRule(for: group, name: trimmedName, titleTemplate: trimmedTitle)
        do {
            try await repository.saveFallbackRule(rule)
            await refreshLibrary()
            await refreshQuick()
            await refreshLinkResolutionData()
            presentStatus(L10n.tr("兜底规则已保存，并已回填现有链接"))
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
            presentStatus(L10n.tr("兜底规则已移除"))
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
                        result = try SmartRuleEngine().matchingItems(in: candidates, ruleSet: rules)
                    } else {
                        result = try await repository.list(filter: .collection(id), query: query, limit: 500)
                    }
                }
                guard !Task.isCancelled, query == quickQuery, scope == quickScope else { return }
                let searchChanged = query != appliedQuickQuery || scope != appliedQuickScope
                quickClips = SearchRanker.rank(result, query: query)
                appliedQuickQuery = query
                appliedQuickScope = scope
                let entries = quickListEntries
                let selectionIsVisible = entries.contains { entry in
                    switch entry.content {
                    case .aggregation(let aggregation): aggregation.id == quickSelectedAggregationID
                    case .clip(let clip, _): quickSelectedAggregationID == nil && clip.id == quickSelectionID
                    }
                }
                if resetSelection || searchChanged || !selectionIsVisible {
                    if let first = entries.first { selectQuickEntry(first) }
                    else {
                        quickSelectedAggregationID = nil
                        quickSelectionID = nil
                    }
                }
                if resetSelection || searchChanged {
                    quickListResetID = UUID()
                }
            } catch { show(error) }
        }
        await quickSearchTask?.value
    }

    func prepareQuickPanel() async {
        await refreshCollections()
        await refreshQuick(resetSelection: true)
        await refreshAggregations()
        if let first = quickListEntries.first { selectQuickEntry(first) }
        await refreshQuickStats()
        quickPresentationID = UUID()
    }

    func refreshQuickStats(now: Date = Date()) async {
        do {
            let range = NaturalDayRange(containing: now)
            async let day = repository.recentClipCount(since: range.todayStart)
            async let week = repository.recentClipCount(since: range.sevenDayStart)
            quickDayCount = try await day
            quickWeekCount = try await week
        } catch { show(error) }
    }

    func refreshStorageAnalytics(period: StorageAnalyticsPeriod, now: Date = Date()) async {
        let request = UUID()
        storageAnalyticsRequest = request
        storageAnalyticsRequestedPeriod = period
        storageAnalyticsLoading = true
        defer { if storageAnalyticsRequest == request { storageAnalyticsLoading = false } }
        do {
            let snapshot = try await storageAnalyticsService.snapshot(period: period, now: now)
            if storageAnalyticsRequest == request { storageAnalyticsSnapshot = snapshot }
        } catch {
            if storageAnalyticsRequest == request { show(error) }
        }
    }

    func cleanHistory(_ preview: HistoryCleanupPreview) async throws -> HistoryCleanupResult {
        guard !isBusy else { throw HistoryCleanupError.previewChanged }
        isBusy = true
        defer { isBusy = false }
        let result = try await repository.cleanHistory(preview)
        await refreshLibrary()
        await refreshQuick()
        await refreshAggregations()
        await refreshQuickStats()
        await refreshLinkResolutionData()
        return result
    }

    func moveQuickSelection(by offset: Int) {
        let entries = quickListEntries
        guard !entries.isEmpty else {
            quickSelectionID = nil
            quickSelectedAggregationID = nil
            return
        }
        let current = entries.firstIndex { entry in
            switch entry.content {
            case .aggregation(let aggregation): aggregation.id == quickSelectedAggregationID
            case .clip(let clip, _): quickSelectedAggregationID == nil && clip.id == quickSelectionID
            }
        } ?? 0
        let next = min(max(current + offset, 0), entries.count - 1)
        selectQuickEntry(entries[next])
#if DEBUG
        print("quick-selection-index=\(next)")
#endif
    }

    func moveQuickScope(by offset: Int) async {
        let tabs = quickTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(where: { $0.scope == quickScope }) ?? 0
        guard let next = QuickPanelNavigation.wrappedIndex(
            current: current,
            offset: offset,
            count: tabs.count
        ) else { return }
        guard tabs[next].scope != quickScope else { return }
        dismissQuickMetadataEditor()
        quickScope = tabs[next].scope
#if DEBUG
        print("quick-scope-index=\(next)")
#endif
        quickPresentationID = UUID()
        await refreshQuick(resetSelection: true)
    }

    func presentQuickMetadataEditor(for clipID: UUID, initialField: QuickMetadataEditorField) {
        quickSelectionID = clipID
        quickSelectedAggregationID = nil
        quickMetadataEditorInitialField = initialField
        quickMetadataEditorFocusedField = initialField
        quickMetadataEditorClipID = clipID
    }

    func dismissQuickMetadataEditor() {
        quickMetadataEditorClipID = nil
        quickMetadataEditorActive = false
        quickMetadataEditorFocusedField = .title
        quickMetadataEditorKeyCommand = nil
        quickMetadataEditorCommitRequestID = nil
        quickMetadataEditorDismissRequestID = nil
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
                    result = try SmartRuleEngine().matchingItems(in: candidates, ruleSet: ruleSet)
                } else {
                    result = try await repository.list(filter: filter, query: query, limit: query.isEmpty ? 10_000 : 500)
                }
                guard !Task.isCancelled, query == libraryQuery, filter == libraryFilter else { return }
                let searchChanged = query != appliedLibraryQuery || filter != appliedLibraryFilter
                clips = SearchRanker.rank(result, query: query)
                appliedLibraryQuery = query
                appliedLibraryFilter = filter
                let entries = libraryListEntries
                let selectionIsVisible = entries.contains { entry in
                    switch entry.content {
                    case .aggregation(let aggregation): aggregation.id == selectedAggregationID
                    case .clip(let clip, _): selectedAggregationID == nil && clip.id == selectedClipID
                    }
                }
                if searchChanged || !selectionIsVisible {
                    if let first = entries.first { selectLibraryEntry(first) }
                    else {
                        selectedAggregationID = nil
                        selectedClipID = nil
                    }
                }
                if searchChanged {
                    libraryListResetID = UUID()
                }
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
                let safeBase = base.isEmpty ? L10n.tr("未命名分组") : base
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
            do { try await repository.updateExisting(clip) }
            catch { show(error) }
        }
    }

    func recordPaste(_ clip: Clip) async -> Bool {
        do {
            guard let updated = try await repository.recordPaste(id: clip.id, at: Date()) else {
                presentStatus(L10n.tr("已粘贴，但没有找到对应的资料库记录"), kind: .warning, dismissAfter: 5)
                return false
            }
            replaceLocal(updated)
            await refreshLibrary()
            await refreshQuick()
            await refreshAggregations()
            if updated.primaryKind == .link, settings.linkResolutionEnabled {
                Task { [weak self, linkResolutionService] in
                    await linkResolutionService.resolve(clip: updated, allowNetwork: true)
                    await self?.resolveUsingAuthenticatedSessionIfAvailable(updated)
                    await self?.refreshLibrary()
                    await self?.refreshQuick()
                    await self?.refreshLinkResolutionData()
                }
            }
            return true
        } catch {
            presentStatus(L10n.tr("已粘贴，但粘贴次数保存失败：\(error.localizedDescription)"), kind: .warning, dismissAfter: 5)
            return false
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

    func updateMetadata(
        for clip: Clip,
        title: String,
        note: String,
        collectionIDs: Set<UUID>? = nil
    ) {
        let editableCollectionIDs = Set(collections.filter { $0.kind == .normal }.map(\.id))
        mutate(clip) { value in
            value.title = String(title.prefix(120))
            value.note = String(note.prefix(4_000))
            if let collectionIDs {
                value.collectionIDs.subtract(editableCollectionIDs)
                value.collectionIDs.formUnion(collectionIDs.intersection(editableCollectionIDs))
            }
        }
    }

    func captureEvents(for clip: Clip, limit: Int = 20) async -> [ClipCaptureEvent] {
        do { return try await repository.captureEvents(for: clip.id, limit: limit) }
        catch { show(error); return [] }
    }

    func linkResource(for clip: Clip) async -> LinkResource? {
        guard clip.primaryKind == .link,
              let url = URLFallbackEngine.normalizedWebURL(clip.previewText) else { return nil }
        return try? await repository.linkResource(normalizedURL: url.absoluteString)
    }

    func moveToTrash(_ clip: Clip) {
        var value = clip; value.deletedAt = Date(); value.updatedAt = Date(); update(value)
        Task { await refreshLibrary(); await refreshQuick(); await refreshAggregations(); await refreshQuickStats() }
    }

    func restore(_ clip: Clip) {
        var value = clip; value.deletedAt = nil; value.updatedAt = Date(); update(value)
        Task { await refreshLibrary(); await refreshQuick(); await refreshAggregations(); await refreshQuickStats() }
    }

    func permanentlyDelete(_ clip: Clip) async {
        do { try await repository.removePermanently(id: clip.id); await refreshLibrary(); await refreshQuick(); await refreshAggregations(); await refreshQuickStats() }
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
        let text = L10n.tr("新建文本剪辑")
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
                try await repository.updateExisting(clip)
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
        let ordered = CollectionOrdering.moving(
            kind: kind,
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            in: collections
        )
        await persistCollectionOrder(ordered)
    }

    func moveCollection(id: UUID, before targetID: UUID) async {
        await persistCollectionOrder(CollectionOrdering.moving(id: id, before: targetID, in: collections))
    }

    func moveCollectionToEnd(id: UUID) async {
        await persistCollectionOrder(CollectionOrdering.movingToEnd(id: id, in: collections))
    }

    private func persistCollectionOrder(_ ordered: [ClipCollection]) async {
        guard ordered.map(\.id) != collections.map(\.id) else { return }
        let previous = collections
        collections = ordered
        do {
            for collection in ordered {
                try await repository.saveCollection(collection)
            }
            await refreshCollections()
        } catch {
            collections = previous
            show(error)
        }
    }

    func collectionNameValidationMessage(_ name: String, excluding id: UUID? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L10n.tr("请输入分组名称") }
        if trimmed.count > 40 { return L10n.tr("分组名称最多 40 个字符") }
        let key = canonicalCollectionName(trimmed)
        if collections.contains(where: { $0.id != id && canonicalCollectionName($0.name) == key }) { return L10n.tr("分组名称已经存在") }
        return nil
    }

    func smartRuleCandidates() async -> [Clip] {
        do { return try await repository.list(filter: .all, query: "", limit: 100_000) }
        catch { show(error); return [] }
    }

    func runArchive() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { let count = try await archive.run(); presentStatus(count > 0 ? L10n.tr("已归档 \(count) 条内容") : L10n.tr("当前没有需要归档的内容")); await refreshLibrary(); await refreshQuick(); await refreshQuickStats() }
        catch { show(error) }
    }

    func exportBackup(to url: URL) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try await backup.export(to: url); presentStatus(L10n.tr("备份已导出")) }
        catch { show(error) }
    }

    func importBackup(from url: URL) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { let count = try await backup.importBackup(from: url); presentStatus(L10n.tr("已导入 \(count) 条内容")); await refreshLibrary(); await refreshQuick(); await refreshQuickStats() }
        catch { show(error) }
    }

    func show(_ error: Error) { presentStatus(error.localizedDescription, kind: .error, dismissAfter: 5) }

    func presentStatus(_ message: String, kind: AppStatusKind = .info, dismissAfter seconds: Double = 3) {
        statusDismissTask?.cancel()
        if !message.hasPrefix(L10n.tr("已聚合 ")) { undoableAggregation = nil }
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

    func replaceLocal(_ clip: Clip) {
        if let index = clips.firstIndex(where: { $0.id == clip.id }) { clips[index] = clip }
        if let index = quickClips.firstIndex(where: { $0.id == clip.id }) { quickClips[index] = clip }
        for aggregationID in aggregationMembers.keys {
            if let index = aggregationMembers[aggregationID]?.firstIndex(where: { $0.id == clip.id }) {
                aggregationMembers[aggregationID]?[index] = clip
            }
        }
    }

    private func canonicalCollectionName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func normalizedLegacyRules(_ rules: SmartRuleSet) -> SmartRuleSet {
        SmartRuleSet(
            mode: rules.mode,
            conditions: rules.conditions.map(normalizedLegacyCondition),
            groups: rules.groups.map(normalizedLegacyGroup)
        )
    }

    private func normalizedLegacyGroup(_ group: SmartRuleGroup) -> SmartRuleGroup {
        SmartRuleGroup(
            id: group.id,
            mode: group.mode,
            conditions: group.conditions.map(normalizedLegacyCondition),
            groups: group.groups.map(normalizedLegacyGroup)
        )
    }

    private func normalizedLegacyCondition(_ condition: SmartCondition) -> SmartCondition {
        guard !condition.field.supportedOperators.contains(condition.operation) else { return condition }
        var value = condition
        value.operation = condition.field.supportedOperators[0]
        switch condition.field {
        case .sourceConfidence, .kind, .priority, .favorite, .quickTextAction:
            value.value = condition.field.defaultValue
        default:
            if value.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value.value = condition.field.defaultValue
            }
        }
        return value
    }
}
