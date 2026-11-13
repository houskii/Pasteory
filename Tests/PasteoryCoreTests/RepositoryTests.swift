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

@Test func naturalDayRangeUsesCalendarMidnightAndIncludesSevenDates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 3, hour: 18, minute: 30
    )))
    let range = NaturalDayRange(containing: now, calendar: calendar)

    #expect(calendar.dateComponents([.year, .month, .day, .hour], from: range.todayStart)
        == DateComponents(year: 2026, month: 9, day: 3, hour: 0))
    #expect(calendar.dateComponents([.year, .month, .day, .hour], from: range.sevenDayStart)
        == DateComponents(year: 2026, month: 8, day: 28, hour: 0))
}

@Test func storageAnalyticsPeriodsUseNaturalDayBoundaries() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 3, hour: 18, minute: 30
    )))

    let oneDay = try #require(StorageAnalyticsPeriod.oneDay.startDate(containing: now, calendar: calendar))
    let sevenDays = try #require(StorageAnalyticsPeriod.sevenDays.startDate(containing: now, calendar: calendar))
    let thirtyDays = try #require(StorageAnalyticsPeriod.thirtyDays.startDate(containing: now, calendar: calendar))

    #expect(calendar.dateComponents([.year, .month, .day, .hour], from: oneDay)
        == DateComponents(year: 2026, month: 9, day: 3, hour: 0))
    #expect(calendar.dateComponents([.year, .month, .day, .hour], from: sevenDays)
        == DateComponents(year: 2026, month: 8, day: 28, hour: 0))
    #expect(calendar.dateComponents([.year, .month, .day, .hour], from: thirtyDays)
        == DateComponents(year: 2026, month: 8, day: 5, hour: 0))
    #expect(StorageAnalyticsPeriod.all.startDate(containing: now, calendar: calendar) == nil)
}

@Test func storedClipKindCountsUseLastCopyTimeAndExcludeTrash() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let threshold = Date(timeIntervalSince1970: 1_000_000)

    var text = textClip("最近文本", date: threshold.addingTimeInterval(-10))
    text.lastCopiedAt = threshold.addingTimeInterval(10)
    var image = textClip("最近图片", date: threshold.addingTimeInterval(20))
    image.primaryKind = .image
    var oldFile = textClip("旧文件", date: threshold.addingTimeInterval(-100))
    oldFile.primaryKind = .file
    var trashed = textClip("废纸篓链接", date: threshold.addingTimeInterval(30))
    trashed.primaryKind = .link
    trashed.deletedAt = threshold.addingTimeInterval(40)
    try await repository.saveBatch([text, image, oldFile, trashed])

    let recent = try await repository.storedClipKindCounts(since: threshold, before: nil)
    #expect(Dictionary(uniqueKeysWithValues: recent.map { ($0.kind, $0.count) }) == [.text: 1, .image: 1])

    let all = try await repository.storedClipKindCounts(since: nil, before: nil)
    #expect(Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0.count) }) == [.text: 1, .image: 1, .file: 1])
}

@Test func storageAnalyticsSeparatesManagedDirectories() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    try Data(repeating: 1, count: 2_000).write(to: directories.attachments.appendingPathComponent("image.bin"))
    try Data(repeating: 2, count: 3_000).write(to: directories.backups.appendingPathComponent("backup.bin"))
    try Data(repeating: 3, count: 1_000).write(to: directories.logs.appendingPathComponent("pasteory.log"))
    try await repository.save(textClip("统计样本"))

    let service = StorageAnalyticsService(repository: repository, directories: directories)
    let snapshot = try await service.snapshot(period: .all)
    let usage = Dictionary(uniqueKeysWithValues: snapshot.storageUsage.map { ($0.category, $0.byteCount) })

    #expect(snapshot.clipCount == 1)
    #expect(usage[.database, default: 0] > 0)
    #expect(usage[.attachments, default: 0] > 0)
    #expect(usage[.backups, default: 0] > 0)
    #expect(usage[.logs, default: 0] > 0)
    #expect(snapshot.totalStorageBytes >= usage.values.reduce(0, +))
}

