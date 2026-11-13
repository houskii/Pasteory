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
        if isDirectory { return L10n.tr("文件夹") }
        guard let byteCount else { return L10n.tr("大小未知") }
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
        L10n.tr("图片格式: \(format ?? L10n.tr("未知"))")
    }

    var dimensionsText: String {
        switch (pixelWidth, pixelHeight) {
        case let (width?, height?):
            return L10n.tr("图片大小: \(width) * \(height)")
        default:
            return L10n.tr("图片大小: 未知")
        }
    }

    var fileSizeText: String {
        guard let byteCount else { return L10n.tr("文件大小: 未知") }
        return L10n.tr("文件大小: \(FileSizeFormatter.string(forByteCount: byteCount))")
    }
}

enum PasteboardFileURLDecoder {
    static func decode(_ data: Data, uti: String) -> URL? {
        decodeAll(data, uti: uti).first
    }

    static func decodeAll(_ data: Data, uti: String) -> [URL] {
        FileReferenceDecoder.urls(from: data, uti: uti)
    }

    static func resolvedPathURL(_ url: URL) -> URL {
        FileReferenceDecoder.resolvedFileURL(url)
    }
}

enum ClipFilePresentationLoader {
    static func fallback(for clip: Clip) -> LoadedFilePresentation {
        let name = FileIconResolver.normalizedFileName(clip.previewText)
        return LoadedFilePresentation(
            name: name.isEmpty ? L10n.tr("未命名文件") : name,
            path: nil,
            byteCount: nil,
            uti: nil,
            isDirectory: false,
            exists: nil
        )
    }

    static func load(clip: Clip, attachments: AttachmentStore) async -> LoadedFilePresentation {
        await loadAll(clip: clip, attachments: attachments).first ?? fallback(for: clip)
    }

    static func loadAll(clip: Clip, attachments: AttachmentStore) async -> [LoadedFilePresentation] {
        var result = [LoadedFilePresentation]()
        let metadata = clip.effectiveFileMetadata
        for item in clip.items.sorted(by: { $0.order < $1.order }) {
            for representation in item.representations.sorted(by: { $0.uti < $1.uti })
            where representation.uti == "public.file-url" || representation.uti == "NSFilenamesPboardType" {
                guard let data = try? await attachments.data(for: representation) else { continue }
                let urls = PasteboardFileURLDecoder.decodeAll(data, uti: representation.uti)
                guard !urls.isEmpty else { continue }
                for url in urls {
                    let index = result.count
                    let fallbackName: String? = metadata.flatMap {
                        $0.fileNames.indices.contains(index) ? $0.fileNames[index] : nil
                    }
                    let fallbackPath: String? = metadata.flatMap { metadata in
                        guard let paths = metadata.filePaths, paths.indices.contains(index) else { return nil }
                        return paths[index]
                    }
                    result.append(presentation(
                        for: url,
                        fallbackName: fallbackName,
                        fallbackPath: fallbackPath
                    ))
                }
                break
            }
        }
        if !result.isEmpty { return result }
        return clip.effectiveFileMetadata?.fileNames.map { name in
            LoadedFilePresentation(
                name: name,
                path: nil,
                byteCount: nil,
                uti: nil,
                isDirectory: false,
                exists: nil
            )
        } ?? [fallback(for: clip)]
    }

    private static func presentation(
        for encodedURL: URL,
        fallbackName: String?,
        fallbackPath: String?
    ) -> LoadedFilePresentation {
        let resolvedURL = PasteboardFileURLDecoder.resolvedPathURL(encodedURL)
        let url = if !resolvedURL.path.isEmpty,
                     !FileReferenceDecoder.isOpaqueFileReference(resolvedURL) {
            resolvedURL
        } else if let fallbackPath, !fallbackPath.isEmpty {
            URL(fileURLWithPath: fallbackPath)
        } else {
            resolvedURL
        }
        let exists = !url.path.isEmpty && FileManager.default.fileExists(atPath: url.path)
        let values = exists
            ? try? url.resourceValues(forKeys: [.nameKey, .fileSizeKey, .typeIdentifierKey, .isDirectoryKey])
            : nil
        return LoadedFilePresentation(
            name: values?.name
                ?? fallbackName
                ?? (url.lastPathComponent.isEmpty ? L10n.tr("未命名文件") : url.lastPathComponent),
            path: url.path.isEmpty ? nil : url.deletingLastPathComponent().path,
            byteCount: values?.fileSize,
            uti: values?.typeIdentifier,
            isDirectory: values?.isDirectory == true,
            exists: exists
        )
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
        .accessibilityLabel(L10n.tr("\(descriptor.label) 文件"))
    }
}

