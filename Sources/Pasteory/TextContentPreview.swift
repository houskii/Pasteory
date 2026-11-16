import AppKit
import Foundation
import MarkdownUI
import PasteoryCore
import SwiftUI

enum TextPreviewMode: String, CaseIterable {
    case markdown, source
    var title: String { self == .markdown ? "Markdown" : L10n.tr("原文") }
}

/// MarkdownUI 2.x contains immutable value nodes, but predates Sendable annotations.
struct TextPreviewDocument: @unchecked Sendable {
    let source: String
    let markdown: MarkdownContent
    let isTruncated: Bool
    let isMarkdown: Bool
}

actor TextPreviewLoader {
    static let shared = TextPreviewLoader()
    static let maximumCharacters = 64_000
    private var cache: [String: TextPreviewDocument] = [:]
    private var order = [String]()
    private(set) var parseCount = 0

    func document(for clip: Clip, attachments: AttachmentStore) async throws -> TextPreviewDocument {
        let key = clip.id.uuidString + ":" + clip.contentHash
        if let cached = cache[key] { return cached }
        let fullText = try await ClipTextReader.read(clip, attachments: attachments)
        try Task.checkCancellation()
        let text = String(fullText.prefix(Self.maximumCharacters))
        let result = TextPreviewDocument(source: text, markdown: MarkdownContent(text),
                                         isTruncated: fullText.count > text.count, isMarkdown: Self.looksLikeMarkdown(text))
        try Task.checkCancellation()
        cache[key] = result; order.append(key); parseCount += 1
        while order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }

    nonisolated static func looksLikeMarkdown(_ text: String) -> Bool {
        let patterns = [#"(?m)^ {0,3}#{1,6}\s+\S"#, #"(?m)^ {0,3}(?:[-*+] |\d+\. )\S"#,
                        #"(?m)^ {0,3}(?:```|~~~|> )"#, #"\*\*\S[^\n]*\*\*"#,
                        #"\[[^\]\n]+\]\([^\s)]+\)"#, #"(?m)^\s*\|?.+\|.+\n\s*\|?\s*:?-{3,}"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

struct TextContentPreview: View {
    let clip: Clip
    let attachments: AttachmentStore
    var expand: (() -> Void)?
    @State private var document: TextPreviewDocument?
    @State private var mode = TextPreviewMode.source
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(L10n.tr("文字显示方式"), selection: $mode) {
                    ForEach(TextPreviewMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 230).controlSize(.small)
                Spacer()
                if let expand { Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help(L10n.tr("展开文字预览")) }
            }
            if let document {
                ScrollView {
                    Group {
                        if mode == .markdown {
                            Markdown(document.markdown)
                                .markdownTheme(.gitHub)
                                .markdownImageProvider(PreviewImageProvider())
                                .markdownInlineImageProvider(PreviewInlineImageProvider())
                                .environment(\.openURL, OpenURLAction { url in
                                    TextPreviewLinks.canOpen(url) ? .systemAction(url) : .discarded
                                })
                        } else {
                            Text(verbatim: document.source)
                                .font(clip.primaryKind == .code ? .system(.body, design: .monospaced) : .body)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                }
                if document.isTruncated {
                    Text(L10n.tr("长文本仅预览前 \(TextPreviewLoader.maximumCharacters) 字符；复制原文保留完整内容。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: clip.id.uuidString + clip.contentHash) {
            document = nil; failure = nil
            do {
                let loaded = try await TextPreviewLoader.shared.document(for: clip, attachments: attachments)
                try Task.checkCancellation()
                mode = loaded.isMarkdown ? .markdown : .source
                document = loaded
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}

enum TextPreviewLinks {
    static func canOpen(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil }
}

private struct PreviewImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Label(url?.lastPathComponent.isEmpty == false ? url!.lastPathComponent : L10n.tr("图片"), systemImage: "photo")
            .font(.caption).foregroundStyle(.secondary).padding(8)
    }
}

private struct PreviewInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}

@MainActor
final class TextPreviewController {
    private let attachments: AttachmentStore
    private var window: NSWindow?
    private let presentWindow: ((NSWindow) -> Void)?
    var copy: ((Clip, String) async throws -> Void)?
    init(attachments: AttachmentStore, presentWindow: ((NSWindow) -> Void)? = nil) {
        self.attachments = attachments; self.presentWindow = presentWindow
    }

    func present(_ clip: Clip) {
        let window = window ?? makeWindow()
        self.window = window
        window.title = clip.displayTitle.isEmpty ? L10n.tr("文字预览") : clip.displayTitle
        window.contentView = NSHostingView(rootView: TextPreviewWindowContent(clip: clip, attachments: attachments, copy: copy, close: { [weak window] in window?.orderOut(nil) }))
        if let presentWindow { presentWindow(window); return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-background-snapshot") { window.orderBack(nil); return }
#endif
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 540, height: 380)
        window.center(); window.setFrameAutosaveName("PasteoryTextPreview")
        return window
    }
#if DEBUG
    var debugWindow: NSWindow? { window }
#endif
}

private struct TextPreviewWindowContent: View {
    let clip: Clip
    let attachments: AttachmentStore
    let copy: ((Clip, String) async throws -> Void)?
    let close: () -> Void
    @State private var copying = false
    @State private var message = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(L10n.tr("文字预览"), systemImage: "doc.text").font(.headline)
                Spacer()
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                Button(L10n.tr("复制原文")) {
                    copying = true
                    Task {
                        defer { copying = false }
                        do {
                            let text = try await ClipTextReader.read(clip, attachments: attachments)
                            try await copy?(clip, text); message = L10n.tr("已复制原文")
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(copying || copy == nil)
                Button(L10n.tr("关闭"), action: close).keyboardShortcut(.cancelAction)
            }
            Divider()
            TextContentPreview(clip: clip, attachments: attachments)
        }.padding(20).frame(minWidth: 500, minHeight: 340)
    }
}
