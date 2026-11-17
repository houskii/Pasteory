import AppKit
import Combine
import Foundation
import PasteoryAI
import PasteoryCore

@MainActor
final class AIOrganizationController: ObservableObject {
    @Published private(set) var state = AIOrganizationState()
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var models: [AIModelDescriptor] = []
    @Published var showingReview = false
    @Published private(set) var clipIndex: [UUID: Clip] = [:]
    @Published private(set) var clipActivities: [UUID: ActivityEvaluation] = [:]
    @Published private(set) var clipActivityPercentiles: [UUID: Int] = [:]
    @Published private(set) var groupActivityPercentiles: [UUID: Int] = [:]
    @Published private var cachedGroupActivities: [UUID: GroupActivity] = [:]
    private var cachedGroupActivityRevisions: [UUID: Int] = [:]
    private var cachedActivityPolicy: LifecyclePolicy?
    private var rankingTask: Task<Void, Never>?
    private var rankingRevision: UInt64 = 0
    private var metadataEligibleIDs = Set<UUID>()
    private var safeImageTextIDs = Set<UUID>()
    var eligibleClipIDs: Set<UUID> {
        settings.aiConfiguration.includeImageText == true ? metadataEligibleIDs.intersection(safeImageTextIDs) : metadataEligibleIDs
    }
    @Published private(set) var storageBusy = false
    let repository: any ClipRepository
    let settings: AppSettings
    var onApplied: ((Bool) -> Void)?
    private let analyzer: AIAnalyzer
    private let fileAgent: AIFileAgent
    private let taskDirectories: AppDirectories?
    private let useFileAgent: Bool
    @Published private(set) var latestTaskDirectory: URL?
    private let credentialProvider: () throws -> String
    private let client = OpenAICompatibleClient()
    private var work: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?
    private var queueWrite: Task<Void, Never>?
    private let themePlanner: AIThemePlanner
    var readingGroupIDs: () -> Set<UUID> = { [] }
    var idleTime: () -> TimeInterval = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null) }
    var clock: () -> Date = Date.init
    private var sleeping = false
    private var workspaceObservers = Set<AnyCancellable>()
    private var queuedManual: (all: Bool, groupID: UUID?, trigger: String, contentIDs: [UUID]?, selection: AIGroupSelection?)?
    @Published private(set) var recommendedIDs: [UUID] = []
    @Published private(set) var presentationGroupOrder: [UUID] = []
    private var configurationFingerprint = ""
    private var automaticPaused = false
    private var lastLifecycleRefresh = Date.distantPast
    private var metadataRevision: Int64?
    private var activityPolicyFingerprint = ""
    private var indexMutation: UInt64 = 0
    private var synchronizedAt: [UUID: UInt64] = [:]
    private var reloadGeneration: UInt64 = 0

    init(repository: any ClipRepository, settings: AppSettings, transport: any AIChatTransport = OpenAICompatibleClient(),
         credentialProvider: @escaping () throws -> String = { try AICredentialStore.load() },
         directories: AppDirectories? = nil, useFileAgent: Bool = true) {
        self.repository = repository; self.settings = settings
        self.analyzer = AIAnalyzer(transport: transport); self.themePlanner = AIThemePlanner(transport: transport)
        self.fileAgent = AIFileAgent(transport: transport); self.taskDirectories = directories ?? (try? AppDirectories())
        self.useFileAgent = useFileAgent
        self.credentialProvider = credentialProvider
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in self?.sleeping = true }
        }.store(in: &workspaceObservers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; await self?.tick() }
        }.store(in: &workspaceObservers)
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.reconfigure() }
        }
    }
    deinit { polling?.cancel(); work?.cancel() }

    var pending: AIChangeSet? { state.changes.last { !$0.isApplied && !$0.isRejected } }
    var latestUndoable: AIChangeSet? { state.changes.last { $0.isApplied && !$0.isUndone } }
    var todayUsage: [AIUsageRecord] {
        let start = Calendar.current.startOfDay(for: Date())
        return state.usage.filter { $0.date >= start }
    }
    var todayTokens: Int { todayUsage.reduce(0) { $0 + $1.totalTokens } }
    var todayAutomaticRuns: Int { Set(todayUsage.filter { ["new", "idle", "review"].contains($0.trigger) }.map(\.runID)).count }
    var checkpointProgress: String {
        guard let job = state.checkpoint else { return "" }
        if job.fileTaskVersion != nil { return L10n.tr("任务资料：\(job.clipIDs.count) 条") }
        return "\(job.cursor) / \(job.clipIDs.count)"
    }
    var checkpointRecovery: String? {
        guard let job = state.checkpoint, !(job.requeuedIDs ?? []).isEmpty || !(job.skippedIDs ?? []).isEmpty else { return nil }
        return L10n.tr("资料更新后补算 \(job.requeuedIDs?.count ?? 0) 条，跳过 \(job.skippedIDs?.count ?? 0) 条；其余进度已保留。")
    }
    var needsAttention: Bool { running || pending != nil || state.checkpoint != nil || error != nil }
    var libraryContentCount: Int { clipIndex.values.filter { $0.deletedAt == nil }.count }
    var groupedContentCount: Int {
        Set(state.groups.values.flatMap(\.memberIDs)).filter { clipIndex[$0]?.deletedAt == nil && clipIndex[$0] != nil }.count
    }
    var recentRegroupIDs: [UUID] {
        Array(clipIndex.values.filter { $0.deletedAt == nil && !$0.isArchived }.sorted {
            $0.lastCopiedAt == $1.lastCopiedAt ? $0.id.uuidString < $1.id.uuidString : $0.lastCopiedAt > $1.lastCopiedAt
        }.prefix(settings.aiConfiguration.topN).map(\.id))
    }

    func bootstrap(deferMaintenance: Bool = false) async {
        if deferMaintenance { lastLifecycleRefresh = clock() }
        do { try await recoverSavedContentChanges(); reconfigure(); if state.automation.recommendedIDs.isEmpty { refreshRecommendations() } }
        catch { self.error = error.localizedDescription }
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }; await self.tick()
            }
        }
    }

    func reload() async throws {
        reloadGeneration += 1
        let generation = reloadGeneration
        let loadedState = try await repository.aiState()
        guard generation == reloadGeneration else { return }
        if state != loadedState { state = loadedState }
        if !running, error == nil, let failure = state.checkpoint?.failureMessage { error = failure }
        // Establish a baseline for an existing library once, so upgrading does
        // not label historical material as new. Later additions stay unread.
        if state.automation.viewedGroupMembers == nil {
            let baseline = state.groups.mapValues(\.memberIDs)
            state.automation.viewedGroupMembers = baseline
            try await repository.updateAIState { if $0.automation.viewedGroupMembers == nil { $0.automation.viewedGroupMembers = baseline } }
        }
        let startedAt = indexMutation
        let changes = try await repository.clipMetadataChanges(since: metadataRevision)
        let policy = settings.aiConfiguration.lifecycle
        let clips = changes.upserts
        let prepared = await Task.detached(priority: .utility) {
            (Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) }),
             Dictionary(uniqueKeysWithValues: clips.filter { $0.deletedAt == nil }.map { ($0.id, policy.evaluate($0.activity)) }),
             Set(clips.filter(\.mayParticipateInAI).map(\.id)),
             Set(clips.filter { Clip.isSafeAIText($0.recognizedImageText) }.map(\.id)))
        }.value
        guard generation == reloadGeneration else { return }
        if changes.resetsIndex {
            let local = clipIndex.filter { (synchronizedAt[$0.key] ?? 0) > startedAt }
            clipIndex = prepared.0.merging(local) { _, local in local }
            clipActivities = prepared.1
            metadataEligibleIDs = prepared.2; safeImageTextIDs = prepared.3
            for clip in local.values { synchronize(clip) }
        } else {
            for id in changes.removedIDs where (synchronizedAt[id] ?? 0) <= startedAt {
                clipIndex.removeValue(forKey: id); clipActivities.removeValue(forKey: id); metadataEligibleIDs.remove(id); safeImageTextIDs.remove(id)
            }
            for (id, clip) in prepared.0 where (synchronizedAt[id] ?? 0) <= startedAt {
                if clipIndex[id] != clip { clipIndex[id] = clip }
                if clipActivities[id] != prepared.1[id] { clipActivities[id] = prepared.1[id] }
                if prepared.2.contains(id) { metadataEligibleIDs.insert(id) } else { metadataEligibleIDs.remove(id) }
                if prepared.3.contains(id) { safeImageTextIDs.insert(id) } else { safeImageTextIDs.remove(id) }
            }
        }
        metadataRevision = changes.revision
        let fingerprint = AIHash.fingerprint(policy)
        if activityPolicyFingerprint != fingerprint {
            if !changes.resetsIndex { await refreshActivities() }
            activityPolicyFingerprint = fingerprint
        }
        refreshActivityRanks()
    }

    private func refreshActivities() async {
        let clips = Array(clipIndex.values), policy = settings.aiConfiguration.lifecycle
        let next = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: clips.filter { $0.deletedAt == nil }.map { ($0.id, policy.evaluate($0.activity)) })
        }.value
        if clipActivities != next { clipActivities = next }
        refreshActivityRanks()
    }

    private func refreshActivityRanks() {
        rankingTask?.cancel(); rankingRevision += 1
        let revision = rankingRevision, evaluations = clipActivities, groups = state.groups
        let policy = settings.aiConfiguration.lifecycle
        rankingTask = Task { [weak self] in
            // A burst of metadata changes produces one background ranking pass.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let ranks = await Task.detached(priority: .utility) {
                let content = ActivityPercentile.ranks(evaluations.mapValues(\.score))
                let groupValues = groups.mapValues { policy.group($0.memberIDs.compactMap { evaluations[$0] }) }
                return (content, ActivityPercentile.ranks(groupValues.mapValues(\.score)), groupValues)
            }.value
            guard let self, !Task.isCancelled, revision == self.rankingRevision else { return }
            if self.clipActivityPercentiles != ranks.0 { self.clipActivityPercentiles = ranks.0 }
            if self.groupActivityPercentiles != ranks.1 { self.groupActivityPercentiles = ranks.1 }
            self.cachedGroupActivityRevisions = groups.mapValues(\.revision); self.cachedActivityPolicy = policy
            if self.cachedGroupActivities != ranks.2 { self.cachedGroupActivities = ranks.2 }
        }
    }

    func contentChanged(_ id: UUID) {
        guard let clip = clipIndex[id], eligibleClipIDs.contains(id) else { return }
        let revision = clip.aiContentRevision, now = clock()
        state.automation.enqueue(id: id, revision: revision, at: now)
        let previous = queueWrite, repository = repository
        queueWrite = Task {
            await previous?.value
            do { try await repository.updateAIState { $0.automation.enqueue(id: id, revision: revision, at: now) } }
            catch { self.error = error.localizedDescription }
        }
    }

    func refreshRecommendations() {
        let count = settings.aiConfiguration.organizationPolicy.recommendedCount
        let ordered = state.groups.values.map { (group: $0, score: groupActivity($0).score) }.sorted {
            if $0.group.retained != $1.group.retained { return $0.group.retained }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.group.id.uuidString < $1.group.id.uuidString
        }.map(\.group.id)
        let next = Array(ordered.prefix(count)), old = recommendedIDs.isEmpty ? state.automation.recommendedIDs : recommendedIDs
        if recommendedIDs != next { recommendedIDs = next }
        if presentationGroupOrder != ordered { presentationGroupOrder = ordered }
        guard state.automation.recommendedIDs != next || old != next else { return }
        let now = clock(), repository = repository
        state.automation.recommendedIDs = next
        for id in Set(old).subtracting(next) { state.automation.protectedUntil[id] = now.addingTimeInterval(7 * 86_400) }
        Task {
            do {
                try await repository.updateAIState { s in
                    for id in Set(old).subtracting(next) { s.automation.protectedUntil[id] = now.addingTimeInterval(7 * 86_400) }
                    s.automation.recommendedIDs = next
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func groupOpened(_ id: UUID) {
        guard let group = state.groups[id] else { return }
        let now = clock(), repository = repository
        state.automation.groupOpenedAt[id] = now
        state.automation.viewedGroupMembers?[id] = group.memberIDs
        let previous = queueWrite
        queueWrite = Task {
            await previous?.value
            do { try await repository.updateAIState {
                $0.automation.groupOpenedAt[id] = now
                if $0.automation.viewedGroupMembers == nil { $0.automation.viewedGroupMembers = [:] }
                $0.automation.viewedGroupMembers?[id] = group.memberIDs
            } } catch { self.error = error.localizedDescription }
        }
    }

    func newGroupContentCount(_ id: UUID) -> Int {
        guard let group = state.groups[id], let viewed = state.automation.viewedGroupMembers else { return 0 }
        return group.memberIDs.subtracting(viewed[id] ?? []).filter { id in
            guard let clip = clipIndex[id] else { return false }; return clip.deletedAt == nil
        }.count
    }
    var protectedGroups: Set<UUID> {
        let births = Dictionary(state.changes.flatMap { change in change.commands.filter { $0.kind == .createGroup }.map { ($0.targetID, change.createdAt) } }, uniquingKeysWith: min)
        return AIGroupProtection.ids(groups: Array(state.groups.values), automation: state.automation,
                                     activities: clipIndex.mapValues(\.activity), births: births,
                                     reading: readingGroupIDs().union(recommendedIDs), now: clock())
            .union(state.groups.values.filter { group in group.memberIDs.contains { clipIndex[$0]?.mayParticipateInAI != true } }.map(\.id))
    }

    func synchronize(_ clip: Clip) {
        indexMutation += 1; synchronizedAt[clip.id] = indexMutation
        if clip.mayParticipateInAI { metadataEligibleIDs.insert(clip.id) } else { metadataEligibleIDs.remove(clip.id) }
        if Clip.isSafeAIText(clip.recognizedImageText) { safeImageTextIDs.insert(clip.id) } else { safeImageTextIDs.remove(clip.id) }
        var metadata = clip; metadata.items = []
        if clipIndex[clip.id] != metadata { clipIndex[clip.id] = metadata }
        if clip.deletedAt == nil { clipActivities[clip.id] = settings.aiConfiguration.lifecycle.evaluate(clip.activity) }
        else { clipActivities.removeValue(forKey: clip.id) }
        refreshActivityRanks()
    }
    private func reconfigure() {
        let config = settings.aiConfiguration
        let fingerprint = AIHash.fingerprint(config)
        guard fingerprint != configurationFingerprint else { return }
        configurationFingerprint = fingerprint; automaticPaused = false
        if !config.enabled { work?.cancel() }
        lastLifecycleRefresh = .distantPast
    }

    func tick() async {
        let config = settings.aiConfiguration, now = clock(), policy = settings.aiConfiguration.organizationPolicy
        if !running && now.timeIntervalSince(lastLifecycleRefresh) >= 300 {
            do {
                _ = try await repository.purgeTrash(olderThan: now.addingTimeInterval(-30 * 86_400))
                try await reload(); lastLifecycleRefresh = now
                await refreshActivities()
                if config.lifecycleEnabled && config.automaticCompression && !storageBusy { await compress(groupID: nil) }
            } catch { self.error = error.localizedDescription }
        }
        guard config.enabled, !running, !automaticPaused, !sleeping, todayAutomaticRuns < config.dailyAutomaticRuns else { return }
        let minimumInterval = state.lastAutomaticRunAt.map { now.timeIntervalSince($0) >= 300 } ?? true
        let ids = state.automation.incrementalIDs(at: now)
        let mayAppend = pending == nil || (config.applyMode == .appendExisting && pending?.isThemeReview == true)
        if minimumInterval, config.analyzeNew, mayAppend, state.checkpoint == nil,
           let id = state.automation.requestedGroupReviews?.sorted(by: { $0.uuidString < $1.uuidString }).first {
            analyze(groupID: id, trigger: "definition"); return
        }
        if minimumInterval, config.analyzeNew, !ids.isEmpty, mayAppend,
           state.checkpoint == nil || ["idle", "review"].contains(state.checkpoint?.organization?.trigger ?? "") {
            if state.checkpoint != nil { try? await deferAutomaticJob() }
            analyze(trigger: "new", contentIDs: ids); return
        }
        if minimumInterval, config.analyzeNew, mayAppend {
            if state.checkpoint == nil, state.deferredJobs?.contains(where: { $0.organization?.trigger == "new" }) == true {
                do {
                    try await repository.updateAIState { s in
                        var jobs = s.deferredJobs ?? []
                        if let index = jobs.firstIndex(where: { $0.organization?.trigger == "new" }) { s.checkpoint = jobs.remove(at: index); s.deferredJobs = jobs }
                    }
                    try await reload()
                } catch { self.error = error.localizedDescription; return }
            }
            if state.checkpoint?.organization?.trigger == "new" { analyze(resume: true, trigger: "new"); return }
        }
        guard minimumInterval, policy.idleEnabled, policy.isIdleWindow(at: now), idleTime() >= policy.idleSeconds,
              !ProcessInfo.processInfo.isLowPowerModeEnabled, mayAppend else { return }
        if state.automation.lastNightlyDate.map({ Calendar.current.isDate($0, inSameDayAs: now) }) == true { return }
        if let budget = state.automation.nightlyBudget, Calendar.current.isDate(budget.day, inSameDayAs: now),
           budget.exhausted(policy: policy, now: now, tokens: nightlyTokens) { return }
        if state.checkpoint == nil, let jobs = state.deferredJobs, !jobs.isEmpty {
            do {
                try await repository.updateAIState { s in
                    var pending = s.deferredJobs ?? []
                    pending.sort { ($0.organization?.trigger == "new" ? 0 : 1) < ($1.organization?.trigger == "new" ? 0 : 1) }
                    s.checkpoint = pending.removeFirst(); s.deferredJobs = pending
                }
                try await reload()
            } catch { self.error = error.localizedDescription; return }
        }
        if let job = state.checkpoint {
            if job.organization?.trigger == "new", config.analyzeNew { analyze(resume: true, trigger: "new"); return }
            if ["idle", "review"].contains(job.organization?.trigger ?? "") { analyze(resume: true, trigger: job.organization!.trigger) }
            return
        }
        if state.automation.lastNightlyDate.map({ Calendar.current.isDate($0, inSameDayAs: now) }) == true { return }
        let review = pending == nil && policy.weeklyReviewEnabled && policy.reviewIsDue(lastReview: state.automation.lastReviewAt, now: now)
        analyze(trigger: review ? "review" : "idle")
    }

    func save(configuration: AIConfiguration, credential: String) throws {
        if configuration.enabled { try configuration.validate() }
        else { _ = try configuration.validatedEndpoint(); try configuration.lifecycle.validate() }
        try AICredentialStore.save(credential)
        settings.aiConfiguration = configuration
        error = nil; status = L10n.tr("已保存 AI 整理配置")
    }

    func fetchModels(configuration: AIConfiguration, credential: String) async {
        do { models = try await client.models(configuration: configuration, credential: credential); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func test(configuration: AIConfiguration, credential: String) async {
        guard !running else { return }
        running = true; error = nil; status = L10n.tr("正在使用合成资料测试连接")
        defer { running = false }
        do {
            let repository = repository
            try await analyzer.testConnection(configuration: configuration, credential: credential, ledger: state.usage,
                                             onUsage: { record in try await repository.updateAIState { $0.usage.append(record) } })
            try await reload(); status = L10n.tr("模型连接测试通过")
        } catch { self.error = error.localizedDescription; try? await reload() }
    }

    func analyze(all: Bool = false, resume: Bool = false, groupID: UUID? = nil, trigger: String = "manual", contentIDs: [UUID]? = nil, groupSelection: AIGroupSelection? = nil) {
        if running {
            if trigger.hasPrefix("manual"), !resume { queuedManual = (all, groupID, trigger, contentIDs, groupSelection); status = L10n.tr("当前批次完成后优先执行手动任务") }
            return
        }
        guard !storageBusy else { return }
        guard settings.aiConfiguration.enabled else { error = L10n.tr("请先在 AI 整理设置中启用模型连接"); return }
        if pending != nil && !(["new", "idle"].contains(trigger) && settings.aiConfiguration.applyMode == .appendExisting && pending?.isThemeReview == true) { showingReview = true; return }
        if !resume, let saved = state.checkpoint,
           !["new", "idle", "review"].contains(saved.organization?.trigger ?? "") {
            error = L10n.tr("上次整理尚未完成，请先继续整理，或放弃保存的任务后重新开始。")
            status = L10n.tr("上次整理进度：\(checkpointProgress)")
            return
        }
        running = true; error = nil; status = L10n.tr("正在准备分析范围")
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.running = false; self.work = nil
                if let request = self.queuedManual {
                    self.queuedManual = nil
                    self.analyze(all: request.all, groupID: request.groupID, trigger: request.trigger, contentIDs: request.contentIDs, groupSelection: request.selection)
                }
            }
            do { try await self.runAnalysis(all: all, resume: resume, groupID: groupID, trigger: trigger, contentIDs: contentIDs, groupSelection: groupSelection) }
            catch is CancellationError { self.status = L10n.tr("分析已暂停，可以继续上次任务") }
            catch {
                if Task.isCancelled {
                    self.status = L10n.tr("分析已暂停，可以继续上次任务")
                } else {
                    self.error = error.localizedDescription
                    let message = error.localizedDescription
                    try? await self.repository.updateAIState { $0.checkpoint?.failureMessage = message }
                    self.status = L10n.tr("整理未完成，进度已保存")
                }
                if case AIError.http(let code, _) = error, code == 401 || code == 403 { self.automaticPaused = true }
                if case AIError.budget = error, ["idle", "review"].contains(self.state.checkpoint?.organization?.trigger ?? "") {
                    let now = self.clock()
                    try? await self.repository.updateAIState { $0.automation.lastNightlyDate = now; $0.checkpoint?.failureMessage = nil }
                    self.error = nil; self.status = L10n.tr("夜间整理已保存进度，将在下个闲时窗口继续")
                }
            }
            try? await self.reload()
        }
    }
    func regroupGroups(_ selection: AIGroupSelection) -> Bool {
        guard !running, !storageBusy else { return false }
        guard pending == nil, state.checkpoint == nil else { error = L10n.tr("请先处理整理建议或继续、放弃已保存的任务"); return false }
        guard settings.aiConfiguration.enabled else { error = L10n.tr("请先在 AI 整理设置中启用模型连接"); return false }
        do {
            try settings.aiConfiguration.validate(); try selection.validate(in: state.groups)
            guard !selection.memberIDs.isDisjoint(with: eligibleClipIDs) else {
                error = L10n.tr("所选组没有可分析内容，可以使用清理分组"); return false
            }
            analyze(trigger: "manual-regroup", groupSelection: selection)
            return running
        } catch { self.error = error.localizedDescription; return false }
    }

    func regroupLibrary(recentOnly: Bool = false) -> Bool {
        guard !running, !storageBusy else { return false }
        guard pending == nil, state.checkpoint == nil else { error = L10n.tr("请先处理整理建议或继续、放弃已保存的任务"); return false }
        guard settings.aiConfiguration.enabled else { error = L10n.tr("请先在 AI 整理设置中启用模型连接"); return false }
        do {
            try settings.aiConfiguration.validate()
            guard !eligibleClipIDs.isEmpty else { error = L10n.tr("没有需要整理的内容"); return false }
            let selection = state.groups.isEmpty ? nil : AIGroupSelection(groups: Array(state.groups.values))
            analyze(all: !recentOnly, trigger: recentOnly ? "manual-regroup-recent" : "manual-regroup-all", groupSelection: selection)
            return running
        } catch { self.error = error.localizedDescription; return false }
    }

    func cleanupGroups(_ selection: AIGroupSelection) async -> Bool {
        guard !running, !storageBusy else { return false }
        guard pending == nil, state.checkpoint == nil else { error = L10n.tr("请先处理整理建议或继续、放弃已保存的任务"); return false }
        storageBusy = true; error = nil
        defer { storageBusy = false }
        var draftID: UUID?
        do {
            await queueWrite?.value; try await reload()
            let draft = try AIGroupManagement.cleanup(selection, state: state, clips: Array(clipIndex.values))
            draftID = draft.id
            try await repository.updateAIState { $0.changes.append(draft) }
            try await repository.applyAIChangeSet(draft)
            try await reload(); refreshRecommendations(); onApplied?(false)
            status = L10n.tr("已清理 \(selection.groupIDs.count) 个 AI 分组，可以撤销")
            return true
        } catch {
            self.error = error.localizedDescription
            if let id = draftID {
                try? await repository.updateAIState { s in
                    if let index = s.changes.firstIndex(where: { $0.id == id && !$0.isApplied }) { s.changes[index].isRejected = true }
                }
            }
            try? await reload(); return false
        }
    }

    func pause() { work?.cancel() }
    func openTaskHistory(taskID: UUID? = nil) {
        guard let directories = taskDirectories else { return }
        try? FileManager.default.createDirectory(at: directories.aiTasks, withIntermediateDirectories: true)
        if let taskID {
            let requested = directories.aiTasks.appendingPathComponent(taskID.uuidString.lowercased() + ".agent")
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: requested.path) ? requested : directories.aiTasks)
        } else { NSWorkspace.shared.open(latestTaskDirectory ?? directories.aiTasks) }
    }
    private func reloadForAnalysis() async throws {
        while true {
            try Task.checkCancellation()
            let generation = reloadGeneration + 1
            try await reload()
            if generation == reloadGeneration, metadataRevision != nil { return }
        }
    }
    func recoverSavedContentChanges() async throws {
        try await reloadForAnalysis()
        guard !running, let saved = state.checkpoint,
              saved.failureMessage?.contains("Content changed; review or discard the saved task") == true else { return }
        if let fingerprint = saved.organization?.semanticFingerprint,
           fingerprint != AIThemeCatalog.configurationFingerprint(settings.aiConfiguration) { return }
        var recovered = saved
        let deferred = try AIJobRecovery.reconcile(&recovered, clips: clipIndex, groups: state.groups, eligibleIDs: eligibleClipIDs,
                                                  minimumThemeMembers: settings.aiConfiguration.organizationPolicy.minimumThemeMembers)
        recovered.failureMessage = nil
        let updated = recovered, deferredClips = deferred.compactMap { clipIndex[$0] }
        try await repository.updateAIState { s in
            guard s.checkpoint == saved else { return }
            s.checkpoint = updated
            for clip in deferredClips { s.automation.enqueue(id: clip.id, revision: clip.aiContentRevision) }
        }
        error = nil
        try await reload()
        status = L10n.tr("已保留整理进度，变化的资料已重新入队，可继续整理。")
    }
    func waitUntilIdle() async { await queueWrite?.value; await work?.value; await rankingTask?.value }
    func discardCheckpoint() async {
        guard !running else { return }
        do {
            if let id = state.checkpoint?.id, let directories = taskDirectories { try AIFileTaskWorkspace.markStatus("discarded", taskID: id, directories: directories) }
            try await repository.updateAIState { $0.checkpoint = nil }
            error = nil; status = L10n.tr("已放弃保存的整理任务")
            try await reload()
        }
        catch { self.error = error.localizedDescription }
    }

    private var nightlyTokens: Int { todayUsage.filter { ["idle", "review"].contains($0.trigger) }.reduce(0) { $0 + $1.totalTokens } }

    private func deferAutomaticJob() async throws {
        guard let checkpoint = state.checkpoint, ["idle", "review", "new"].contains(checkpoint.organization?.trigger ?? "") else { return }
        try await repository.updateAIState { s in
            var pending = s.deferredJobs ?? []; pending.append(checkpoint); s.deferredJobs = pending; s.checkpoint = nil
        }
        try await reload()
    }

    private func runAnalysis(all: Bool, resume: Bool, groupID: UUID?, trigger: String, contentIDs: [UUID]?, groupSelection: AIGroupSelection?) async throws {
        if useFileAgent {
            try await runFileAnalysis(all: all, resume: resume, groupID: groupID, trigger: trigger, contentIDs: contentIDs, groupSelection: groupSelection)
        } else {
            // Retained for compatibility verification of pre-file task checkpoints.
            try await runLegacyAnalysis(all: all, resume: resume, groupID: groupID, trigger: trigger, contentIDs: contentIDs, groupSelection: groupSelection)
        }
    }

    private func runFileAnalysis(all: Bool, resume: Bool, groupID: UUID?, trigger requestedTrigger: String, contentIDs: [UUID]?, groupSelection: AIGroupSelection?) async throws {
        await queueWrite?.value
        let config = settings.aiConfiguration, policy = config.organizationPolicy
        try config.validate(); try await reloadForAnalysis()
        guard let directories = taskDirectories else { throw AIError.invalid("Task storage is unavailable") }
        if !resume, requestedTrigger.hasPrefix("manual") { try await deferAutomaticJob() }
        let trigger = resume ? state.checkpoint?.organization?.trigger ?? requestedTrigger : requestedTrigger
        let nightly = ["idle", "review"].contains(trigger), review = ["review", "manual-review"].contains(trigger)
        let eligible = clipIndex.values.filter { eligibleClipIDs.contains($0.id) }.sorted {
            $0.lastCopiedAt == $1.lastCopiedAt ? $0.id.uuidString < $1.id.uuidString : $0.lastCopiedAt > $1.lastCopiedAt
        }
        let selection = resume ? state.checkpoint?.organization?.groupSelection : groupSelection
        try selection?.validate(in: state.groups)
        let catalog = state.groups.filter { selection?.groupIDs.contains($0.key) != true }
        let scope: [UUID]
        if resume { scope = state.checkpoint?.clipIDs ?? [] }
        else if trigger == "manual-regroup-all" || all { scope = eligible.map(\.id) }
        else if trigger == "manual-regroup-recent" { scope = Array(eligible.filter { !$0.isArchived }.prefix(config.topN).map(\.id)) }
        else if let selection { scope = eligible.filter { selection.memberIDs.contains($0.id) }.map(\.id) }
        else if let contentIDs { let ids = Set(contentIDs); scope = eligible.filter { ids.contains($0.id) }.map(\.id) }
        else if let groupID { scope = eligible.filter { $0.collectionIDs.contains(groupID) }.map(\.id) }
        else if nightly {
            let fingerprint = AIThemeCatalog.fingerprint(Array(state.groups.values)), prompt = AIHash.fingerprint(config.prompt)
            scope = Array(eligible.filter { clip in
                if review { return !clip.collectionIDs.isDisjoint(with: Set(state.groups.keys).subtracting(protectedGroups)) || clip.collectionIDs.isEmpty }
                guard !clip.isArchived, clip.collectionIDs.isEmpty else { return false }
                guard let decision = state.automation.decisions[clip.id] else { return true }
                return decision.revision != clip.aiContentRevision || decision.promptFingerprint != prompt || decision.catalogFingerprint != fingerprint
            }.prefix(policy.nightlyItemLimit).map(\.id))
        } else { scope = Array(eligible.filter { !$0.isArchived }.prefix(config.topN).map(\.id)) }
        if scope.isEmpty { status = L10n.tr("没有需要整理的内容"); return }
        var job: AIJobCheckpoint
        if resume {
            guard let saved = state.checkpoint else { throw AIError.invalid("No resumable analysis") }
            job = saved; job.failureMessage = nil
            if saved.fileTaskVersion != nil, let fingerprint = saved.organization?.semanticFingerprint,
               fingerprint != fileTaskFingerprint(config) { throw AIError.conflict("The model, prompt or content-sharing scope changed; start a separate analysis") }
            let deferred = try AIJobRecovery.reconcile(&job, clips: clipIndex, groups: state.groups, eligibleIDs: eligibleClipIDs, minimumThemeMembers: 1)
            for id in deferred { if let clip = clipIndex[id] { contentChanged(clip.id) } }
        } else {
            guard state.checkpoint == nil else { throw AIError.invalid("Resume or discard the saved task first") }
            job = AIJobCheckpoint(clipIDs: scope, batchSize: config.batchSize, configurationFingerprint: AIHash.fingerprint(config))
            job.organization = AIJobOrganization(trigger: trigger, revisions: Dictionary(uniqueKeysWithValues: scope.compactMap { id in clipIndex[id].map { (id, $0.aiContentRevision) } }), protectedGroupIDs: protectedGroups, review: review)
            job.organization?.groupSelection = selection; job.organization?.groupSnapshots = state.groups
        }
        job.fileTaskVersion = 2; job.configurationFingerprint = AIHash.fingerprint(config)
        job.organization?.semanticFingerprint = fileTaskFingerprint(config)
        let checkpoint = job
        let started = clock(), day = Calendar.current.startOfDay(for: clock())
        try await repository.updateAIState { s in
            s.checkpoint = checkpoint
            if !trigger.hasPrefix("manual") { s.lastAutomaticRunAt = started }
            if nightly, s.automation.nightlyBudget?.day != day { s.automation.nightlyBudget = AINightlyBudget(now: started) }
        }
        if nightly { state = try await repository.aiState() }
        state.checkpoint = job
        status = L10n.tr("正在生成完整任务资料")
        let clips = try await repository.clips(ids: job.clipIDs), byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        let ordered = job.clipIDs.compactMap { byID[$0] }
        let taskURL = directories.aiTasks.appendingPathComponent(job.id.uuidString.lowercased() + ".agent")
        var aliases = [UUID: String]()
        if let data = try? Data(contentsOf: taskURL.appendingPathComponent("items.json")), let saved = try? JSONDecoder().decode(AIFileTaskInput.self, from: data) {
            aliases = Dictionary(uniqueKeysWithValues: saved.items.map { ($0.clipID, $0.itemID) })
        }
        let input = try await AIFileTaskExporter.input(clips: ordered, taskID: job.id, configuration: config, directories: directories, aliases: aliases)
        let names = Set(try await repository.collections().filter { selection?.groupIDs.contains($0.id) != true }.map(\.name))
        let workspace = try AIFileTaskWorkspace(input: input, clips: clips, groups: catalog, reservedNames: names, configuration: config, directories: directories, trigger: trigger)
        latestTaskDirectory = await workspace.directory
        let prompt = try await workspace.prepare(previousDraft: job.draft, changedIDs: job.requeuedIDs ?? [])
        let repository = repository
        var runConfiguration = config
        if nightly { runConfiguration.dailyTokenLimit = min(config.dailyTokenLimit, todayTokens + max(0, policy.nightlyTokenLimit - nightlyTokens)) }
        do {
            try await fileAgent.run(taskID: job.id, prompt: prompt, directory: taskURL.path, configuration: runConfiguration, credential: credentialProvider(), ledger: state.usage, trigger: trigger,
                workspace: workspace, onProgress: { [weak self] round, tool in
                    try await self?.fileAgentProgress(round: round, tool: tool, nightly: nightly)
                }, onUsage: { record in
                    try await repository.updateAIState { $0.usage.append(record) }
                    try await workspace.recordUsage(record)
                })
            var result = try await workspace.result()
            try await reloadForAnalysis()
            // A moving clipboard invalidates only changed items, not the entire plan.
            let stale = Set(input.items.filter { item in
                guard let current = clipIndex[item.clipID] else { return true }
                return !eligibleClipIDs.contains(item.clipID) || current.aiContentRevision != item.contentRevision
            }.map(\.clipID))
            if !stale.isEmpty {
                for id in stale where eligibleClipIDs.contains(id) { if let clip = clipIndex[id] { contentChanged(clip.id) } }
                result.commands = result.commands.compactMap { original in
                    var command = original
                    if command.kind == .updateOverview && !Set(command.clipIDs).isDisjoint(with: stale) { return nil }
                    command.clipIDs.removeAll { stale.contains($0) }
                    if command.kind == .addItems && command.clipIDs.isEmpty { return nil }; return command
                }
                let populated = Set(result.commands.filter { $0.kind == .addItems }.map(\.targetID))
                let empty = Set(result.commands.filter { $0.kind == .createGroup && !populated.contains($0.targetID) }.map(\.targetID))
                result.commands.removeAll { empty.contains($0.targetID) }
                result.decisions = result.decisions?.filter { !stale.contains($0.key) }
                result.inputCount -= stale.count
                try await workspace.record(event: "changed_items_deferred", details: .array(stale.map { .string($0.uuidString) }))
            }
            result.clipRevisions = result.clipRevisions.filter { !stale.contains($0.key) }.mapValues { $0 }
            for id in result.clipRevisions.keys { result.clipRevisions[id] = clipIndex[id]?.aiRevision }
            if let selection {
                try selection.validate(in: state.groups)
                let cleanup = try AIGroupManagement.cleanup(selection, state: state, clips: Array(clipIndex.values))
                result = try AIGroupManagement.combining(cleanup: cleanup, analysis: result)
            }
            result.promptFingerprint = AIHash.fingerprint(config.prompt); result.policyFingerprint = config.lifecycle.fingerprint
            result.protectedGroupIDs = protectedGroups
            let fingerprint = AIThemeCatalog.fingerprint(Array(catalog.values))
            for id in result.decisions?.keys.map({ $0 }) ?? [] {
                result.decisions?[id]?.promptFingerprint = result.promptFingerprint
                result.decisions?[id]?.catalogFingerprint = fingerprint
            }
            let finished = result, revisions = job.organization?.revisions ?? [:], now = clock(), completedIDs = job.clipIDs
            try await workspace.saveValidatedResult(finished)
            try await repository.updateAIState { s in
                s.checkpoint = nil; s.automation.decisions.merge(finished.decisions ?? [:]) { _, new in new }
                for id in completedIDs where !stale.contains(id) && s.automation.dirty[id]?.revision == revisions[id] { s.automation.dirty.removeValue(forKey: id) }
                if nightly { s.automation.lastNightlyDate = now; s.automation.nightlyBudget?.processedIDs.formUnion(completedIDs) }
                if review { s.automation.lastReviewAt = now }
                if let groupID { s.automation.requestedGroupReviews?.remove(groupID) }
                if !finished.commands.isEmpty { s.changes.append(finished) }
            }
            try await workspace.finish(status: "ready_for_review")
            try await reload()
            if finished.commands.isEmpty { status = L10n.tr("分析完成，无关内容保留未分组") }
            else if config.applyMode == .appendExisting && finished.appendOnly {
                try await repository.applyAIChangeSet(finished); try await workspace.finish(status: "applied"); try await reload(); onApplied?(!trigger.hasPrefix("manual"))
                status = L10n.tr("已补充已有 AI 分组，主题与阅读位置保持稳定")
            } else { showingReview = !nightly && trigger != "new"; status = L10n.tr("整理建议已生成，可检查后统一应用") }
        } catch {
            try? await workspace.finish(status: Task.isCancelled ? "paused" : "failed", message: error.localizedDescription)
            throw error
        }
    }

    private func fileAgentProgress(round: Int, tool: String?, nightly: Bool) throws {
        let policy = settings.aiConfiguration.organizationPolicy
        if nightly, sleeping || !policy.isIdleWindow(at: clock()) || idleTime() < policy.idleSeconds ||
            state.automation.nightlyBudget?.exhausted(policy: policy, now: clock(), tokens: nightlyTokens) == true { throw CancellationError() }
        let action: String
        switch tool {
        case "task_read", "task_query": action = L10n.tr("读取资料")
        case "task_write": action = L10n.tr("保存方案")
        case "resource_image": action = L10n.tr("查看图片")
        case "task_exec": action = L10n.tr("整理任务文件")
        default: action = L10n.tr("分析资料")
        }
        status = L10n.tr("Agent 第 \(round) 轮") + " · " + action
    }
    private func fileTaskFingerprint(_ config: AIConfiguration) -> String {
        AIHash.fingerprint([config.endpoint, config.model, config.prompt, String(config.includeNotes), String(config.includeSource),
                            String(config.includeImageText == true), String(config.allowOriginalResourceRead != false)])
    }

    private func runLegacyAnalysis(all: Bool, resume: Bool, groupID: UUID?, trigger requestedTrigger: String, contentIDs: [UUID]?, groupSelection: AIGroupSelection?) async throws {
        await queueWrite?.value
        let config = settings.aiConfiguration, policy = settings.aiConfiguration.organizationPolicy
        try config.validate(); try await reloadForAnalysis()
        if !resume, requestedTrigger.hasPrefix("manual") { try await deferAutomaticJob() }
        let credential = try credentialProvider()
        let trigger = resume ? state.checkpoint?.organization?.trigger ?? requestedTrigger : requestedTrigger
        let nightly = ["idle", "review"].contains(trigger)
        let review = trigger == "review" || trigger == "manual-review"
        var selection = resume ? state.checkpoint?.organization?.groupSelection : groupSelection
        if !resume { try selection?.validate(in: state.groups) }
        let replacedIDs = selection?.groupIDs ?? []
        let catalogGroups = Array(state.groups.values.filter { !replacedIDs.contains($0.id) })
        let protected = selection == nil ? protectedGroups : Set(catalogGroups.map(\.id))
        let allowedIDs = eligibleClipIDs
        let eligible = clipIndex.values.filter { allowedIDs.contains($0.id) }.sorted {
            $0.lastCopiedAt == $1.lastCopiedAt ? $0.id.uuidString < $1.id.uuidString : $0.lastCopiedAt > $1.lastCopiedAt
        }
        let catalog = AIThemeCatalog.fingerprint(Array(state.groups.values)), prompt = AIHash.fingerprint(config.prompt)
        let focus: [Clip]
        if trigger == "manual-regroup-all" { focus = eligible }
        else if trigger == "manual-regroup-recent" { let ids = Set(recentRegroupIDs); focus = eligible.filter { ids.contains($0.id) } }
        else if let selection { focus = eligible.filter { selection.memberIDs.contains($0.id) } }
        else if let ids = contentIDs { let selected = Set(ids); focus = eligible.filter { selected.contains($0.id) } }
        else if review {
            let cold = Set(state.groups.keys).subtracting(protected)
            let ungrouped = eligible.filter { $0.collectionIDs.isEmpty && !$0.isArchived && state.automation.decisions[$0.id]?.revision != $0.aiContentRevision }
            let selected = Set(ungrouped.prefix(policy.nightlyItemLimit).map(\.id))
            focus = eligible.filter { !$0.collectionIDs.isDisjoint(with: cold) || selected.contains($0.id) }
        } else if trigger == "idle" {
            let aiIDs = Set(state.groups.keys)
            focus = eligible.filter { clip in
                guard !clip.isArchived, clip.collectionIDs.isDisjoint(with: aiIDs), clip.collectionIDs.isEmpty else { return false }
                guard let decision = state.automation.decisions[clip.id] else { return true }
                return decision.revision != clip.aiContentRevision || decision.promptFingerprint != prompt || decision.catalogFingerprint != catalog
            }
        } else if let groupID { focus = eligible.filter { $0.collectionIDs.contains(groupID) } }
        else if all { focus = eligible }
        else { focus = Array(eligible.filter { !$0.isArchived }.prefix(config.topN)) }
        if focus.isEmpty && !resume {
            if nightly { try await repository.updateAIState { $0.automation.lastNightlyDate = Date() } }
            status = L10n.tr("没有需要整理的内容"); return
        }
        var job: AIJobCheckpoint
        var initiallyDeferred = [Clip]()
        if resume {
            guard let saved = state.checkpoint else { throw AIError.invalid("No resumable analysis") }
            job = saved
            job.failureMessage = nil
            // Batch size and budget edits do not discard already analyzed IDs or draft work.
            job.batchSize = min(20, config.batchSize); job.configurationFingerprint = AIHash.fingerprint(config)
            if let organization = job.organization {
                if let fingerprint = organization.semanticFingerprint, fingerprint != AIThemeCatalog.configurationFingerprint(config) {
                    throw AIError.conflict("The model, prompt or content-sharing scope changed; start a separate analysis")
                }
            }
            let deferred = try AIJobRecovery.reconcile(&job, clips: clipIndex, groups: state.groups, eligibleIDs: allowedIDs,
                                                       minimumThemeMembers: policy.minimumThemeMembers)
            initiallyDeferred = deferred.compactMap { clipIndex[$0] }
            selection = job.organization?.groupSelection
            try selection?.validate(in: state.groups)
        } else {
            guard state.checkpoint == nil else { throw AIError.invalid("Resume or discard the saved task first") }
            job = AIJobCheckpoint(clipIDs: focus.map(\.id), batchSize: min(20, config.batchSize), configurationFingerprint: AIHash.fingerprint(config))
            job.organization = AIJobOrganization(trigger: trigger, revisions: Dictionary(uniqueKeysWithValues: focus.map { ($0.id, $0.aiContentRevision) }), protectedGroupIDs: protected, review: review)
            job.organization?.semanticFingerprint = AIThemeCatalog.configurationFingerprint(config)
            job.organization?.groupSnapshots = state.groups
            job.organization?.requiresThemePlan = review || (trigger.hasPrefix("manual") && state.groups.isEmpty && focus.count >= 18)
            if ["manual-regroup-all", "manual-regroup-recent"].contains(trigger), focus.count >= policy.minimumThemeMembers { job.organization?.requiresThemePlan = true }
            if let selection {
                job.organization?.groupSelection = selection
                job.organization?.groupCleanup = try AIGroupManagement.cleanup(selection, state: state, clips: Array(clipIndex.values))
                job.organization?.requiresThemePlan = catalogGroups.count < policy.maximumGroupCount && focus.count >= policy.minimumThemeMembers
            }
        }
        let scope = Set(job.clipIDs)
        var documents = eligible.filter { scope.contains($0.id) }.map { clip -> AIClipDocument in
            var document = clip.aiDocument(includeNotes: config.includeNotes, includeSource: config.includeSource, includeImageText: config.includeImageText == true)
            document.groupIDs.removeAll { replacedIDs.contains($0) }; return document
        }
        var rules = AIAnalysisRules(); rules.protectedGroupIDs = job.organization?.protectedGroupIDs ?? protected
        rules.allowOverviewRefresh = nightly
        if let groupID { rules.protectedGroupIDs.remove(groupID) }
        rules.allowReassignment = review || groupID != nil
        rules.allowNewGroups = trigger.hasPrefix("manual") && !review && state.groups.count < 6 && job.draft.isThemeReview != true
        if selection != nil { rules.allowNewGroups = false }
        let checkpoint = job, deferredClips = initiallyDeferred
        try await repository.updateAIState { s in
            s.checkpoint = checkpoint
            for clip in deferredClips { s.automation.enqueue(id: clip.id, revision: clip.aiContentRevision) }
            if !trigger.hasPrefix("manual") { s.lastAutomaticRunAt = Date() }
        }
        state.checkpoint = checkpoint
        let repository = repository
        if nightly {
            let now = clock(), day = Calendar.current.startOfDay(for: clock())
            try await repository.updateAIState { s in
                if s.automation.nightlyBudget?.day != day { s.automation.nightlyBudget = AINightlyBudget(now: now) }
            }
            state = try await repository.aiState()
        }
        if job.organization?.requiresThemePlan == true {
            status = selection == nil ? L10n.tr("正在统一规划 6～8 个主题") : L10n.tr("正在规划所选内容的主题")
            var planningConfiguration = config
            if nightly { planningConfiguration.dailyTokenLimit = min(config.dailyTokenLimit, todayTokens + max(0, policy.nightlyTokenLimit - nightlyTokens)) }
            job.draft = try await themePlanner.plan(documents: documents, groups: catalogGroups, protectedIDs: protected,
                                                    candidates: state.automation.candidates, configuration: planningConfiguration, credential: credential,
                                                    ledger: state.usage, runID: job.id, trigger: trigger,
                                                    onUsage: { record in try await repository.updateAIState { $0.usage.append(record) } })
            job.organization?.requiresThemePlan = false
            let planned = job, readIDs = job.draft.planningInputIDs ?? []
            try await repository.updateAIState { s in
                s.checkpoint = planned
                if nightly { s.automation.nightlyBudget?.processedIDs.formUnion(readIDs) }
            }
            rules.allowNewGroups = false
            state = try await repository.aiState()
        }
        let names = Set(try await repository.collections().filter { !replacedIDs.contains($0.id) }.map(\.name))
        while true {
            try Task.checkCancellation()
            try await reloadForAnalysis()
            let deferred = try AIJobRecovery.reconcile(&job, clips: clipIndex, groups: state.groups, eligibleIDs: eligibleClipIDs,
                                                      minimumThemeMembers: policy.minimumThemeMembers)
            let scope = Set(job.clipIDs)
            documents = clipIndex.values.filter { scope.contains($0.id) }.map { clip in
                var document = clip.aiDocument(includeNotes: config.includeNotes, includeSource: config.includeSource, includeImageText: config.includeImageText == true)
                document.groupIDs.removeAll { replacedIDs.contains($0) }; return document
            }
            let refreshed = job, deferredClips = deferred.compactMap { clipIndex[$0] }
            try await repository.updateAIState { s in
                s.checkpoint = refreshed
                for clip in deferredClips { s.automation.enqueue(id: clip.id, revision: clip.aiContentRevision) }
            }
            state.checkpoint = job
            guard job.cursor < job.clipIDs.count else { break }
            if queuedManual != nil { status = L10n.tr("已保存后台进度，准备手动任务"); return }
            if nightly && (sleeping || !policy.isIdleWindow(at: clock()) || idleTime() < policy.idleSeconds ||
                           state.automation.nightlyBudget?.exhausted(policy: policy, now: clock(), tokens: nightlyTokens) == true) {
                status = L10n.tr("夜间整理已保存进度，将在下个闲时窗口继续")
                if state.automation.nightlyBudget?.exhausted(policy: policy, now: clock(), tokens: nightlyTokens) == true {
                    try await repository.updateAIState { $0.automation.lastNightlyDate = Date() }
                }
                return
            }
            var end = min(job.cursor + job.batchSize, job.clipIDs.count)
            if nightly, let budget = state.automation.nightlyBudget {
                var seen = budget.processedIDs, boundary = job.cursor
                while boundary < end {
                    let id = job.clipIDs[boundary]
                    if !seen.contains(id), seen.count >= policy.nightlyItemLimit { break }
                    seen.insert(id); boundary += 1
                }
                end = boundary
            }
            let ids = Array(job.clipIDs[job.cursor..<end])
            let fullDocuments = try await repository.aiContext(ids: ids, includeNotes: config.includeNotes, includeSource: config.includeSource, includeImageText: config.includeImageText == true).map { original -> AIClipDocument in
                var document = original; document.groupIDs.removeAll { replacedIDs.contains($0) }; return document
            }
            let fullByID = Dictionary(uniqueKeysWithValues: fullDocuments.map { ($0.id, $0) })
            let missing = Set(ids).subtracting(fullByID.keys)
            if !missing.isEmpty {
                try AIJobRecovery.reconcile(&job, clips: clipIndex, groups: state.groups, eligibleIDs: eligibleClipIDs.subtracting(missing),
                                            minimumThemeMembers: policy.minimumThemeMembers)
                continue
            }
            let liveIDs = ids.filter { fullByID[$0] != nil }
            if liveIDs.isEmpty { job.cursor = end }
            else {
                status = L10n.tr("正在分批整理：\(job.cursor) / \(job.clipIDs.count)")
                let current = Set(ids), context = documents.filter { !current.contains($0.id) } + fullDocuments
                var bounded = config
                if nightly { bounded.dailyTokenLimit = min(config.dailyTokenLimit, todayTokens + max(0, policy.nightlyTokenLimit - nightlyTokens)) }
                let result = try await analyzer.analyze(documents: context, batchIDs: liveIDs, groups: catalogGroups,
                                                        reservedNames: names, continuing: job.draft, configuration: bounded,
                                                        credential: credential, ledger: state.usage, trigger: trigger, runID: job.id, rules: rules,
                                                        onUsage: { record in try await repository.updateAIState { $0.usage.append(record) } })
                job.draft = result.changeSet
                guard let last = result.analyzedIDs.last, let position = ids.firstIndex(of: last) else { throw AIError.invalid("Analysis made no progress") }
                job.cursor += position + 1
            }
            let checkpoint = job, processed = Set(job.clipIDs.prefix(job.cursor))
            try await repository.updateAIState { s in
                s.checkpoint = checkpoint
                if nightly { s.automation.nightlyBudget?.processedIDs.formUnion(processed) }
            }
            state = try await repository.aiState()
        }
        var result = job.draft
        if let cleanup = job.organization?.groupCleanup {
            result = try AIGroupManagement.combining(cleanup: cleanup, analysis: result)
            result.inputCount = job.clipIDs.count
        }
        result.promptFingerprint = prompt; result.policyFingerprint = config.lifecycle.fingerprint
        result.protectedGroupIDs = rules.protectedGroupIDs
        var decisions = result.decisions ?? [:]
        for (id, var decision) in decisions {
            decision.revision = clipIndex[id]?.aiContentRevision ?? decision.revision
            decision.catalogFingerprint = catalog; decision.promptFingerprint = prompt; decisions[id] = decision
        }
        let completedDecisions = decisions, finished = result, revisions = job.organization?.revisions ?? [:], completedIDs = job.clipIDs
        try await repository.updateAIState { s in
            s.checkpoint = nil
            s.automation.decisions.merge(completedDecisions) { _, new in new }
            s.automation.mergeCandidates(finished.candidates ?? [])
            for id in completedIDs where s.automation.dirty[id]?.revision == revisions[id] { s.automation.dirty.removeValue(forKey: id) }
            if nightly { s.automation.lastNightlyDate = Date() }
            if review { s.automation.lastReviewAt = Date() }
            if let groupID { s.automation.requestedGroupReviews?.remove(groupID) }
            if !finished.commands.isEmpty { s.changes.append(finished) }
        }
        try await reload()
        if finished.commands.isEmpty { status = L10n.tr("分析完成，无关内容保留未分组") }
        else if config.applyMode == .appendExisting && finished.appendOnly {
            try await repository.applyAIChangeSet(finished); try await reload()
            onApplied?(!trigger.hasPrefix("manual"))
            status = L10n.tr("已补充已有 AI 分组，主题与阅读位置保持稳定")
        } else {
            showingReview = !nightly && trigger != "new"
            status = L10n.tr("整理建议已生成，可检查后统一应用")
        }
    }

    func apply(_ original: AIChangeSet, selectedIDs: Set<UUID>) async {
        guard !running else { return }
        if original.fileTaskID != nil {
            let presentation = AIReviewPresentation(draft: original, catalog: state.groups)
            if presentation.requiresRevision(policy: settings.aiConfiguration.organizationPolicy, existingGroupCount: state.groups.count) {
                error = L10n.tr("方案未满足保存的主题数量设置，请在原会话中继续修正。")
                return
            }
        }
        if original.isThemeReview == true, selectedIDs != Set(original.commands.map(\.id)) { error = L10n.tr("主题复核需要整体应用；可以保留建议或放弃本次复核。"); return }
        var proposed = original
        proposed.commands = original.commands.filter { selectedIDs.contains($0.id) }
        guard !proposed.commands.isEmpty else { return }
        error = nil
        do {
            try await repository.applyAIChangeSet(proposed)
            if let id = proposed.fileTaskID, let directories = taskDirectories { try AIFileTaskWorkspace.markStatus("applied", taskID: id, directories: directories) }
            try await reload(); onApplied?(false); status = L10n.tr("整理已应用，可以撤销")
        }
        catch { self.error = error.localizedDescription }
    }
    func reviseFilePlan(_ original: AIChangeSet) async -> Bool {
        guard !running, !storageBusy, pending?.id == original.id,
              let taskID = original.fileTaskID, let directories = taskDirectories else { return false }
        do {
            await queueWrite?.value; try await reloadForAnalysis()
            guard pending?.id == original.id else { return false }
            let directory = directories.aiTasks.appendingPathComponent(taskID.uuidString.lowercased() + ".agent")
            let input = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(AIFileTaskInput.self, from: Data(contentsOf: directory.appendingPathComponent("items.json")))
            }.value
            let archive = directory.appendingPathComponent("revisions/" + original.id.uuidString.lowercased())
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            for name in ["plan.json", "validated-changes.json"] {
                let source = directory.appendingPathComponent("output/" + name), target = archive.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
            }
            var job = AIJobCheckpoint(clipIDs: input.items.map(\.clipID), batchSize: settings.aiConfiguration.batchSize,
                                      configurationFingerprint: AIHash.fingerprint(settings.aiConfiguration))
            job.id = taskID; job.fileTaskVersion = 2; job.draft = original
            job.organization = AIJobOrganization(trigger: "manual-revise", revisions: Dictionary(uniqueKeysWithValues: input.items.map { ($0.clipID, $0.contentRevision) }))
            job.organization?.semanticFingerprint = fileTaskFingerprint(settings.aiConfiguration)
            job.organization?.groupSnapshots = state.groups
            if let selected = original.userSelectedGroupIDs, !selected.isEmpty {
                let groups = selected.compactMap { state.groups[$0] }
                guard groups.count == selected.count else { throw AIError.conflict("The selected groups changed; start a new organization task") }
                job.organization?.groupSelection = AIGroupSelection(groups: groups)
            }
            let checkpoint = job, originalID = original.id
            try await repository.updateAIState { s in
                guard s.checkpoint == nil, let index = s.changes.firstIndex(where: { $0.id == originalID && !$0.isApplied && !$0.isRejected }) else {
                    throw AIError.conflict("The organization task changed")
                }
                s.changes[index].isRejected = true; s.checkpoint = checkpoint
            }
            try AIFileTaskWorkspace.markStatus("revision_requested", taskID: taskID, directories: directories)
            try await reload(); showingReview = false; analyze(resume: true)
            return running
        } catch { self.error = error.localizedDescription; return false }
    }
    func reject(_ original: AIChangeSet) async {
        do {
            try await repository.updateAIState { s in if let index = s.changes.firstIndex(where: { $0.id == original.id }) { s.changes[index].isRejected = true } }
            if let id = original.fileTaskID, let directories = taskDirectories { try AIFileTaskWorkspace.markStatus("rejected", taskID: id, directories: directories) }
            try await reload()
        } catch { self.error = error.localizedDescription }
    }
    func undo() async {
        guard let last = latestUndoable, !running else { return }
        do { try await repository.undoAIChangeSet(last.id); try await reload(); onApplied?(false); status = L10n.tr("已撤销本次整理，原文保持不变") }
        catch { self.error = error.localizedDescription }
    }

    func saveGroup(id: UUID, name: String, definition: String, retained: Bool, expectedVersion: Int) async -> Bool {
        do {
            try await repository.updateAIGroupDefinition(id: id, name: name, definition: definition, retained: retained, expectedVersion: expectedVersion)
            try await repository.updateAIState { s in
                var requested = s.automation.requestedGroupReviews ?? []; requested.insert(id); s.automation.requestedGroupReviews = requested
            }
            try await reload(); onApplied?(false); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func groupActivity(_ profile: AIGroupProfile) -> GroupActivity {
        if cachedActivityPolicy == settings.aiConfiguration.lifecycle,
           cachedGroupActivityRevisions[profile.id] == profile.revision, let cached = cachedGroupActivities[profile.id] { return cached }
        return settings.aiConfiguration.lifecycle.group(profile.memberIDs.compactMap { clipActivities[$0] })
    }
    func compress(groupID: UUID?) async {
        guard !running, !storageBusy else { return }
        storageBusy = true; error = nil
        defer { storageBusy = false }
        do {
            let bytes = try await repository.compressAIGroup(id: groupID, policy: settings.aiConfiguration.lifecycle, now: Date())
            try await reload(); onApplied?(false)
            status = L10n.tr("压缩整理完成，回收原文载荷 \(FileSizeFormatter.string(forByteCount: bytes))")
        } catch { self.error = error.localizedDescription }
    }
}
