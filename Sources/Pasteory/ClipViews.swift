import AppKit
import ImageIO
import PasteoryCore
import SwiftUI
import UniformTypeIdentifiers

enum ClipRowMetrics {
    static func height(for clip: Clip, compact: Bool) -> CGFloat {
        switch clip.primaryKind {
        case .code: compact ? 96 : 104
        case .link: compact ? 86 : 92
        case .file: compact ? 96 : 104
        case .image:
            imageContentHeight(for: clip, compact: compact) + (compact ? 30 : 34)
        default: compact ? 72 : 82
        }
    }

    static func imageContentHeight(for clip: Clip, compact: Bool) -> CGFloat {
        var height: CGFloat = compact ? 58 : 62
        if !clip.displayTitle.isEmpty { height += compact ? 14 : 15 }
        if !clip.note.isEmpty { height += compact ? 13 : 14 }
        return height
    }
}

struct ClipRowView: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
    let clip: Clip
    let attachments: AttachmentStore?
    var compact = false
    var shortcutNumber: Int? = nil
    var filePresentationRefreshID: UUID? = nil
    @State private var fileIsMissing = false

    private var rowHeight: CGFloat { ClipRowMetrics.height(for: clip, compact: compact) }

    var body: some View {
        HStack(
            alignment: .center,
            spacing: ClipSourceLayout.usesVerticalIdentity ? 6 : 10
        ) {
            leadingArea
            VStack(alignment: .leading, spacing: 3) {
                mainContent
                HStack(spacing: 7) {
                    if !ClipSourceLayout.usesVerticalIdentity {
                        Text(String(clip.source.appName.prefix(40)))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                    }
                    Text(timestamp)
                        .monospacedDigit()
                        .fixedSize()
                        .layoutPriority(2)
                    if clip.primaryKind != .file, clip.items.count > 1 {
                        Text(L10n.tr("\(clip.items.count) 项"))
                    }
                    if clip.primaryKind == .code,
                       let lineCount = clip.codeMetadata?.totalLineCount,
                       lineCount > 1 {
                        Text(L10n.tr("\(lineCount) 行")).fixedSize()
                    }
                    usageCount
                        .fixedSize()
                        .layoutPriority(2)
                        .help(L10n.tr("复制 \(clip.copyCount) 次，通过 Pasteory 粘贴 \(clip.recordedPasteCount) 次"))
                        .accessibilityLabel(L10n.tr("复制 \(clip.copyCount) 次，通过 Pasteory 粘贴 \(clip.recordedPasteCount) 次"))
                    if clip.isPinned { Image(systemName: "pin.fill").foregroundStyle(pasteoryAccentColor).help(L10n.tr("已置顶")) }
                    if clip.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if clip.priority > 0 { Text("P\(clip.priority)").font(.caption2.bold()).foregroundStyle(pasteoryAccentColor) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                if !ClipTypeMarkerPreview.overlaysSourceIcon {
                    ClipKindLabel(clip: clip)
                }
                Spacer(minLength: 0)
                if let shortcutNumber {
                    Text("⌘ \(shortcutNumber)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize()
                }
            }
            .frame(
                width: ClipTypeMarkerPreview.overlaysSourceIcon ? (compact ? 34 : 38) : (compact ? 54 : 58),
                height: max(56, rowHeight - 16),
                alignment: .trailing
            )
            .padding(.trailing, 4)
            .padding(.bottom, 4)
        }
        .saturation(fileIsMissing ? 0 : 1)
        .opacity(fileIsMissing ? 0.5 : 1)
        .frame(height: rowHeight)
        .clipped()
        .modifier(ClipRowAccessibility(summary: accessibilitySummary))
        .task(id: filePresentationTaskID) {
            await refreshFileAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshFileAvailability() }
        }
    }

    @ViewBuilder
    private var usageCount: some View {
        if compact && L10n.language == .english {
            HStack(spacing: 3) {
                Image(systemName: "doc.on.doc")
                Text(CompactCountFormatter.string(for: clip.copyCount))
                Text("·")
                Image(systemName: "doc.on.clipboard")
                Text(CompactCountFormatter.string(for: clip.recordedPasteCount))
            }
        } else {
            Text(
                L10n.tr("复制 ×\(CompactCountFormatter.string(for: clip.copyCount)) · ")
                    + L10n.tr("粘贴 ×\(CompactCountFormatter.string(for: clip.recordedPasteCount))")
            )
        }
    }

    private var timestamp: String {
        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: clip.lastUsedAt)
        return String(format: "%02d-%02d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    @ViewBuilder
    private var leadingArea: some View {
        if ClipSourceLayout.usesVerticalIdentity {
            VStack(spacing: 1) {
                ClipLeadingVisual(clip: clip, showsTypeBadge: true)
                    .frame(width: compact ? 38 : 46, height: compact ? 38 : 46)
                Text(String(clip.source.appName.prefix(12)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 8.5, weight: .medium))
            .frame(width: compact ? 54 : 60, height: compact ? 54 : 60, alignment: .center)
        } else {
            ClipLeadingVisual(clip: clip)
                .frame(width: compact ? 38 : 46, height: compact ? 38 : 46)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if hasImagePreview, let attachments {
            HStack(spacing: 8) {
                ClipInlineThumbnail(
                    clip: clip,
                    attachments: attachments,
                    width: compact ? 52 : 60,
                    height: compact ? 42 : 46
                )
                VStack(alignment: .leading, spacing: 3) {
                    if !clip.displayTitle.isEmpty { titleText }
                    if clip.primaryKind == .file {
                        PasteoryFileMetadataDetailsView(
                            clip: clip,
                            attachments: attachments,
                            compact: compact,
                            refreshID: filePresentationRefreshID
                        )
                    } else {
                        PasteoryImageMetadataDetailsView(
                            clip: clip,
                            attachments: attachments,
                            compact: compact
                        )
                    }
                    if !clip.note.isEmpty { noteText }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(
                height: clip.primaryKind == .file
                    ? (compact ? 62 : 66)
                    : (clip.primaryKind == .image
                        ? ClipRowMetrics.imageContentHeight(for: clip, compact: compact)
                        : (compact ? 42 : 46)),
                alignment: .leading
            )
        } else if clip.primaryKind == .file {
            HStack(spacing: 8) {
                if let metadata = clip.effectiveFileMetadata, metadata.isMultiple {
                    PasteoryMultiFileIconView(
                        fileNames: metadata.fileNames,
                        accentColor: pasteoryAccentColor
                    )
                    .frame(width: compact ? 52 : 60, height: compact ? 52 : 60)
                } else {
                    PasteoryFileIconView(fileName: FileIconResolver.normalizedFileName(clip.previewText))
                        .frame(width: compact ? 52 : 60, height: compact ? 52 : 60)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if !clip.displayTitle.isEmpty { titleText }
                    if let attachments {
                        PasteoryFileMetadataDetailsView(
                            clip: clip,
                            attachments: attachments,
                            compact: compact,
                            refreshID: filePresentationRefreshID
                        )
                    } else {
                        Text(FileIconResolver.normalizedFileName(clip.previewText))
                            .strikethrough(fileIsMissing)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !clip.note.isEmpty { noteText }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: compact ? 62 : 66, alignment: .leading)
        } else if clip.primaryKind == .color, let color = ColorParser.color(from: clip.previewText) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color)
                    .frame(width: compact ? 42 : 48, height: compact ? 42 : 48)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(.primary.opacity(0.16), lineWidth: 1)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    if !clip.displayTitle.isEmpty { titleText }
                    Text(clip.previewText.uppercased())
                        .font(.system(size: compact ? 12 : 13, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    if !clip.note.isEmpty { noteText }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: compact ? 42 : 48, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if !clip.displayTitle.isEmpty {
                    titleText
                    primaryContentText
                } else {
                    primaryContentText
                }
                if !clip.note.isEmpty { noteText }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var titleText: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag.fill")
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
                .fixedSize()
                .accessibilityHidden(true)
            Text(String(clip.displayTitle.prefix(120)))
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .strikethrough(fileIsMissing)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
        .foregroundStyle(pasteoryAccentColor)
        .help(String(clip.displayTitle.prefix(500)))
    }

    @ViewBuilder
    private var primaryContentText: some View {
        if clip.primaryKind == .code {
            Text(displayPreview)
                .font(.system(size: compact ? 12 : 13, weight: .regular, design: .monospaced))
                .foregroundStyle(clip.primaryKind.markerColor)
                .lineLimit(richContentLineLimit)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(clip.primaryKind.markerColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else if clip.primaryKind == .link {
            Text(displayPreview)
                .font(.system(size: compact ? 12.5 : 13.5, weight: .regular))
                .foregroundStyle(clip.primaryKind.markerColor)
                .lineLimit(richContentLineLimit)
                .truncationMode(.middle)
        } else {
            Text(displayPreview)
                .font(.system(size: compact ? 13 : 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(clip.displayTitle.isEmpty && clip.note.isEmpty ? 2 : 1)
                .truncationMode(.tail)
        }
    }

    private var noteText: some View {
        HStack(spacing: 4) {
            Image(systemName: "note.text").font(.system(size: 9))
            Text(String(clip.note.prefix(160))).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: compact ? 10 : 11))
        .foregroundStyle(.tertiary)
        .help(String(clip.note.prefix(500)))
    }

    private var displayPreview: String {
        if clip.primaryKind == .code {
            return CodePreviewSummary.make(
                from: clip.previewText,
                language: clip.codeMetadata?.language,
                maximumLines: richContentLineLimit
            )
        }
        return String(clip.previewText.prefix(360))
    }

    private var richContentLineLimit: Int {
        if clip.displayTitle.isEmpty && clip.note.isEmpty { return 3 }
        if clip.displayTitle.isEmpty || clip.note.isEmpty { return 2 }
        return 1
    }

    private var filePresentationTaskID: String {
        "\(clip.id.uuidString):\(filePresentationRefreshID?.uuidString ?? "static")"
    }

    private func refreshFileAvailability() async {
        guard clip.primaryKind == .file, let attachments else {
            fileIsMissing = false
            return
        }
        let presentations = await ClipFilePresentationLoader.loadAll(
            clip: clip,
            attachments: attachments
        )
        fileIsMissing = !presentations.isEmpty && presentations.allSatisfy(\.isMissing)
    }

    private var accessibilitySummary: String {
        let title = String(clip.displayTitle.prefix(120))
        let preview = String(clip.previewText.prefix(240))
        let note = String(clip.note.prefix(160))
        return L10n.tr("\(clip.primaryKind.displayName)，\(title)，\(preview)，\(note)，来自 \(String(clip.source.appName.prefix(80)))\(clip.isPinned ? L10n.tr("，已置顶") : "")")
    }

    private var hasImagePreview: Bool {
        if clip.primaryKind == .image { return true }
        if clip.primaryKind == .file {
            if clip.effectiveFileMetadata?.isMultiple == true { return false }
            return ImageFormatLabel.fileNameIsImage(FileIconResolver.normalizedFileName(clip.previewText))
        }
        let supportedImageUTIs = Set(["public.png", "public.tiff", "public.jpeg", "public.jpeg-2000", "public.heic", "public.heif", "com.compuserve.gif", "org.webmproject.webp", "public.svg-image"])
        return clip.items.contains { item in
            item.representations.contains { supportedImageUTIs.contains($0.uti) }
        }
    }
}

private enum CodePreviewSummary {
    static func make(from source: String, language: CodeLanguage?, maximumLines: Int) -> String {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return source }

        let declarationPrefixes = [
            "func ", "struct ", "class ", "enum ", "protocol ", "extension ", "actor ",
            "def ", "async def ", "fun ", "data class ", "interface ", "public class ",
            "private class ", "protected class ", "const ", "function ", "export ",
            "select ", "insert ", "update ", "delete ", "diff --git"
        ]
        let anchor = lines.firstIndex { line in
            let value = line.trimmingCharacters(in: .whitespaces).lowercased()
            return declarationPrefixes.contains { value.hasPrefix($0) }
        } ?? lines.firstIndex { line in
            let value = line.trimmingCharacters(in: .whitespaces).lowercased()
            return !value.hasPrefix("import ")
                && !value.hasPrefix("package ")
                && !value.hasPrefix("using ")
                && !value.hasPrefix("//")
                && !value.hasPrefix("/*")
                && !value.hasPrefix("#")
        } ?? 0

        let selected = Array(lines[anchor...].prefix(max(maximumLines, 1)))
        let commonIndent = selected.map(leadingWhitespaceCount).min() ?? 0
        return selected.map { line in
            String(line.dropFirst(min(commonIndent, line.count))).prefix(180)
        }.map(String.init).joined(separator: "\n")
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }
}

private struct ClipRowAccessibility: ViewModifier {
    let summary: String

    @ViewBuilder
    func body(content: Content) -> some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-ui-qa") {
            content.accessibilityHidden(true)
        } else {
            content.accessibilityElement(children: .combine).accessibilityLabel(summary)
        }
#else
        content.accessibilityElement(children: .combine).accessibilityLabel(summary)
#endif
    }
}

private struct ClipLeadingVisual: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
    let clip: Clip
    var showsTypeBadge = ClipTypeMarkerPreview.overlaysSourceIcon

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if let appIcon = ApplicationCatalog.icon(
                    for: clip.source.bundleIdentifier,
                    fallbackName: clip.source.appName
                ) {
                    Image(nsImage: appIcon).resizable().scaledToFit().padding(3)
                } else {
                    RoundedRectangle(cornerRadius: 9).fill(pasteoryAccentColor.opacity(0.12))
                    Image(systemName: clip.primaryKind.symbolName).foregroundStyle(pasteoryAccentColor)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))

            if showsTypeBadge {
                ClipTypeBadge(kind: clip.primaryKind)
                    .offset(x: 2, y: 2)
            }
        }
    }
}

private struct ClipTypeBadge: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
    let kind: ClipKind

    private let diameter: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
            Circle()
                .fill(pasteoryAccentColor)
                .padding(1.5)
            Image(systemName: kind.symbolName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: diameter - 3, height: diameter - 3, alignment: .center)
        }
        .frame(width: diameter, height: diameter, alignment: .center)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

private struct ClipKindLabel: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
    let clip: Clip

    var body: some View {
        Text(clip.codeMetadata?.displayName ?? clip.primaryKind.displayName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(pasteoryAccentColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(pasteoryAccentColor.opacity(0.10), in: Capsule())
            .accessibilityHidden(true)
    }
}

private extension ClipKind {
    var markerColor: Color {
        switch self {
        case .text: Color(red: 0.39, green: 0.40, blue: 0.95)
        case .image: Color(red: 0.86, green: 0.15, blue: 0.47)
        case .link: Color(red: 0.10, green: 0.45, blue: 0.86)
        case .color: Color(red: 0.85, green: 0.40, blue: 0.08)
        case .code: Color(red: 0.49, green: 0.23, blue: 0.93)
        case .file: Color(red: 0.06, green: 0.62, blue: 0.56)
        case .mixed: Color(red: 0.42, green: 0.40, blue: 0.45)
        }
    }
}

private enum ClipTypeMarkerPreview {
    static var overlaysSourceIcon: Bool {
#if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--debug-type-marker-as-label")
#else
        true
#endif
    }
}

private enum ClipSourceLayout {
    static var usesVerticalIdentity: Bool {
#if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--debug-source-type-overlay")
#else
        true
#endif
    }
}

private struct ClipInlineThumbnail: View {
    let clip: Clip
    let attachments: AttachmentStore
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?
    @State private var didFinishLoading = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else if !didFinishLoading {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary)
                    .frame(width: width, height: height)
                    .overlay { ProgressView().controlSize(.small) }
            } else if clip.primaryKind == .file {
                PasteoryFileIconView(fileName: FileIconResolver.normalizedFileName(clip.previewText))
                    .padding(2)
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1))
        .task(id: clip.id) {
            image = nil
            didFinishLoading = false
            image = await ClipImageLoader.loadThumbnail(clip: clip, attachments: attachments)
            didFinishLoading = true
        }
    }
}

@MainActor
private enum ClipImageLoader {
    private struct SendableCGImage: @unchecked Sendable {
        let value: CGImage
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func loadThumbnail(clip: Clip, attachments: AttachmentStore) async -> NSImage? {
        let cacheKey = "thumbnail-\(clip.id.uuidString)-\(clip.contentHash)" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }
        for item in clip.items {
            for representation in item.representations where isImageUTI(representation.uti) {
                guard let data = try? await attachments.data(for: representation),
                      let image = await makeThumbnail(from: data) else { continue }
                thumbnailCache.setObject(image, forKey: cacheKey, cost: 192 * 192 * 4)
                return image
            }
        }
        guard clip.primaryKind == .file else { return nil }
        for item in clip.items {
            for representation in item.representations where representation.uti == "public.file-url" || representation.uti == "NSFilenamesPboardType" {
                guard let data = try? await attachments.data(for: representation),
                      let url = fileURL(from: data, uti: representation.uti), isImageFile(url),
                      let image = await makeThumbnail(from: url) else { continue }
                thumbnailCache.setObject(image, forKey: cacheKey, cost: 192 * 192 * 4)
                return image
            }
        }
        return nil
    }

    static func load(clip: Clip, attachments: AttachmentStore) async -> NSImage? {
        let cacheKey = "\(clip.id.uuidString)-\(clip.contentHash)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        for item in clip.items {
            for representation in item.representations where isImageUTI(representation.uti) {
                if let data = try? await attachments.data(for: representation), let image = NSImage(data: data) {
                    cache.setObject(image, forKey: cacheKey, cost: data.count)
                    return image
                }
            }
        }
        guard clip.primaryKind == .file else { return nil }
        for item in clip.items {
            for representation in item.representations where representation.uti == "public.file-url" || representation.uti == "NSFilenamesPboardType" {
                guard let data = try? await attachments.data(for: representation), let url = fileURL(from: data, uti: representation.uti), isImageFile(url) else { continue }
                if let image = NSImage(contentsOf: url) {
                    cache.setObject(image, forKey: cacheKey)
                    return image
                }
            }
        }
        return nil
    }

    private static func makeThumbnail(from data: Data) async -> NSImage? {
        let result = await Task.detached(priority: .utility) { () -> SendableCGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
            return SendableCGImage(value: image)
        }.value
        guard let result else { return nil }
        return NSImage(cgImage: result.value, size: .zero)
    }

    private static func makeThumbnail(from url: URL) async -> NSImage? {
        let result = await Task.detached(priority: .utility) { () -> SendableCGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
            return SendableCGImage(value: image)
        }.value
        guard let result else { return nil }
        return NSImage(cgImage: result.value, size: .zero)
    }

    private nonisolated static var thumbnailOptions: CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 192
        ] as CFDictionary
    }

    private static func isImageUTI(_ uti: String) -> Bool {
        ["public.png", "public.tiff", "public.jpeg", "public.jpeg-2000", "public.heic", "public.heif", "com.compuserve.gif", "org.webmproject.webp"].contains(uti)
    }

    private static func fileURL(from data: Data, uti: String) -> URL? {
        guard let url = PasteboardFileURLDecoder.decode(data, uti: uti) else { return nil }
        return PasteboardFileURLDecoder.resolvedPathURL(url)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"].contains(url.pathExtension.lowercased())
    }
}

