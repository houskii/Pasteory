import AppKit
import Combine
import Foundation
import PasteoryAI
import PasteoryCore

@MainActor
final class StoryController: ObservableObject {
    @Published private(set) var reports: [AIStoryReport] = []
    @Published private(set) var checkpoint: AIStoryCheckpoint?
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    private let repository: any ClipRepository
    private let settings: AppSettings
    private let directories: AppDirectories?
    private let agent: AIFileAgent
    private let credentialProvider: () throws -> String
    private var work: Task<Void, Never>?
    private var configurationObserver: AnyCancellable?
    private var workspaceObservers = Set<AnyCancellable>()
    private var sleeping = false
    private var automationStarted = false
    private var automaticRun = false
    private var automaticRequiresIdle = false
    private var storyWasEnabled = false
    var clock: () -> Date = Date.init
    var idleTime: () -> TimeInterval = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null) }
    var organizationBusy: () -> Bool = { false }
    var onUpdated: (@MainActor @Sendable () async -> Void)?

    init(repository: any ClipRepository, settings: AppSettings, directories: AppDirectories? = nil,
         transport: any AIChatTransport = OpenAICompatibleClient(),
         credentialProvider: @escaping () throws -> String = { try AICredentialStore.load() }) {
        self.repository = repository; self.settings = settings; self.directories = directories ?? (try? AppDirectories())
        storyWasEnabled = settings.aiConfiguration.storyEnabled == true
        agent = AIFileAgent(transport: transport); self.credentialProvider = credentialProvider
        configurationObserver = settings.$aiConfiguration.dropFirst().sink { [weak self] configuration in
            guard let self else { return }
            if !self.storyWasEnabled, configuration.storyEnabled == true {
                self.settings.defaults.set(false, forKey: "storyAutomationPaused")
            }
            self.storyWasEnabled = configuration.storyEnabled == true
            if !configuration.enabled || configuration.storyEnabled != true { self.work?.cancel() }
            else {
                if let saved = self.checkpoint, saved.sharingFingerprint != AIStoryCheckpoint.sharingFingerprint(configuration) { self.work?.cancel() }
                if self.automationStarted {
                    self.settings.defaults.removeObject(forKey: "storyLastAutomaticAttempt")
                    Task { await self.tick() }
                }
            }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true
                if self?.automaticRun == true { self?.work?.cancel() }
            }
        }.store(in: &workspaceObservers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                if self?.automationStarted == true { await self?.tick() }
            }
        }.store(in: &workspaceObservers)
    }

    func startAutomation() async {
        automationStarted = true
        await load()
        await tick()
    }

    func tick() async {
        let configuration = settings.aiConfiguration, now = clock()
        guard configuration.enabled, configuration.storyEnabled == true, !running, !sleeping, !organizationBusy(),
              !settings.defaults.bool(forKey: "storyAutomationPaused"),
              (try? configuration.validate()) != nil else { return }
        guard checkpoint != nil || AIStorySchedule.isDue(reports.first, now: now) else { return }
        // A format migration is an update to an existing report and uses the
        // same idle requirement as a weekly refresh.
        guard canStartWithoutWaitingForIdle else {
            status = L10n.tr("Story 将在设备空闲时静默更新。")
            return
        }
        if let attempt = settings.defaults.object(forKey: "storyLastAutomaticAttempt") as? Date,
           now.timeIntervalSince(attempt) < 3_600 { return }
        guard let state = try? await repository.aiState() else { return }
        let start = Calendar.current.startOfDay(for: now), today = state.usage.filter { $0.date >= start }
        let automaticJobs = Set(today.filter { ["new", "idle", "review"].contains($0.trigger) || $0.automatic == true }.map(\.runID))
        guard today.reduce(0, { $0 + $1.totalTokens }) < configuration.dailyTokenLimit,
              automaticJobs.count < configuration.dailyAutomaticRuns else {
            status = L10n.tr("今日 AI 预算或自动任务额度已用完，Story 将在额度恢复后更新。")
            return
        }
        var canResume = checkpoint?.promptVersion == AIStorySchedule.promptVersion &&
            checkpoint?.sharingFingerprint == AIStoryCheckpoint.sharingFingerprint(configuration) &&
            checkpoint.map { now.timeIntervalSince($0.periodEnd) < AIStorySchedule.interval } == true
        guard let metadata = try? await repository.clipMetadataChanges(since: nil) else { return }
        if canResume, let checkpoint, let directories {
            let allowed = Set(metadata.upserts.filter(\.mayParticipateInAI).map(\.id))
            let file = directories.aiTasks.appendingPathComponent(checkpoint.id.uuidString.lowercased() + ".agent/items.json")
            canResume = (try? await Task.detached(priority: .utility) {
                let input = try JSONDecoder().decode(AIFileTaskInput.self, from: Data(contentsOf: file))
                return input.items.filter { !$0.sharingExcluded }.allSatisfy { allowed.contains($0.clipID) }
            }.value) == true
        }
        let period = DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
        guard canResume || metadata.upserts.contains(where: { Self.includes($0, in: period) }) else {
            status = L10n.tr("最近 7 天还没有可用于 Story 的内容，留下新记录后会自动生成。")
            return
        }
        guard settings.aiConfiguration == configuration, !running, !sleeping, !organizationBusy(),
              !settings.defaults.bool(forKey: "storyAutomationPaused"), canStartWithoutWaitingForIdle else { return }
        settings.defaults.set(now, forKey: "storyLastAutomaticAttempt")
        generate(resume: canResume, automatic: true)
    }

    func load() async {
        do {
            let state = try await repository.aiState()
            reports = (state.stories ?? []).sorted { $0.generatedAt > $1.generatedAt }
            checkpoint = state.storyCheckpoint
        } catch { self.error = error.localizedDescription }
    }

    static func includes(_ clip: Clip, in period: DateInterval) -> Bool {
        guard clip.deletedAt == nil, clip.mayParticipateInAI else { return false }
        // Persistence represents dates in milliseconds. Compare at that same
        // precision so a round trip cannot exclude an item at the boundary.
        let start = (period.start.timeIntervalSince1970 * 1_000).rounded()
        let end = (period.end.timeIntervalSince1970 * 1_000).rounded()
        return [clip.lastCopiedAt, clip.lastPastedAt].compactMap { $0 }
            .contains {
                let milliseconds = ($0.timeIntervalSince1970 * 1_000).rounded()
                return milliseconds >= start && milliseconds <= end
            }
    }

    func generate(resume: Bool = false, automatic: Bool = false) {
        guard !running else { return }
        guard settings.aiConfiguration.storyEnabled == true else { return }
        guard settings.aiConfiguration.enabled else {
            error = L10n.tr("请先在模型连接中启用 AI，再生成 Story。")
            return
        }
        if !automatic { settings.defaults.set(false, forKey: "storyAutomationPaused") }
        automaticRun = automatic
        automaticRequiresIdle = automatic && !reports.isEmpty
        running = true; error = nil; status = L10n.tr("正在准备这一周的资料…")
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.running = false; self.work = nil; self.automaticRun = false }
            do { try await self.run(resume: resume) }
            catch is CancellationError { self.recordPause(automatic: automatic) }
            catch {
                if Task.isCancelled { self.recordPause(automatic: automatic) }
                else { self.error = error.localizedDescription; self.status = "" }
            }
            await self.load()
            await self.onUpdated?()
        }
    }

    func pause() { settings.defaults.set(true, forKey: "storyAutomationPaused"); work?.cancel() }
    func waitUntilIdle() async { await work?.value }

    private func run(resume: Bool) async throws {
        guard let directories else { throw AIError.unavailable }
        let configuration = settings.aiConfiguration
        try configuration.validate()
        let state = try await repository.aiState()
        let checkpoint: AIStoryCheckpoint
        let input: AIFileTaskInput
        let clips: [Clip]
        if resume, let saved = state.storyCheckpoint {
            guard saved.sharingFingerprint == AIStoryCheckpoint.sharingFingerprint(configuration) else {
                throw AIError.invalid(L10n.tr("内容分享设置已变化，请重新生成 Story。"))
            }
            checkpoint = saved
            let file = directories.aiTasks.appendingPathComponent(saved.id.uuidString.lowercased() + ".agent/items.json")
            input = try JSONDecoder().decode(AIFileTaskInput.self, from: Data(contentsOf: file))
            clips = try await repository.clips(ids: input.items.map(\.clipID))
            let allowed = Set(clips.filter(\.mayParticipateInAI).map(\.id))
            guard input.items.filter({ !$0.sharingExcluded }).allSatisfy({ allowed.contains($0.clipID) }) else {
                throw AIError.invalid(L10n.tr("有资料已退出 AI 分析范围，请按当前资料重新生成 Story。"))
            }
        } else {
            let end = clock(), start = end.addingTimeInterval(-7 * 86_400)
            checkpoint = AIStoryCheckpoint(periodStart: start, periodEnd: end, language: settings.appLanguage.rawValue,
                sharingFingerprint: AIStoryCheckpoint.sharingFingerprint(configuration))
            let metadata = try await repository.clipMetadataChanges(since: nil)
            let period = DateInterval(start: start, end: end)
            let candidates = metadata.upserts.filter { Self.includes($0, in: period) }.sorted {
                let left = max($0.lastCopiedAt, $0.lastPastedAt ?? $0.lastCopiedAt)
                let right = max($1.lastCopiedAt, $1.lastPastedAt ?? $1.lastCopiedAt)
                return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
            }
            guard !candidates.isEmpty else { throw AIError.invalid(L10n.tr("最近 7 天还没有可用于 Story 的内容。")) }
            clips = try await repository.clips(ids: candidates.map(\.id))
            input = try await AIFileTaskExporter.input(clips: clips, taskID: checkpoint.id, configuration: configuration,
                directories: directories, includeActivityDates: true)
            guard input.items.contains(where: { !$0.sharingExcluded }) else {
                throw AIError.invalid(L10n.tr("最近 7 天还没有可用于 Story 的内容。"))
            }
            if let old = state.storyCheckpoint { try AIFileTaskWorkspace.markStatus("superseded", taskID: old.id, directories: directories) }
        }
        try Task.checkCancellation()
        let saved = checkpoint
        try await repository.updateAIState { $0.storyCheckpoint = saved }
        self.checkpoint = checkpoint
        let allowed = Dictionary(uniqueKeysWithValues: input.items.filter { !$0.sharingExcluded }.map { ($0.clipID, $0.contentRevision) })
        let previous = (state.stories ?? []).filter { report in
            report.sharingFingerprint == checkpoint.sharingFingerprint && !report.sourceRevisions.isEmpty &&
                report.sourceRevisions.allSatisfy { allowed[$0.key] == $0.value }
        }.sorted { $0.generatedAt > $1.generatedAt }.prefix(3).map(\.encouragement)
        let workspace = try AIFileTaskWorkspace(input: input, clips: clips, groups: state.groups, reservedNames: [],
            configuration: configuration, directories: directories, trigger: "story", purpose: .story(checkpoint),
            previousEncouragements: previous)
        let prompt = try await workspace.prepare(previousDraft: nil)
        let path = await workspace.directory
        let repository = repository, onUpdated = onUpdated, automatic = automaticRun
        do {
            try await agent.run(taskID: checkpoint.id, prompt: prompt, directory: path.path, configuration: configuration,
                credential: credentialProvider(), ledger: state.usage, trigger: "story", workspace: workspace,
                onProgress: { [weak self] _, tool in
                    if await self?.shouldPauseAutomaticWork() == true { throw CancellationError() }
                    await self?.progress(reading: tool != nil)
                },
                onUsage: { record in
                    var record = record; record.automatic = automatic
                    let usage = record
                    try await repository.updateAIState { $0.usage.append(usage) }
                    try await workspace.recordUsage(record)
                    await onUpdated?()
                })
            try Task.checkCancellation()
            if shouldPauseAutomaticWork() { throw CancellationError() }
            let report = try await workspace.storyResult()
            try await workspace.saveValidatedStory(report)
            try await repository.updateAIState { state in
                var stories = state.stories ?? []
                stories.removeAll { $0.id == report.id }; stories.append(report)
                state.stories = Array(stories.sorted { $0.generatedAt < $1.generatedAt }.suffix(30))
                if state.storyCheckpoint?.id == saved.id { state.storyCheckpoint = nil }
            }
            try await workspace.finish(status: "completed")
            status = L10n.tr("这一周的 Story 已生成。")
        } catch {
            try? await workspace.finish(status: Task.isCancelled || error is CancellationError ? "paused" : "failed", message: error.localizedDescription)
            throw error
        }
    }

    private func progress(reading: Bool) {
        status = reading ? L10n.tr("正在核对这一周的线索…") : L10n.tr("正在写下这一周的 Story…")
    }

    private func shouldPauseAutomaticWork() -> Bool {
        automaticRun && (sleeping || organizationBusy() || (automaticRequiresIdle && idleTime() < settings.aiConfiguration.organizationPolicy.idleSeconds))
    }

    private var canStartWithoutWaitingForIdle: Bool {
        reports.isEmpty || idleTime() >= settings.aiConfiguration.organizationPolicy.idleSeconds
    }

    private func recordPause(automatic: Bool) {
        if automatic && !settings.defaults.bool(forKey: "storyAutomationPaused") {
            settings.defaults.removeObject(forKey: "storyLastAutomaticAttempt")
            status = L10n.tr("Story 将在下次闲时继续更新。")
        } else { status = L10n.tr("Story 已暂停，可以继续生成。") }
    }

    func openTask(_ id: UUID) {
        guard let directories else { return }
        try? FileManager.default.createDirectory(at: directories.aiTasks, withIntermediateDirectories: true)
        let requested = directories.aiTasks.appendingPathComponent(id.uuidString.lowercased() + ".agent")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: requested.path) ? requested : directories.aiTasks)
    }
}
