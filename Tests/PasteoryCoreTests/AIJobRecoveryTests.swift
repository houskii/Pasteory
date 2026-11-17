import Foundation
import PasteoryAI
import PasteoryCore
import Testing
@testable import Pasteory

private func recoveryClip(_ index: Int) throws -> Clip {
    try #require(ClipClassifier.makeClip(from: .init(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data("Recovery synthetic document \(index)".utf8))])],
                                                   source: .init(appName: "Synthetic"), capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))))
}

private func recoveryJob(_ clips: [Clip], completed: Int, groups: [AIGroupProfile], configuration: AIConfiguration, staged: Bool = false) -> AIJobCheckpoint {
    var job = AIJobCheckpoint(clipIDs: clips.map(\.id), batchSize: configuration.batchSize, configurationFingerprint: AIHash.fingerprint(configuration))
    job.cursor = completed
    job.organization = AIJobOrganization(trigger: "manual-regroup-recent", revisions: Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.aiContentRevision) }))
    job.organization?.semanticFingerprint = AIThemeCatalog.configurationFingerprint(configuration)
    job.organization?.requiresThemePlan = false
    job.draft.isThemeReview = true
    job.draft.inputCount = completed
    job.draft.decisions = [:]
    for group in groups {
        if staged { job.draft.commands.append(.init(kind: .createGroup, targetID: group.id, name: group.name, definition: group.definition)) }
        else { job.draft.groupRevisions[group.id] = group.revision }
    }
    for (index, clip) in clips.prefix(completed).enumerated() {
        let group = groups[index % groups.count]
        job.draft.commands.append(.init(kind: .addItems, targetID: group.id, clipIDs: [clip.id]))
        job.draft.clipRevisions[clip.id] = clip.aiRevision
        job.draft.decisions?[clip.id] = AIClassificationDecision(revision: clip.aiRevision, groupIDs: [group.id], outcome: .assigned, reason: "Saved classification")
    }
    return job
}

private actor RecoveryTransport: AIChatTransport {
    var batches = [[UUID]]()
    var bodies = [UUID: [String]]()
    var requests = 0
    let afterFirstBatch: (@Sendable () async throws -> Void)?
    init(afterFirstBatch: (@Sendable () async throws -> Void)? = nil) { self.afterFirstBatch = afterFirstBatch }
    func completion(body: Data, configuration: AIConfiguration, credential: String) async throws -> Data {
        requests += 1
        let request = try JSONDecoder().decode(JSONValue.self, from: body)
        let messages = try #require(request["messages"].array)
        let message: AIChatMessage
        if messages.last?["role"].string == "tool" {
            if requests == 2 { try await afterFirstBatch?() }
            message = AIChatMessage(role: "assistant", content: "Complete")
        } else {
            let payload = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(messages.last?["content"].string).utf8))
            let documents = try #require(payload["current_batch"].array)
            let ids = try documents.map { try #require($0["id"].string.flatMap(UUID.init(uuidString:))) }
            batches.append(ids)
            for (index, document) in documents.enumerated() { bodies[ids[index], default: []].append(document["body"].string ?? "") }
            let group = payload["existing_ai_groups"].array?.first?["group_id"].string
            let decisions: [JSONValue] = ids.map { .object(["clip_id": .string($0.uuidString), "group_ids": .array(group.map { [.string($0)] } ?? []), "reason": .string("Synthetic classification")]) }
            message = AIChatMessage(role: "assistant", toolCalls: [.init(id: "recovery-\(requests)", name: "clips_classify", arguments: JSONValue.object(["decisions": .array(decisions)]).encoded)])
        }
        return try JSONEncoder.sorted.encode(JSONValue.object(["choices": .array([.object(["message": try .value(message)])]),
                                                              "usage": .object(["prompt_tokens": .number(100), "completion_tokens": .number(20)])]))
    }
}

