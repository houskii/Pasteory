import Foundation
import Testing
@testable import PassteCore

private func temporaryDirectories() throws -> AppDirectories {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PassteTests-\(UUID().uuidString)", isDirectory: true)
    return try AppDirectories(root: root)
}

private func textClip(_ value: String, date: Date = Date(), source: String = "app.test") -> Clip {
    let data = Data(value.utf8)
    let capture = PasteboardCapture(
        items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: data)])],
        source: ClipSource(appName: "测试应用", bundleIdentifier: source, processIdentifier: 42, confidence: .high),
        capturedAt: date
    )
    return ClipClassifier.makeClip(from: capture)!
}

@Test func repositorySearchesChineseMetadataAndDeduplicatesAdjacentCopy() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    var clip = textClip("发布脚本 swift build")
    clip.note = "常用命令"
    clip.title = "本地构建"
    _ = try await repository.saveCaptured(clip)
    var next = textClip("发布脚本 swift build", date: clip.createdAt.addingTimeInterval(20))
    next.note = clip.note; next.title = clip.title
    let merged = try await repository.saveCaptured(next)
    #expect(merged.id == clip.id)
    #expect(merged.copyCount == 2)
    #expect(try await repository.list(filter: .all, query: "构建", limit: 10).count == 1)
    #expect(try await repository.list(filter: .all, query: "命令", limit: 10).count == 1)
}

@Test func normalCollectionProtectsClipFromArchive() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let collection = ClipCollection(name: "重要", kind: .normal)
    try await repository.saveCollection(collection)
    var protected = textClip("保留", date: Date(timeIntervalSinceNow: -60 * 86_400))
    protected.collectionIDs.insert(collection.id)
    try await repository.save(protected)
    let candidates = try await repository.archiveCandidates(olderThan: Date(timeIntervalSinceNow: -30 * 86_400), hotLimit: 10_000)
    #expect(candidates.isEmpty)
}

@Test func archiveCompressesAndRestoresInlineRepresentation() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let attachments = AttachmentStore(directories: directories)
    let archive = ArchiveService(repository: repository, directories: directories)
    let original = textClip(String(repeating: "可恢复内容", count: 100), date: Date(timeIntervalSinceNow: -40 * 86_400))
    try await repository.save(original)
    #expect(try await archive.run() == 1)
    let stored = try #require(try await repository.clip(id: original.id))
    #expect(stored.isArchived)
    let representation = try #require(stored.items.first?.representations.first)
    let restored = try await attachments.data(for: representation)
    #expect(String(data: restored, encoding: .utf8) == String(repeating: "可恢复内容", count: 100))
}

@Test func backupRoundTripValidatesAndImports() async throws {
    let sourceDirectories = try temporaryDirectories()
    let targetDirectories = try temporaryDirectories()
    defer {
        try? FileManager.default.removeItem(at: sourceDirectories.root)
        try? FileManager.default.removeItem(at: targetDirectories.root)
    }
    let sourceRepository = try SQLiteClipRepository(databaseURL: sourceDirectories.databaseFile)
    let sourceBackup = BackupService(repository: sourceRepository, directories: sourceDirectories)
    let clip = textClip("备份内容")
    try await sourceRepository.save(clip)
    let backupURL = FileManager.default.temporaryDirectory.appendingPathComponent("Passte-\(UUID().uuidString).passtebackup")
    defer { try? FileManager.default.removeItem(at: backupURL) }
    try await sourceBackup.export(to: backupURL)

    let targetRepository = try SQLiteClipRepository(databaseURL: targetDirectories.databaseFile)
    let targetBackup = BackupService(repository: targetRepository, directories: targetDirectories)
    #expect(try await targetBackup.importBackup(from: backupURL) == 1)
    #expect(try await targetRepository.clip(id: clip.id)?.previewText == "备份内容")
}

@Test func listsClipsInNewestCopyOrder() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let older = textClip("较早", date: Date(timeIntervalSince1970: 10))
    let newer = textClip("较新", date: Date(timeIntervalSince1970: 20))
    try await repository.saveBatch([older, newer])
    let result = try await repository.list(filter: .all, query: "", limit: 10)
    #expect(result.map(\.id) == [newer.id, older.id])
}
