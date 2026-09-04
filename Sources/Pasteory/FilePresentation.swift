import AppKit
import Foundation
import ImageIO
import PasteoryCore
import SwiftUI
import UniformTypeIdentifiers

struct LoadedFilePresentation: Equatable, Sendable {
    var name: String
    var path: String?
    var byteCount: Int?
    var uti: String?
    var isDirectory: Bool
    var exists: Bool?

    var isMissing: Bool { exists == false }

    var sizeText: String {
        if isDirectory { return "文件夹" }
        guard let byteCount else { return "大小未知" }
        return FileSizeFormatter.string(forByteCount: byteCount)
    }

    var shortenedPath: String? {
        guard let path, !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

struct LoadedImagePresentation: Equatable, Sendable {
    var format: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteCount: Int?

    var formatText: String {
        "图片格式: \(format ?? "未知")"
    }

    var dimensionsText: String {
        switch (pixelWidth, pixelHeight) {
        case let (width?, height?):
            return "图片大小: \(width) * \(height)"
        default:
            return "图片大小: 未知"
        }
    }

    var fileSizeText: String {
        guard let byteCount else { return "文件大小: 未知" }
        return "文件大小: \(FileSizeFormatter.string(forByteCount: byteCount))"
    }
}

enum PasteboardFileURLDecoder {
    static func decode(_ data: Data, uti: String) -> URL? {
        if uti == "NSFilenamesPboardType",
           let paths = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String],
           let path = paths.first {
            return URL(fileURLWithPath: path)
        }
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if uti == "public.file-url", value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        return URL(string: value)
    }

    static func resolvedPathURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        return (url as NSURL).filePathURL ?? url
    }
}

enum ClipFilePresentationLoader {
    static func fallback(for clip: Clip) -> LoadedFilePresentation {
        let name = FileIconResolver.normalizedFileName(clip.previewText)
        return LoadedFilePresentation(
            name: name.isEmpty ? "未命名文件" : name,
            path: nil,
            byteCount: nil,
            uti: nil,
            isDirectory: false,
            exists: nil
        )
    }

    static func load(clip: Clip, attachments: AttachmentStore) async -> LoadedFilePresentation {
        let fallback = fallback(for: clip)
        let fileRepresentations = clip.items
            .sorted(by: { $0.order < $1.order })
            .flatMap(\.representations)
            .filter { $0.uti == "public.file-url" || $0.uti == "NSFilenamesPboardType" }

        for representation in fileRepresentations {
            guard let data = try? await attachments.data(for: representation),
                  let encodedURL = PasteboardFileURLDecoder.decode(data, uti: representation.uti) else { continue }
            let url = PasteboardFileURLDecoder.resolvedPathURL(encodedURL)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let values = exists
                ? try? url.resourceValues(forKeys: [.nameKey, .fileSizeKey, .typeIdentifierKey, .isDirectoryKey])
                : nil
            return LoadedFilePresentation(
                name: values?.name ?? (url.lastPathComponent.isEmpty ? fallback.name : url.lastPathComponent),
                path: url.path.isEmpty ? nil : url.deletingLastPathComponent().path,
                byteCount: values?.fileSize,
                uti: values?.typeIdentifier,
                isDirectory: values?.isDirectory == true,
                exists: exists
            )
        }
        return fallback
    }
}

@MainActor
enum ClipImagePresentationLoader {
    private final class CacheEntry: NSObject {
        let presentation: LoadedImagePresentation

        init(_ presentation: LoadedImagePresentation) {
            self.presentation = presentation
        }
    }