@Test @MainActor func saved993ItemJobReusesCompletedResultsAndOnlyRequeuesChangedItems() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let suite = "Recovery993." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic"; settings.aiConfiguration.topN = 1000
    let clips = try (0..<993).map(recoveryClip), themes = (0..<6).map { AIGroupProfile(name: "Theme \($0)", definition: "Synthetic theme \($0)") }
    try await repo.saveBatch(clips)
    let job = recoveryJob(clips, completed: 440, groups: themes, configuration: settings.aiConfiguration, staged: true)
    try await repo.updateAIState { $0.checkpoint = job }
    var changed = clips[0]; changed.note = "A real user edit"; try await repo.updateExisting(changed)
    var recaptured = clips[439]; recaptured.contentHash = "new-capture-format"; try await repo.updateExisting(recaptured)
    try await repo.removePermanently(id: clips[7].id)
    #expect(try await repo.aiState().checkpoint?.id == job.id)
    var excluded = clips[8]; excluded.aiAnalysisExcluded = true; try await repo.updateExisting(excluded)
    let unrelated = try recoveryClip(9999); try await repo.save(unrelated)
    let transport = RecoveryTransport(), controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "synthetic" }, useFileAgent: false)
    controller.analyze(resume: true); await controller.waitUntilIdle()
    #expect(controller.error == nil && controller.state.checkpoint == nil)
    let sent = await transport.batches.flatMap { $0 }, pending = try #require(controller.pending)
    let expected = Set(clips.dropFirst(440).map(\.id)).union([clips[0].id, clips[439].id])
    #expect(Set(sent) == expected && sent.count == expected.count)
    #expect(!sent.contains(unrelated.id) && !sent.contains(excluded.id) && !sent.contains(clips[7].id))
    #expect(pending.id == job.draft.id && pending.inputCount == 991 && pending.decisions?.count == 991)
    #expect(Set(pending.commands.filter { $0.kind == .createGroup }.map(\.targetID)) == Set(themes.map(\.id)))
    #expect(pending.clipRevisions[changed.id] == changed.aiRevision && pending.clipRevisions[recaptured.id] == recaptured.aiRevision)
    let retained = Set(clips.prefix(440).map(\.id)).subtracting([changed.id, recaptured.id, excluded.id, clips[7].id])
    #expect(job.draft.commands.filter { $0.kind == .addItems && !Set($0.clipIDs).isDisjoint(with: retained) }.allSatisfy { old in pending.commands.contains { $0.id == old.id } })
    await controller.apply(pending, selectedIDs: Set(pending.commands.map(\.id)))
    #expect(controller.error == nil && controller.state.groups.count == 6)
    #expect(try await repo.clip(id: changed.id)?.note == changed.note)
    #expect(try await repo.clip(id: excluded.id)?.collectionIDs.isEmpty == true)
    #expect(try await repo.clip(id: unrelated.id)?.collectionIDs.isEmpty == true)
}

@Test @MainActor func anEditDuringAModelRequestOnlyRepeatsTheAffectedDocument() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let suite = "RecoveryInFlight." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic"; settings.aiConfiguration.batchSize = 2
    let clips = try (0..<6).map(recoveryClip), group = AIGroupProfile(name: "Existing", definition: "Existing theme")
    try await repo.saveBatch(clips); try await repo.saveCollection(ClipCollection(id: group.id, name: group.name, kind: .normal, sortOrder: 0))
    let job = recoveryJob(clips, completed: 2, groups: [group], configuration: settings.aiConfiguration)
    try await repo.updateAIState { $0.groups[group.id] = group; $0.checkpoint = job }
    let target = clips[2]
    let transport = RecoveryTransport(afterFirstBatch: {
        var current = target; current.note = "Changed while the first batch was in flight"; try await repo.updateExisting(current)
    })
    let controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "synthetic" }, useFileAgent: false)
    controller.analyze(resume: true); await controller.waitUntilIdle()
    #expect(controller.error == nil && controller.state.checkpoint == nil)
    let sent = await transport.batches.flatMap { $0 }
    #expect(sent.filter { $0 == target.id }.count == 2)
    #expect(Set(sent) == Set(clips.dropFirst(2).map(\.id)) && sent.count == 5)
    #expect(controller.pending?.inputCount == 6 && controller.pending?.decisions?.count == 6)
    let current = try #require(await repo.clip(id: target.id))
    #expect(controller.pending?.clipRevisions[target.id] == current.aiRevision)
}

