import AppKit
import Foundation
import PasteoryAI
import Testing
@testable import Pasteory
@testable import PasteoryCore

private func cacheClip(_ text: String) throws -> Clip {
    try #require(ClipClassifier.makeClip(from: .init(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data(text.utf8))])], source: .init(appName: "Synthetic"))))
}

@Test func repositoryKeepsOneMetadataCacheAndReportsCommittedCRUDChanges() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    var a = try cacheClip("first cache entry"), b = try cacheClip("second cache entry")
    try await repo.saveBatch([a, b])
    let first = try await repo.clipMetadataChanges(since: nil)
    #expect(first.resetsIndex && first.upserts.count == 2 && first.upserts.allSatisfy { $0.items.isEmpty })
    for _ in 0..<3 {
        let same = try await repo.clipMetadataChanges(since: first.revision)
        #expect(same.upserts.isEmpty && same.removedIDs.isEmpty && same.revision == first.revision)
        _ = try await repo.listMetadata(filter: .all, query: "cache", limit: 100, offset: 0)
    }
    a.note = "Changed outside first page"; try await repo.updateExisting(a)
    let edited = try await repo.clipMetadataChanges(since: first.revision)
    #expect(edited.upserts.map(\.id) == [a.id] && edited.upserts.first?.note == a.note)
    b.deletedAt = Date(); try await repo.updateExisting(b)
    let deleted = try await repo.clipMetadataChanges(since: edited.revision)
    #expect(deleted.upserts.first?.deletedAt != nil)
    try await repo.removePermanently(id: b.id)
    let removed = try await repo.clipMetadataChanges(since: deleted.revision)
    #expect(removed.upserts.isEmpty && removed.removedIDs == [b.id])
    // A second connection also advances the committed revision, without resetting the cache.
    let other = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    a.note = "Updated through second connection"; try await other.updateExisting(a)
    let external = try await repo.clipMetadataChanges(since: removed.revision)
    #expect(external.upserts.first?.note == a.note)
    #expect(try await repo.aiClipMetadata().count == 1)
    #expect(await repo.metadataCacheBuildCount() == 1)
}

@MainActor private func syntheticOCRImage(_ label: String = "Pasteory OCR 2468\n本地图片搜索") throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 280,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1400, height: 280).fill()
    (label as NSString).draw(at: NSPoint(x: 40, y: 35), withAttributes: [.font: NSFont.systemFont(ofSize: 60), .foregroundColor: NSColor.black])
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@Test @MainActor func visionRecognizesRealLocalImageAndSearchPersistsWithoutChangingTheOriginal() async throws {
    let image = try syntheticOCRImage()
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let clip = try #require(ClipClassifier.makeClip(from: .init(items: [.init(order: 0, representations: [.init(uti: "public.png", data: image)])], source: .init(appName: "Synthetic image"))))
    _ = try await repo.saveCaptured(clip)
    let stored = try #require(await repo.clip(id: clip.id))
    let service = LocalImageOCRService(repository: repo, attachments: AttachmentStore(directories: dirs))
    let result = try #require(await service.recognize(id: stored.id))
    #expect(result.recognizedImageText.localizedCaseInsensitiveContains("Pasteory"))
    #expect(result.recognizedImageText.contains("2468") && result.recognizedImageText.contains("本地"))
    #expect(result.items == stored.items && result.contentHash == stored.contentHash && result.identityKey == stored.identityKey)
    #expect(result.createdAt == stored.createdAt && result.updatedAt == stored.updatedAt && result.lastCopiedAt == stored.lastCopiedAt)
    #expect(result.copyCount == stored.copyCount && result.recordedPasteCount == stored.recordedPasteCount)
    #expect(result.note.hasPrefix("[OCR:") && result.note.contains("2468"))
    #expect(try await repo.list(filter: .all, query: "2468", limit: 100).map(\.id) == [stored.id])
    #expect(try await repo.list(filter: .all, query: "本地", limit: 100).map(\.id) == [stored.id])
    #expect(try await service.recognize(id: stored.id) == nil)
    let reopened = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    #expect(try await reopened.clip(id: stored.id)?.recognizedImageText == result.recognizedImageText)
    #expect(try await reopened.listMetadata(filter: .all, query: "2468", limit: 100, offset: 0).first?.items.isEmpty == true)
    let privateDoc = try #require(await repo.aiContext(ids: [stored.id], includeNotes: true, includeSource: false).first)
    #expect(!privateDoc.body.contains("2468") && !privateDoc.note.contains("2468"))
    let sharedDoc = try #require(await repo.aiContext(ids: [stored.id], includeNotes: false, includeSource: false, includeImageText: true).first)
    #expect(sharedDoc.body.contains("2468") && sharedDoc.body.contains("Local image OCR"))
}

