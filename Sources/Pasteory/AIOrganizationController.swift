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
    @Published private(set) var storageBusy = false
    let repository: any ClipRepository
    let settings: AppSettings
    var onApplied: ((Bool) -> Void)?
    private let analyzer: AIAnalyzer
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
    private var queuedManual: (all: Bool, groupID: UUID?, trigger: String)?
    @Published private(set) var recommendedIDs: [UUID] = []
    @Published private(set) var presentationGroupOrder: [UUID] = []
    private var configurationFingerprint = ""
    private var automaticPaused = false
    private var lastLifecycleRefresh = Date.distantPast

    init(repository: any ClipRepository, settings: AppSettings, transport: any AIChatTransport = OpenAICompatibleClient(),
         credentialProvider: @escaping () throws -> String = { try AICredentialStore.load() }) {
        self.repository = repository; self.settings = settings
        self.analyzer = AIAnalyzer(transport: transport); self.themePlanner = AIThemePlanner(transport: transport)
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
        return "\(job.cursor) / \(job.clipIDs.count)"
    }

    func bootstrap(deferMaintenance: Bool = false) async {
        if deferMaintenance { lastLifecycleRefresh = clock() }
        do { try await reload(); reconfigure(); if state.automation.recommendedIDs.isEmpty { refreshRecommendations() } }
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
        state = try await repository.aiState()
        let clips = try await repository.allClips()
        clipIndex = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        let policy = settings.aiConfiguration.lifecycle
        clipActivities = Dictionary(uniqueKeysWithValues: clips.filter { $0.deletedAt == nil }.map { ($0.id, policy.evaluate($0.activity)) })
    }

    func contentChanged(_ id: UUID) {
        guard let clip = clipIndex[id], clip.mayParticipateInAI else { return }
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
        let ordered = state.groups.values.sorted {
            let left = groupActivity($0).score, right = groupActivity($1).score
            if $0.retained != $1.retained { return $0.retained }
            if left != right { return left > right }
            return $0.id.uuidString < $1.id.uuidString
        }.map(\.id)
        let next = Array(ordered.prefix(count)), old = recommendedIDs.isEmpty ? state.automation.recommendedIDs : recommendedIDs
        recommendedIDs = next; presentationGroupOrder = ordered
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
        guard state.groups[id] != nil else { return }
        let now = clock(), repository = repository
        state.automation.groupOpenedAt[id] = now
        Task { do { try await repository.updateAIState { $0.automation.groupOpenedAt[id] = now } } catch { self.error = error.localizedDescription } }
    }
    var protectedGroups: Set<UUID> {
        let births = Dictionary(state.changes.flatMap { change in change.commands.filter { $0.kind == .createGroup }.map { ($0.targetID, change.createdAt) } }, uniquingKeysWith: min)
        return AIGroupProtection.ids(groups: Array(state.groups.values), automation: state.automation,
                                     activities: clipIndex.mapValues(\.activity), births: births,
                                     reading: readingGroupIDs().union(recommendedIDs), now: clock())
            .union(state.groups.values.filter { group in group.memberIDs.contains { clipIndex[$0]?.mayParticipateInAI != true } }.map(\.id))
    }

    func synchronize(_ clip: Clip) {
        clipIndex[clip.id] = clip
        if clip.deletedAt == nil { clipActivities[clip.id] = settings.aiConfiguration.lifecycle.evaluate(clip.activity) }
        else { clipActivities.removeValue(forKey: clip.id) }
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

    func analyze(all: Bool = false, resume: Bool = false, groupID: UUID? = nil, trigger: String = "manual", contentIDs: [UUID]? = nil) {
        if running {
            if trigger.hasPrefix("manual"), !resume { queuedManual = (all, groupID, trigger); status = L10n.tr("当前批次完成后优先执行手动任务") }
            return
        }
        guard !storageBusy else { return }
        guard settings.aiConfiguration.enabled else { error = L10n.tr("请先在 AI 整理设置中启用模型连接"); return }
        if pending != nil && !(["new", "idle"].contains(trigger) && settings.aiConfiguration.applyMode == .appendExisting && pending?.isThemeReview == true) { showingReview = true; return }
        running = true; error = nil; status = L10n.tr("正在准备分析范围")
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.running = false; self.work = nil
                if let request = self.queuedManual {
                    self.queuedManual = nil
                    self.analyze(all: request.all, groupID: request.groupID, trigger: request.trigger)
                }
            }
            do { try await self.runAnalysis(all: all, resume: resume, groupID: groupID, trigger: trigger, contentIDs: contentIDs) }
            catch is CancellationError { self.status = L10n.tr("分析已暂停，可以继续上次任务") }
            catch {
                self.error = error.localizedDescription
                if case AIError.http(let code, _) = error, code == 401 || code == 403 { self.automaticPaused = true }
                if case AIError.budget = error, ["idle", "review"].contains(self.state.checkpoint?.organization?.trigger ?? "") {
                    let now = self.clock()
                    try? await self.repository.updateAIState { $0.automation.lastNightlyDate = now }
                    self.error = nil; self.status = L10n.tr("夜间整理已保存进度，将在下个闲时窗口继续")
                }
            }
            try? await self.reload()
        }
    }
    func pause() { work?.cancel() }
    func waitUntilIdle() async { await queueWrite?.value; await work?.value }
    func discardCheckpoint() async {
        guard !running else { return }
        do { try await repository.updateAIState { $0.checkpoint = nil }; try await reload() }
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

    private func runAnalysis(all: Bool, resume: Bool, groupID: UUID?, trigger requestedTrigger: String, contentIDs: [UUID]?) async throws {
        await queueWrite?.value
        let config = settings.aiConfiguration, policy = settings.aiConfiguration.organizationPolicy
        try config.validate(); try await reload()
        if !resume, requestedTrigger.hasPrefix("manual") { try await deferAutomaticJob() }
        let credential = try credentialProvider()
        let trigger = resume ? state.checkpoint?.organization?.trigger ?? requestedTrigger : requestedTrigger
        let nightly = ["idle", "review"].contains(trigger)
        let review = trigger == "review" || trigger == "manual-review"
        let protected = protectedGroups
        let eligible = clipIndex.values.filter(\.mayParticipateInAI).sorted {
            $0.lastCopiedAt == $1.lastCopiedAt ? $0.id.uuidString < $1.id.uuidString : $0.lastCopiedAt > $1.lastCopiedAt
        }
        let catalog = AIThemeCatalog.fingerprint(Array(state.groups.values)), prompt = AIHash.fingerprint(config.prompt)
        let focus: [Clip]
        if let ids = contentIDs { let selected = Set(ids); focus = eligible.filter { selected.contains($0.id) } }
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
        if resume {
            guard let saved = state.checkpoint else { throw AIError.invalid("No resumable analysis") }
            job = saved
            // Batch size and budget edits do not discard already analyzed IDs or draft work.
            job.batchSize = min(20, config.batchSize); job.configurationFingerprint = AIHash.fingerprint(config)
            if let organization = job.organization {
                if let fingerprint = organization.semanticFingerprint, fingerprint != AIThemeCatalog.configurationFingerprint(config) {
                    throw AIError.conflict("The model, prompt or content-sharing scope changed; start a separate analysis")
                }
                for (id, revision) in organization.revisions {
                    guard clipIndex[id]?.aiContentRevision == revision else { throw AIError.conflict("Content changed; review or discard the saved task") }
                }
            }
        } else {
            guard state.checkpoint == nil else { throw AIError.invalid("Resume or discard the saved task first") }
            job = AIJobCheckpoint(clipIDs: focus.map(\.id), batchSize: min(20, config.batchSize), configurationFingerprint: AIHash.fingerprint(config))
            job.organization = AIJobOrganization(trigger: trigger, revisions: Dictionary(uniqueKeysWithValues: focus.map { ($0.id, $0.aiContentRevision) }), protectedGroupIDs: protected, review: review)
            job.organization?.semanticFingerprint = AIThemeCatalog.configurationFingerprint(config)
            job.organization?.requiresThemePlan = review || (trigger.hasPrefix("manual") && state.groups.isEmpty && focus.count >= 18)
        }
        let scope = Set(job.clipIDs)
        let documents = eligible.filter { scope.contains($0.id) }.map { $0.aiDocument(includeNotes: config.includeNotes, includeSource: config.includeSource) }
        var rules = AIAnalysisRules(); rules.protectedGroupIDs = job.organization?.protectedGroupIDs ?? protected
        rules.allowOverviewRefresh = nightly
        if let groupID { rules.protectedGroupIDs.remove(groupID) }
        rules.allowReassignment = review || groupID != nil
        rules.allowNewGroups = trigger.hasPrefix("manual") && !review && state.groups.count < 6 && job.draft.isThemeReview != true
        let checkpoint = job
        try await repository.updateAIState { s in s.checkpoint = checkpoint; if trigger != "manual" && trigger != "manual-review" { s.lastAutomaticRunAt = Date() } }
        let repository = repository
        if nightly {
            let now = clock(), day = Calendar.current.startOfDay(for: clock())
            try await repository.updateAIState { s in
                if s.automation.nightlyBudget?.day != day { s.automation.nightlyBudget = AINightlyBudget(now: now) }
            }
            state = try await repository.aiState()
        }
        if job.organization?.requiresThemePlan == true {
            status = L10n.tr("正在统一规划 6～8 个主题")
            var planningConfiguration = config
            if nightly { planningConfiguration.dailyTokenLimit = min(config.dailyTokenLimit, todayTokens + max(0, policy.nightlyTokenLimit - nightlyTokens)) }
            job.draft = try await themePlanner.plan(documents: documents, groups: Array(state.groups.values), protectedIDs: protected,
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
        let initialCursor = job.cursor
        let names = Set(try await repository.collections().map(\.name))
        while job.cursor < job.clipIDs.count {
            try Task.checkCancellation()
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
            let fullDocuments = try await repository.aiContext(ids: ids, includeNotes: config.includeNotes, includeSource: config.includeSource)
            let fullByID = Dictionary(uniqueKeysWithValues: fullDocuments.map { ($0.id, $0) })
            let liveIDs = ids.filter { fullByID[$0] != nil }
            if liveIDs.isEmpty { job.cursor = end }
            else {
                status = L10n.tr("正在分批整理：\(job.cursor) / \(job.clipIDs.count)")
                let current = Set(ids), context = documents.filter { !current.contains($0.id) } + fullDocuments
                var bounded = config
                if nightly { bounded.dailyTokenLimit = min(config.dailyTokenLimit, todayTokens + max(0, policy.nightlyTokenLimit - nightlyTokens)) }
                let result = try await analyzer.analyze(documents: context, batchIDs: liveIDs, groups: Array(state.groups.values),
                                                        reservedNames: names, continuing: job.draft, configuration: bounded,
                                                        credential: credential, ledger: state.usage, trigger: trigger, runID: job.id, rules: rules,
                                                        onUsage: { record in try await repository.updateAIState { $0.usage.append(record) } })
                job.draft = result.changeSet
                guard let last = result.analyzedIDs.last, let position = ids.firstIndex(of: last) else { throw AIError.invalid("Analysis made no progress") }
                job.cursor += position + 1
            }
            let checkpoint = job, processed = Set(job.clipIDs[initialCursor..<job.cursor])
            try await repository.updateAIState { s in
                s.checkpoint = checkpoint
                if nightly { s.automation.nightlyBudget?.processedIDs.formUnion(processed) }
            }
            state = try await repository.aiState()
        }
        var result = job.draft
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
        if original.isThemeReview == true, selectedIDs != Set(original.commands.map(\.id)) { error = L10n.tr("主题复核需要整体应用；可以保留建议或放弃本次复核。"); return }
        var proposed = original
        proposed.commands = original.commands.filter { selectedIDs.contains($0.id) }
        guard !proposed.commands.isEmpty else { return }
        do { try await repository.applyAIChangeSet(proposed); try await reload(); onApplied?(false); status = L10n.tr("整理已应用，可以撤销") }
        catch { self.error = error.localizedDescription }
    }
    func reject(_ original: AIChangeSet) async {
        do {
            try await repository.updateAIState { s in if let index = s.changes.firstIndex(where: { $0.id == original.id }) { s.changes[index].isRejected = true } }
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
        settings.aiConfiguration.lifecycle.group(profile.memberIDs.compactMap { clipActivities[$0] })
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
