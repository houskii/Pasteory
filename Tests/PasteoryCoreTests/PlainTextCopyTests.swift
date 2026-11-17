import AppKit
import Foundation
import PasteoryCore
import Testing
@testable import Pasteory

@MainActor
private final class PlainTextCopyFixture {
    let root: URL
    let attachments: AttachmentStore
    let pasteboard: NSPasteboard
    let coordinator: PasteCoordinator

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryPlainCopy-\(UUID())")
        attachments = AttachmentStore(directories: try AppDirectories(root: root))
        pasteboard = NSPasteboard(name: .init("PasteoryPlainCopy.\(UUID())"))
        coordinator = PasteCoordinator(attachments: attachments, pasteboard: pasteboard)
    }

    func cleanup() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    func clip(kind: ClipKind = .image, note: String = "", uti: String = "public.png", data: Data = Data([1, 2, 3])) -> Clip {
        Clip(primaryKind: kind, note: note, source: .init(appName: "Synthetic"),
             previewText: "Preview metadata is not OCR", contentHash: UUID().uuidString, byteSize: data.count,
             items: [.init(order: 0, representations: [.init(uti: uti, storage: .inline(data))])])
    }
}

@Test @MainActor func plainTextCopyUsesTheCurrentImageAndFileNoteWithoutOCRWrappers() async throws {
    let f = try PlainTextCopyFixture(); defer { f.cleanup() }
    for kind in [ClipKind.image, .file, .mixed] {
        let note = "My note\n\n[OCR:Corrected first line\nSecond [label]]\n[OCR:Another block]"
        let clip = f.clip(kind: kind, note: note, uti: kind == .file ? "public.file-url" : "public.png")
        let result = try await f.coordinator.perform(clip, plainText: true, paste: false, target: nil)
        #expect(result == .copied)
        #expect(f.pasteboard.string(forType: .string) == "My note\n\nCorrected first line\nSecond [label]\nAnother block")
        let textTypes: Set<NSPasteboard.PasteboardType> = [.string, .init("NSStringPboardType")]
        #expect(Set(f.pasteboard.types ?? []).isSubset(of: textTypes))
        #expect(clip.note == note)
    }
}

@Test @MainActor func plainTextCopyPreservesTextAndHonorsItsDeclaredEncoding() async throws {
    let f = try PlainTextCopyFixture(); defer { f.cleanup() }
    let original = "  Original [OCR:literal text]\n你好\t"
    let data = try #require(original.data(using: .utf16))
    let clip = f.clip(kind: .text, note: "[OCR:An unrelated annotation]", uti: "public.utf16-plain-text", data: data)
    _ = try await f.coordinator.perform(clip, plainText: true, paste: false, target: nil)
    #expect(f.pasteboard.string(forType: .string) == original)
}

@Test @MainActor func plainTextCopyUsesTheFullRecognitionBeyondTheCardPreviewLimit() async throws {
    let f = try PlainTextCopyFixture(); defer { f.cleanup() }
    let text = String(repeating: "Full OCR text 识别正文\n", count: 500)
    let clip = f.clip(note: "[OCR:\(text)]")
    _ = try await f.coordinator.perform(clip, plainText: true, paste: false, target: nil)
    #expect(f.pasteboard.string(forType: .string) == text)
}

@Test @MainActor func plainTextCopyUsesLegacyRecognitionAndRespectsDeletedOCR() async throws {
    let f = try PlainTextCopyFixture(); defer { f.cleanup() }
    var clip = f.clip()
    clip.localOCR = LocalOCRResult(contentHash: clip.contentHash, text: "Legacy recognition")
    _ = try await f.coordinator.perform(clip, plainText: true, paste: false, target: nil)
    #expect(f.pasteboard.string(forType: .string) == "Legacy recognition")
    clip.localOCR?.appendedNote = "[OCR:Legacy recognition]"
    clip.note = "Only the user's current note"
    _ = try await f.coordinator.perform(clip, plainText: true, paste: false, target: nil)
    #expect(f.pasteboard.string(forType: .string) == "Only the user's current note")
    clip.note = ""
    #expect(try await ClipPlainTextReader.read(clip, attachments: f.attachments) == nil)
}

@Test @MainActor func unavailableImageTextKeepsTheExistingClipboardAndRawCopyKeepsImageBytes() async throws {
    let f = try PlainTextCopyFixture(); defer { f.cleanup() }
    f.pasteboard.setString("Keep this clipboard", forType: .string)
    let clip = f.clip()
    await #expect(throws: PasteError.self) {
        try await f.coordinator.perform(clip, plainText: true, paste: false, target: nil)
    }
    #expect(f.pasteboard.string(forType: .string) == "Keep this clipboard")
    _ = try await f.coordinator.perform(clip, plainText: false, paste: false, target: nil)
    #expect(f.pasteboard.data(forType: .png) == Data([1, 2, 3]))
    #expect(f.pasteboard.string(forType: .string) == nil)
}

@Test func OCRNoteUnwrappingKeepsOrdinaryBracketsWhitespaceAndUnfinishedText() {
    for (note, expected) in [
        ("[Other] [OCR:alpha [label]] [Keep]", "[Other] alpha [label] [Keep]"),
        ("  [OCR:你好\n世界]  ", "  你好\n世界  "),
        ("[OCR:unfinished [label]", "unfinished [label]"),
        ("[OCR:outer [OCR:inner]]", "outer inner"),
        ("notes without an OCR marker []", "notes without an OCR marker []")
    ] {
        #expect(ClipPlainTextReader.unwrapOCR(in: note) == expected)
    }
}
