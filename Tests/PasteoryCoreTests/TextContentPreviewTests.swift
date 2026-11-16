import AppKit
import Foundation
import Testing
@testable import Pasteory
@testable import PasteoryCore

private func previewClip(_ text: String) throws -> Clip {
    try #require(ClipClassifier.makeClip(from: .init(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data(text.utf8))])], source: .init(appName: "Synthetic"))))
}

@Test func markdownPreviewLoadsBeyondTheCardPreviewAndRendersStructuredBlocks() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let markdown = """
    # 本地 Markdown

    **加粗文字**

    - [x] 已完成
    - [ ] 待处理

    | 项目 | 结果 |
    | --- | --- |
    | 本地渲染 | 通过 |

    ```swift
    let title = "Pasteory"
    ```

    """ + String(repeating: "正文段落。\n\n", count: 400) + "END_OF_FULL_TEXT"
    let clip = try previewClip(markdown), loader = TextPreviewLoader()
    let doc = try await loader.document(for: clip, attachments: AttachmentStore(directories: dirs))
    #expect(!clip.previewText.contains("END_OF_FULL_TEXT"))
    #expect(doc.source == markdown && doc.isMarkdown && !doc.isTruncated)
    let html = doc.markdown.renderHTML()
    #expect(html.contains("<h1>") && html.contains("<table>") && html.contains("<pre><code"))
    #expect(html.contains("END_OF_FULL_TEXT") && html.contains("<strong>"))
}

@Test func textPreviewReusesParsedContentUntilTheOriginalChangesAndBoundsLargePreviews() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let attachments = AttachmentStore(directories: dirs), loader = TextPreviewLoader()
    var clip = try previewClip("# 标题\n\n原始内容")
    _ = try await loader.document(for: clip, attachments: attachments)
    clip.note = "Edited note"; clip.title = "Edited title"
    _ = try await loader.document(for: clip, attachments: attachments)
    #expect(await loader.parseCount == 1)
    clip.contentHash = "updated-text"; clip.items[0].representations[0].storage = .inline(Data("# 更新标题".utf8))
    let changed = try await loader.document(for: clip, attachments: attachments)
    #expect(changed.source == "# 更新标题")
    #expect(await loader.parseCount == 2)
    let long = String(repeating: "甲", count: TextPreviewLoader.maximumCharacters + 500) + "FULL_COPY_END"
    let large = try previewClip(long)
    let doc = try await loader.document(for: large, attachments: attachments)
    #expect(doc.isTruncated && doc.source.count == TextPreviewLoader.maximumCharacters)
    #expect(try await ClipTextReader.read(large, attachments: attachments) == long)
    #expect(!TextPreviewLoader.looksLikeMarkdown("普通文字\n保留换行"))
}

@Test @MainActor func openingTextAndUnconfiguredCodeUsesOneInternalPreviewWindow() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let suite = "TextPreview." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let attachments = AttachmentStore(directories: dirs), settings = AppSettings(defaults: defaults)
    var windows = [NSWindow]()
    let preview = TextPreviewController(attachments: attachments, presentWindow: { windows.append($0) })
    let opener = ClipOpenCoordinator(settings: settings, attachments: attachments, textPreview: preview)
    var clip = try previewClip("纯文本无需配置打开方式")
    try await opener.open(clip)
    clip.primaryKind = .code
    try await opener.open(clip)
    #expect(windows.count == 2 && windows[0] === windows[1])
    #expect(!windows[0].isVisible && settings.codeEditorBundleIdentifier.isEmpty)
    windows[0].close()
}

@Test func markdownLinksDoNotDispatchFileOrApplicationCommands() throws {
    #expect(TextPreviewLinks.canOpen(try #require(URL(string: "https://example.com/page"))))
    #expect(!TextPreviewLinks.canOpen(try #require(URL(string: "file:///tmp/example"))))
    #expect(!TextPreviewLinks.canOpen(try #require(URL(string: "javascript:alert(1)"))))
    #expect(!TextPreviewLinks.canOpen(try #require(URL(string: "pasteory:delete"))))
}

@Test func choosingSourceWhileLoadingIsNotOverwrittenByMarkdownDetection() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let clip = try previewClip("# Markdown 标题\n\n**保留格式标记**")
    var selection = TextPreviewSelection()
    selection.begin(contentKey: clip.contentHash)
    selection.select(.source)
    let document = try await TextPreviewLoader().document(for: clip, attachments: AttachmentStore(directories: dirs))
    #expect(document.isMarkdown && selection.mode(for: document) == .source)
    selection.begin(contentKey: clip.contentHash)
    #expect(selection.mode(for: document) == .source)
    selection.select(.markdown)
    #expect(selection.mode(for: document) == .markdown)
    selection.begin(contentKey: "another-clip")
    #expect(selection.mode(for: document) == .markdown)
    #expect(selection.mode(for: nil) == .source)
}

@Test @MainActor func commandWClosesThePreviewAndTheSameWindowCanBeReopened() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    var windows = [NSWindow]()
    let preview = TextPreviewController(attachments: AttachmentStore(directories: dirs), presentWindow: {
        windows.append($0)
        $0.orderBack(nil)
    })
    let clip = try previewClip("关闭后可以重新打开")
    preview.present(clip)
    let window = try #require(windows.first)
    defer { window.close() }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    #expect(window.isVisible)
    #expect(TextEditingCommands.handleClose(event, in: window))
    #expect(!window.isVisible)
    preview.present(clip)
    #expect(windows.count == 2 && windows[0] === windows[1] && window.isVisible)
    let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    #expect(!TextEditingCommands.handleClose(event, in: panel))
    panel.close()
}
