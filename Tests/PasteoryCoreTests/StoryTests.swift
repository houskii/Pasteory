import Foundation
import PasteoryAI
import PasteoryCore
import Testing
@testable import Pasteory

private let storyNow = Date(timeIntervalSince1970: 1_800_000_000)

private func storyClip(_ text: String, daysAgo: Double = 0) -> Clip {
    let date = storyNow.addingTimeInterval(-daysAgo * 86_400)
    return Clip(createdAt: date, updatedAt: date, lastCopiedAt: date, primaryKind: .text,
        source: .init(appName: "Story tests"), previewText: text, contentHash: UUID().uuidString, byteSize: text.utf8.count,
        items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", storage: .inline(Data(text.utf8)))])])
}

private actor StoryTestTransport: AIChatTransport {
    var requests = 0
    var executions = 0
    var holdFinal: Bool
    init(holdFinal: Bool = false) { self.holdFinal = holdFinal }
    func unblock() { holdFinal = false }
    func completion(body: Data, configuration: AIConfiguration, credential: String) async throws -> Data {
        requests += 1
        let message: AIChatMessage
        if executions == 0 {
            executions += 1
            let script = """
            python3 - <<'PY'
            import json,pathlib
            p=pathlib.Path('.')
            data=json.loads((p/'items.json').read_text())
            allowed=[x for x in data['items'] if not x['sharing_excluded']]
            items=[allowed[0]] if len(allowed)==1 else [allowed[0],allowed[-1]]
            def section(x):
                return {'title':'工具验证','text':'你最近在核对工具的实际使用结果。','evidence':[{'item_id':x['item_id'],'quote':x['body'][:100]}]}
            result={'task_id':data['task_id'],'title':'这一周，你在把工具做顺手','introduction':'你最近留下的记录围绕工具的细节和验证。','recent_work':[section(x) for x in items],'observations':[section(items[0])],'encouragement':'把一个细节做顺，也是在减少每天的摩擦。'}
            (p/'output/plan.json').write_text(json.dumps(result,ensure_ascii=False))
            print('Story scope:',len(allowed))
            PY
            """
            message = .init(role: "assistant", toolCalls: [.init(id: "write-story", name: "task_exec",
                arguments: JSONValue.object(["command": .string(script)]).encoded)])
        } else {
            let request = try JSONDecoder().decode(JSONValue.self, from: body)
            if let tool = request["messages"].array?.last(where: { $0["role"].string == "tool" })?["content"].string {
                let result = try JSONDecoder().decode(JSONValue.self, from: Data(tool.utf8))
                guard result["exit_code"].number == 0 else { throw AIError.invalid("Story fixture tool failed: " + tool) }
            }
            if holdFinal { try await Task.sleep(for: .seconds(60)) }
            message = .init(role: "assistant", content: "Story is ready")
        }
        return try JSONEncoder().encode(JSONValue.object([
            "model": .string("synthetic-story"), "choices": .array([.object(["message": try .value(message)])]),
            "usage": .object(["prompt_tokens": .number(100), "completion_tokens": .number(50)])
        ]))
    }
}

@MainActor private final class StoryIdleFixture { var readyToResume = false }

@Test @MainActor func periodicStoryPausesForUserActivityAndResumesAutomaticallyWithoutRerequestingItsPlan() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    try await f.repository.save(storyClip("A retained source at the weekly boundary"))
    let first = f.controller(StoryTestTransport())
    first.generate(); await first.waitUntilIdle()
    let idle = StoryIdleFixture(), transport = StoryTestTransport()
    let controller = f.controller(transport)
    controller.clock = { storyNow.addingTimeInterval(AIStorySchedule.interval) }
    controller.idleTime = { [weak controller] in
        guard !idle.readyToResume, let task = controller?.checkpoint?.id else { return 600 }
        let output = f.directories.aiTasks.appendingPathComponent(task.uuidString.lowercased() + ".agent/output/plan.json")
        // The user returns after the tool saved its work. That completed tool
        // must survive the pause; the next idle period continues the same task.
        return FileManager.default.fileExists(atPath: output.path) ? 0 : 600
    }
    await controller.load(); await controller.tick(); await controller.waitUntilIdle()
    #expect(controller.reports.count == 1 && controller.checkpoint != nil && controller.error == nil)
    #expect(!f.defaults.bool(forKey: "storyAutomationPaused"))
    let requests = await transport.requests
    await controller.tick(); await controller.waitUntilIdle()
    #expect(await transport.requests == requests)
    idle.readyToResume = true
    await controller.tick(); await controller.waitUntilIdle()
    #expect(controller.error == nil, "\(controller.error ?? "")")
    #expect(controller.reports.count == 2 && controller.checkpoint == nil && controller.error == nil)
    #expect(await transport.requests == 2)
}

