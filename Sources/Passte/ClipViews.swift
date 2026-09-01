import AppKit
import PassteCore
import SwiftUI
import UniformTypeIdentifiers

struct ClipRowView: View {
    let clip: Clip
    let attachments: AttachmentStore?
    var compact = false
    var shortcutNumber: Int? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ClipLeadingVisual(clip: clip)
                .frame(width: compact ? 38 : 46, height: compact ? 38 : 46)
            VStack(alignment: .leading, spacing: 3) {
                mainContent
                HStack(spacing: 7) {
                    Text(String(clip.source.appName.prefix(40)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text(timestamp)
                        .monospacedDigit()
                        .fixedSize()
                        .layoutPriority(2)
                    if clip.items.count > 1 { Text("\(clip.items.count) 项") }
                    Text("复制 \(clip.copyCount) 次")
                        .fixedSize()
                        .layoutPriority(2)
                    if clip.isPinned { Image(systemName: "pin.fill").foregroundStyle(.purple).help("已置顶") }
                    if clip.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if clip.priority > 0 { Text("P\(clip.priority)").font(.caption2.bold()).foregroundStyle(.purple) }
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
                ClipKindLabel(kind: clip.primaryKind)
                Spacer(minLength: 0)
                if let shortcutNumber {
                    Text("⌘ \(shortcutNumber)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize()
                }
            }
            .frame(width: compact ? 54 : 58, height: 56, alignment: .trailing)
            .padding(.trailing, 4)
            .padding(.bottom, 4)
        }
        .frame(height: compact ? 72 : 72)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var timestamp: String {
        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: clip.lastCopiedAt)
        return String(format: "%02d-%02d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
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
                if !clip.title.isEmpty || !clip.note.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if !clip.title.isEmpty { titleText }
                        if !clip.note.isEmpty { noteText }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: compact ? 42 : 46, alignment: .leading)
        } else if clip.primaryKind == .file {
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.system(size: compact ? 27 : 31))
                    .foregroundStyle(.secondary)
                    .frame(width: compact ? 36 : 42, height: compact ? 42 : 46)
                VStack(alignment: .leading, spacing: 2) {
                    if !clip.title.isEmpty { titleText }
                    primaryContentText
                    if !clip.note.isEmpty { noteText }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: compact ? 42 : 46, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if !clip.title.isEmpty {
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
        Text(String(clip.title.prefix(120)))
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(.purple)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(String(clip.title.prefix(500)))
    }

    private var primaryContentText: some View {
        Text(displayPreview)
            .font(.system(size: compact ? 13 : 14, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(clip.title.isEmpty && clip.note.isEmpty ? 2 : 1)
            .truncationMode(.tail)
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
        String(clip.previewText.prefix(240))
    }

    private var accessibilitySummary: String {
        let title = String(clip.title.prefix(120))
        let preview = String(clip.previewText.prefix(240))
        let note = String(clip.note.prefix(160))
        return "\(clip.primaryKind.displayName)，\(title)，\(preview)，\(note)，来自 \(String(clip.source.appName.prefix(80)))\(clip.isPinned ? "，已置顶" : "")"
    }

    private var hasImagePreview: Bool {
        if clip.primaryKind == .image || clip.items.contains(where: { item in
            item.representations.contains { representation in
                UTType(representation.uti)?.conforms(to: .image) == true
            }
        }) { return true }
        guard clip.primaryKind == .file else { return false }
        let ext = URL(fileURLWithPath: clip.previewText).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"].contains(ext)
    }
}

private struct ClipLeadingVisual: View {
    let clip: Clip
    @State private var appIcon: NSImage?

    var body: some View {
        ZStack {
            if let appIcon {
                Image(nsImage: appIcon).resizable().scaledToFit().padding(3)
            } else {
                RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.12))
                Image(systemName: clip.primaryKind.symbolName).foregroundStyle(Color.accentColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .task(id: clip.source.bundleIdentifier) { loadAppIcon() }
    }

    @MainActor
    private func loadAppIcon() {
        if let bundle = clip.source.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

private struct ClipKindLabel: View {
    let kind: ClipKind

    var body: some View {
        Text(kind.displayName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(markerColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(markerColor.opacity(0.10), in: Capsule())
            .accessibilityLabel("内容类型：\(kind.displayName)")
    }

    private var markerColor: Color {
        switch kind {
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

private struct ClipInlineThumbnail: View {
    let clip: Clip
    let attachments: AttachmentStore
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary)
                    .frame(width: width, height: height)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1))
        .task(id: clip.id) { image = await ClipImageLoader.load(clip: clip, attachments: attachments) }
    }
}

@MainActor
private enum ClipImageLoader {
    static func load(clip: Clip, attachments: AttachmentStore) async -> NSImage? {
        for item in clip.items {
            for representation in item.representations where isImageUTI(representation.uti) {
                if let data = try? await attachments.data(for: representation), let image = NSImage(data: data) { return image }
            }
        }
        guard clip.primaryKind == .file else { return nil }
        for item in clip.items {
            for representation in item.representations where representation.uti == "public.file-url" || representation.uti == "NSFilenamesPboardType" {
                guard let data = try? await attachments.data(for: representation), let url = fileURL(from: data, uti: representation.uti), isImageFile(url) else { continue }
                if let image = NSImage(contentsOf: url) { return image }
            }
        }
        return nil
    }

    private static func isImageUTI(_ uti: String) -> Bool {
        ["public.png", "public.tiff", "public.jpeg", "public.jpeg-2000", "public.heic", "public.heif", "com.compuserve.gif", "org.webmproject.webp"].contains(uti)
    }

    private static func fileURL(from data: Data, uti: String) -> URL? {
        if uti == "NSFilenamesPboardType", let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String], let path = paths.first { return URL(fileURLWithPath: path) }
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return URL(string: value) ?? URL(fileURLWithPath: value)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"].contains(url.pathExtension.lowercased())
    }
}

struct RepresentationPreview: View {
    let clip: Clip
    let attachments: AttachmentStore
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if clip.primaryKind == .color, let color = ColorParser.color(from: clip.previewText) {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 16).fill(color).frame(maxWidth: .infinity, minHeight: 180)
                    Text(clip.previewText).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            } else {
                ScrollView {
                    Text(clip.previewText)
                        .font(clip.primaryKind == .code ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: clip.id) { await loadImage() }
    }

    private func loadImage() async {
        image = await ClipImageLoader.load(clip: clip, attachments: attachments)
    }
}

enum ColorParser {
    static func color(from value: String) -> Color? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let red = Double((number >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = Double((number >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = Double((number >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? Double(number & 0xff) / 255 : 1
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