@Test func recoveryPrunesStaleEvidenceAndReclassifiesOnlyTheDependentSmallTheme() throws {
    var clips = try (0..<6).map(recoveryClip)
    let themes = (0..<2).map { AIGroupProfile(name: "Theme \($0)", definition: "Definition \($0)") }
    var job = recoveryJob(clips, completed: 6, groups: themes, configuration: AIConfiguration(), staged: true)
    let aggregation = UUID()
    job.draft.commands += [.init(kind: .createAggregation, targetID: aggregation, clipIDs: [clips[0].id, clips[1].id]),
                           .init(kind: .setSummary, targetID: aggregation, claims: [.init(kind: .fact, text: "Old claim", evidence: [.init(clipID: clips[0].id, quote: clips[0].previewText)])]),
                           .init(kind: .updateOverview, targetID: themes[1].id, clipIDs: [clips[0].id], overview: "Old overview")]
    clips[0].note = "Changed source"
    let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) }), scope = Set(clips.map(\.id))
    try AIJobRecovery.reconcile(&job, clips: byID, groups: [:], eligibleIDs: scope)
    #expect(job.cursor == 3 && job.requeuedIDs == Set([clips[0].id, clips[2].id, clips[4].id]))
    #expect(!job.draft.commands.contains { $0.targetID == aggregation || $0.targetID == themes[0].id || $0.kind == .updateOverview })
    #expect(job.draft.decisions?.count == 3 && job.draft.clipRevisions.count == 3)
    let workspace = try AtomicWorkspace(documents: clips.map { $0.aiDocument(includeNotes: true, includeSource: true) }, writableIDs: scope, groups: [], draft: job.draft, rules: AIAnalysisRules())
    #expect(try workspace.finish().commands.filter { $0.kind == .createGroup }.count == 1)
}

@Test func continuouslyChangingContentIsDeferredWithoutRestartingOtherItems() throws {
    var clips = try (0..<3).map(recoveryClip)
    let group = AIGroupProfile(name: "Existing", definition: "Existing theme")
    var job = recoveryJob(clips, completed: 1, groups: [group], configuration: AIConfiguration())
    for version in 1...3 {
        clips[0].note = "Version \(version)"
        let deferred = try AIJobRecovery.reconcile(&job, clips: Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) }), groups: [group.id: group], eligibleIDs: Set(clips.map(\.id)))
        #expect(deferred == (version == 3 ? [clips[0].id] : []))
    }
    #expect(job.clipIDs == clips.dropFirst().map(\.id) && job.cursor == 0)
    #expect(job.skippedIDs == [clips[0].id] && job.retryCounts?[clips[0].id] == 2)
}

@Test @MainActor func restoringALegacyContentConflictRepairsTheQueueWithoutCallingTheModel() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let suite = "RecoveryLegacy." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic"
    let clips = try (0..<3).map(recoveryClip), group = AIGroupProfile(name: "Existing", definition: "Existing theme")
    try await repo.saveBatch(clips)
    var job = recoveryJob(clips, completed: 2, groups: [group], configuration: settings.aiConfiguration)
    job.failureMessage = AIError.conflict("Content changed; review or discard the saved task").localizedDescription
    let saved = job
    try await repo.updateAIState { $0.groups[group.id] = group; $0.checkpoint = saved }
    var changed = clips[0]; changed.note = "New note"; try await repo.updateExisting(changed)
    let transport = RecoveryTransport(), controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "synthetic" }, useFileAgent: false)
    try await controller.reload(); #expect(controller.error != nil)
    try await controller.recoverSavedContentChanges()
    let restored = try #require(controller.state.checkpoint)
    #expect(controller.error == nil && restored.failureMessage == nil)
    #expect(restored.id == job.id && restored.cursor == 1 && restored.clipIDs == [clips[1].id, clips[2].id, clips[0].id])
    #expect(restored.requeuedIDs == [clips[0].id] && restored.draft.decisions?.count == 1)
    #expect(await transport.requests == 0)
}

