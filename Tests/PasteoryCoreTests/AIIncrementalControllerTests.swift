import Foundation
import PasteoryAI
import PasteoryCore
import Testing
@testable import Pasteory

private actor ClassificationTransport: AIChatTransport {
    var batches: [[UUID]] = []
    var requests = 0
    let afterFirstBatch: (@Sendable () -> Void)?
    init(afterFirstBatch: (@Sendable () -> Void)? = nil) { self.afterFirstBatch = afterFirstBatch }
    func completion(body: Data, configuration: AIConfiguration, credential: String) async throws -> Data {
        requests += 1
        let request = try JSONDecoder().decode(JSONValue.self, from: body)
        let messages = try #require(request["messages"].array)
        let message: AIChatMessage
        if messages.last?["role"].string == "tool" {
            message = AIChatMessage(role: "assistant", content: "Complete")
            if requests == 2 { afterFirstBatch?() }
        } else {
            let payload = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(messages.last?["content"].string).utf8))
            let docs = try #require(payload["current_batch"].array)
            let ids = try docs.map { try #require($0["id"].string.flatMap(UUID.init(uuidString:))) }
            batches.append(ids)
            let decisions: [JSONValue] = ids.map { .object(["clip_id": .string($0.uuidString), "group_ids": .array([]), "reason": .string("Unrelated synthetic content")]) }
            message = AIChatMessage(role: "assistant", toolCalls: [AIToolCall(id: "test-\(requests)", name: "clips_classify", arguments: JSONValue.object(["decisions": .array(decisions)]).encoded)])
        }
        return try JSONEncoder.sorted.encode(JSONValue.object(["model": .string("synthetic-model"), "choices": .array([.object(["message": try .value(message)])]), "usage": .object(["prompt_tokens": .number(100), "completion_tokens": .number(20)])]))
    }
}

private final class OrganizationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    func set(_ value: Date) { lock.withLock { date = value } }
}

@Test @MainActor func nightlyJobStopsAtTwoAndResumesSameIDsWithNewBatchBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryNightly-" + UUID().uuidString)
    let directories = try AppDirectories(root: root); defer { try? FileManager.default.removeItem(at: root) }
    let repo = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let suite = "PasteoryNightly." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic-model"
    settings.aiConfiguration.organizationPolicy.idleEnabled = true
    settings.aiConfiguration.organizationPolicy.weeklyReviewEnabled = false
    var ids = Set<UUID>()
    for index in 0..<60 {
        let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("Nightly synthetic item \(index)".utf8))])], source: ClipSource(appName: "Test", bundleIdentifier: "test.nightly", confidence: .high))))
        try await repo.save(clip); ids.insert(clip.id)
    }
    let calendar = Calendar.current, day = calendar.startOfDay(for: Date())
    let start = try #require(calendar.date(bySettingHour: 1, minute: 50, second: 0, of: day))
    let clock = OrganizationTestClock(start), transport = ClassificationTransport(afterFirstBatch: { clock.advance(1800) })
    let controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "synthetic-credential" }, useFileAgent: false)
    controller.clock = { clock.now() }; controller.idleTime = { 600 }
    controller.analyze(trigger: "idle"); await controller.waitUntilIdle()
    #expect(controller.error == nil)
    #expect(controller.state.checkpoint?.cursor == 20)
    #expect(controller.state.automation.nightlyBudget?.processedIDs.count == 20)
    #expect(await transport.batches.count == 1)
    settings.aiConfiguration.batchSize = 10; settings.aiConfiguration.dailyTokenLimit *= 2
    clock.set(try #require(calendar.date(byAdding: .day, value: 1, to: start)))
    controller.analyze(resume: true, trigger: "idle"); await controller.waitUntilIdle()
    #expect(controller.error == nil)
    #expect(controller.state.checkpoint == nil)
    let batches = await transport.batches
    #expect(batches.count == 5)
    #expect(batches.dropFirst().allSatisfy { $0.count == 10 })
    #expect(batches.flatMap { $0 }.count == ids.count)
    #expect(Set(batches.flatMap { $0 }) == ids)
    #expect(controller.state.automation.decisions.count == 60)
}

@Test @MainActor func automaticIncrementalJobUsesOnlyFiveDirtyIDsAndSkipsRepeatCopies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryIncremental-" + UUID().uuidString)
    let dirs = try AppDirectories(root: root); defer { try? FileManager.default.removeItem(at: root) }
    let suite = "PasteoryIncremental." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    let clips = try (0..<120).map { index in
        try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data("Synthetic item \(index)".utf8))])], source: .init(appName: "Tests", bundleIdentifier: "test.incremental", confidence: .high), capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))))
    }
    try await repo.saveBatch(clips)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.analyzeNew = true; settings.aiConfiguration.model = "synthetic-model"
    settings.aiConfiguration.topN = 1000
    let transport = ClassificationTransport(), controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "synthetic-credential" }, useFileAgent: false)
    try await controller.reload()
    let now = Date(); controller.clock = { now.addingTimeInterval(-40) }
    for clip in clips.prefix(5) { controller.contentChanged(clip.id) }
    await controller.waitUntilIdle(); controller.clock = { now }
    let order = try await repo.list(filter: .all, query: "", limit: 1000).map(\.id)
    await controller.tick(); await controller.waitUntilIdle()
    #expect(controller.error == nil)
    #expect(await transport.batches.count == 1)
    #expect(Set(try #require(await transport.batches.first)) == Set(clips.prefix(5).map(\.id)))
    #expect(controller.state.automation.decisions.count == 5)
    #expect(controller.state.automation.dirty.isEmpty)
    #expect(try await repo.list(filter: .all, query: "", limit: 1000).map(\.id) == order)
    try await repo.recordHumanActivity(id: clips[0].id, event: .copy, at: now)
    let copied = try #require(await repo.clip(id: clips[0].id)); controller.synchronize(copied); controller.contentChanged(copied.id)
    await controller.waitUntilIdle(); controller.clock = { now.addingTimeInterval(360) }
    await controller.tick(); await controller.waitUntilIdle()
    #expect(await transport.batches.count == 1)
    #expect(controller.state.automation.dirty.isEmpty)
}
