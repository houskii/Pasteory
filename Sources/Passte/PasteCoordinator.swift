import AppKit
import ApplicationServices
import Foundation
import PassteCore

@MainActor
final class PasteCoordinator {
    enum Result { case pasted, copied, copiedFallback, copiedPermissionRequired }

    private let attachments: AttachmentStore
    weak var monitor: ClipboardMonitor?

    init(attachments: AttachmentStore) { self.attachments = attachments }

    func perform(_ clip: Clip, plainText: Bool, paste: Bool, target: NSRunningApplication?) async throws -> Result {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if plainText {
            guard let text = try await plainTextValue(for: clip) else { throw PasteError.noPlainText }
            pasteboard.setString(text, forType: .string)
        } else {
            var objects = [NSPasteboardItem]()
            for clipItem in clip.items.sorted(by: { $0.order < $1.order }) {
                let item = NSPasteboardItem()
                for representation in clipItem.representations {
                    let data = try await attachments.data(for: representation)
                    item.setData(data, forType: NSPasteboard.PasteboardType(representation.uti))
                }
                objects.append(item)
            }
            guard !objects.isEmpty, pasteboard.writeObjects(objects) else { throw PasteError.writeFailed }
        }
        monitor?.markOwnWrite(changeCount: pasteboard.changeCount)
        guard paste else { return .copied }
        if !accessibilityTrusted() {
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(120))
                if accessibilityTrusted() { break }
            }
        }
        guard accessibilityTrusted() else { requestAccessibilityPermission(); return .copiedPermissionRequired }
        guard let target, !target.isTerminated else { return .copiedFallback }
        target.activate()
        var targetIsFrontmost = false
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { targetIsFrontmost = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard targetIsFrontmost else { return .copiedFallback }
        try? await Task.sleep(for: .milliseconds(80))
        guard postCommandV() else { return .copiedFallback }
        return .pasted
    }

    func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func accessibilityTrusted() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
    }

    private func plainTextValue(for clip: Clip) async throws -> String? {
        let preferred = ["public.utf8-plain-text", "public.utf16-plain-text", "public.text", "NSStringPboardType", "public.url"]
        for uti in preferred {
            for item in clip.items {
                guard let representation = item.representations.first(where: { $0.uti == uti }) else { continue }
                let data = try await attachments.data(for: representation)
                if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) { return text }
            }
        }
        return clip.previewText.isEmpty ? nil : clip.previewText
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
}

enum PasteError: LocalizedError {
    case noPlainText, writeFailed
    var errorDescription: String? {
        switch self {
        case .noPlainText: "此内容没有可用的纯文本格式"
        case .writeFailed: "无法写入系统剪贴板"
        }
    }
}
