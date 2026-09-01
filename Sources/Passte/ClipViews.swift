import AppKit
import PassteCore
import SwiftUI

struct ClipRowView: View {
    let clip: Clip
    let attachments: AttachmentStore?
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ClipLeadingVisual(clip: clip, attachments: attachments)
                .frame(width: compact ? 38 : 46, height: compact ? 38 : 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.title.isEmpty ? clip.previewText : clip.title)
                    .font(.system(size: compact ? 13 : 14, weight: .medium))
                    .lineLimit(compact ? 2 : 3)
                HStack(spacing: 7) {
                    Text(clip.source.appName)
                    Text(timestamp)
                    if clip.items.count > 1 { Text("\(clip.items.count) 项") }
                    if clip.copyCount > 1 { Text("复制 \(clip.copyCount) 次") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                if clip.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                if clip.priority > 0 { Text("P\(clip.priority)").font(.caption2.bold()).foregroundStyle(.purple) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clip.primaryKind.displayName)，\(clip.previewText)，来自 \(clip.source.appName)")
    }

    private var timestamp: String {
        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: clip.lastCopiedAt)
        return String(format: "%02d-%02d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }
}

private struct ClipLeadingVisual: View {
    let clip: Clip
    let attachments: AttachmentStore?
    @State private var thumbnail: NSImage?
    @State private var appIcon: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else if let appIcon {
                    Image(nsImage: appIcon).resizable().scaledToFit().padding(3)
                } else {
                    RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.12))
                    Image(systemName: clip.primaryKind.symbolName).foregroundStyle(Color.accentColor)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            if thumbnail != nil, let appIcon {
                Image(nsImage: appIcon).resizable().scaledToFit().padding(1)
                    .frame(width: 17, height: 17).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: clip.primaryKind.symbolName).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 15, height: 15).background(Color.purple, in: Circle())
            }
        }
        .task(id: clip.id) { await loadVisuals() }
    }

    @MainActor
    private func loadVisuals() async {
        if let bundle = clip.source.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
        guard let attachments else { return }
        for item in clip.items {
            for representation in item.representations where representation.uti == "public.png" || representation.uti == "public.tiff" {
                if let data = try? await attachments.data(for: representation), let image = NSImage(data: data) { thumbnail = image; return }
            }
        }
        guard clip.primaryKind == .file else { return }
        for item in clip.items {
            for representation in item.representations where representation.uti == "public.file-url" || representation.uti == "NSFilenamesPboardType" {
                guard let data = try? await attachments.data(for: representation), let url = fileURL(from: data, uti: representation.uti), isImageFile(url) else { continue }
                if let image = NSImage(contentsOf: url) { thumbnail = image; return }
            }
        }
    }

    private func fileURL(from data: Data, uti: String) -> URL? {
        if uti == "NSFilenamesPboardType",
           let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String],
           let path = paths.first { return URL(fileURLWithPath: path) }
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return URL(string: value) ?? URL(fileURLWithPath: value)
    }

    private func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"].contains(url.pathExtension.lowercased())
    }
}

struct RepresentationPreview: View {
    let clip: Clip
    let attachments: AttachmentStore
    @State private var image: NSImage?

    var body: some View {
        Group {
            if clip.primaryKind == .image, let image {
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
        guard clip.primaryKind == .image else { image = nil; return }
        for item in clip.items {
            for representation in item.representations where representation.uti == "public.png" || representation.uti == "public.tiff" {
                if let data = try? await attachments.data(for: representation), let value = NSImage(data: data) { image = value; return }
            }
        }
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
