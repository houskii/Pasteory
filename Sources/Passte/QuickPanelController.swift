import AppKit
import PassteCore
import SwiftUI

final class PasstePanel: NSPanel {
    var allowsMainWindow = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { allowsMainWindow }
}

@MainActor
final class QuickPanelController: NSObject {
    private let state: AppState
    private let pasteCoordinator: PasteCoordinator
    private let targetProvider: () -> NSRunningApplication?
    private let onOpenLibrary: () -> Void
    private let onOpenSettings: () -> Void
    private let onCreateTextClip: () -> Void
    private let onCreateCollection: (Bool) -> Void
    private let onEditCollection: (ClipCollection) -> Void
    private let onDeleteCollection: (ClipCollection) -> Void
    private let panel: PasstePanel
    private var eventMonitor: Any?
    private var globalMouseMonitor: Any?
    private let frameAutosaveName = "PassteQuickPanelWindow"
    private var hasInitialPlacement = false
    private(set) var targetApplication: NSRunningApplication?

    init(
        state: AppState,
        pasteCoordinator: PasteCoordinator,
        targetProvider: @escaping () -> NSRunningApplication?,
        onOpenLibrary: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCreateTextClip: @escaping () -> Void,
        onCreateCollection: @escaping (Bool) -> Void,
        onEditCollection: @escaping (ClipCollection) -> Void,
        onDeleteCollection: @escaping (ClipCollection) -> Void
    ) {
        self.state = state; self.pasteCoordinator = pasteCoordinator; self.targetProvider = targetProvider
        self.onOpenLibrary = onOpenLibrary; self.onOpenSettings = onOpenSettings
        self.onCreateTextClip = onCreateTextClip; self.onCreateCollection = onCreateCollection
        self.onEditCollection = onEditCollection; self.onDeleteCollection = onDeleteCollection
#if DEBUG
        let isDebugUIQA = ProcessInfo.processInfo.arguments.contains("--debug-ui-qa")
        let panelStyleMask: NSWindow.StyleMask = isDebugUIQA
            ? [.borderless, .resizable]
            : [.nonactivatingPanel, .borderless, .resizable]
#else
        let panelStyleMask: NSWindow.StyleMask = [.nonactivatingPanel, .borderless, .resizable]
#endif
        panel = PasstePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 660),
            styleMask: panelStyleMask,
            backing: .buffered,
            defer: false
        )
        super.init()
#if DEBUG
        panel.allowsMainWindow = isDebugUIQA
        panel.isFloatingPanel = !isDebugUIQA; panel.level = isDebugUIQA ? .normal : .floating; panel.hidesOnDeactivate = false
#else
        panel.allowsMainWindow = false
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
#endif
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 340, height: 480); panel.maxSize = NSSize(width: 520, height: 760)
        panel.isMovableByWindowBackground = true
        let view = QuickPanelView(
            state: state,
            onCopy: { [weak self] clip, plain, paste in self?.perform(clip, plainText: plain, paste: paste) },
            onOpenLibrary: { [weak self] in self?.close(); onOpenLibrary() },
            onOpenSettings: { [weak self] in self?.close(); onOpenSettings() },
            onCreateTextClip: { [weak self] in self?.close(); onCreateTextClip() },
            onCreateCollection: { [weak self] smart in self?.close(); onCreateCollection(smart) },
            onEditCollection: { [weak self] collection in self?.close(); onEditCollection(collection) },
            onDeleteCollection: { [weak self] collection in self?.close(); onDeleteCollection(collection) }
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: 380, height: 660))
        hasInitialPlacement = panel.setFrameUsingName(frameAutosaveName)
        panel.setFrameAutosaveName(frameAutosaveName)
    }

    func toggle() { panel.isVisible ? close() : show() }

    func show() {
        state.quickCommandKeyDown = false
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = frontmost
        } else if let fallback = targetProvider(), !fallback.isTerminated {
            targetApplication = fallback
        }
        if !hasInitialPlacement || !isPanelOnVisibleScreen {
            positionOnMouseScreen()
            hasInitialPlacement = true
        }
        panel.orderFrontRegardless(); panel.makeKey()
#if DEBUG
        DispatchQueue.main.async { [weak panel] in print("quick-panel-is-key=\(panel?.isKeyWindow == true)") }
#endif
        installKeyMonitor()
        installOutsideClickMonitor()
        Task { await state.prepareQuickPanel() }
    }

    func close() {
        state.quickCommandKeyDown = false
        state.quickHoveredClipID = nil
        state.quickMetadataEditorActive = false
        panel.saveFrame(usingName: frameAutosaveName)
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
                case .pasted: state.presentStatus("已粘贴")
                case .copied: state.presentStatus("已复制")
                case .copiedFallback: state.presentStatus("目标应用未能恢复，内容已复制，请手动粘贴", kind: .warning, dismissAfter: 5); showFallbackNotification()
                case .copiedPermissionRequired: state.presentStatus("已复制；请在系统设置中允许辅助功能后再次按 Return", kind: .warning, dismissAfter: 5); showFallbackNotification()
                }
            } catch { state.show(error); showFallbackNotification() }
        }
    }

    private func showFallbackNotification() {
        NSSound.beep()
    }

    private func installKeyMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if state.quickMetadataEditorActive {
                if event.type == .flagsChanged || event.type == .rightMouseDown { return event }
                if (event.keyCode == 36 || event.keyCode == 76) {
                    if self.textInputHasMarkedText { return event }
                    state.quickMetadataEditorCommitRequestID = UUID()
                    return nil
                }
                if event.keyCode == 53 || (event.keyCode == 13 && modifiers.contains(.command)) {
                    state.quickMetadataEditorDismissRequestID = UUID()
                    return nil
                }
                return event
            }
            if event.type == .rightMouseDown {
                if let hovered = state.quickHoveredClipID { state.quickSelectionID = hovered }
                return event
            }
            if event.type == .flagsChanged {
                state.quickCommandKeyDown = modifiers.contains(.command)
                return event
            }
            let numberKeyIndexes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if modifiers.contains(.command), let index = numberKeyIndexes[event.keyCode], state.quickClips.indices.contains(index) {
                state.quickSelectionID = state.quickClips[index].id
                performSelected(plainText: false, paste: true)
                return nil
            }
            switch event.keyCode {
            case 13 where modifiers.contains(.command): self.close(); return nil
            case 43 where modifiers.contains(.command): self.close(); self.onOpenSettings(); return nil
            case 37 where modifiers.contains(.command): self.close(); self.onOpenLibrary(); return nil
            case 36, 76:
                let paste = modifiers.contains(.command) ? !self.state.settings.defaultDirectPaste : self.state.settings.defaultDirectPaste
                self.performSelected(plainText: modifiers.contains(.option), paste: paste); return nil
            case 53: self.close(); return nil
            case 49: self.previewSelected(); return nil
            case 31 where modifiers.contains(.command): self.close(); self.onOpenLibrary(); return nil
            case 125: self.state.moveQuickSelection(by: 1); return nil
            case 126: self.state.moveQuickSelection(by: -1); return nil
            case 123: Task { await self.state.moveQuickScope(by: -1) }; return nil
            case 124: Task { await self.state.moveQuickScope(by: 1) }; return nil
            case 115: self.state.quickSelectionID = self.state.quickClips.first?.id; return nil
            default: return event
            }
        }
    }

    private func installOutsideClickMonitor() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      !self.state.quickPanelPinned,
                      !self.state.quickMetadataEditorActive else { return }
                self.close()
            }
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

    private var isPanelOnVisibleScreen: Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
    }

    private var textInputHasMarkedText: Bool {
        (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
}