private struct LoadedCodeText: Equatable {
    let text: String
    let isTruncated: Bool
}

private enum ClipCodeTextLoader {
    private static let maximumPreviewBytes = 64 * 1024
    private static let legacyTextTypes = Set(["NSStringPboardType", "public.utf8-plain-text", "public.utf16-plain-text", "public.text"])

    static func load(clip: Clip, attachments: AttachmentStore) async -> LoadedCodeText? {
        let representations = clip.items
            .sorted(by: { $0.order < $1.order })
            .flatMap(\.representations)
            .filter { representation in
                let type = UTType(representation.uti)
                return legacyTextTypes.contains(representation.uti)
                    || type?.conforms(to: .sourceCode) == true
                    || type?.conforms(to: .text) == true
            }
            .sorted { rank($0.uti) < rank($1.uti) }

        for representation in representations {
            guard let data = try? await attachments.data(for: representation) else { continue }
            var previewByteCount = min(data.count, maximumPreviewBytes)
            if representation.uti.localizedCaseInsensitiveContains("utf16") {
                previewByteCount -= previewByteCount % 2
            }
            let previewData = Data(data.prefix(previewByteCount))
            let text: String?
            if representation.uti.localizedCaseInsensitiveContains("utf16") {
                text = String(data: previewData, encoding: .utf16)
                    ?? String(data: data, encoding: .utf16).map { String($0.prefix(maximumPreviewBytes / 2)) }
            } else {
                text = String(decoding: previewData, as: UTF8.self)
            }
            if let text, !text.isEmpty {
                return LoadedCodeText(text: text, isTruncated: data.count > previewByteCount)
            }
        }
        return nil
    }

