import Foundation
import PasteoryAI
import Testing
@testable import PasteoryCore

private func aiDirectories() throws -> AppDirectories {
    try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryAI-" + UUID().uuidString))
}
private func aiClip(_ text: String, at date: Date = Date()) -> Clip {
    ClipClassifier.makeClip(from: PasteboardCapture(
        items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))])],
        source: ClipSource(appName: "AI Test", bundleIdentifier: "test.ai", processIdentifier: 1, confidence: .high), capturedAt: date))!
}
private func aiGrouping(_ clips: [Clip], group: UUID = UUID()) -> AIChangeSet {
    var change = AIChangeSet()
    change.clipRevisions = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.aiRevision) })
    change.commands = [AICommand(kind: .createGroup, targetID: group, name: "Project", definition: "Project source materials"),
                       AICommand(kind: .addItems, targetID: group, clipIDs: clips.map(\.id))]
    return change
}

@Test func aiApplyIsAtomicIdempotentAndUndoPreservesLaterHumanNotes() async throws {
    let dirs = try aiDirectories(); defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    var original = aiClip("Project implementation notes")
    original.note = "A user-authored note"; original.isFavorite = true
    try await repo.save(original)
    let before = try #require(await repo.clip(id: original.id))
    let draft = aiGrouping([original]), group = draft.commands[0].targetID
    try await repo.applyAIChangeSet(draft)
    try await repo.applyAIChangeSet(draft)
    var saved = try #require(await repo.clip(id: original.id))
    #expect(saved.collectionIDs == [group])
    #expect(saved.note == original.note && saved.isFavorite && saved.items == original.items)
    #expect(abs(saved.activity.lastUsedAt.timeIntervalSince(before.activity.lastUsedAt)) < 0.001)
    #expect(saved.activity.samples.count == before.activity.samples.count)
    for (actual, expected) in zip(saved.activity.samples, before.activity.samples) {
        #expect(actual.event == expected.event)
        #expect(abs(actual.at.timeIntervalSince(expected.at)) < 0.001)
    }
    #expect(try await repo.list(filter: .collection(group), query: "", limit: 10).map(\.id) == [original.id])
    saved.note = "Edited after AI organization"; try await repo.updateExisting(saved)
    try await repo.undoAIChangeSet(draft.id)
    let undone = try #require(await repo.clip(id: original.id))
    #expect(undone.collectionIDs.isEmpty && undone.note == saved.note && undone.isFavorite)
    #expect(try await repo.collections().isEmpty)
}

@Test func aiInvalidSecondCommandRollsBackNewGroupAndMemberships() async throws {
    let dirs = try aiDirectories(); defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), clip = aiClip("Atomic transaction")
    try await repo.save(clip)
    var draft = aiGrouping([clip])
    draft.commands[1].clipIDs = [UUID()]
    do { try await repo.applyAIChangeSet(draft); Issue.record("Invalid command unexpectedly committed") }
    catch AIError.invalid(let message) { #expect(message.contains("Unread")) }
    #expect(try await repo.collections().isEmpty)
    #expect(try await repo.clip(id: clip.id)?.collectionIDs.isEmpty == true)
    #expect(try await repo.aiState().changes.isEmpty)
}

@Test func aiContextLoadsLongTextOnDemandAndFiltersSecretsBeyondThePreview() async throws {
    let dirs = try aiDirectories(); defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let ordinary = aiClip(String(repeating: "Project material. ", count: 300) + "Later evidence")
    let secret = aiClip(String(repeating: "innocent text ", count: 300) + "sk-abcdefghijklmnopqrstuvwxyz123456")
    var titled = aiClip("Ordinary body"); titled.title = "sk-abcdefghijklmnopqrstuvwxyz123456"
    try await repo.saveBatch([ordinary, secret, titled])
    let context = try await repo.aiContext(ids: [ordinary.id, secret.id, titled.id], includeNotes: false, includeSource: false)
    #expect(context.map(\.id) == [ordinary.id])
    #expect(context[0].body.contains("Later evidence"))
    #expect(context[0].source.isEmpty && context[0].note.isEmpty)
}

@Test func explicitHumanUseProtectsOldClipsFromHistoryCleanup() async throws {
    let dirs = try aiDirectories(); defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let clip = aiClip("A document opened again", at: now.addingTimeInterval(-90 * 86_400))
    try await repo.save(clip)
    let cutoff = now.addingTimeInterval(-30 * 86_400)
    #expect(try await repo.previewHistoryCleanup(olderThan: cutoff, largerThan: 0).entries.map(\.id) == [clip.id])
    try await repo.recordHumanActivity(id: clip.id, event: .open, at: now)
    #expect(try await repo.previewHistoryCleanup(olderThan: cutoff, largerThan: 0).entries.isEmpty)
    #expect(try await repo.clip(id: clip.id)?.lastUsedAt == now)
    try await repo.recordHumanActivity(id: clip.id, event: .copy, at: now.addingTimeInterval(1))
    let copied = try #require(await repo.clip(id: clip.id))
    #expect(copied.lastCopiedAt == now.addingTimeInterval(1) && copied.copyCount == clip.copyCount + 1)
}

