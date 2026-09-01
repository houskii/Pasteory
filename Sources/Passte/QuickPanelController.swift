import AppKit
import PassteCore
import SwiftUI

final class PasstePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickPanelController: NSObject {
    private let state: AppState
    private let pasteCoordinator: PasteCoordinator
    private let targetProvider: () -> NSRunningApplication?
    private let onOpenLibrary: () -> Void
    private let panel: PasstePanel
    private var eventMonitor: Any?
    private var globalMouseMonitor: Any?
    private(set) var targetApplication: NSRunningApplication?

    init(state: AppState, pasteCoordinator: PasteCoordinator, targetProvider: @escaping () -> NSRunningApplication?, onOpenLibrary: @escaping () -> Void) {
        self.state = state; self.pasteCoordinator = pasteCoordinator; self.targetProvider = targetProvider; self.onOpenLibrary = onOpenLibrary
        panel = PasstePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 660),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 340, height: 480); panel.maxSize = NSSize(width: 520, height: 760)
        panel.isMovableByWindowBackground = true
        let view = QuickPanelView(state: state, onCopy: { [weak self] clip, plain, paste in self?.perform(clip, plainText: plain, paste: paste) }, onOpenLibrary: onOpenLibrary)
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: 380, height: 660))
    }

    func toggle() { panel.isVisible ? close() : show() }

    func show() {
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = frontmost
        } else if let fallback = targetProvider(), !fallback.isTerminated {
            targetApplication = fallback
        }
        positionOnMouseScreen()
        panel.orderFrontRegardless(); panel.makeKey()
        installKeyMonitor()
        installOutsideClickMonitor()
        Task { await state.refreshQuick() }
    }

    func close() {
        panel.orderOut(nil)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
    }

    func performSelected(plainText: Bool, paste: Bool) {
        guard let clip = state.quickSelectedClip ?? state.quickClips.first else { return }
        perform(clip, plainText: plainText, paste: paste)
    }

    private func perform(_ clip: Clip, plainText: Bool, paste: Bool) {
        let target = targetApplication
        close()
        Task {
            do {
                let result = try await pasteCoordinator.perform(clip, plainText: plainText, paste: paste, target: target)
                var updated = clip; updated.lastCopiedAt = Date(); updated.copyCount += 1; state.update(updated)
                switch result {
                case .pasted: state.statusMessage = "已粘贴"
                case .copied: state.statusMessage = "已复制"
                case .copiedFallback: state.statusMessage = "目标应用未能恢复，内容已复制，请手动粘贴"; showFallbackNotification()
                case .copiedPermissionRequired: state.statusMessage = "已复制；请在系统设置中允许辅助功能后再次按 Return"; showFallbackNotification()
                }
            } catch { state.show(error); showFallbackNotification() }
        }
    }

    private func showFallbackNotification() {
        NSSound.beep()
    }

    private func installKeyMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 36, 76:
                let paste = modifiers.contains(.command) ? !self.state.settings.defaultDirectPaste : self.state.settings.defaultDirectPaste
                self.performSelected(plainText: modifiers.contains(.option), paste: paste); return nil
            case 53: self.close(); return nil
            case 49: self.previewSelected(); return nil
            case 31 where modifiers.contains(.command): self.close(); self.onOpenLibrary(); return nil
            default: return event
            }
        }
    }

    private func installOutsideClickMonitor() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func previewSelected() {
        guard let clip = state.quickSelectedClip else { return }
        let controller = NSHostingController(rootView: RepresentationPreview(clip: clip, attachments: state.attachments).padding().frame(minWidth: 560, minHeight: 420))
        let window = NSWindow(contentViewController: controller); window.title = "内容预览"; window.setContentSize(NSSize(width: 620, height: 480))
        window.center(); window.makeKeyAndOrderFront(nil)
    }

    private func positionOnMouseScreen() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        var origin = NSPoint(x: point.x - panel.frame.width / 2, y: point.y - panel.frame.height - 12)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
    }
}
