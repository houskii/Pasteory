import AppKit
import Foundation
import Testing
@testable import PasteoryCore

@Test @MainActor func weChatImageWithFileURLIsCapturedAsImage() throws {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    bitmap.setColor(.red, atX: 0, y: 0)
    let tiff = try #require(bitmap.tiffRepresentation)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setData(Data(), forType: .init("com.trolltech.anymime.application--x-qt-image"))
    item.setData(Data(), forType: .init("com.trolltech.anymime.text--uri-list"))
    item.setString("file:///nonexistent/wechat-image.jpg", forType: .fileURL)
    item.setData(tiff, forType: .tiff)
    #expect(pasteboard.writeObjects([item]))

    let captured = try #require(pasteboard.pasteboardItems?.first)
    let representations = captured.types.compactMap { type in
        captured.data(forType: type).map { CapturedRepresentation(uti: type.rawValue, data: $0) }
    }
    let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(
        items: [CapturedItem(order: 0, representations: representations)],
        source: ClipSource(appName: "微信", bundleIdentifier: "com.tencent.xinWeChat")
    )))
    #expect(clip.primaryKind == .image)
    #expect(clip.previewText == "Image")
    #expect(clip.effectiveFileMetadata == nil)
    #expect(clip.identityKey?.hasPrefix("v2:image:") == true)
    #expect(clip.items[0].representations.count == representations.count)
    let storedImage = try #require(clip.items[0].representations.first { $0.uti == "public.tiff" })
    let imageData = try ClipIdentity.inlineData(for: storedImage)
    #expect(imageData == tiff)
    #expect(NSImage(data: imageData) != nil)
    #expect(clip.items[0].representations.contains { $0.uti == "public.file-url" })
}

@Test(arguments: ["public.file-url", "NSFilenamesPboardType"])
func embeddedImageTakesPriorityOverFileRepresentations(fileType: String) throws {
    let fileData = fileType == "public.file-url"
        ? Data("file:///nonexistent/photo.png".utf8)
        : try PropertyListSerialization.data(fromPropertyList: ["/nonexistent/photo.png"], format: .binary, options: 0)
    let file = CapturedRepresentation(uti: fileType, data: fileData)
    for imageType in ["public.png", "public.tiff", "public.jpeg"] {
        let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [file,
                CapturedRepresentation(uti: imageType, data: Data([1, 2, 3]))
            ])], source: ClipSource()
        )))
        #expect(clip.primaryKind == .image)
    }
    for extras: [CapturedRepresentation] in [[], [CapturedRepresentation(uti: "public.tiff", data: Data())]] {
        let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [file] + extras)], source: ClipSource()
        )))
        #expect(clip.primaryKind == .file)
        #expect(clip.effectiveFileMetadata?.fileNames == ["photo.png"])
    }
}

@Test func separateImageAndFileItemsRemainMixed() throws {
    let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [
        CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.tiff", data: Data([1, 2, 3]))]),
        CapturedItem(order: 1, representations: [CapturedRepresentation(uti: "public.file-url", data: Data("file:///nonexistent/document.txt".utf8))])
    ], source: ClipSource())))
    #expect(clip.primaryKind == .mixed)
    #expect(clip.items.count == 2)
}