@Test @MainActor func deferredChangesStayQueuedForALaterJobWhileOtherItemsFinish() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let suite = "RecoveryDeferred." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    settings.aiConfiguration.enabled = true; settings.aiConfiguration.model = "synthetic"
    let clips = try (0..<3).map(recoveryClip), group = AIGroupProfile(name: "Existing", definition: "Existing theme")
    try await repo.saveBatch(clips)
    var job = recoveryJob(clips, completed: 1, groups: [group], configuration: settings.aiConfiguration)
    job.retryCounts = [clips[0].id: 2]
    let saved = job
    try await repo.updateAIState { $0.groups[group.id] = group; $0.checkpoint = saved }
    var changed = clips[0]; changed.note = "Still changing"; try await repo.updateExisting(changed)
    let transport = RecoveryTransport(), controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { "synthetic" }, useFileAgent: false)
    controller.analyze(resume: true); await controller.waitUntilIdle()
    #expect(controller.error == nil && controller.state.checkpoint == nil)
    #expect(Set(await transport.batches.flatMap { $0 }) == Set(clips.dropFirst().map(\.id)))
    #expect(controller.state.automation.dirty[changed.id]?.revision == changed.aiContentRevision)
    #expect(controller.pending?.inputCount == 2 && controller.pending?.decisions?[changed.id] == nil)
}

@Test @MainActor func deletingASelectedGroupMemberPreservesTheJobAndRefreshesOnlyMembershipVersions() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), clips = try (0..<4).map(recoveryClip)
    var group = AIGroupProfile(name: "Selected", definition: "Selected theme")
    group.memberIDs = Set(clips.map(\.id)); group.aiMemberIDs = group.memberIDs
    var members = clips; for index in members.indices { members[index].collectionIDs = [group.id] }
    try await repo.saveCollection(ClipCollection(id: group.id, name: group.name, kind: .normal, sortOrder: 0)); try await repo.saveBatch(members)
    var state = AIOrganizationState(); state.groups[group.id] = group
    var job = recoveryJob(members, completed: 2, groups: [group], configuration: AIConfiguration())
    let selection = AIGroupSelection(groups: [group])
    job.organization?.groupSelection = selection; job.organization?.groupSnapshots = state.groups
    job.organization?.groupCleanup = try AIGroupManagement.cleanup(selection, state: state, clips: members)
    let saved = job, profile = group
    try await repo.updateAIState { $0.groups[profile.id] = profile; $0.checkpoint = saved }
    try await repo.removePermanently(id: clips[0].id)
    var restored = try #require(await repo.aiState().checkpoint)
    let current = try await repo.allClips(), groups = try await repo.aiState().groups
    try AIJobRecovery.reconcile(&restored, clips: Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) }), groups: groups, eligibleIDs: Set(current.map(\.id)))
    #expect(restored.id == saved.id && restored.cursor == 1 && restored.clipIDs.count == 3)
    try restored.organization?.groupSelection?.validate(in: groups)
    #expect(restored.organization?.groupCleanup?.clipRevisions.count == 3)
    #expect(restored.draft.groupRevisions[group.id] == groups[group.id]?.revision)
    var editedGroups = groups; editedGroups[group.id]?.definition = "Manual definition change"; editedGroups[group.id]?.revision += 1
    #expect(throws: AIError.self) { try AIJobRecovery.reconcile(&restored, clips: Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) }), groups: editedGroups, eligibleIDs: Set(current.map(\.id))) }
}
