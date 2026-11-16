import Foundation
import SQLite3
import PasteoryAI
import Testing
@testable import Pasteory
@testable import PasteoryCore

private func managementClip(_ text: String, timestamp: Double = 1_700_000_000) throws -> Clip {
    try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data(text.utf8))])],
                                                               source: .init(appName: "Tests", bundleIdentifier: "test.groups", confidence: .high),
                                                               capturedAt: Date(timeIntervalSince1970: timestamp))))
}

private func addManagementGroup(_ clips: [Clip], name: String, repo: SQLiteClipRepository) async throws -> UUID {
    let id = UUID(); var draft = AIChangeSet()
    let current = try await repo.clips(ids: clips.map(\.id))
    draft.clipRevisions = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.aiRevision) })
    draft.commands = [.init(kind: .createGroup, targetID: id, name: name, definition: name + " definition"), .init(kind: .addItems, targetID: id, clipIDs: clips.map(\.id))]
    try await repo.applyAIChangeSet(draft); return id
}

@Test @MainActor func cleanupAllDeduplicatesSharedMembersAndWorksWithoutModelAccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIGroupAll-" + UUID().uuidString)
    let dirs = try AppDirectories(root: root); defer { try? FileManager.default.removeItem(at: root) }
    let suite = "AIGroupAll." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    let clips = try (0..<3).map { try managementClip("Shared member \($0)") }; try await repo.saveBatch(clips)
    _ = try await addManagementGroup(Array(clips.prefix(2)), name: "One", repo: repo)
    _ = try await addManagementGroup([clips[0], clips[2]], name: "Two", repo: repo)
    let transport = RegroupTransport(), controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { throw AIError.invalid("Cleanup must not load credentials") })
    try await controller.reload()
    let original = controller.state.groups, selection = AIGroupSelection(groups: Array(original.values))
    #expect(selection.memberIDs.count == 3)
    var applied = [Bool](); controller.onApplied = { applied.append($0) }
    #expect(await controller.cleanupGroups(selection))
    #expect(applied == [false])
    #expect(controller.state.groups.isEmpty)
    #expect(try await repo.allClips().count == 3)
    #expect(try await repo.allClips().allSatisfy { $0.collectionIDs.isEmpty })
    let planningCalls = await transport.planningCalls, batches = await transport.batches
    #expect(planningCalls == 0 && batches.isEmpty)
    await controller.undo()
    #expect(controller.state.groups == original)
    #expect(try await repo.clip(id: clips[0].id)?.collectionIDs.count == 2)
}

