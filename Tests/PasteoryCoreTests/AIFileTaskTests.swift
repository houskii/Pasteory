import Foundation
import PasteoryAI
import PasteoryCore
import Testing
@testable import Pasteory

private func fileTaskClip(_ text: String) throws -> Clip {
    try #require(ClipClassifier.makeClip(from: .init(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data(text.utf8))])], source: .init(appName: "File task tests", bundleIdentifier: "test.filetask", confidence: .high))))
}

private actor FileTaskTransport: AIChatTransport {
    var requests: [JSONValue] = []
    var directory: URL?
    let groupCount: Int
    var blockFinal: Bool
    let afterPlan: (@Sendable () async throws -> Void)?
    init(groupCount: Int = 10, blockFinal: Bool = false, afterPlan: (@Sendable () async throws -> Void)? = nil) {
        self.groupCount = groupCount; self.blockFinal = blockFinal; self.afterPlan = afterPlan
    }
    func unblock() { blockFinal = false }
    func completion(body: Data, configuration: AIConfiguration, credential: String) async throws -> Data {
        let value = try JSONDecoder().decode(JSONValue.self, from: body); requests.append(value)
        if directory == nil {
            let message = try #require(value["messages"].array?.first { $0["role"].string == "user" }?["content"].string)
            let task = try JSONDecoder().decode(JSONValue.self, from: Data(message.utf8))
            directory = URL(fileURLWithPath: try #require(task["task_directory"].string))
        }
        let message: AIChatMessage
        if requests.count == 1 {
            let script = """
            python3 - <<'PY'
            import json,pathlib
            p=pathlib.Path('.')
            data=json.loads((p/'items.json').read_text())
            count=min(\(groupCount),len(data['items']))
            groups=[{'key':'theme-'+str(i),'name':'主题'+str(i),'definition':'Synthetic task topic '+str(i),'existing_group_id':None} for i in range(count)]
            assignments=[{'item_id':x['item_id'],'group_keys':['theme-'+str(i%count)],'reason':'Synthetic semantic test topic'} for i,x in enumerate(data['items'])]
            plan={'task_id':data['task_id'],'preserve_existing_memberships':True,'groups':groups,'assignments':assignments}
            (p/'output/plan.json').write_text(json.dumps(plan,ensure_ascii=False))
            print('Complete task:',len(data['items']),'items,',len(groups),'groups')
            PY
            """
            message = .init(role: "assistant", toolCalls: [.init(id: "write-whole-plan", name: "task_exec", arguments: JSONValue.object(["command": .string(script)]).encoded)])
        } else {
            if let tool = value["messages"].array?.last(where: { $0["role"].string == "tool" })?["content"].string {
                let result = try JSONDecoder().decode(JSONValue.self, from: Data(tool.utf8))
                guard result["exit_code"].number == 0 else { throw AIError.invalid("Synthetic task command failed: " + tool) }
            }
            if blockFinal { try await Task.sleep(for: .seconds(60)) }
            try await afterPlan?()
            message = .init(role: "assistant", content: "output/plan.json is complete")
        }
        return try JSONEncoder().encode(JSONValue.object(["model": .string("synthetic-file-agent"),
            "choices": .array([.object(["message": try .value(message)])]), "usage": .object(["prompt_tokens": .number(1000), "completion_tokens": .number(200),
                "prompt_tokens_details": .object(["cached_tokens": .number(500)]), "completion_tokens_details": .object(["reasoning_tokens": .number(50)])])]))
    }
}

@Test @MainActor func fileAgentProcessesTheWholeLibraryAndAppliesMoreThanEightGroupsWithoutChangingContent() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let suite = "FileTaskWhole." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic"; settings.aiConfiguration.topN = 1000
    let clips = try (0..<1005).map { try fileTaskClip("Complete source \($0): " + ($0 == 0 ? String(repeating: "full body text ", count: 10_000) : "body")) }
    try await repo.saveBatch(clips)
    let persistedDate = try await repo.clip(id: clips[0].id)?.lastCopiedAt
    let transport = FileTaskTransport(), controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "never-in-task-files" }, directories: dirs)
    controller.analyze(all: true); await controller.waitUntilIdle()
    #expect(controller.error == nil)
    let pending = try #require(controller.pending), directory = try #require(controller.latestTaskDirectory)
    #expect(pending.inputCount == 1005 && pending.fileTaskID != nil && pending.isThemeReview == true)
    #expect(pending.commands.filter { $0.kind == .createGroup }.count == 10)
    let input = try JSONDecoder().decode(AIFileTaskInput.self, from: Data(contentsOf: directory.appendingPathComponent("items.json")))
    #expect(input.items.count == 1005)
    #expect(input.items.first { $0.clipID == clips[0].id }?.body == "Complete source 0: " + String(repeating: "full body text ", count: 10_000))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("items").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("assets").path))
    let requests = await transport.requests
    #expect(requests.count == 2 && requests[0]["reasoning_effort"] == .null)
    #expect(!requests[0].encoded.contains("current_batch") && !requests[0].encoded.contains("never-in-task-files"))
    #expect(controller.state.usage.count == 2 && controller.state.usage.allSatisfy { $0.cachedInputTokens == 500 && $0.reasoningTokens == 50 })
    await controller.apply(pending, selectedIDs: Set(pending.commands.map(\.id)))
    #expect(controller.error == nil && controller.state.groups.count == 10)
    #expect(try await repo.clip(id: clips[0].id)?.note == clips[0].note)
    #expect(try await repo.clip(id: clips[0].id)?.lastCopiedAt == persistedDate)
    let snapshot = try await StorageAnalyticsService(repository: repo, directories: dirs).snapshot(period: .all)
    #expect(snapshot.storageUsage.first { $0.category == .aiTaskHistory }?.byteCount ?? 0 > 150_000)
    await controller.undo()
    #expect(controller.error == nil && controller.state.groups.isEmpty)
}

