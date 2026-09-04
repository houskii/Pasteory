import Foundation
import Testing
@testable import Pasteory
@testable import PasteoryCore

@Test func multiFilePresentationLoadsEveryReferencedFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryMultiFilePresentation-\(UUID().uuidString)")
    let directories = try AppDirectories(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("first.hap")
    let secondURL = root.appendingPathComponent("second.txt")
    try Data("hap bytes".utf8).write(to: firstURL)
    try Data("text bytes".utf8).write(to: secondURL)
    let plist = try PropertyListSerialization.data(
        fromPropertyList: [firstURL.path, secondURL.path],
        format: .binary,
        options: 0
    )
    let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(
        items: [CapturedItem(order: 0, representations: [
            CapturedRepresentation(uti: "NSFilenamesPboardType", data: plist)
        ])],
        source: ClipSource(appName: "访达", bundleIdentifier: "com.apple.finder", confidence: .high)
    )))

    let presentations = await ClipFilePresentationLoader.loadAll(
        clip: clip,
        attachments: AttachmentStore(directories: directories)
    )
    #expect(presentations.map(\.name) == ["first.hap", "second.txt"])
    #expect(presentations.allSatisfy { $0.exists == true })

    try FileManager.default.removeItem(at: secondURL)
    let afterDeletion = await ClipFilePresentationLoader.loadAll(
        clip: clip,
        attachments: AttachmentStore(directories: directories)
    )
    #expect(afterDeletion.map(\.isMissing) == [false, true])
}

@Test func deletedOpaqueFinderReferenceKeepsItsRecordedName() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryOpaqueFilePresentation-\(UUID().uuidString)")
    let directories = try AppDirectories(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let reference = Data("file:///.file/id=6571367.999999999".utf8)
    let decodedReferences = FileReferenceDecoder.urls(from: reference, uti: "public.file-url")
    #expect(decodedReferences.count == 1)
    #expect(decodedReferences.first.map(FileReferenceDecoder.isOpaqueFileReference) == true)
    let clip = Clip(
        primaryKind: .file,
        source: ClipSource(appName: "访达", bundleIdentifier: "com.apple.finder", confidence: .high),
        previewText: "douyin-douyin-debug.apk",
        contentHash: "opaque-file-reference",
        byteSize: reference.count,
        items: [ClipItem(order: 0, representations: [
            ClipRepresentation(uti: "public.file-url", storage: .inline(reference))
        ])]
    )

    let presentations = await ClipFilePresentationLoader.loadAll(
        clip: clip,
        attachments: AttachmentStore(directories: directories)
    )

    #expect(presentations.count == 1)
    #expect(presentations.first?.name == "douyin-douyin-debug.apk")
    #expect(presentations.first?.isMissing == true)
}
