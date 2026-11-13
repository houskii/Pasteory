import Foundation
import Testing
@testable import PasteoryAI

private func payloadRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryPayloadTests-" + UUID().uuidString) }

@Test func sharedRawIsReleasedOnlyAfterEveryOwnerHasPackedItsReference() async throws {
    let root = payloadRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try ContentPayloadStore(root: root)
    let bytes = Data(String(repeating: "Project clipboard material. ", count: 1000).utf8)
    let record = try await store.register(bytes, ownerIDs: ["group-A", "group-B"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Raw").path).count == 1)
    _ = try await store.pack(ownerIDs: ["group-A"])
    #expect(await store.referenceCounts(for: record.contentID).raw == 1)
    #expect(try await store.releaseUnreferencedRaw() == 0)
    _ = try await store.pack(ownerIDs: ["group-B"])
    #expect(await store.referenceCounts(for: record.contentID).raw == 0)
    #expect(try await store.releaseUnreferencedRaw() == bytes.count)
    #expect(try await store.read(contentID: record.contentID) == bytes)
    let reopened = try ContentPayloadStore(root: root)
    #expect(try await reopened.read(contentID: record.contentID) == bytes)
    try await reopened.restoreRaw(ownerID: "group-A")
    #expect(await reopened.referenceCounts(for: record.contentID).raw == 1)
}

@Test func leasesAndExternalHoldersPreventRawCollection() async throws {
    let root = payloadRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try ContentPayloadStore(root: root)
    let record = try await store.register(Data("reference counted data".utf8), ownerIDs: ["A"])
    _ = try await store.pack(ownerIDs: ["A"])
    let lease = try await store.acquireRawLease(contentID: record.contentID)
    #expect(try await store.releaseUnreferencedRaw() == 0)
    await store.releaseRawLease(contentID: record.contentID, lease: lease)
    #expect(try await store.releaseUnreferencedRaw(excluding: [record.contentID]) == 0)
    #expect(try await store.releaseUnreferencedRaw() > 0)
}

@Test func corruptPackNeverAllowsRawDeletion() async throws {
    let root = payloadRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try ContentPayloadStore(root: root)
    let bytes = Data(String(repeating: "retain this", count: 100).utf8)
    let record = try await store.register(bytes, ownerIDs: ["A"])
    _ = try await store.pack(ownerIDs: ["A"])
    try Data("corrupt".utf8).write(to: root.appendingPathComponent("Packed/" + record.packedFilename))
    await #expect(throws: (any Error).self) { try await store.releaseUnreferencedRaw() }
    #expect(try Data(contentsOf: root.appendingPathComponent("Raw/" + record.rawFilename)) == bytes)
}

@Test func exportIncludesPartialPacksAndImportPreservesReferenceModes() async throws {
    let root = payloadRoot(), backup = payloadRoot(), target = payloadRoot()
    defer { for url in [root, backup, target] { try? FileManager.default.removeItem(at: url) } }
    let store = try ContentPayloadStore(root: root)
    let bytes = Data("some shared source material".utf8)
    let record = try await store.register(bytes, ownerIDs: ["A", "B"])
    _ = try await store.pack(ownerIDs: ["A"])
    try await store.exportArchive(to: backup)
    let restored = try ContentPayloadStore(root: target)
    try await restored.importArchive(from: backup)
    #expect(await restored.referenceCounts(for: record.contentID).raw == 1)
    #expect(await restored.referenceCounts(for: record.contentID).packed == 1)
    #expect(try await restored.read(contentID: record.contentID) == bytes)
    try await restored.removeReference(ownerID: "A")
    await #expect(throws: AIError.self) { try await restored.removeReference(ownerID: "B") }
}

@Test func emptyAndTinyPayloadsRoundTrip() async throws {
    let root = payloadRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try ContentPayloadStore(root: root)
    for (i, bytes) in [Data(), Data([1]), Data("你好".utf8)].enumerated() {
        let owner = "owner-\(i)"
        let record = try await store.register(bytes, ownerIDs: [owner])
        _ = try await store.pack(ownerIDs: [owner]); _ = try await store.releaseUnreferencedRaw()
        #expect(try await store.read(contentID: record.contentID) == bytes)
    }
}

@Test func reconciliationPreservesLiveOwnersAndLeasesDuringExplicitCleanup() async throws {
    let root = payloadRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try ContentPayloadStore(root: root)
    let bytes = Data("Shared lifecycle material".utf8)
    let record = try await store.register(bytes, ownerIDs: ["A", "B"])
    _ = try await store.pack(ownerIDs: ["A"])
    _ = try await store.reconcile([PayloadReference(ownerID: "B", contentID: record.contentID)], snapshotAt: Date(), purgeUnreferenced: true)
    #expect(await store.referenceCounts(for: record.contentID).raw == 1)
    #expect(try await store.read(contentID: record.contentID) == bytes)
    let lease = try await store.acquireRawLease(contentID: record.contentID)
    _ = try await store.reconcile([], snapshotAt: Date(), purgeUnreferenced: true)
    #expect(await store.snapshot().records.count == 1)
    await store.releaseRawLease(contentID: record.contentID, lease: lease)
    #expect(try await store.reconcile([], snapshotAt: Date(), purgeUnreferenced: true) > 0)
    #expect(await store.snapshot().records.isEmpty)
}

@Test func staleReconciliationCannotDiscardNewlyPublishedOwners() async throws {
    let root = payloadRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try ContentPayloadStore(root: root), snapshot = Date()
    let record = try await store.register(Data("New capture".utf8), ownerIDs: ["new-owner"])
    _ = try await store.reconcile([], snapshotAt: snapshot, purgeUnreferenced: true)
    #expect(await store.referenceCounts(for: record.contentID).raw == 1)
    #expect(await store.snapshot().records.count == 1)
}