    private static func rank(_ uti: String) -> Int {
        if UTType(uti)?.conforms(to: .sourceCode) == true { return 0 }
        if uti == "public.utf8-plain-text" { return 1 }
        if uti == "public.utf16-plain-text" { return 2 }
        if UTType(uti)?.conforms(to: .text) == true { return 3 }
        return 4
    }
}

struct RepresentationPreview: View {
    let clip: Clip
    let attachments: AttachmentStore
    @State private var image: NSImage?
    @State private var loadedCodeText: LoadedCodeText?

    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: image).resizable().scaledToFit()
                    PasteoryImageMetadataDetailsView(clip: clip, attachments: attachments)
                }
            } else if clip.primaryKind == .color, let color = ColorParser.color(from: clip.previewText) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(color)
                        .frame(width: 150, height: 150)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.primary.opacity(0.16), lineWidth: 1)
                        }
                    Text(clip.previewText.uppercased())
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if clip.primaryKind == .code {
                CodeSnippetPreview(
                    text: loadedCodeText?.text ?? clip.previewText,
                    metadata: clip.codeMetadata,
                    isTruncated: loadedCodeText?.isTruncated ?? false
                )
            } else if clip.primaryKind == .file {
                PasteoryFileDetailPreview(clip: clip, attachments: attachments)
            } else {
                ScrollView {
                    Text(clip.previewText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: clip.id) { await loadRepresentations() }
    }

    private func loadRepresentations() async {
        image = nil
        loadedCodeText = nil
        image = await ClipImageLoader.load(clip: clip, attachments: attachments)
        loadedCodeText = clip.primaryKind == .code
            ? await ClipCodeTextLoader.load(clip: clip, attachments: attachments)
            : nil
    }
}