@Test func storageAnalyticsIncludesOnlyCurrentVariantsNetworkCacheAndCountsHardLinksOnce() async throws {
    let temporary = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: temporary.root) }
    let cacheRoot = temporary.root.appendingPathComponent("Caches", isDirectory: true)
    let support = temporary.root.appendingPathComponent("Support", isDirectory: true)
    let directories = try AppDirectories(root: support, identity: .qa, cachesRoot: cacheRoot)
    let production = try AppDirectories(root: support, identity: .production, cachesRoot: cacheRoot)
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let cache = try #require(directories.webKitNetworkCache)
    #expect(cache.path.hasSuffix("/app.pasteory.Pasteory.qa/WebKit/NetworkCache"))
    let productionCache = try #require(production.webKitNetworkCache)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: productionCache, withIntermediateDirectories: true)
    let resource = cache.appendingPathComponent("resource")
    try Data(repeating: 1, count: 128_000).write(to: resource)
    try FileManager.default.linkItem(at: resource, to: cache.appendingPathComponent("resource-link"))
    try Data(repeating: 2, count: 256_000).write(to: productionCache.appendingPathComponent("resource"))
    try Data(repeating: 3, count: 256_000).write(to: cache.deletingLastPathComponent().appendingPathComponent("other-webkit-data"))
    let service = StorageAnalyticsService(repository: repository, directories: directories)
    let snapshot = try await service.snapshot(period: .all)
    let usage = try #require(snapshot.storageUsage.first { $0.category == .webKitNetworkCache })
    let values = try resource.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
    let allocated = try #require(values.totalFileAllocatedSize ?? values.fileAllocatedSize)
    #expect(usage.byteCount == Int64(allocated))
    #expect(usage.byteCount >= 128_000)
}

@Test func historyCleanupFiltersByLastUseAndActualBytesAndPreservesProtectedAndSharedFiles() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let attachments = AttachmentStore(directories: directories)
    let cutoff = Date(timeIntervalSince1970: 10_000)
    let old = cutoff.addingTimeInterval(-100)
    let shared = CapturedRepresentation(uti: "public.png", data: Data(repeating: 1, count: 128_000))
    let privateImage = CapturedRepresentation(uti: "public.tiff", data: Data(repeating: 2, count: 128_000))
    let sourceFile = directories.root.appendingPathComponent("original.png")
    try Data(repeating: 3, count: 256_000).write(to: sourceFile)
    let fileReference = CapturedRepresentation(uti: "public.file-url", data: Data(sourceFile.absoluteString.utf8))
    func make(_ data: [CapturedRepresentation], at date: Date) throws -> Clip {
        try #require(ClipClassifier.makeClip(from: PasteboardCapture(
            items: [CapturedItem(order: 0, representations: data)],
            source: ClipSource(), capturedAt: date
        )))
    }
    var candidate = try make([shared, privateImage, fileReference], at: old)
    candidate.title = "旧图片"
    let stored = try await repository.saveCaptured(candidate)
    var favorite = try make([shared], at: old)
    favorite.isFavorite = true
    let savedFavorite = try await attachments.externalize(favorite)
    try await repository.save(savedFavorite)
    var recentlyPasted = try make([privateImage], at: old)
    recentlyPasted.lastPastedAt = cutoff
    let savedRecent = try await attachments.externalize(recentlyPasted)
    try await repository.save(savedRecent)
    var pinned = try make([privateImage], at: old)
    pinned.isPinned = true
    let savedPinned = try await attachments.externalize(pinned)
    try await repository.save(savedPinned)
    let collection = ClipCollection(name: "保留", kind: .normal)
    try await repository.saveCollection(collection)
    var grouped = try make([shared], at: old)
    grouped.collectionIDs.insert(collection.id)
    try await repository.save(attachments.externalize(grouped))
    let referenceOnly = try make([fileReference], at: old)
    try await repository.save(referenceOnly)
    let small = textClip("small", date: old)
    try await repository.save(small)
    let aggregation = ClipAggregation(title: "聚合", memberClipIDs: [small.id, savedRecent.id])
    _ = try await repository.saveAggregation(aggregation)

    let exact = try await repository.previewHistoryCleanup(olderThan: cutoff, largerThan: Int64(stored.byteSize))
    #expect(exact.entries.isEmpty)
    let sharedOnly = try await repository.previewHistoryCleanup(olderThan: cutoff, largerThan: 100_000)
    #expect(sharedOnly.entries.map(\.id) == [stored.id])
    #expect(sharedOnly.reclaimableBytes == 0)
    try await repository.removePermanently(id: savedRecent.id)
    try await repository.removePermanently(id: savedPinned.id)
    let preview = try await repository.previewHistoryCleanup(olderThan: cutoff, largerThan: 100_000)
    #expect(preview.entries.map(\.id) == [stored.id])
    #expect(preview.reclaimableBytes >= 128_000)
    let result = try await repository.cleanHistory(preview)
    #expect(result.deletedCount == 1)
    #expect(result.freedBytes == preview.reclaimableBytes)
    #expect(result.failedFileCount == 0)
    #expect(try await repository.clip(id: stored.id) == nil)
    #expect(try await repository.clip(id: referenceOnly.id) != nil)
    let retained = try #require(savedFavorite.items.first?.representations.first)
    #expect(try await attachments.data(for: retained) == shared.data)
    #expect(try Data(contentsOf: sourceFile) == Data(repeating: 3, count: 256_000))
    let removed = try #require(stored.items.first?.representations.first { $0.uti == privateImage.uti })
    guard case .attachment(let relativePath, _, _) = removed.storage else {
        Issue.record("Expected a stored attachment")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: directories.attachments.appendingPathComponent(relativePath).path))
}