@Test @MainActor func fileAgentPauseResumesTheSameDirectoryWithoutRepeatingCompletedTools() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let suite = "FileTaskResume." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic"
    try await repo.saveBatch((0..<6).map { try fileTaskClip("Resume test \($0)") })
    let transport = FileTaskTransport(groupCount: 2, blockFinal: true)
    let controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "" }, directories: dirs)
    controller.analyze()
    for _ in 0..<200 { if await transport.requests.count >= 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
    controller.pause(); await controller.waitUntilIdle()
    let checkpoint = try #require(controller.state.checkpoint), directory = try #require(controller.latestTaskDirectory)
    #expect(checkpoint.fileTaskVersion == 2 && controller.pending == nil)
    let original = try Data(contentsOf: directory.appendingPathComponent("output/plan.json"))
    settings.aiConfiguration.includeNotes = false
    controller.analyze(resume: true); await controller.waitUntilIdle()
    #expect(controller.error?.contains("content-sharing scope changed") == true)
    #expect(await transport.requests.count == 2)
    settings.aiConfiguration.includeNotes = true
    await transport.unblock(); controller.analyze(resume: true); await controller.waitUntilIdle()
    #expect(controller.error == nil && controller.state.checkpoint == nil && controller.pending?.inputCount == 6)
    #expect(controller.latestTaskDirectory == directory)
    #expect(try Data(contentsOf: directory.appendingPathComponent("output/plan.json")) == original)
    #expect(await transport.requests.count == 3)
}

@Test @MainActor func aLegacyCheckpointMigratesToOneCompleteFileTaskWithoutFixingItsOldThemes() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let suite = "FileTaskLegacy." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic"
    let clips = try (0..<6).map { try fileTaskClip("Legacy migration source \($0)") }; try await repo.saveBatch(clips)
    var saved = AIJobCheckpoint(clipIDs: clips.map(\.id), batchSize: 2, configurationFingerprint: "legacy")
    saved.cursor = 3; saved.organization = AIJobOrganization(trigger: "manual", revisions: Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.aiContentRevision) }))
    saved.draft.commands = (0..<6).map { .init(kind: .createGroup, targetID: UUID(), name: "Old draft \($0)", definition: "Unconfirmed draft") }
    let checkpoint = saved; try await repo.updateAIState { $0.checkpoint = checkpoint }
    let transport = FileTaskTransport(groupCount: 2)
    let controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "" }, directories: dirs)
    controller.analyze(resume: true); await controller.waitUntilIdle()
    #expect(controller.error == nil && controller.state.checkpoint == nil)
    let pending = try #require(controller.pending)
    #expect(pending.fileTaskID == saved.id && pending.inputCount == 6 && pending.decisions?.count == 6)
    #expect(pending.commands.filter { $0.kind == .createGroup }.count == 2)
    let directory = try #require(controller.latestTaskDirectory)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("existing/saved-plan.json").path))
    #expect(try await repo.aiState().groups.isEmpty)
}

