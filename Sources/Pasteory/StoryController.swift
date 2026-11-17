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
    var clock: () -> Date = Date.init
    var onUpdated: (@MainActor @Sendable () async -> Void)?

    init(repository: any ClipRepository, settings: AppSettings, directories: AppDirectories? = nil,
         transport: any AIChatTransport = OpenAICompatibleClient(),
         credentialProvider: @escaping () throws -> String = { try AICredentialStore.load() }) {
        self.repository = repository; self.settings = settings; self.directories = directories ?? (try? AppDirectories())
        agent = AIFileAgent(transport: transport); self.credentialProvider = credentialProvider
        configurationObserver = settings.$aiConfiguration.dropFirst().sink { [weak self] configuration in
            if !configuration.enabled || configuration.storyEnabled != true { self?.work?.cancel() }
        }
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

    func generate(resume: Bool = false) {
        guard !running else { return }
        guard settings.aiConfiguration.storyEnabled == true else { return }
        guard settings.aiConfiguration.enabled else {
            error = L10n.tr("请先在模型连接中启用 AI，再生成 Story。")
            return
        }
        running = true; error = nil; status = L10n.tr("正在准备这一周的资料…")
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.running = false; self.work = nil }
            do { try await self.run(resume: resume) }
            catch is CancellationError { self.status = L10n.tr("Story 已暂停，可以继续生成。") }
            catch {
                if Task.isCancelled { self.status = L10n.tr("Story 已暂停，可以继续生成。") }
                else { self.error = error.localizedDescription; self.status = "" }
            }
            await self.load()
            await self.onUpdated?()
        }
    }

    func pause() { work?.cancel() }
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
        let workspace = try AIFileTaskWorkspace(input: input, clips: clips, groups: state.groups, reservedNames: [],
            configuration: configuration, directories: directories, trigger: "story", purpose: .story(checkpoint))
        let prompt = try await workspace.prepare(previousDraft: nil)
        let path = await workspace.directory
        let repository = repository, onUpdated = onUpdated
        do {
            try await agent.run(taskID: checkpoint.id, prompt: prompt, directory: path.path, configuration: configuration,
                credential: credentialProvider(), ledger: state.usage, trigger: "story", workspace: workspace,
                onProgress: { [weak self] _, tool in await self?.progress(reading: tool != nil) },
                onUsage: { record in
                    try await repository.updateAIState { $0.usage.append(record) }
                    try await workspace.recordUsage(record)
                    await onUpdated?()
                })
            try Task.checkCancellation()
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
            try? await workspace.finish(status: Task.isCancelled ? "paused" : "failed", message: error.localizedDescription)
            throw error
        }
    }

    private func progress(reading: Bool) {
        status = reading ? L10n.tr("正在核对这一周的线索…") : L10n.tr("正在写下这一周的 Story…")
    }

    func openTask(_ id: UUID) {
        guard let directories else { return }
        try? FileManager.default.createDirectory(at: directories.aiTasks, withIntermediateDirectories: true)
        let requested = directories.aiTasks.appendingPathComponent(id.uuidString.lowercased() + ".agent")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: requested.path) ? requested : directories.aiTasks)
    }
}