@Test func legacyBackupMembershipsRestoreWithoutForeignKeyFailures() async throws {
    let source = try aiDirectories(), destination = try aiDirectories()
    defer { for root in [source.root, destination.root] { try? FileManager.default.removeItem(at: root) } }
    let repo = try SQLiteClipRepository(databaseURL: source.databaseFile)
    let group = ClipCollection(name: "Legacy", kind: .normal, sortOrder: 0)
    try await repo.saveCollection(group)
    var clip = aiClip("Legacy grouped item"); clip.collectionIDs = [group.id]; try await repo.save(clip)
    let path = source.backups.appendingPathComponent("legacy.pasteorybackup")
    try await BackupService(repository: repo, directories: source).export(to: path)
    let manifestURL = path.appendingPathComponent("manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    manifest["formatVersion"] = 4
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
    let restored = try SQLiteClipRepository(databaseURL: destination.databaseFile)
    _ = try await BackupService(repository: restored, directories: destination).importBackup(from: path)
    #expect(try await restored.clip(id: clip.id)?.collectionIDs == [group.id])
    #expect(try await restored.collections().first?.id == group.id)
}

@Test func aiDefinitionAndMembershipConflictsProtectHumanEdits() async throws {
    let dirs = try aiDirectories(); defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), clip = aiClip("Project references")
    try await repo.save(clip)
    let draft = aiGrouping([clip]), group = draft.commands[0].targetID
    try await repo.applyAIChangeSet(draft)
    let profile = try #require(await repo.aiState().groups[group])
    var followup = AIChangeSet(); followup.groupRevisions[group] = profile.revision
    followup.clipRevisions[clip.id] = try #require(await repo.clip(id: clip.id)).aiRevision
    followup.commands = [AICommand(kind: .removeItems, targetID: group, clipIDs: [clip.id])]
    try await repo.updateAIGroupDefinition(id: group, name: "My project", definition: "My explicit scope", retained: true, expectedVersion: profile.definitionVersion)
    await #expect(throws: (any Error).self) { try await repo.applyAIChangeSet(followup) }
    await #expect(throws: (any Error).self) { try await repo.undoAIChangeSet(draft.id) }
    await #expect(throws: (any Error).self) {
        try await repo.updateAIGroupDefinition(id: group, name: "Stale edit", definition: "Old", retained: false, expectedVersion: profile.definitionVersion)
    }
    var member = try #require(await repo.clip(id: clip.id)); member.collectionIDs.remove(group)
    try await repo.updateExisting(member)
    let excluded = try #require(await repo.aiState().groups[group])
    #expect(excluded.excludedClipIDs.contains(clip.id) && !excluded.memberIDs.contains(clip.id))
    var add = AIChangeSet(); add.groupRevisions[group] = excluded.revision
    add.clipRevisions[clip.id] = member.aiRevision
    add.commands = [AICommand(kind: .addItems, targetID: group, clipIDs: [clip.id])]
    await #expect(throws: (any Error).self) { try await repo.applyAIChangeSet(add) }
}

@Test func aiAggregationSummaryIsCitedAndFreshAfterGrouping() async throws {
    let dirs = try aiDirectories(); defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let a = aiClip("The launch is scheduled for Monday."), b = aiClip("The owner is Alice.")
    try await repo.saveBatch([a, b])
    var draft = aiGrouping([a, b]); let bundle = UUID()
    draft.commands += [AICommand(kind: .createAggregation, targetID: bundle, clipIDs: [a.id, b.id], name: "Launch brief"),
                       AICommand(kind: .setSummary, targetID: bundle, claims: [AIClaim(kind: .fact, text: "Launch: Monday", evidence: [AIEvidence(clipID: a.id, quote: "scheduled for Monday")])])]
    try await repo.applyAIChangeSet(draft)
    let summary = try #require(await repo.aiState().summaries[bundle])
    #expect(summary.sourceRevisions[a.id] == a.aiContentRevision)
    #expect(try await repo.aggregation(id: bundle)?.memberClipIDs.count == 2)
    #expect(try await repo.aggregation(id: bundle)?.membershipMode == .fixed)
    var changed = try #require(await repo.clip(id: a.id)); changed.note = "New context"
    try await repo.updateExisting(changed)
    #expect(summary.sourceRevisions[a.id] != changed.aiContentRevision)
    try await repo.removePermanently(id: a.id)
    #expect(try await repo.aiState().summaries[bundle] == nil)
}