struct PasteoryMultiFileIconView: View {
    let fileNames: [String]
    let accentColor: Color

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                ForEach(Array(fileNames.prefix(3).enumerated()), id: \.offset) { index, name in
                    PasteoryFileIconView(fileName: name)
                        .frame(width: 38, height: 38)
                        .offset(x: CGFloat(index) * 5 - 5, y: CGFloat(index) * -3 + 3)
                }
            }
            Text("\(fileNames.count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minHeight: 17)
                .background(accentColor, in: Capsule())
        }
        .accessibilityLabel(L10n.tr("\(fileNames.count) 个文件"))
    }
}

struct PasteoryFileMetadataDetailsView: View {
    let clip: Clip
    let attachments: AttachmentStore
    var compact = false
    var refreshID: UUID? = nil
    @State private var presentation: LoadedFilePresentation
    @State private var presentations: [LoadedFilePresentation] = []

    init(clip: Clip, attachments: AttachmentStore, compact: Bool = false, refreshID: UUID? = nil) {
        self.clip = clip
        self.attachments = attachments
        self.compact = compact
        self.refreshID = refreshID
        _presentation = State(initialValue: ClipFilePresentationLoader.fallback(for: clip))
    }

    var body: some View {
        Group {
            if let metadata = clip.effectiveFileMetadata, metadata.isMultiple {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(metadata.displayName)
                            .font(.system(size: compact ? 12 : 13, weight: .semibold))
                            .strikethrough(allFilesMissing)
                        if missingFileCount > 0 {
                            Text(allFilesMissing ? L10n.tr("已删除") : L10n.tr("\(missingFileCount) 个已删除"))
                                .font(.system(size: compact ? 8.5 : 9.5, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                .fixedSize()
                        }
                    }
                    Text(metadata.namesSummary)
                        .font(.system(size: compact ? 9.5 : 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(metadata.fileNames.joined(separator: "\n"))
                }
                .opacity(allFilesMissing ? 0.5 : 1)
            } else {
                singleFileBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: refreshTaskID) {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var refreshTaskID: String {
        "\(clip.id.uuidString):\(refreshID?.uuidString ?? "static")"
    }

    private var missingFileCount: Int {
        presentations.filter(\.isMissing).count
    }

    private var allFilesMissing: Bool {
        !presentations.isEmpty && presentations.allSatisfy(\.isMissing)
    }

    private func refresh() async {
        let loaded = await ClipFilePresentationLoader.loadAll(clip: clip, attachments: attachments)
        presentations = loaded
        if let first = loaded.first { presentation = first }
    }

    private var singleFileBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(presentation.name)
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .strikethrough(presentation.isMissing)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(presentation.name)
                if presentation.isMissing {
                    Text(L10n.tr("已删除"))
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
    }
}

struct PasteoryFileDetailPreview: View {
    let clip: Clip
    let attachments: AttachmentStore
    @State private var presentation: LoadedFilePresentation
    @State private var presentations: [LoadedFilePresentation]

    init(clip: Clip, attachments: AttachmentStore) {
        self.clip = clip
        self.attachments = attachments
        _presentation = State(initialValue: ClipFilePresentationLoader.fallback(for: clip))
        _presentations = State(initialValue: [])
    }

    var body: some View {
        Group {
            if clip.effectiveFileMetadata?.isMultiple == true {
                multipleFileBody
            } else {
                singleFileBody
            }
        }
        .task(id: clip.id) {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        presentations = await ClipFilePresentationLoader.loadAll(clip: clip, attachments: attachments)
        if let first = presentations.first { presentation = first }
    }

    private var singleFileBody: some View {
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
                Label(L10n.tr("原文件已删除"), systemImage: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(presentation.isMissing ? 0.5 : 1)
        .frame(maxWidth: .infinity)
    }

    private var multipleFileBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PasteoryMultiFileIconView(
                    fileNames: clip.effectiveFileMetadata?.fileNames ?? presentations.map(\.name),
                    accentColor: .accentColor
                )
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("\(presentations.isEmpty ? (clip.effectiveFileMetadata?.fileCount ?? 0) : presentations.count) 个文件"))
                        .font(.headline)
                    let missingCount = presentations.filter(\.isMissing).count
                    Text(
                        presentations.isEmpty
                            ? L10n.tr("正在读取文件信息")
                            : (missingCount == 0 ? L10n.tr("全部文件可用") : L10n.tr("\(missingCount) 个原文件已删除"))
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(presentations.enumerated()), id: \.offset) { _, file in
                        HStack(spacing: 9) {
                            PasteoryFileIconView(fileName: file.name, uti: file.uti)
                                .frame(width: 30, height: 30)
                                .saturation(file.isMissing ? 0 : 1)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name)
                                    .strikethrough(file.isMissing)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 5) {
                                    Text(file.sizeText)
                                    if file.isMissing { Text(L10n.tr("已删除")) }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .opacity(file.isMissing ? 0.5 : 1)
                        .padding(.horizontal, 8)
                        .frame(height: 42)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