@MainActor
private final class StoryFixture {
    let suite = "Pasteory.StoryTests.\(UUID())"
    let defaults: UserDefaults
    let directories: AppDirectories
    let repository: SQLiteClipRepository
    let settings: AppSettings
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        directories = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent("Story-\(UUID())"))
        repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
        settings = AppSettings(defaults: defaults)
        settings.aiConfiguration.enabled = true; settings.aiConfiguration.storyEnabled = true
        settings.aiConfiguration.model = "synthetic-story"; settings.aiConfiguration.topN = 100
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directories.root) }
    func controller(_ transport: StoryTestTransport) -> StoryController {
        let controller = StoryController(repository: repository, settings: settings, directories: directories,
            transport: transport, credentialProvider: { "" })
        controller.clock = { storyNow }
        return controller
    }
}

@Test @MainActor func storyEntryIsOptionalAndAppearsAboveTheLibrary() throws {
    #expect(SettingsDestination.primaryDestinations(storyEnabled: false) == [.library])
    #expect(SettingsDestination.primaryDestinations(storyEnabled: true) == [.story, .library])
    var configuration = try JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(AIConfiguration()))
    #expect(configuration.storyEnabled == true)
    configuration.storyEnabled = true
    #expect(try JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(configuration)).storyEnabled == true)
    let legacy = try JSONDecoder().decode(AIOrganizationState.self, from: JSONEncoder().encode(AIOrganizationState()))
    #expect(legacy.stories == nil && legacy.storyCheckpoint == nil)
}

@Test @MainActor func firstStoryGeneratesAutomaticallyAndWeeklyRefreshWaitsForIdle() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    try await f.repository.save(storyClip("A synthetic weekly source"))
    let transport = StoryTestTransport(), first = f.controller(transport)
    first.idleTime = { 0 }
    await first.tick(); await first.waitUntilIdle()
    #expect(first.reports.count == 1 && first.reports.first?.promptVersion == AIStorySchedule.promptVersion)
    let usage = try await f.repository.aiState().usage
    #expect(!usage.isEmpty && usage.allSatisfy { $0.automatic == true })
    let requests = await transport.requests
    await first.tick(); await first.waitUntilIdle()
    #expect(await transport.requests == requests)
    let nextTransport = StoryTestTransport(), next = f.controller(nextTransport)
    await next.load(); next.idleTime = { 600 }
    next.clock = { storyNow.addingTimeInterval(AIStorySchedule.interval - 1) }
    await next.tick(); await next.waitUntilIdle()
    #expect(await nextTransport.requests == 0)
    next.clock = { storyNow.addingTimeInterval(AIStorySchedule.interval) }; next.idleTime = { 0 }
    await next.tick(); await next.waitUntilIdle()
    #expect(await nextTransport.requests == 0)
    next.idleTime = { 600 }
    await next.tick(); await next.waitUntilIdle()
    #expect(next.reports.count == 2 && next.reports.first?.id != first.reports.first?.id)
    #expect(next.reports.first?.periodStart == storyNow)
}

@Test @MainActor func anEmptyLibraryWaitsWithoutSpendingAndGeneratesAfterTheFirstEligibleCopy() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    let transport = StoryTestTransport(), controller = f.controller(transport)
    await controller.tick(); await controller.waitUntilIdle()
    #expect(await transport.requests == 0 && controller.checkpoint == nil)
    #expect(f.defaults.object(forKey: "storyLastAutomaticAttempt") == nil)
    try await f.repository.save(storyClip("The first eligible copy"))
    await controller.tick(); await controller.waitUntilIdle()
    #expect(controller.reports.count == 1 && controller.error == nil)
}

