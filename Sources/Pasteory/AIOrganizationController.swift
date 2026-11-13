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
    var onApplied: (() -> Void)?
    private let analyzer = AIAnalyzer()
    private let client = OpenAICompatibleClient()
    private var work: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?
    private var dirtyIDs = Set<UUID>()
    private var oldestDirty: Date?
    private var newestDirty: Date?
    private var nextTimer = Date.distantFuture
    private var configurationFingerprint = ""
    private var automaticPaused = false
    private var lastLifecycleRefresh = Date.distantPast

    init(repository: any ClipRepository, settings: AppSettings) {
        self.repository = repository; self.settings = settings
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
    var todayAutomaticRuns: Int { Set(todayUsage.filter { ["new", "timer"].contains($0.trigger) }.map(\.runID)).count }
    var checkpointProgress: String {
        guard let job = state.checkpoint else { return "" }
        return "\(job.cursor) / \(job.clipIDs.count)"
    }

    func bootstrap() async {
        do { try await reload(); reconfigure() }
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
        dirtyIDs.insert(id); newestDirty = Date()
        if oldestDirty == nil { oldestDirty = newestDirty }
    }
    private func reconfigure() {
        let config = settings.aiConfiguration
        let fingerprint = AIHash.fingerprint(config)
        guard fingerprint != configurationFingerprint else { return }
        configurationFingerprint = fingerprint; automaticPaused = false
        nextTimer = Date().addingTimeInterval(Double(max(1, config.intervalMinutes)) * 60)
        if !config.enabled { work?.cancel() }
        lastLifecycleRefresh = .distantPast
    }

    private func tick() async {
        let config = settings.aiConfiguration
        if !running && Date().timeIntervalSince(lastLifecycleRefresh) >= 300 {
            do {
                _ = try await repository.purgeTrash(olderThan: Date().addingTimeInterval(-30 * 86_400))
                try await reload(); lastLifecycleRefresh = Date()
                if config.lifecycleEnabled && config.automaticCompression && !storageBusy {
                    await compress(groupID: nil)
                }
            } catch { self.error = error.localizedDescription }
        }
        guard config.enabled, !running, pending == nil, state.checkpoint == nil, !automaticPaused,
              todayAutomaticRuns < config.dailyAutomaticRuns else { return }
        let now = Date()
        let timerDue = config.timerEnabled && now >= nextTimer
        if timerDue { nextTimer = now.addingTimeInterval(Double(config.intervalMinutes) * 60) }
        let enoughChanges = dirtyIDs.count >= 5 || oldestDirty.map { now.timeIntervalSince($0) >= 120 } == true
        let quiet = newestDirty.map { now.timeIntervalSince($0) >= 30 } == true
        let minimumInterval = state.lastAutomaticRunAt.map { now.timeIntervalSince($0) >= 300 } ?? true
        if minimumInterval && !dirtyIDs.isEmpty && (timerDue || (config.analyzeNew && enoughChanges && quiet)) {
            analyze(trigger: timerDue ? "timer" : "new")
        }
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
            try await reload(); status = L10n.tr("模型连接和工具协议测试通过")
        } catch { self.error = error.localizedDescription; try? await reload() }
    }

    func analyze(all: Bool = false, resume: Bool = false, groupID: UUID? = nil, trigger: String = "manual") {
        guard !running, !storageBusy else { return }
        guard settings.aiConfiguration.enabled else { error = L10n.tr("请先在 AI 整理设置中启用模型连接"); return }
        if pending != nil { showingReview = true; return }
        running = true; error = nil; status = L10n.tr("正在准备分析范围")
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.running = false; self.work = nil }
            do { try await self.runAnalysis(all: all, resume: resume, groupID: groupID, trigger: trigger) }
            catch is CancellationError { self.status = L10n.tr("分析已暂停，可以继续上次任务") }
            catch {
                self.error = error.localizedDescription
                if case AIError.http(let code, _) = error, code == 401 || code == 403 { self.automaticPaused = true }
            }
            try? await self.reload()
        }
    }
    func pause() { work?.cancel() }
    func discardCheckpoint() async {
        guard !running else { return }
        do { try await repository.updateAIState { $0.checkpoint = nil }; try await reload() }
        catch { self.error = error.localizedDescription }
    }

    private func runAnalysis(all: Bool, resume: Bool, groupID: UUID?, trigger: String) async throws {
        let config = settings.aiConfiguration
        try config.validate(); try await reload()
        let credential = try AICredentialStore.load()
        let eligible = clipIndex.values.filter(\.mayParticipateInAI).sorted {
            $0.lastCopiedAt == $1.lastCopiedAt ? $0.id.uuidString < $1.id.uuidString : $0.lastCopiedAt > $1.lastCopiedAt
        }
        let documents = eligible.map { $0.aiDocument(includeNotes: config.includeNotes, includeSource: config.includeSource) }
        let focus: [Clip]
        if let groupID { focus = eligible.filter { $0.collectionIDs.contains(groupID) } }
        else if all { focus = eligible }
        else { focus = Array(eligible.filter { !$0.isArchived }.prefix(config.topN)) }
        guard !focus.isEmpty else { status = L10n.tr("没有可参与 AI 分析的内容"); return }
        let fingerprint = AIHash.fingerprint(focus.map { $0.aiRevision } + [AIHash.fingerprint(config)])
        if trigger != "manual" && state.lastSnapshotFingerprint == fingerprint {
            dirtyIDs.removeAll(); oldestDirty = nil; newestDirty = nil; status = L10n.tr("内容没有变化，已跳过分析"); return
        }
        var job: AIJobCheckpoint
        if resume {
            guard let saved = state.checkpoint else { throw AIError.invalid("No resumable analysis") }
            guard saved.configurationFingerprint == AIHash.fingerprint(config) else { throw AIError.conflict("Configuration changed; discard the old task before starting again") }
            job = saved
        } else {
            guard state.checkpoint == nil else { throw AIError.invalid("Resume or discard the existing analysis first") }
            job = AIJobCheckpoint(clipIDs: focus.map(\.id), batchSize: config.batchSize, configurationFingerprint: AIHash.fingerprint(config))
        }
        let checkpoint = job
        let started = Date()
        try await repository.updateAIState { s in s.checkpoint = checkpoint; if trigger != "manual" { s.lastAutomaticRunAt = started } }
        let names = Set(try await repository.collections().map(\.name))
        let repository = repository
        while job.cursor < job.clipIDs.count {
            try Task.checkCancellation()
            let end = min(job.cursor + job.batchSize, job.clipIDs.count)
            let ids = Array(job.clipIDs[job.cursor..<end])
            let liveIDs = ids.filter { clipIndex[$0]?.mayParticipateInAI == true }
            if liveIDs.isEmpty { job.cursor = end }
            else {
                status = L10n.tr("正在分批整理：\(job.cursor) / \(job.clipIDs.count)")
                let result = try await analyzer.analyze(documents: documents, batchIDs: liveIDs,
                                                        groups: Array(state.groups.values), reservedNames: names, continuing: job.draft,
                                                        configuration: config, credential: credential, ledger: state.usage,
                                                        trigger: trigger, runID: job.id,
                                                        onUsage: { record in try await repository.updateAIState { $0.usage.append(record) } })
                job.draft = result.changeSet
                guard let last = result.analyzedIDs.last, let position = ids.firstIndex(of: last) else { throw AIError.invalid("Analysis made no progress") }
                job.cursor += position + 1
            }
            let checkpoint = job
            try await repository.updateAIState { $0.checkpoint = checkpoint }
            // Read back accounting and externally edited group definitions without
            // mutating the original dataset snapshot used for concurrency checks.
            state = try await repository.aiState()
        }
        var result = job.draft
        result.promptFingerprint = AIHash.fingerprint(config.prompt)
        result.policyFingerprint = config.lifecycle.fingerprint
        let finished = result
        try await repository.updateAIState { s in
            s.checkpoint = nil; s.lastSnapshotFingerprint = fingerprint
            if !finished.commands.isEmpty { s.changes.append(finished) }
        }
        dirtyIDs.subtract(job.clipIDs); if dirtyIDs.isEmpty { oldestDirty = nil; newestDirty = nil }
        try await reload()
        if finished.commands.isEmpty { status = L10n.tr("分析完成，没有需要应用的变更") }
        else if config.applyMode == .appendExisting && finished.appendOnly {
            try await repository.applyAIChangeSet(finished); try await reload(); onApplied?()
            status = L10n.tr("已自动补充已有 AI 分组")
        } else { showingReview = true; status = L10n.tr("整理建议已生成，请检查后应用") }
    }

    func apply(_ original: AIChangeSet, selectedIDs: Set<UUID>) async {
        guard !running else { return }
        var proposed = original
        proposed.commands = original.commands.filter { selectedIDs.contains($0.id) }
        guard !proposed.commands.isEmpty else { return }
        do { try await repository.applyAIChangeSet(proposed); try await reload(); onApplied?(); status = L10n.tr("整理已应用，可以撤销") }
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
        do { try await repository.undoAIChangeSet(last.id); try await reload(); onApplied?(); status = L10n.tr("已撤销本次整理，原文保持不变") }
        catch { self.error = error.localizedDescription }
    }

    func saveGroup(id: UUID, name: String, definition: String, retained: Bool, expectedVersion: Int) async -> Bool {
        do {
            try await repository.updateAIGroupDefinition(id: id, name: name, definition: definition, retained: retained, expectedVersion: expectedVersion)
            contentChanged(id); try await reload(); onApplied?(); return true
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
            try await reload(); onApplied?()
            status = L10n.tr("压缩整理完成，回收原文载荷 \(FileSizeFormatter.string(forByteCount: bytes))")
        } catch { self.error = error.localizedDescription }
    }
}
