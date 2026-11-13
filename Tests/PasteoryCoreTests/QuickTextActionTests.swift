import Foundation
import Testing
@testable import PasteoryCore

@Test func quickTextBase64PreservesUTF8WhitespaceAndEmptyInput() throws {
    for input in ["", "hello", "你好 🌈\n", "  hello\n\t", "\u{0000}"] {
        let encoded = try QuickTextAction.base64Encode.apply(to: input)
        #expect(try QuickTextAction.base64Decode.apply(to: encoded) == input)
    }
    #expect(try QuickTextAction.base64Encode.apply(to: "hello") == "aGVsbG8=")
    #expect(try QuickTextAction.base64Decode.apply(to: " aGVs\nbG8 \t") == "hello")
    #expect(try QuickTextAction.base64Decode.apply(to: "8J-YgA") == "😀")
}

@Test func quickTextBase64RejectsInvalidAndBinaryInputs() {
    for input in ["%", "a", "a=", "aGVsbG8===", "a=GVsbG8", "Zg=", "====", "Zh=="] {
        #expect(throws: QuickTextActionError.self) { try QuickTextAction.base64Decode.apply(to: input) }
    }
    #expect(throws: QuickTextActionError.self) { try QuickTextAction.base64Decode.apply(to: "/w==") }
}

@Test func quickTextMD5UsesExactUTF8Bytes() throws {
    #expect(try QuickTextAction.md5.apply(to: "") == "d41d8cd98f00b204e9800998ecf8427e")
    #expect(try QuickTextAction.md5.apply(to: "hello") == "5d41402abc4b2a76b9719d911017c592")
    #expect(try QuickTextAction.md5.apply(to: "你好") == "7eca689f0d3389d9dea66ae112e5cfd7")
    #expect(try QuickTextAction.md5.apply(to: "hello\n") != QuickTextAction.md5.apply(to: "hello"))
}

@Test func quickTextURLRoundTripsParametersWithoutFormDecoding() throws {
    #expect(try QuickTextAction.urlEncode.apply(to: "a b+c/?&=中文") == "a%20b%2Bc%2F%3F%26%3D%E4%B8%AD%E6%96%87")
    #expect(try QuickTextAction.urlEncode.apply(to: "AZaz09-._~") == "AZaz09-._~")
    #expect(try QuickTextAction.urlDecode.apply(to: "a+b%20c") == "a+b c")
    for input in ["", "https://example.com/?name=你好&value=100%", "\n \t😀"] {
        #expect(try QuickTextAction.urlDecode.apply(to: QuickTextAction.urlEncode.apply(to: input)) == input)
    }
    for input in ["%", "%2", "%GG", "%FF", "%E4%B8"] {
        #expect(throws: QuickTextActionError.self) { try QuickTextAction.urlDecode.apply(to: input) }
    }
}

@Test func quickTextColorConvertsChannelsAndAlphaAtTheEnd() throws {
    #expect(try QuickTextAction.rgbaToHex.apply(to: "rgba(255, 128, 0, 0.5)") == "#FF800080")
    #expect(try QuickTextAction.rgbaToHex.apply(to: " RGB(0, 255, 1)\n") == "#00FF01FF")
    #expect(try QuickTextAction.rgbaToHex.apply(to: "rgba(0, 0, 0, 0)") == "#00000000")
    #expect(try QuickTextAction.hexToRGBA.apply(to: "#f80") == "rgba(255, 136, 0, 1)")
    #expect(try QuickTextAction.hexToRGBA.apply(to: "#f808") == "rgba(255, 136, 0, 0.533333)")
    #expect(try QuickTextAction.hexToRGBA.apply(to: " #FF800080\n") == "rgba(255, 128, 0, 0.501961)")
    for alphaByte in 0...255 {
        let hex = String(format: "#ABCD01%02X", alphaByte)
        #expect(try QuickTextAction.rgbaToHex.apply(to: QuickTextAction.hexToRGBA.apply(to: hex)) == hex)
    }
}

@Test func quickTextColorRejectsInvalidRangesAndFormats() {
    for input in ["rgba(256, 0, 0, 1)", "rgba(-1, 0, 0, 1)", "rgba(0, 0, 0, 1.1)",
                  "rgba(0, 0, 0, -0.1)", "rgba(0, 0, 0)", "rgb(0, 0, 0, 1)", "rgb(0.5, 0, 0)",
                  "rgba(999999999999999999999, 0, 0, 1)", "red"] {
        #expect(throws: QuickTextActionError.self) { try QuickTextAction.rgbaToHex.apply(to: input) }
    }
    for input in ["#12", "#12345", "#1234567", "#123456789", "#GG0000", "red", ""] {
        #expect(throws: QuickTextActionError.self) { try QuickTextAction.hexToRGBA.apply(to: input) }
    }
}

@Test func quickTextReaderLoadsCompleteExternalAndArchivedText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryQuickText-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directories = try AppDirectories(root: root)
    let attachments = AttachmentStore(directories: directories, threshold: 1)
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let archive = ArchiveService(repository: repository, directories: directories)
    let text = String(repeating: "完整内容🌈\n", count: 15_000)
    var clip = Clip(primaryKind: .text, source: ClipSource(appName: "Test", confidence: .high),
                    previewText: "截断预览", contentHash: UUID().uuidString, byteSize: text.utf8.count,
                    items: [ClipItem(order: 0, representations: [
                        ClipRepresentation(uti: "public.utf8-plain-text", storage: .inline(Data(text.utf8)))
                    ])])
    #expect(try await ClipTextReader.read(clip, attachments: attachments) == text)
    clip = try await attachments.externalize(clip)
    #expect(try await ClipTextReader.read(clip, attachments: attachments) == text)
    clip.items[0].representations[0].storage = .inline(Data(text.utf8))
    try await repository.save(clip)
    try await archive.archive(clip)
    let archived = try #require(try await repository.allClips().first)
    #expect(archived.isArchived)
    guard case .archived = archived.items[0].representations[0].storage else {
        Issue.record("Expected archived text representation")
        return
    }
    #expect(try await ClipTextReader.read(archived, attachments: attachments) == text)
}

@Test func quickTextReaderRespectsTextEncodingAndDoesNotUseImagePreview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryQuickEncoding-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let attachments = AttachmentStore(directories: try AppDirectories(root: root))
    let text = "你好 UTF-16"
    let data = try #require(text.data(using: .utf16))
    var clip = Clip(primaryKind: .text, source: ClipSource(appName: "Test", confidence: .high),
                    previewText: "预览", contentHash: UUID().uuidString, byteSize: data.count,
                    items: [ClipItem(order: 0, representations: [
                        ClipRepresentation(uti: "public.utf16-plain-text", storage: .inline(data))
                    ])])
    #expect(try await ClipTextReader.read(clip, attachments: attachments) == text)
    clip.items = []
    await #expect(throws: QuickTextActionError.self) { try await ClipTextReader.read(clip, attachments: attachments) }
}