@Test func historyCleanupRejectsStalePreviewAndArchiveCannotRestoreADeletedClip() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let archive = ArchiveService(repository: repository, directories: directories)
    let cutoff = Date(timeIntervalSince1970: 10_000)
    let clip = textClip(String(repeating: "这段历史可以清理", count: 100), date: cutoff.addingTimeInterval(-100))
    try await repository.save(clip)
    let preview = try await repository.previewHistoryCleanup(olderThan: cutoff, largerThan: 0)
    #expect(preview.entries.count == 1)
    _ = try await repository.recordPaste(id: clip.id, at: cutoff)
    await #expect(throws: HistoryCleanupError.previewChanged) {
        try await repository.cleanHistory(preview)
    }
    #expect(try await repository.clip(id: clip.id)?.lastPastedAt == cutoff)
    let updated = try #require(try await repository.clip(id: clip.id))
    try await archive.archive(updated)
    #expect(try await repository.clip(id: clip.id)?.isArchived == true)
    let later = try await repository.previewHistoryCleanup(olderThan: cutoff.addingTimeInterval(100), largerThan: 0)
    #expect(later.reclaimableBytes > 0)
    let result = try await repository.cleanHistory(later)
    #expect(result.deletedCount == 1)
    #expect(result.freedBytes == later.reclaimableBytes)
    try await repository.updateExisting(clip)
    try await archive.archive(clip)
    var staleArchive = clip
    staleArchive.isArchived = true
    #expect(try await repository.saveArchived(staleArchive, replacing: clip) == false)
    #expect(try await repository.clip(id: clip.id) == nil)
}

@Test func sevenDayStorageAnalyticsReturnsOneBucketPerNaturalDay() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 3, hour: 18
    )))
    let firstDay = try #require(StorageAnalyticsPeriod.sevenDays.startDate(containing: now, calendar: calendar))
    let firstSampleDate = try #require(calendar.date(byAdding: .hour, value: 1, to: firstDay))
    let todaySampleDate = try #require(calendar.date(byAdding: .hour, value: -1, to: now))
    var first = textClip("第一天", date: firstSampleDate)
    first.primaryKind = .code
    var today = textClip("今天", date: todaySampleDate)
    today.primaryKind = .image
    try await repository.saveBatch([first, today])

    let service = StorageAnalyticsService(repository: repository, directories: directories)
    let snapshot = try await service.snapshot(period: .sevenDays, now: now, calendar: calendar)

    #expect(snapshot.clipBuckets.count == 7)
    #expect(snapshot.clipBuckets.first?.startDate == firstDay)
    #expect(snapshot.clipBuckets.first?.totalCount == 1)
    #expect(snapshot.clipBuckets.last?.totalCount == 1)
    #expect(snapshot.clipCount == 2)

    let thirtyDaySnapshot = try await service.snapshot(period: .thirtyDays, now: now, calendar: calendar)
    #expect(thirtyDaySnapshot.clipBuckets.count == 30)
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