@Test @MainActor func loadingAnOldStoryKeepsItVisibleAndItsFormatUpdateWaitsForIdle() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    try await f.repository.save(storyClip("A source for a saved Story from the earlier format"))
    let original = f.controller(StoryTestTransport())
    original.generate(); await original.waitUntilIdle()
    let previousID = try #require(original.reports.first?.id)
    try await f.repository.updateAIState { $0.stories?[0].promptVersion = nil }

    let transport = StoryTestTransport(), controller = f.controller(transport)
    controller.idleTime = { 0 }
    await controller.startAutomation()
    await controller.load()
    await controller.waitUntilIdle()
    #expect(controller.reports.first?.id == previousID && controller.checkpoint == nil)
    #expect(await transport.requests == 0)

    controller.idleTime = { 600 }
    await controller.tick(); await controller.waitUntilIdle()
    #expect(controller.reports.count == 2 && controller.checkpoint == nil)
    #expect(controller.reports.first?.id != previousID)
    #expect(controller.reports.first?.promptVersion == AIStorySchedule.promptVersion)
    #expect(await transport.requests == 2)
}

@Test @MainActor func automaticStoryWaitsForOtherAIWorkAndHonorsSharedRunAndTokenLimits() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    try await f.repository.save(storyClip("A source waiting for automatic processing"))
    let transport = StoryTestTransport(), controller = f.controller(transport)
    controller.organizationBusy = { true }
    await controller.tick(); await controller.waitUntilIdle()
    #expect(await transport.requests == 0)
    controller.organizationBusy = { false }
    f.settings.aiConfiguration.dailyAutomaticRuns = 1
    var used = AIUsageRecord(runID: UUID(), requestedModel: "synthetic", inputTokens: 1, outputTokens: 1,
                             estimated: false, succeeded: true, trigger: "story")
    used.date = storyNow; used.automatic = true
    let runLimit = used; try await f.repository.updateAIState { $0.usage = [runLimit] }
    await controller.tick(); await controller.waitUntilIdle()
    #expect(await transport.requests == 0)
    f.settings.aiConfiguration.dailyAutomaticRuns = 10; f.settings.aiConfiguration.dailyTokenLimit = 1000
    used.inputTokens = 1000
    let tokenLimit = used; try await f.repository.updateAIState { $0.usage = [tokenLimit] }
    await controller.tick(); await controller.waitUntilIdle()
    #expect(await transport.requests == 0)
    try await f.repository.updateAIState { $0.usage = [] }
    f.defaults.set(true, forKey: "storyAutomationPaused")
    await controller.tick(); await controller.waitUntilIdle()
    #expect(await transport.requests == 0)
}

@Test @MainActor func storyScopeUsesSevenDaysOfCopyOrPasteAndHonorsExclusions() {
    let period = DateInterval(start: storyNow.addingTimeInterval(-7 * 86_400), end: storyNow)
    #expect(StoryController.includes(storyClip("New"), in: period))
    #expect(StoryController.includes(storyClip("Boundary", daysAgo: 7), in: period))
    #expect(!StoryController.includes(storyClip("Old", daysAgo: 8), in: period))
    #expect(!StoryController.includes(storyClip("Future", daysAgo: -1), in: period))
    var boundary = storyClip("Storage round trip")
    boundary.lastCopiedAt = period.end.addingTimeInterval(0.000_000_2)
    #expect(StoryController.includes(boundary, in: period))
    var reused = storyClip("Old but pasted recently", daysAgo: 30)
    reused.lastPastedAt = storyNow.addingTimeInterval(-86_400)
    #expect(StoryController.includes(reused, in: period))
    reused.aiAnalysisExcluded = true
    #expect(!StoryController.includes(reused, in: period))
    reused.aiAnalysisExcluded = false; reused.deletedAt = storyNow
    #expect(!StoryController.includes(reused, in: period))
}