    private static let cache: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.countLimit = 240
        return cache
    }()

    static func fallback(for clip: Clip) -> LoadedImagePresentation {
        let representation = imageRepresentations(in: clip).first
        return LoadedImagePresentation(
            format: ImageFormatLabel.format(for: clip),
            pixelWidth: nil,
            pixelHeight: nil,
            byteCount: representation?.storage.byteCount
        )
    }

    static func load(clip: Clip, attachments: AttachmentStore) async -> LoadedImagePresentation {
        let cacheKey = "\(clip.id.uuidString)-\(clip.contentHash)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached.presentation }

        let fallback = fallback(for: clip)
        if clip.primaryKind == .file,
           let filePresentation = await loadFileImage(clip: clip, attachments: attachments, fallback: fallback) {
            cache.setObject(CacheEntry(filePresentation), forKey: cacheKey)
            return filePresentation
        }

        for representation in imageRepresentations(in: clip) {
            guard let data = try? await attachments.data(for: representation) else { continue }
            let format = ImageFormatLabel.format(forUTI: representation.uti) ?? fallback.format
            let presentation = await Task.detached(priority: .utility) {
                inspect(data: data, format: format)
            }.value
            cache.setObject(CacheEntry(presentation), forKey: cacheKey)
            return presentation
        }

        if let filePresentation = await loadFileImage(clip: clip, attachments: attachments, fallback: fallback) {
            cache.setObject(CacheEntry(filePresentation), forKey: cacheKey)
            return filePresentation
        }

        cache.setObject(CacheEntry(fallback), forKey: cacheKey)
        return fallback
    }

    private static func imageRepresentations(in clip: Clip) -> [ClipRepresentation] {
        clip.items
            .sorted(by: { $0.order < $1.order })
            .flatMap(\.representations)
            .filter { ImageFormatLabel.isImageUTI($0.uti) }
    }

    private static func loadFileImage(
        clip: Clip,
        attachments: AttachmentStore,
        fallback: LoadedImagePresentation
    ) async -> LoadedImagePresentation? {
        let fileRepresentations = clip.items
            .sorted(by: { $0.order < $1.order })
            .flatMap(\.representations)
            .filter { $0.uti == "public.file-url" || $0.uti == "NSFilenamesPboardType" }

        for representation in fileRepresentations {
            guard let data = try? await attachments.data(for: representation),
                  let encodedURL = PasteboardFileURLDecoder.decode(data, uti: representation.uti) else { continue }
            let url = PasteboardFileURLDecoder.resolvedPathURL(encodedURL)
            guard ImageFormatLabel.fileNameIsImage(url.lastPathComponent) else { continue }
            return await Task.detached(priority: .utility) {
                inspect(fileURL: url, fallback: fallback)
            }.value
        }
        return nil
    }

    private nonisolated static func inspect(data: Data, format: String?) -> LoadedImagePresentation {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return LoadedImagePresentation(format: format, pixelWidth: nil, pixelHeight: nil, byteCount: data.count)
        }
        let dimensions = pixelDimensions(of: source)
        let detectedFormat = CGImageSourceGetType(source)
            .flatMap { ImageFormatLabel.format(forUTI: $0 as String) }
        return LoadedImagePresentation(
            format: format ?? detectedFormat,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            byteCount: data.count
        )
    }

    private nonisolated static func inspect(
        fileURL: URL,
        fallback: LoadedImagePresentation
    ) -> LoadedImagePresentation {
        let source = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        )
        let dimensions = source.map(pixelDimensions(of:)) ?? (width: nil, height: nil)
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .typeIdentifierKey])
        let format = ImageFormatLabel.format(forFileName: fileURL.lastPathComponent)
            ?? values?.typeIdentifier.flatMap(ImageFormatLabel.format(forUTI:))
            ?? fallback.format
        return LoadedImagePresentation(
            format: format,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            byteCount: values?.fileSize
        )
    }

    private nonisolated static func pixelDimensions(of source: CGImageSource) -> (width: Int?, height: Int?) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any] else { return (nil, nil) }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        return (width, height)
    }
}

@MainActor
enum PasteoryFileIconStore {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func image(assetName: String) -> NSImage? {
        let key = assetName as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var candidates = [URL]()
        if let packaged = Bundle.main.url(forResource: assetName, withExtension: "png", subdirectory: "FileIcons") {
            candidates.append(packaged)
        }
#if DEBUG
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources/FileIcons/\(assetName).png")
        )
#endif
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let image = NSImage(contentsOf: url) else { continue }
            cache.setObject(image, forKey: key, cost: 128 * 128 * 4)
            return image
        }
        return nil
    }
}

struct PasteoryFileIconView: View {
    let fileName: String
    var uti: String?

    private var descriptor: FileIconDescriptor {
        FileIconResolver.descriptor(fileName: fileName, uti: uti)
    }