private func groupManagementDates(_ url: URL) throws -> [String: [Double?]] {
    var db: OpaquePointer?; try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    try #require(sqlite3_prepare_v2(db, "SELECT id,created_at,updated_at,last_copied_at,last_pasted_at,last_used_at FROM clips", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    var result = [String: [Double?]]()
    while sqlite3_step(statement) == SQLITE_ROW {
        let id = String(cString: try #require(sqlite3_column_text(statement, 0)))
        result[id] = (1...5).map { sqlite3_column_type(statement, Int32($0)) == SQLITE_NULL ? nil : sqlite3_column_double(statement, Int32($0)) }
    }
    return result
}

@Test @MainActor func selectedCleanupPreservesManualFoldersExcludedContentAndExactDatesAndCanUndo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIGroupCleanup-" + UUID().uuidString)
    let dirs = try AppDirectories(root: root); defer { try? FileManager.default.removeItem(at: root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let a = try managementClip("A", timestamp: 1_700_000_000.1234567), b = try managementClip("B", timestamp: 1_700_000_000.2234567)
    try await repo.saveBatch([a, b])
    let selected = try await addManagementGroup([a], name: "Selected", repo: repo)
    let other = try await addManagementGroup([b], name: "Other", repo: repo)
    let folder = ClipCollection(name: "Manual folder", kind: .normal, sortOrder: 2); try await repo.saveCollection(folder)
    var member = try #require(await repo.clip(id: a.id)); member.collectionIDs.insert(folder.id); member.note = "My note"; member.aiAnalysisExcluded = true
    try await repo.updateExisting(member)
    let profile = try #require(await repo.aiState().groups[selected])
    try await repo.updateAIGroupDefinition(id: selected, name: profile.name, definition: "Manually edited prompt", retained: true, expectedVersion: profile.definitionVersion)
    let state = try await repo.aiState(), dates = try groupManagementDates(dirs.databaseFile)
    let selection = AIGroupSelection(groups: [try #require(state.groups[selected])])
    let cleanup = try AIGroupManagement.cleanup(selection, state: state, clips: await repo.allClips())
    try await repo.applyAIChangeSet(cleanup)
    #expect(try await repo.aiState().groups[selected] == nil)
    #expect(try await repo.aiState().groups[other] == state.groups[other])
    #expect(try await repo.clip(id: a.id)?.collectionIDs == [folder.id])
    #expect(try await repo.clip(id: a.id)?.note == "My note")
    #expect(try await repo.clip(id: a.id)?.aiAnalysisExcluded == true)
    #expect(try groupManagementDates(dirs.databaseFile) == dates)
    try await repo.undoAIChangeSet(cleanup.id)
    #expect(try await repo.aiState().groups[selected] == state.groups[selected])
    #expect(try await repo.clip(id: a.id)?.collectionIDs == [selected, folder.id])
    #expect(try groupManagementDates(dirs.databaseFile) == dates)
}

@Test func cleanupRejectsStaleSelectionAndForgedScopeWithoutPartialDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIGroupScope-" + UUID().uuidString)
    let dirs = try AppDirectories(root: root); defer { try? FileManager.default.removeItem(at: root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), clip = try managementClip("Versioned cleanup")
    try await repo.save(clip)
    let id = try await addManagementGroup([clip], name: "Scope", repo: repo)
    let state = try await repo.aiState(), scope = AIGroupSelection(groups: [try #require(state.groups[id])])
    let cleanup = try AIGroupManagement.cleanup(scope, state: state, clips: await repo.allClips())
    try await repo.updateAIState { $0.changes.append(cleanup) }
    var forged = cleanup; forged.userSelectedGroupIDs = []
    await #expect(throws: (any Error).self) { try await repo.applyAIChangeSet(forged) }
    #expect(try await repo.aiState().groups[id] != nil)
    var changed = try #require(await repo.clip(id: clip.id)); changed.note = "Edited during review"; try await repo.updateExisting(changed)
    await #expect(throws: (any Error).self) { try await repo.applyAIChangeSet(cleanup) }
    #expect(try await repo.aiState().groups[id] != nil)
    #expect(try await repo.clip(id: clip.id)?.collectionIDs == [id])
    let manual = ClipCollection(name: "Ordinary folder", kind: .normal, sortOrder: 4); try await repo.saveCollection(manual)
    let fake = AIGroupSelection(groups: [AIGroupProfile(id: manual.id, name: manual.name, definition: "Not an AI group")])
    #expect(throws: (any Error).self) { try AIGroupManagement.cleanup(fake, state: state, clips: [clip]) }
}

private actor RegroupTransport: AIChatTransport {
    var batches = [[UUID]]()
    var planningCalls = 0
    var delayAfterFirstBatch: Bool
    init(delayAfterFirstBatch: Bool = false) { self.delayAfterFirstBatch = delayAfterFirstBatch }
    func resumeImmediately() { delayAfterFirstBatch = false }
    func completion(body: Data, configuration: AIConfiguration, credential: String) async throws -> Data {
        let request = try JSONDecoder().decode(JSONValue.self, from: body), messages = try #require(request["messages"].array)
        let message: AIChatMessage
        if messages.last?["role"].string == "tool" { message = .init(role: "assistant", content: "Complete") }
        else {
            let payload = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(messages.last?["content"].string).utf8))
            if request["tools"].array == nil {
                planningCalls += 1
                let examples = try #require(payload["examples"].array), existing = try #require(payload["existing_themes"].array)
                var themes = try existing.map { theme -> JSONValue in
                    .object(["group_id": .string(try #require(theme["group_id"].string)), "name": .string(try #require(theme["name"].string)), "definition": .string(try #require(theme["definition"].string)), "support_ids": .array([])])
                }
                for (name, start) in [("主题一", 0), ("主题二", 3)] {
                    themes.append(.object(["group_id": .null, "name": .string(name), "definition": .string(name + " synthetic"), "support_ids": .array(try examples[start..<start+3].map { .string(try #require($0["id"].string)) })]))
                }
                message = .init(role: "assistant", content: JSONValue.object(["themes": .array(themes)]).encoded)
            } else {
                let docs = try #require(payload["current_batch"].array)
                batches.append(try docs.map { try #require($0["id"].string.flatMap(UUID.init(uuidString:))) })
                if delayAfterFirstBatch, batches.count > 1 { try await Task.sleep(for: .seconds(30)) }
                let catalog = try #require(payload["existing_ai_groups"].array)
                let target = try #require((catalog.first(where: { $0["name"].string == "主题一" }) ?? catalog.first)?["group_id"].string)
                let decisions: [JSONValue] = try docs.map { .object(["clip_id": .string(try #require($0["id"].string)), "group_ids": .array([.string(target)]), "reason": .string("Synthetic selected-content classification")]) }
                message = .init(role: "assistant", toolCalls: [.init(id: UUID().uuidString, name: "clips_classify", arguments: JSONValue.object(["decisions": .array(decisions)]).encoded)])
            }
        }
        return try JSONEncoder.sorted.encode(JSONValue.object(["model": .string("synthetic-model"), "choices": .array([.object(["message": try .value(message)])]), "usage": .object(["prompt_tokens": .number(100), "completion_tokens": .number(20)])]))
    }
}

@Test @MainActor func regroupUsesOnlySelectedMembersPreviewsAtomicallyAndResumesTheSameScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRegroup-" + UUID().uuidString)
    let dirs = try AppDirectories(root: root); defer { try? FileManager.default.removeItem(at: root) }
    let suite = "AIRegroup." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic-model"; settings.aiConfiguration.topN = 1; settings.aiConfiguration.batchSize = 3
    settings.aiConfiguration.applyMode = .appendExisting
    let clips = try (0..<7).map { try managementClip("Synthetic regroup \($0)", timestamp: 1_700_000_000 + Double($0)) }
    try await repo.saveBatch(clips)
    let selected = try await addManagementGroup(Array(clips.prefix(6)), name: "Old selected", repo: repo)
    let untouched = try await addManagementGroup([clips[6]], name: "Kept", repo: repo)
    let transport = RegroupTransport(delayAfterFirstBatch: true)
    let controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "synthetic" })
    try await controller.reload()
    let original = controller.state, scope = AIGroupSelection(groups: [try #require(original.groups[selected])])
    #expect(controller.regroupGroups(scope))
    for _ in 0..<300 { if await transport.batches.count >= 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
    controller.pause(); await controller.waitUntilIdle()
    #expect(controller.state.checkpoint?.cursor == 3)
    #expect(controller.state.checkpoint?.organization?.groupSelection == scope)
    #expect(try await repo.aiState().groups[selected] == original.groups[selected])
    await transport.resumeImmediately(); controller.analyze(resume: true); await controller.waitUntilIdle()
    #expect(controller.error == nil)
    #expect(await transport.planningCalls == 1)
    #expect(Set(await transport.batches.flatMap { $0 }) == Set(clips.prefix(6).map(\.id)))
    let pending = try #require(controller.pending)
    #expect(pending.userSelectedGroupIDs == [selected] && pending.isThemeReview == true && pending.inputCount == 6)
    #expect(controller.state.lastAutomaticRunAt == nil)
    #expect(try await repo.aiState().groups[selected] == original.groups[selected])
    await controller.apply(pending, selectedIDs: Set(pending.commands.dropFirst().map(\.id)))
    #expect(try await repo.aiState().groups[selected] != nil)
    await controller.apply(pending, selectedIDs: Set(pending.commands.map(\.id)))
    #expect(try await repo.aiState().groups[selected] == nil)
    #expect(try await repo.aiState().groups[untouched] == original.groups[untouched])
    #expect(try await repo.clip(id: clips[6].id)?.collectionIDs == [untouched])
    try await repo.undoAIChangeSet(pending.id)
    #expect(try await repo.aiState().groups[selected] == original.groups[selected])
}

@Test @MainActor func scopedRegroupReusesFullLegacyCatalogWithoutExpandingItsInputOrCreatingMoreThemes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRegroupLegacy-" + UUID().uuidString)
    let dirs = try AppDirectories(root: root); defer { try? FileManager.default.removeItem(at: root) }
    let suite = "AIRegroupLegacy." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic-model"
    let clips = try (0..<11).map { try managementClip("Legacy source \($0)") }; try await repo.saveBatch(clips)
    let selected = try await addManagementGroup(Array(clips.prefix(3)), name: "Selected legacy", repo: repo)
    // Simulate a library imported from the older uncapped version.
    for index in 0..<8 {
        let collection = ClipCollection(name: "Kept \(index)", kind: .normal, sortOrder: index + 1); try await repo.saveCollection(collection)
        var clip = clips[index + 3]; clip.collectionIDs = [collection.id]; try await repo.updateExisting(clip)
        var profile = AIGroupProfile(id: collection.id, name: collection.name, definition: "Keep this definition \(index)")
        profile.memberIDs = [clip.id]; profile.aiMemberIDs = [clip.id]
        let saved = profile; try await repo.updateAIState { $0.groups[saved.id] = saved }
    }
    let transport = RegroupTransport(), controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "synthetic" })
    try await controller.reload()
    let definitions = controller.state.groups.filter { $0.key != selected }.mapValues(\.definition)
    #expect(controller.regroupGroups(AIGroupSelection(groups: [try #require(controller.state.groups[selected])])))
    await controller.waitUntilIdle()
    #expect(controller.error == nil)
    #expect(await transport.planningCalls == 0)
    #expect(Set(await transport.batches.flatMap { $0 }) == Set(clips.prefix(3).map(\.id)))
    let pending = try #require(controller.pending)
    #expect(!pending.commands.contains { $0.kind == .createGroup })
    await controller.apply(pending, selectedIDs: Set(pending.commands.map(\.id)))
    #expect(controller.error == nil)
    #expect(controller.state.groups.count == 8)
    #expect(controller.state.groups.mapValues(\.definition) == definitions)
}