private struct CodeSnippetPreview: View {
    let text: String
    let metadata: CodeMetadata?
    let isTruncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .bold))
                Text(metadata?.displayName ?? L10n.tr("代码"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let lineCount = metadata?.totalLineCount, lineCount > 1 {
                    Text(L10n.tr("\(lineCount) 行"))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let metadata {
                    Text("\(Int((metadata.confidence * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(L10n.tr("代码识别置信度"))
                }
            }
            .foregroundStyle(ClipKind.code.markerColor)
            .padding(.horizontal, 10)
            .frame(height: 30)

            Divider().opacity(0.55)

            ScrollView([.horizontal, .vertical]) {
                Text(CodeSyntaxHighlighter.highlight(text, language: metadata?.language))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)

            if isTruncated {
                Divider().opacity(0.55)
                Text(L10n.tr("仅预览前 64 KB，复制仍保留完整内容"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
            }
        }
        .background(ClipKind.code.markerColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ClipKind.code.markerColor.opacity(0.16), lineWidth: 1))
    }
}

private enum CodeSyntaxHighlighter {
    static func highlight(_ source: String, language: CodeLanguage?) -> AttributedString {
        var result = AttributedString(source)
        result.font = .system(.body, design: .monospaced)
        result.foregroundColor = .primary

        apply(#"\b\d+(?:\.\d+)?\b"#, color: .orange, source: source, result: &result)
        if let keywordPattern = keywordPattern(for: language) {
            apply(keywordPattern, color: .purple, source: source, result: &result)
        }
        if language == .html || language == .xml {
            apply(#"</?[A-Za-z_][\w:.-]*(?:\s+[^<>]*?)?/?>"#, color: .blue, source: source, result: &result)
        }
        if language == .shell {
            apply(#"(?m)^\s*(?:git|npm|pnpm|yarn|curl|sudo|brew|make|swift)\b"#, color: .blue, source: source, result: &result)
        }
        apply(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: .green, source: source, result: &result)
        if let commentPattern = commentPattern(for: language) {
            apply(commentPattern, color: .secondary, source: source, result: &result)
        }
        return result
    }

    private static func keywordPattern(for language: CodeLanguage?) -> String? {
        let keywords: [String]
        switch language {
        case .swift:
            keywords = ["actor", "async", "await", "case", "class", "enum", "extension", "func", "guard", "if", "import", "let", "protocol", "return", "struct", "switch", "throw", "throws", "try", "var", "where"]
        case .kotlin:
            keywords = ["class", "data", "else", "fun", "if", "import", "interface", "object", "package", "return", "suspend", "val", "var", "when"]
        case .java:
            keywords = ["abstract", "class", "else", "enum", "extends", "final", "if", "implements", "import", "interface", "new", "package", "private", "protected", "public", "return", "static", "void"]
        case .python:
            keywords = ["and", "async", "await", "class", "def", "elif", "else", "except", "for", "from", "if", "import", "in", "lambda", "not", "or", "return", "try", "with", "yield"]
        case .javascript, .typescript:
            keywords = ["async", "await", "class", "const", "else", "export", "extends", "function", "if", "import", "interface", "let", "new", "return", "type", "var"]
        case .shell:
            keywords = ["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "then", "while"]
        case .sql:
            keywords = ["and", "as", "by", "delete", "from", "group", "having", "insert", "into", "join", "limit", "on", "or", "order", "select", "set", "update", "values", "where"]
        case .json:
            keywords = ["false", "null", "true"]
        case .yaml, .xml, .html, .css, nil:
            return nil
        }
        return #"(?i)\b(?:"# + keywords.joined(separator: "|") + #")\b"#
    }

    private static func commentPattern(for language: CodeLanguage?) -> String? {
        switch language {
        case .python, .shell, .yaml: #"(?m)#.*$"#
        case .sql: #"(?m)--.*$"#
        case .xml, .html: #"(?s)<!--.*?-->"#
        case .swift, .kotlin, .java, .javascript, .typescript, .css, .json, nil: #"(?s)/\*.*?\*/|(?m)//.*$"#
        }
    }

    private static func apply(_ pattern: String, color: Color, source: String, result: inout AttributedString) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in expression.matches(in: source, range: range) {
            guard let sourceRange = Range(match.range, in: source),
                  let lower = AttributedString.Index(sourceRange.lowerBound, within: result),
                  let upper = AttributedString.Index(sourceRange.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = color
        }
    }
}

enum ColorParser {
    static func color(from value: String) -> Color? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { return hexColor(String(trimmed.dropFirst())) }

        let lower = trimmed.lowercased()
        guard let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else { return nil }
        let values = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if lower.hasPrefix("rgb"), values.count == 3 || values.count == 4,
           let red = Double(values[0]), let green = Double(values[1]), let blue = Double(values[2]) {
            let alpha = values.count == 4 ? Double(values[3]) ?? 1 : 1
            return Color(
                red: min(max(red / 255, 0), 1),
                green: min(max(green / 255, 0), 1),
                blue: min(max(blue / 255, 0), 1),
                opacity: min(max(alpha, 0), 1)
            )
        }

        if lower.hasPrefix("hsl"), values.count == 3 || values.count == 4,
           let hue = Double(values[0].replacingOccurrences(of: "deg", with: "")),
           let saturation = percentage(values[1]),
           let lightness = percentage(values[2]) {
            let alpha = values.count == 4 ? Double(values[3]) ?? 1 : 1
            let rgb = hslToRGB(hue: hue, saturation: saturation, lightness: lightness)
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: min(max(alpha, 0), 1))
        }
        return nil
    }

    private static func hexColor(_ source: String) -> Color? {
        var hex = source
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let red = Double((number >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = Double((number >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = Double((number >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? Double(number & 0xff) / 255 : 1
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    private static func percentage(_ value: String) -> Double? {
        guard value.hasSuffix("%"), let number = Double(value.dropLast()) else { return nil }
        return min(max(number / 100, 0), 1)
    }

    private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (red: Double, green: Double, blue: Double) {
        let normalizedHue = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        return (
            hueComponent(p: p, q: q, t: normalizedHue + 1 / 3),
            hueComponent(p: p, q: q, t: normalizedHue),
            hueComponent(p: p, q: q, t: normalizedHue - 1 / 3)
        )
    }

    private static func hueComponent(p: Double, q: Double, t source: Double) -> Double {
        var t = source
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1 / 6 { return p + (q - p) * 6 * t }
        if t < 1 / 2 { return q }
        if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
        return p
    }
}