@Test func repositoryMergesSameTextWhenClipboardFormattingDiffers() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let source = ClipSource(appName: "Chrome", bundleIdentifier: "com.google.Chrome", confidence: .high)
    func richText(_ html: String, at date: Date) throws -> Clip {
        try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [
            CapturedItem(order: 0, representations: [
                CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("4.4.93-alpha.0".utf8)),
                CapturedRepresentation(uti: "public.html", data: Data(html.utf8))
            ])
        ], source: source, capturedAt: date)))
    }

    let first = try richText("<span>4.4.93-alpha.0</span>", at: Date(timeIntervalSince1970: 100))
    let second = try richText("<span class='diff'>4.4.93-alpha.0</span>", at: Date(timeIntervalSince1970: 200))
    #expect(first.contentHash != second.contentHash)
    let stored = try await repository.saveCaptured(first)
    let merged = try await repository.saveCaptured(second)

    #expect(merged.id == stored.id)
    #expect(merged.copyCount == 2)
    #expect(merged.contentHash == second.contentHash)
    #expect(merged.items == second.items)
    #expect(try await repository.allClips().count == 1)
}

@Test func repositoryReusesContentAcrossAppsAndTimeWhileKeepingCaptureEvents() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let firstDate = Date(timeIntervalSince1970: 100)
    var first = textClip("https://example.com/same", date: firstDate, source: "com.google.Chrome")
    first.title = "手动标题"
    first.note = "不要覆盖"
    first.isFavorite = true
    let stored = try await repository.saveCaptured(first)

    let secondDate = firstDate.addingTimeInterval(86_400)
    let second = textClip("https://example.com/same", date: secondDate, source: "com.electron.lark")
    let merged = try await repository.saveCaptured(second)

    #expect(merged.id == stored.id)
    #expect(merged.createdAt == firstDate)
    #expect(merged.lastCopiedAt == secondDate)
    #expect(merged.updatedAt == secondDate)
    #expect(merged.copyCount == 2)
    #expect(merged.recordedPasteCount == 0)
    #expect(merged.source.bundleIdentifier == "com.electron.lark")
    #expect(merged.title == "手动标题")
    #expect(merged.note == "不要覆盖")
    #expect(merged.isFavorite)
    let events = try await repository.captureEvents(for: stored.id, limit: 10)
    #expect(events.count == 2)
    #expect(events.map(\.source.bundleIdentifier) == ["com.electron.lark", "com.google.Chrome"])
}

@Test func copyingArchivedContentReusesAndRestoresTheExistingItem() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let firstDate = Date(timeIntervalSince1970: 100)
    var archived = try await repository.saveCaptured(textClip("archived duplicate", date: firstDate))
    archived.isArchived = true
    try await repository.save(archived)

    let copiedAgain = try await repository.saveCaptured(
        textClip("archived duplicate", date: Date(timeIntervalSince1970: 200), source: "app.second")
    )

    #expect(copiedAgain.id == archived.id)
    #expect(!copiedAgain.isArchived)
    #expect(copiedAgain.copyCount == 2)
    #expect(try await repository.list(filter: .all, query: "", limit: 10).map(\.id) == [archived.id])
}

@Test func repositoryConsolidatesLegacyDuplicatesAndMovesEvents() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let firstDate = Date(timeIntervalSince1970: 100)
    var first = textClip("legacy duplicate", date: firstDate, source: "app.first")
    first.identityKey = nil
    first.copyCount = 2
    first.title = "最早标题"
    let secondDate = Date(timeIntervalSince1970: 200)
    var second = textClip("legacy duplicate", date: secondDate, source: "app.second")
    second.identityKey = nil
    second.copyCount = 3
    second.pasteCount = 4
    second.note = "后续备注"
    second.isPinned = true
    try await repository.save(first)
    try await repository.save(second)
    try await repository.saveCaptureEvents([
        ClipCaptureEvent(clipID: first.id, capturedAt: firstDate, source: first.source),
        ClipCaptureEvent(clipID: second.id, capturedAt: secondDate, source: second.source)
    ])

    #expect(try await repository.consolidateDuplicateClips() == 1)
    let all = try await repository.allClips()
    let merged = try #require(all.first)
    #expect(all.count == 1)
    #expect(merged.id == first.id)
    #expect(merged.copyCount == 5)
    #expect(merged.recordedPasteCount == 4)
    #expect(merged.title == "最早标题")
    #expect(merged.note == "后续备注")
    #expect(merged.isPinned)
    #expect(merged.source.bundleIdentifier == "app.second")
    let events = try await repository.captureEvents(for: merged.id, limit: 10)
    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.clipID == merged.id })
}