@Test @MainActor func storyUsesOneCompleteFileAndKeepsOrganizationCheckpointsUntouched() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    let clips = (0..<1_205).map { storyClip("Recent work \($0): verify clipboard tools") }
    var excluded = storyClip("Excluded private note"); excluded.aiAnalysisExcluded = true
    try await f.repository.saveBatch(clips + [storyClip("Outside the week", daysAgo: 8), excluded])
    let organization = AIJobCheckpoint(clipIDs: [clips[0].id], batchSize: 20, configurationFingerprint: "saved-organization")
    try await f.repository.updateAIState { $0.checkpoint = organization }
    let storedOrganization = try await f.repository.aiState().checkpoint
    let transport = StoryTestTransport(), controller = f.controller(transport)
    controller.generate(); await controller.waitUntilIdle()
    #expect(controller.error == nil)
    let report = try #require(controller.reports.first)
    #expect(report.sourceCount == 1_205)
    #expect(report.periodStart == storyNow.addingTimeInterval(-7 * 86_400))
    #expect(report.recentWork.count == 2 && report.observations.count == 1)
    let state = try await f.repository.aiState()
    #expect(state.checkpoint == storedOrganization && state.storyCheckpoint == nil)
    #expect(state.usage.count == 2 && state.usage.allSatisfy { $0.trigger == "story" && $0.runID == report.id })
    #expect(AIUsageTaskPresentation.grouped(state.usage).first?.title.contains("Story") == true)
    #expect(try await f.repository.allClips().count == clips.count + 2)
    let directory = f.directories.aiTasks.appendingPathComponent(report.id.uuidString.lowercased() + ".agent")
    let input = try JSONDecoder().decode(AIFileTaskInput.self, from: Data(contentsOf: directory.appendingPathComponent("items.json")))
    #expect(input.items.count == 1_205 && input.items.allSatisfy { $0.lastCopiedAt != nil })
    let prompt = try String(contentsOf: directory.appendingPathComponent("PROMPT.md"), encoding: .utf8)
    #expect(prompt.contains("Story") && prompt.contains("1205") && !prompt.contains("主题分类"))
    let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent("task.json")))
    #expect(manifest["task_kind"].string == "story")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("output/validated-story.json").path))
}

@Test @MainActor func pausedStoryResumesItsOwnConversationWithoutRepeatingCompletedTools() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    try await f.repository.save(storyClip("Resume this Story task"))
    let transport = StoryTestTransport(holdFinal: true), controller = f.controller(transport)
    controller.generate()
    for _ in 0..<300 {
        if let checkpoint = controller.checkpoint,
           FileManager.default.fileExists(atPath: f.directories.aiTasks.appendingPathComponent(checkpoint.id.uuidString.lowercased() + ".agent/output/plan.json").path) {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let id = try #require(controller.checkpoint?.id)
    for _ in 0..<100 {
        if await transport.requests >= 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    controller.pause(); await controller.waitUntilIdle()
    #expect(controller.reports.isEmpty && controller.checkpoint?.id == id)
    await transport.unblock()
    controller.generate(resume: true); await controller.waitUntilIdle()
    #expect(controller.error == nil, "\(controller.error ?? "")")
    #expect(controller.reports.first?.id == id)
    #expect(await transport.executions == 1)
}

@Test @MainActor func storyRejectsInventedEvidenceAndTaskIDs() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    let checkpoint = AIStoryCheckpoint(periodStart: storyNow.addingTimeInterval(-7 * 86_400), periodEnd: storyNow,
        language: "zh-Hans", sharingFingerprint: "test")
    let input = try await AIFileTaskExporter.input(clips: [storyClip("An exact source quote")], taskID: checkpoint.id,
        configuration: f.settings.aiConfiguration, directories: f.directories)
    let value = JSONValue.object(["task_id": .string(checkpoint.id.uuidString), "title": .string("A week"),
        "introduction": .string("You worked on a tool"), "encouragement": .string("One step at a time"),
        "recent_work": .array([.object(["title": .string("Work"), "text": .string("A task"),
            "evidence": .array([.object(["item_id": .string("c0001"), "quote": .string("Invented quote")])])])]),
        "observations": .array([.object(["title": .string("Progress"), "text": .string("An observation"),
            "evidence": .array([.object(["item_id": .string("c0001"), "quote": .string("An exact source quote")])])])])])
    var plan = try JSONDecoder().decode(AIStoryPlan.self, from: JSONEncoder().encode(value))
    #expect(throws: AIError.self) { try plan.report(input: input, checkpoint: checkpoint) }
    plan.recentWork[0].evidence[0].quote = "An exact source quote"
    #expect(try plan.report(input: input, checkpoint: checkpoint).sourceCount == 1)
    var denied = input; denied.items[0].sharingExcluded = true
    #expect(throws: AIError.self) { try plan.report(input: denied, checkpoint: checkpoint) }
    plan.taskID = UUID()
    #expect(throws: AIError.self) { try plan.report(input: input, checkpoint: checkpoint) }
}

@Test @MainActor func disabledStoryDoesNotRequestTheModel() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    try await f.repository.save(storyClip("Available but not shared with Story"))
    f.settings.aiConfiguration.storyEnabled = false
    let transport = StoryTestTransport(), controller = f.controller(transport)
    controller.generate(); await controller.waitUntilIdle()
    #expect(!controller.running && controller.reports.isEmpty)
    #expect(await transport.requests == 0)
    #expect(try await f.repository.aiState().storyCheckpoint == nil)
}