    var body: some View {
        Group {
            if let image = PasteoryFileIconStore.image(assetName: descriptor.assetName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "doc.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .accessibilityLabel("\(descriptor.label) 文件")
    }
}

struct PasteoryFileMetadataDetailsView: View {
    let clip: Clip
    let attachments: AttachmentStore
    var compact = false
    @State private var presentation: LoadedFilePresentation

    init(clip: Clip, attachments: AttachmentStore, compact: Bool = false) {
        self.clip = clip
        self.attachments = attachments
        self.compact = compact
        _presentation = State(initialValue: ClipFilePresentationLoader.fallback(for: clip))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(presentation.name)
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .strikethrough(presentation.isMissing)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(presentation.name)
                if presentation.isMissing {
                    Text("已删除")
                        .font(.system(size: compact ? 8.5 : 9.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .fixedSize()
                }
            }

            HStack(spacing: 6) {
                if let path = presentation.shortenedPath {
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(presentation.path ?? path)
                        .layoutPriority(1)
                }
                Text(presentation.sizeText)
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(.system(size: compact ? 9.5 : 10.5))
            .foregroundStyle(.secondary)
        }
        .opacity(presentation.isMissing ? 0.5 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: clip.id) {
            presentation = await ClipFilePresentationLoader.load(clip: clip, attachments: attachments)
        }
    }
}

struct PasteoryFileDetailPreview: View {
    let clip: Clip
    let attachments: AttachmentStore
    @State private var presentation: LoadedFilePresentation

    init(clip: Clip, attachments: AttachmentStore) {
        self.clip = clip
        self.attachments = attachments
        _presentation = State(initialValue: ClipFilePresentationLoader.fallback(for: clip))
    }

    var body: some View {
        VStack(spacing: 12) {
            PasteoryFileIconView(fileName: presentation.name, uti: presentation.uti)
                .frame(width: 88, height: 88)
                .saturation(presentation.isMissing ? 0 : 1)
            Text(presentation.name)
                .font(.headline)
                .strikethrough(presentation.isMissing)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let path = presentation.shortenedPath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            Text(presentation.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if presentation.isMissing {
                Label("原文件已删除", systemImage: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(presentation.isMissing ? 0.5 : 1)
        .frame(maxWidth: .infinity)
        .task(id: clip.id) {
            presentation = await ClipFilePresentationLoader.load(clip: clip, attachments: attachments)
        }
    }
}

struct PasteoryImageMetadataDetailsView: View {
    let clip: Clip
    let attachments: AttachmentStore
    var compact = false
    @State private var presentation: LoadedImagePresentation

    init(clip: Clip, attachments: AttachmentStore, compact: Bool = false) {
        self.clip = clip
        self.attachments = attachments
        self.compact = compact
        _presentation = State(initialValue: ClipImagePresentationLoader.fallback(for: clip))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presentation.formatText)
            Text(presentation.dimensionsText)
                .monospacedDigit()
            Text(presentation.fileSizeText)
                .monospacedDigit()
        }
        .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .task(id: clip.id) {
            presentation = await ClipImagePresentationLoader.load(clip: clip, attachments: attachments)
        }
    }
}

enum ImageFormatLabel {
    private static let imageExtensions = Set(["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "svg", "tif", "tiff", "bmp"])
    private static let labelsByUTI: [String: String] = [
        "public.png": "png",
        "public.tiff": "tiff",
        "public.jpeg": "jpeg",
        "public.jpeg-2000": "jpeg",
        "public.heic": "heic",
        "public.heif": "heif",
        "com.compuserve.gif": "gif",
        "org.webmproject.webp": "webp",
        "public.svg-image": "svg"
    ]

    static func format(for clip: Clip) -> String? {
        let fileName = FileIconResolver.normalizedFileName(clip.previewText)
        if let fileFormat = format(forFileName: fileName) { return fileFormat }
        for representation in clip.items.flatMap(\.representations) {
            if let label = format(forUTI: representation.uti) { return label }
        }
        return nil
    }

    static func format(forFileName fileName: String) -> String? {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return imageExtensions.contains(fileExtension) ? fileExtension : nil
    }

    static func format(forUTI uti: String) -> String? {
        labelsByUTI[uti]
    }

    static func isImageUTI(_ uti: String) -> Bool {
        labelsByUTI[uti] != nil || UTType(uti)?.conforms(to: .image) == true
    }

    static func fileNameIsImage(_ fileName: String) -> Bool {
        imageExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
    }
}
