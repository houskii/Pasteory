import AppKit
import Carbon
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
    private var commandHelpPanel: NSPanel?
    private var commandHelpArmed = false
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
        hideCommandHelp()
        commandHelpArmed = !NSEvent.modifierFlags.contains(.command)
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = frontmost
        } else if let fallback = targetProvider(), !fallback.isTerminated {
            targetApplication = fallback
        }
        if !hasInitialPlacement || !isPanelOnVisibleScreen {
            positionOnMouseScreen()
            hasInitialPlacement = true
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-panel-top-edge"), let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: visible.maxY - panel.frame.height - 8))
        }
#endif
        panel.orderFrontRegardless(); panel.makeKey()
#if DEBUG
        DispatchQueue.main.async { [weak panel] in print("quick-panel-is-key=\(panel?.isKeyWindow == true)") }
#endif
        installKeyMonitor()
        installOutsideClickMonitor()
        Task { await state.prepareQuickPanel() }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-command-help") {
            state.quickCommandKeyDown = true
            showCommandHelp()
        }
#endif
    }

    func close() {
        state.quickCommandKeyDown = false
        commandHelpArmed = false
        hideCommandHelp()
        state.quickHoveredClipID = nil
        state.quickMetadataEditorActive = false
        state.quickCollectionPickerActive = false
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
            if event.type == .flagsChanged {
                let commandDown = modifiers.contains(.command)
                if !commandDown {
                    commandHelpArmed = true
                    state.quickCommandKeyDown = false
                    hideCommandHelp()
                } else if commandHelpArmed,
                          !state.quickMetadataEditorActive,
                          !state.quickCollectionPickerActive {
                    state.quickCommandKeyDown = true
                    showCommandHelp()
                } else {
                    state.quickCommandKeyDown = false
                    hideCommandHelp()
                }
                return event
            }
            if state.quickMetadataEditorActive {
                if event.type == .rightMouseDown { return event }
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
            if state.quickCollectionPickerActive {
                if event.type == .rightMouseDown { return event }
                if event.keyCode == 53 || (event.keyCode == 13 && modifiers.contains(.command)) {
                    state.quickCollectionPickerDismissRequestID = UUID()
                    return nil
                }
                return event
            }
            if event.type == .rightMouseDown {
                if let hovered = state.quickHoveredClipID { state.quickSelectionID = hovered }
                return event
            }
            let numberKeyIndexes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if modifiers.contains(.command), let index = numberKeyIndexes[event.keyCode], state.quickClips.indices.contains(index) {
                state.quickSelectionID = state.quickClips[index].id
                performSelected(plainText: false, paste: true)
                return nil
            }
            if let action = state.settings.quickAction(
                keyCode: UInt32(event.keyCode),
                modifiers: self.carbonModifiers(from: modifiers)
            ) {
                self.perform(action)
                return nil
            }
            switch event.keyCode {
            case 53: self.close(); return nil
            case 125: self.state.moveQuickSelection(by: 1); return nil
            case 126: self.state.moveQuickSelection(by: -1); return nil
            case 123: Task { await self.state.moveQuickScope(by: -1) }; return nil
            case 124: Task { await self.state.moveQuickScope(by: 1) }; return nil
            case 115: self.state.quickSelectionID = self.state.quickClips.first?.id; return nil
            default: return event
            }
        }
    }

    private func perform(_ action: QuickPanelAction) {
        switch action {
        case .directPaste: performSelected(plainText: false, paste: true)
        case .copyOnly: performSelected(plainText: false, paste: false)
        case .plainTextPaste: performSelected(plainText: true, paste: true)
        case .plainTextCopy: performSelected(plainText: true, paste: false)
        case .toggleFavorite:
            if let clip = state.quickSelectedClip { state.toggleFavorite(clip) }
        case .togglePinned:
            if let clip = state.quickSelectedClip { state.togglePinned(clip) }
        case .editMetadata:
            hideCommandHelp()
            state.quickMetadataEditorOpenRequestID = UUID()
        case .setCollection:
            hideCommandHelp()
            state.quickCollectionPickerOpenRequestID = UUID()
        case .moveToTrash:
            if let clip = state.quickSelectedClip { state.moveToTrash(clip) }
        case .openLibrary:
            close()
            onOpenLibrary()
        case .openSettings:
            close()
            onOpenSettings()
        case .closePanel:
            close()
        }
    }

    private func showCommandHelp() {
        guard panel.isVisible, commandHelpArmed else { return }
        let targetScreen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main
        guard let screen = targetScreen else { return }
        let visibleFrame = screen.visibleFrame
        let width = min(max(panel.frame.width, 340), visibleFrame.width - 16)

        let helpPanel: NSPanel
        if let existing = commandHelpPanel {
            helpPanel = existing
            helpPanel.contentViewController = NSHostingController(
                rootView: QuickCommandHelpView(settings: state.settings).frame(width: width)
            )
        } else {
            helpPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 180),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            helpPanel.isOpaque = false
            helpPanel.backgroundColor = .clear
            helpPanel.hasShadow = true
            helpPanel.ignoresMouseEvents = true
            helpPanel.level = panel.level
            helpPanel.collectionBehavior = panel.collectionBehavior
            helpPanel.contentViewController = NSHostingController(
                rootView: QuickCommandHelpView(settings: state.settings).frame(width: width)
            )
            commandHelpPanel = helpPanel
        }

        guard let contentView = helpPanel.contentViewController?.view else { return }
        contentView.layoutSubtreeIfNeeded()
        let fittingHeight = max(120, contentView.fittingSize.height)
        helpPanel.setContentSize(NSSize(width: width, height: fittingHeight))

        let gap: CGFloat = 8
        let preferredX = panel.frame.midX - width / 2
        let x = min(max(preferredX, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)
        let belowY = panel.frame.minY - fittingHeight - gap
        let y: CGFloat
        if belowY >= visibleFrame.minY + 8 {
            y = belowY
        } else {
            y = min(panel.frame.maxY + gap, visibleFrame.maxY - fittingHeight - 8)
        }
        helpPanel.setFrameOrigin(NSPoint(x: x, y: y))
#if DEBUG
        print("quick-command-help-placement=\(y == belowY ? "below" : "above") frame=\(helpPanel.frame) panel=\(panel.frame)")
#endif

        if helpPanel.parent !== panel {
            helpPanel.parent?.removeChildWindow(helpPanel)
            panel.addChildWindow(helpPanel, ordered: .above)
        }
        helpPanel.orderFrontRegardless()
    }

    private func hideCommandHelp() {
        guard let commandHelpPanel else { return }
        commandHelpPanel.parent?.removeChildWindow(commandHelpPanel)
        commandHelpPanel.orderOut(nil)
    }

    private func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    private func installOutsideClickMonitor() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      !self.state.quickPanelPinned,
                      !self.state.quickMetadataEditorActive,
                      !self.state.quickCollectionPickerActive else { return }
                self.close()
            }
        }
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