@Test func savingOCRPreservesConcurrentEditsRejectsChangedContentAndCachesEmptyResults() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    var clip = try cacheClip("synthetic picture metadata"); clip.primaryKind = .image
    try await repo.save(clip)
    let result = LocalOCRResult(contentHash: clip.contentHash, text: "")
    clip.note = "Human note while OCR ran"; clip.isFavorite = true; try await repo.updateExisting(clip)
    let saved = try #require(await repo.saveLocalOCR(result, clipID: clip.id))
    #expect(saved.note == clip.note && saved.isFavorite && saved.hasCurrentOCR && saved.recognizedImageText.isEmpty)
    var staleEdit = clip; staleEdit.note = "Edit from the pre-OCR view"; try await repo.updateExisting(staleEdit)
    #expect(try await repo.clip(id: clip.id)?.hasCurrentOCR == true)
    _ = try await repo.saveLocalOCR(LocalOCRResult(contentHash: clip.contentHash, text: "Detected words"), clipID: clip.id)
    let appended = try #require(await repo.clip(id: clip.id))
    #expect(appended.note == "Edit from the pre-OCR view\n\n[OCR:Detected words]")
    staleEdit.note = "Later human edit"; try await repo.updateExisting(staleEdit)
    #expect(try await repo.clip(id: clip.id)?.note == "Later human edit\n\n[OCR:Detected words]")
    var manualOCR = try #require(await repo.clip(id: clip.id))
    manualOCR.note = "Edited original note\n\n[OCR:Corrected phrase]"; try await repo.updateExisting(manualOCR)
    let corrected = try #require(await repo.clip(id: clip.id))
    #expect(corrected.recognizedImageText == "Corrected phrase" && corrected.localOCR?.text == "Corrected phrase")
    var alternateFormat = clip; alternateFormat.contentHash = "same-pixels-other-format"
    let repeated = corrected.mergingCapture(alternateFormat)
    #expect(repeated.hasCurrentOCR && repeated.recognizedImageText == "Corrected phrase" && repeated.note == corrected.note)
    #expect(repeated.aiDocument(includeNotes: true, includeSource: false).note == "Edited original note")
    #expect(try await repo.list(filter: .all, query: "Detected", limit: 100).isEmpty)
    #expect(try await repo.list(filter: .all, query: "Corrected", limit: 100).map(\.id) == [clip.id])
    let privateNotes = try #require(await repo.aiContext(ids: [clip.id], includeNotes: true, includeSource: false).first)
    #expect(privateNotes.note == "Edited original note" && !privateNotes.body.contains("Corrected"))
    manualOCR = corrected; manualOCR.note = "OCR block removed by user"; try await repo.updateExisting(manualOCR)
    let removed = try #require(await repo.clip(id: clip.id))
    #expect(removed.hasCurrentOCR && removed.recognizedImageText.isEmpty)
    #expect(try await repo.list(filter: .all, query: "Corrected", limit: 100).isEmpty)
    let same = saved.mergingCapture(clip)
    #expect(same.hasCurrentOCR)
    clip.contentHash = "different-image"; try await repo.updateExisting(clip)
    #expect(try await repo.saveLocalOCR(result, clipID: clip.id) == nil)
    var differentIdentity = clip; differentIdentity.identityKey = "different-image-identity"
    #expect(!same.mergingCapture(differentIdentity).hasCurrentOCR)
    let secret = LocalOCRResult(contentHash: clip.contentHash, text: "sk-" + String(repeating: "a", count: 24))
    _ = try await repo.saveLocalOCR(secret, clipID: clip.id)
    #expect(try await repo.aiContext(ids: [clip.id], includeNotes: false, includeSource: false, includeImageText: true).isEmpty)
    #expect(try await repo.aiContext(ids: [clip.id], includeNotes: false, includeSource: false).count == 1)
}

private final class CountingOCRRecognizer: ImageTextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var usedMethods = [LocalOCRMethod]()
    var methods: [LocalOCRMethod] { lock.withLock { usedMethods } }
    func recognize(_ data: Data, method: LocalOCRMethod) throws -> String {
        lock.withLock { usedMethods.append(method) }; return "Synthetic OCR words"
    }
}

@Test @MainActor func automaticOCROnlyProcessesNewImagesWhenEnabledAndAppendsTaggedNotes() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let suite = "OCRSwitch." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    let recognizer = CountingOCRRecognizer()
    let state = AppState(repository: repo, attachments: AttachmentStore(directories: dirs), archive: ArchiveService(repository: repo, directories: dirs),
                         backup: BackupService(repository: repo, directories: dirs), storageAnalyticsService: StorageAnalyticsService(repository: repo, directories: dirs),
                         settings: settings, linkResolutionService: LinkResolutionService(repository: repo), imageTextRecognizer: recognizer)
    func capture(_ image: Data) -> PasteboardCapture {
        .init(items: [.init(order: 0, representations: [.init(uti: "public.png", data: image)])], source: .init(appName: "Synthetic"))
    }
    let old = capture(try syntheticOCRImage("Old picture"))
    let oldClip = try await repo.saveCaptured(try #require(ClipClassifier.makeClip(from: old)))
    #expect(!settings.localImageOCREnabled && settings.localOCRMethod == .visionAccurate)
    await state.bootstrap(processExistingClips: false)
    settings.localImageOCREnabled = true; settings.localOCRMethod = .visionFast
    await state.accept(old); await state.waitForLocalOCR()
    #expect(recognizer.methods.isEmpty)
    #expect(try await repo.clip(id: oldClip.id)?.localOCR == nil)
    await state.accept(capture(try syntheticOCRImage("New picture")))
    await state.waitForLocalOCR()
    #expect(recognizer.methods == [.visionFast])
    let new = try #require(await repo.allClips().first { $0.id != oldClip.id })
    #expect(new.note == "[OCR:Synthetic OCR words]" && new.localOCRRequest == nil)
    settings.localImageOCREnabled = false
    await state.accept(capture(try syntheticOCRImage("Disabled picture"))); await state.waitForLocalOCR()
    #expect(recognizer.methods == [.visionFast])
    let persisted = AppSettings(defaults: defaults)
    #expect(!persisted.localImageOCREnabled && persisted.localOCRMethod == .visionFast)
}
