import Foundation
import Testing
@testable import PasteoryCore

private func temporaryDirectories() throws -> AppDirectories {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryTests-\(UUID().uuidString)", isDirectory: true)
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

@Test func detectsGroupAndDirectConversationTypesFromHeaderSignals() {
    #expect(ConversationContextDetector.wechat(
        headerTitle: "Byte AI Agent交流（关群不拉人了(494)",
        hasCallButton: true
    ) == ConversationContextDetection(type: .group, participantCount: 494))
    #expect(ConversationContextDetector.wechat(
        headerTitle: "年",
        hasCallButton: true
    ) == ConversationContextDetection(type: .direct))
    #expect(ConversationContextDetector.wechat(
        headerTitle: "公众号",
        hasCallButton: false
    ) == ConversationContextDetection(type: .unknown))
    #expect(ConversationContextDetector.lark(
        participantCount: 4,
        hasBotCount: true
    ) == ConversationContextDetection(type: .group, participantCount: 4))
    #expect(ConversationContextDetector.lark(
        participantCount: nil,
        hasBotCount: false
    ) == ConversationContextDetection(type: .direct))
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

@Test func deduplicatedClipKeepsEveryCaptureEventAndContextEntity() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let first = textClip("p/pengzipei/feature", date: Date(timeIntervalSince1970: 100), source: "com.google.Chrome")
    let firstContext = CapturedSourceContext(
        kind: .webPage,
        strategyIdentifier: "chrome.extension.web-context.v1",
        summary: "BITS · MR 1",
        payload: ["url": "https://bits.bytedance.net/devops/1/code/detail/1", "branch": "p/pengzipei/feature"],
        entities: [
            SourceContextEntity(
                kind: .branch,
                provider: "chrome.extension.web-context.v1",
                stableIdentifier: "bits:Douyin:p/pengzipei/feature",
                displayName: "p/pengzipei/feature",
                identityQuality: .stableIdentifier
            )
        ]
    )
    let stored = try await repository.saveCaptured(first, context: firstContext)
    let second = textClip("p/pengzipei/feature", date: Date(timeIntervalSince1970: 120), source: "com.google.Chrome")
    let secondContext = CapturedSourceContext(
        kind: .webPage,
        strategyIdentifier: "chrome.extension.web-context.v1",
        summary: "BITS · MR 2",
        payload: ["url": "https://bits.bytedance.net/devops/1/code/detail/2", "branch": "p/pengzipei/feature"]
    )
    let merged = try await repository.saveCaptured(second, context: secondContext)

    #expect(merged.id == stored.id)
    #expect(merged.copyCount == 2)
    let events = try await repository.captureEvents(for: stored.id, limit: 10)
    #expect(events.count == 2)
    #expect(events.map(\.context?.summary) == ["BITS · MR 2", "BITS · MR 1"])
    let aggregates = try await repository.contextAggregates(kind: .branch, limit: 10)
    #expect(aggregates.count == 1)
    #expect(aggregates.first?.clipCount == 1)
    #expect(aggregates.first?.captureCount == 1)
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

@Test func collectionNamesAreUniqueIgnoringCaseAndWhitespace() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    try await repository.saveCollection(ClipCollection(name: "开发资料", kind: .normal))
    var rejected = false
    do {
        try await repository.saveCollection(ClipCollection(name: "  开发资料  ", kind: .smart))
    } catch RepositoryError.duplicateCollectionName {
        rejected = true
    }
    #expect(rejected)
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
    let context = CapturedSourceContext(
        kind: .conversation,
        strategyIdentifier: "wechat.ax.conversation.v1",
        summary: "微信 · 文件传输助手",
        payload: ["conversationName": "文件传输助手"],
        entities: [
            SourceContextEntity(
                kind: .conversation,
                provider: "wechat.ax.conversation.v1",
                displayName: "文件传输助手",
                identityQuality: .displayNameOnly
            )
        ]
    )
    _ = try await sourceRepository.saveCaptured(clip, context: context)
    try await sourceRepository.saveFallbackRule(URLFallbackRule(
        name: "测试规则",
        hostPattern: "example.com",
        pathTemplate: "/items/{itemID}",
        titleTemplate: "条目 · {{path.itemID}}"
    ))
    let backupURL = FileManager.default.temporaryDirectory.appendingPathComponent("Pasteory-\(UUID().uuidString).pasteorybackup")
    defer { try? FileManager.default.removeItem(at: backupURL) }
    try await sourceBackup.export(to: backupURL)

    let targetRepository = try SQLiteClipRepository(databaseURL: targetDirectories.databaseFile)
    let targetBackup = BackupService(repository: targetRepository, directories: targetDirectories)
    #expect(try await targetBackup.importBackup(from: backupURL) == 1)
    #expect(try await targetRepository.clip(id: clip.id)?.previewText == "备份内容")
    #expect(try await targetRepository.captureEvents(for: clip.id, limit: 10).first?.context?.summary == "微信 · 文件传输助手")
    #expect(try await targetRepository.userFallbackRules().map(\.name) == ["测试规则"])
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

@Test func pinnedClipsStayAboveNewerUnpinnedClips() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    var pinned = textClip("已置顶", date: Date(timeIntervalSince1970: 10))
    pinned.isPinned = true
    let newer = textClip("较新的普通内容", date: Date(timeIntervalSince1970: 20))
    try await repository.saveBatch([pinned, newer])
    let result = try await repository.list(filter: .all, query: "", limit: 10)
    #expect(result.map(\.id) == [pinned.id, newer.id])
    #expect(SearchRanker.rank([newer, pinned], query: "").map(\.id) == [pinned.id, newer.id])
}

@Test func recentClipCountUsesLastActivityAndExcludesTrash() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let now = Date(timeIntervalSince1970: 1_000_000)

    var recentlyReused = textClip("最近再次使用", date: now.addingTimeInterval(-30 * 86_400))
    recentlyReused.lastCopiedAt = now.addingTimeInterval(-3_600)
    let old = textClip("很久没有使用", date: now.addingTimeInterval(-30 * 86_400))
    var trashed = textClip("已进废纸篓", date: now.addingTimeInterval(-1_800))
    trashed.deletedAt = now
    try await repository.saveBatch([recentlyReused, old, trashed])

    #expect(try await repository.recentClipCount(since: now.addingTimeInterval(-86_400)) == 1)
    #expect(try await repository.recentClipCount(since: now.addingTimeInterval(-7 * 86_400)) == 1)
}