@Test @MainActor func fileAgentDefersOneInFlightEditAndKeepsEveryOtherAssignment() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let suite = "FileTaskEdit." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic"
    let clips = try (0..<5).map { try fileTaskClip("In flight test \($0)") }; try await repo.saveBatch(clips)
    let transport = FileTaskTransport(groupCount: 1, afterPlan: {
        var current = try #require(await repo.clip(id: clips[0].id)); current.note = "User changed this note"; try await repo.updateExisting(current)
    })
    let controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "" }, directories: dirs)
    controller.analyze(); await controller.waitUntilIdle()
    #expect(controller.error == nil)
    let pending = try #require(controller.pending)
    #expect(pending.inputCount == 4 && pending.decisions?.count == 4 && pending.decisions?[clips[0].id] == nil)
    #expect(controller.state.automation.dirty[clips[0].id] != nil)
    await controller.apply(pending, selectedIDs: Set(pending.commands.map(\.id)))
    #expect(controller.error == nil && controller.state.groups.values.first?.memberIDs.count == 4)
    #expect(try await repo.clip(id: clips[0].id)?.note == "User changed this note")
}

@Test func fileTaskReferencesOriginalResourcesAndRejectsDraftIDsAndWritesOutsideWorkspace() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aG6kAAAAASUVORK5CYII="))
    let captured = try #require(ClipClassifier.makeClip(from: .init(items: [.init(order: 0, representations: [.init(uti: "public.png", data: png)])], source: .init(appName: "Tests", confidence: .high))))
    let image = try await AttachmentStore(directories: dirs).externalize(captured)
    var config = AIConfiguration(); config.model = "synthetic"; config.reasoning = "medium"; config.supportedReasoningLevels = ["medium"]
    let input = try await AIFileTaskExporter.input(clips: [image], taskID: UUID(), configuration: config, directories: dirs)
    let path = try #require(input.items[0].imageReferences.first?.path)
    #expect(FileManager.default.fileExists(atPath: path))
    let workspace = try AIFileTaskWorkspace(input: input, clips: [image], groups: [:], reservedNames: [], configuration: config, directories: dirs)
    _ = try await workspace.prepare(previousDraft: nil)
    let result = try await workspace.perform(.init(id: "image", name: "resource_image", arguments: JSONValue.object(["path": .string(path)]).encoded))
    #expect(result.imagePath == path && !result.text.contains("base64"))
    #expect(try await workspace.imageDataURL(for: path).hasPrefix("data:image/png;base64,"))
    let outside = dirs.root.appendingPathComponent("outside.txt"); try Data("original".utf8).write(to: outside)
    let taskDirectory = await workspace.directory
    try FileManager.default.createSymbolicLink(atPath: taskDirectory.appendingPathComponent("output/escape.txt").path, withDestinationPath: outside.path)
    await #expect(throws: AIError.self) { try await workspace.perform(.init(id: "symlink-write", name: "task_write", arguments: JSONValue.object(["path": .string("output/escape.txt"), "content": .string("bad")]).encoded)) }
    await #expect(throws: AIError.self) { try await workspace.perform(.init(id: "bad-write", name: "task_write", arguments: JSONValue.object(["path": .string(outside.path), "content": .string("bad")]).encoded)) }
    let shell = try await workspace.perform(.init(id: "sandbox", name: "task_exec", arguments: JSONValue.object(["command": .string("cat " + outside.path + "; echo changed > " + outside.path)]).encoded))
    #expect(shell.text.contains("Operation not permitted"))
    #expect(try String(contentsOf: outside, encoding: .utf8) == "original")
    let plan: JSONValue = .object(["task_id": .string(input.taskID.uuidString), "preserve_existing_memberships": .bool(true),
        "groups": .array([.object(["key": .string("draft"), "name": .string("Draft"), "definition": .string("Draft theme"), "existing_group_id": .string(UUID().uuidString)])]),
        "assignments": .array([.object(["item_id": .string("c0001"), "group_keys": .array([.string("draft")]), "reason": .string("Test")])])])
    #expect(throws: AIError.self) { try AIFileTaskPlan.decode(Data(plan.encoded.utf8)).changeSet(input: input, groups: [:]) }
}