@Test func repositoryPersistsAggregationWithUniqueValidMembers() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let first = try await repository.saveCaptured(textClip("member one", date: Date(timeIntervalSince1970: 100)))
    let second = try await repository.saveCaptured(textClip("member two", date: Date(timeIntervalSince1970: 200)))
    let aggregation = ClipAggregation(
        title: "搜索结果",
        note: "abmock",
        memberClipIDs: [first.id, first.id, second.id],
        origin: .search(query: "abmock")
    )

    let stored = try await repository.saveAggregation(aggregation)
    #expect(stored.memberClipIDs == [first.id, second.id])
    let loaded = try #require(try await repository.aggregation(id: stored.id))
    #expect(loaded.id == stored.id)
    #expect(loaded.title == stored.title)
    #expect(loaded.note == stored.note)
    #expect(loaded.memberClipIDs == stored.memberClipIDs)
    #expect(loaded.origin == stored.origin)
    #expect(try await repository.clips(ids: [second.id, first.id, second.id]).map(\.id) == [second.id, first.id])
    #expect(try await repository.aggregations().map(\.id) == [stored.id])
    try await repository.removeAggregation(id: stored.id)
    #expect(try await repository.aggregations().isEmpty)
}

@Test func pasteUsageIsCountedAndMovesTheClipToTheRecentFront() async throws {
    let directories = try temporaryDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let earlierDate = Date(timeIntervalSince1970: 100)
    let laterDate = Date(timeIntervalSince1970: 200)
    let earlier = try await repository.saveCaptured(textClip("较早复制", date: earlierDate))
    let later = try await repository.saveCaptured(textClip("较晚复制", date: laterDate))

    let pasted = try #require(try await repository.recordPaste(id: earlier.id, at: Date(timeIntervalSince1970: 300)))
    #expect(pasted.copyCount == 1)
    #expect(pasted.recordedPasteCount == 1)
    #expect(pasted.lastCopiedAt == earlierDate)
    #expect(pasted.lastPastedAt == Date(timeIntervalSince1970: 300))
    #expect(pasted.lastUsedAt == Date(timeIntervalSince1970: 300))

    let pastedAgain = try #require(try await repository.recordPaste(id: earlier.id, at: Date(timeIntervalSince1970: 400)))
    #expect(pastedAgain.copyCount == 1)
    #expect(pastedAgain.recordedPasteCount == 2)
    #expect(pastedAgain.lastCopiedAt == earlierDate)
    #expect(pastedAgain.lastPastedAt == Date(timeIntervalSince1970: 400))
    #expect(pastedAgain.lastUsedAt == Date(timeIntervalSince1970: 400))

    let ordered = try await repository.list(filter: .all, query: "", limit: 10)
    #expect(ordered.map(\.id) == [earlier.id, later.id])
    #expect(SearchRanker.rank([later, pastedAgain], query: "").map(\.id) == [earlier.id, later.id])
}

@Test func legacyClipWithoutPasteCountStillDecodesAsZero() throws {
    let clip = textClip("旧版记录")
    let encoder = JSONEncoder()
    var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(clip)) as? [String: Any])
    object.removeValue(forKey: "pasteCount")
    object.removeValue(forKey: "lastPastedAt")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(Clip.self, from: legacyData)
    #expect(decoded.recordedPasteCount == 0)
    #expect(decoded.lastPastedAt == nil)
    #expect(decoded.lastUsedAt == decoded.lastCopiedAt)
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
    let secondClip = textClip("备份中的第二项")
    _ = try await sourceRepository.saveCaptured(secondClip)
    let aggregation = try await sourceRepository.saveAggregation(ClipAggregation(
        title: "备份聚合",
        memberClipIDs: [clip.id, secondClip.id],
        origin: .manual
    ))
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
    #expect(try await targetBackup.importBackup(from: backupURL) == 2)
    #expect(try await targetRepository.clip(id: clip.id)?.previewText == "备份内容")
    #expect(try await targetRepository.captureEvents(for: clip.id, limit: 10).first?.context?.summary == "微信 · 文件传输助手")
    #expect(try await targetRepository.userFallbackRules().map(\.name) == ["测试规则"])
    #expect(try await targetRepository.aggregation(id: aggregation.id)?.memberClipIDs == [clip.id, secondClip.id])
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