@Test func duplicateConsolidationPreservesAIExclusionAndManualMembershipProvenance() async throws {
    let dirs = try aiDirectories(); defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let first = aiClip("Same shared source", at: Date().addingTimeInterval(-100))
    var second = aiClip("Same shared source"); second.aiAnalysisExcluded = true
    try await repo.saveBatch([first, second])
    let draft = aiGrouping([first]), id = draft.commands[0].targetID
    try await repo.applyAIChangeSet(draft)
    second.collectionIDs = [id]; try await repo.updateExisting(second)
    #expect(try await repo.consolidateDuplicateClips() == 1)
    let merged = try #require(await repo.clip(id: first.id))
    #expect(merged.aiAnalysisExcluded == true)
    #expect(merged.activity.lastUsedAt >= second.lastUsedAt)
    let profile = try #require(await repo.aiState().groups[id])
    #expect(profile.memberIDs == [first.id] && profile.aiMemberIDs.isEmpty)
}

@Test func aiGroupAggregationAndSummaryUndoAsOneTransaction() async throws {
    let dirs = try aiDirectories(); defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let first = aiClip("Monday launch"), second = aiClip("Alice owns this project")
    try await repo.saveBatch([first, second])
    var draft = aiGrouping([first, second]); let bundle = UUID()
    draft.commands += [AICommand(kind: .createAggregation, targetID: bundle, clipIDs: [first.id, second.id], name: "Launch"),
                       AICommand(kind: .setSummary, targetID: bundle, claims: [AIClaim(kind: .fact, text: "Monday", evidence: [AIEvidence(clipID: first.id, quote: "Monday launch")])])]
    try await repo.applyAIChangeSet(draft)
    var edited = try #require(await repo.clip(id: first.id)); edited.note = "A later human note"
    try await repo.updateExisting(edited)
    try await repo.undoAIChangeSet(draft.id)
    #expect(try await repo.aggregation(id: bundle) == nil)
    #expect(try await repo.aiState().summaries.isEmpty)
    #expect(try await repo.clip(id: first.id)?.note == edited.note)
    #expect(try await repo.clip(id: first.id)?.collectionIDs.isEmpty == true)
}

@Test func partialCompressionSurvivesBackupAndReclaimsRawOnlyWhenAllOwnersPacked() async throws {
    let dirs = try aiDirectories(), restored = try aiDirectories()
    defer { for root in [dirs.root, restored.root] { try? FileManager.default.removeItem(at: root) } }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let a = ClipCollection(name: "A", kind: .normal, sortOrder: 0), b = ClipCollection(name: "B", kind: .normal, sortOrder: 1)
    try await repo.saveCollection(a); try await repo.saveCollection(b)
    let bytes = String(repeating: "Lossless project evidence. ", count: 4000)
    var clip = aiClip(bytes, at: Date().addingTimeInterval(-20 * 86_400)); clip.collectionIDs = [a.id, b.id]
    clip = try await repo.saveCaptured(clip)
    let oldRepresentation = try #require(clip.items.first?.representations.first)
    _ = try await repo.compressAIGroup(id: a.id, policy: LifecyclePolicy(), now: Date())
    let partial = try #require(await repo.clip(id: clip.id))
    guard case .attachment(let raw, _, _) = partial.items[0].representations[0].storage else { Issue.record("B still needs raw content"); return }
    #expect(FileManager.default.fileExists(atPath: dirs.attachments.appendingPathComponent(raw).path))
    let backup = dirs.backups.appendingPathComponent("partial.pasteorybackup")
    try await BackupService(repository: repo, directories: dirs).export(to: backup)
    let target = try SQLiteClipRepository(databaseURL: restored.databaseFile)
    #expect(try await BackupService(repository: target, directories: restored).importBackup(from: backup) == 1)
    #expect(try await target.collections().count == 2)
    let freed = try await target.compressAIGroup(id: b.id, policy: LifecyclePolicy(), now: Date())
    #expect(freed > 0)
    let complete = try #require(await target.clip(id: clip.id))
    guard case .archived = complete.items[0].representations[0].storage else { Issue.record("All owners are packed"); return }
    let attachments = AttachmentStore(directories: restored)
    #expect(try await attachments.data(for: complete.items[0].representations[0]) == Data(bytes.utf8))
    // A reader holding the representation from before GC can still recover it.
    #expect(try await attachments.data(for: oldRepresentation) == Data(bytes.utf8))
    #expect(!FileManager.default.fileExists(atPath: restored.attachments.appendingPathComponent(raw).path))
    try await target.removePermanently(id: clip.id)
    let manifest = try JSONDecoder().decode(PayloadManifest.self, from: Data(contentsOf: restored.root.appendingPathComponent("AIContent/manifest.json")))
    #expect(manifest.records.isEmpty)
}