@Test @MainActor func storyReportsSurviveBackupImportWithoutDuplicatingHistory() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    try await f.repository.save(storyClip("Backup the generated Story with its sources"))
    let controller = f.controller(StoryTestTransport())
    controller.generate(); await controller.waitUntilIdle()
    let id = try #require(controller.reports.first?.id)
    let backup = f.directories.root.appendingPathComponent("story-backup")
    try await BackupService(repository: f.repository, directories: f.directories).export(to: backup)
    let restored = try StoryFixture(); defer { restored.cleanup() }
    let importer = BackupService(repository: restored.repository, directories: restored.directories)
    _ = try await importer.importBackup(from: backup)
    _ = try await importer.importBackup(from: backup)
    let state = try await restored.repository.aiState()
    #expect(state.stories?.count == 1 && state.stories?.first?.id == id)
    #expect(state.storyCheckpoint == nil && state.usage.count == 2)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PASTEORY_STORY_LIVE_QA"] == "1"))
@MainActor func storyLiveModelUsesOnlySyntheticRecentWork() async throws {
    let f = try StoryFixture(); defer { f.cleanup() }
    let defaults = try #require(UserDefaults(suiteName: "app.pasteory.Pasteory"))
    let data = try #require(defaults.data(forKey: "aiOrganizationConfiguration.v1"))
    var configuration = try JSONDecoder().decode(AIConfiguration.self, from: data)
    configuration.enabled = true; configuration.storyEnabled = true; configuration.agentRoundLimit = 12
    f.settings.aiConfiguration = configuration
    f.settings.appLanguage = .simplifiedChinese
    let now = Date()
    let texts = [
        "演示工作记录：在剪贴板工具中核对图片 OCR 排版和纯文本复制。",
        "演示工作记录：测试应用检查更新、安装升级，以及旧数据是否保留。",
        "演示工作记录：设计活跃度的时间衰减曲线，比较复制和粘贴的复用加成。"
    ]
    let clips = texts.map { text -> Clip in
        var clip = storyClip(text); clip.createdAt = now; clip.updatedAt = now; clip.lastCopiedAt = now
        return clip
    }
    try await f.repository.saveBatch(clips)
    let controller = StoryController(repository: f.repository, settings: f.settings, directories: f.directories)
    controller.clock = { now }
    controller.generate(); await controller.waitUntilIdle()
    let state = try await f.repository.aiState()
    if let output = ProcessInfo.processInfo.environment["PASTEORY_STORY_QA_OUTPUT"] {
        let destination = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if let id = controller.reports.first?.id ?? state.storyCheckpoint?.id {
            let task = f.directories.aiTasks.appendingPathComponent(id.uuidString.lowercased() + ".agent")
            try FileManager.default.copyItem(at: task, to: destination.appendingPathComponent(task.lastPathComponent))
        }
        if let report = controller.reports.first {
            try JSONEncoder().encode(report).write(to: destination.appendingPathComponent("story.json"))
        }
        try JSONEncoder().encode(state.usage).write(to: destination.appendingPathComponent("usage.json"))
    }
    #expect(controller.error == nil, "\(controller.error ?? "")")
    let report = try #require(controller.reports.first)
    #expect(report.sourceCount == 3 && !report.encouragement.isEmpty)
    #expect(!state.usage.isEmpty && state.usage.allSatisfy { $0.trigger == "story" })
}
