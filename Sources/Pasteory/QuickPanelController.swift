import AppKit
import Carbon
import PasteoryCore
import SwiftUI

final class PasteoryPanel: NSPanel {
    var allowsMainWindow = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { allowsMainWindow }
}

@MainActor
final class QuickPanelController: NSObject {
    private let state: AppState
    private let pasteCoordinator: PasteCoordinator
    private let clipOpenCoordinator: ClipOpenCoordinator
    private let targetProvider: () -> NSRunningApplication?
    private let onOpenLibrary: () -> Void
    private let onOpenSettings: () -> Void
    private let onCreateTextClip: () -> Void
    private let panel: PasteoryPanel
    private var commandHelpPanel: NSPanel?
    private var commandHelpArmed = false
    private var commandHelpTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var globalMouseMonitor: Any?
    private let frameAutosaveName = "PasteoryQuickPanelWindow"
    private var hasInitialPlacement = false
    private(set) var targetApplication: NSRunningApplication?

    init(
        state: AppState,
        pasteCoordinator: PasteCoordinator,
        targetProvider: @escaping () -> NSRunningApplication?,
        onOpenLibrary: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCreateTextClip: @escaping () -> Void
    ) {
        self.state = state; self.pasteCoordinator = pasteCoordinator; self.targetProvider = targetProvider
        self.clipOpenCoordinator = ClipOpenCoordinator(
            settings: state.settings,
            attachments: state.attachments,
            onCommandCompletion: { [weak state] execution in
                guard let state else { return }
                switch execution.status {
                case .running:
                    break
                case .succeeded:
                    state.presentStatus("文件命令已完成，可在“设置 → 打开方式”查看日志")
                case .failed(let exitCode):
                    state.presentStatus(
                        "文件命令执行失败（退出码 \(exitCode)），请在“设置 → 打开方式”查看日志",
                        kind: .error,
                        dismissAfter: 6
                    )
                }
            }
        )
        self.onOpenLibrary = onOpenLibrary; self.onOpenSettings = onOpenSettings
        self.onCreateTextClip = onCreateTextClip
#if DEBUG
        let isDebugUIQA = ProcessInfo.processInfo.arguments.contains("--debug-ui-qa")
        let panelStyleMask: NSWindow.StyleMask = isDebugUIQA
            ? [.borderless, .resizable]
            : [.nonactivatingPanel, .borderless, .resizable]
#else
        let panelStyleMask: NSWindow.StyleMask = [.nonactivatingPanel, .borderless, .resizable]
#endif
        panel = PasteoryPanel(
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
            onCreateTextClip: { [weak self] in self?.close(); onCreateTextClip() }
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: 380, height: 660))
        hasInitialPlacement = panel.setFrameUsingName(frameAutosaveName)
        panel.setFrameAutosaveName(frameAutosaveName)
    }

    func toggle() { panel.isVisible ? close() : show() }

    func show() {
        state.quickCommandKeyDown = false
        state.quickSearchFocused = false
        cancelPendingCommandHelp()
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
        panel.orderFrontRegardless(); panel.makeKey(); panel.makeFirstResponder(nil)
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
        state.quickSearchFocused = false
        state.quickQuery = ""
        commandHelpArmed = false
        cancelPendingCommandHelp()
        hideCommandHelp()
        state.quickHoveredClipID = nil
        state.quickMetadataEditorActive = false
        state.quickCollectionPickerActive = false
        state.quickCollectionManagerActive = false
        state.dismissQuickAggregationDraft()
        state.exitQuickMultiSelect()
        panel.saveFrame(usingName: frameAutosaveName)
        panel.orderOut(nil)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
    }

    func performSelected(plainText: Bool, paste: Bool) {
        if let aggregation = state.quickSelectedAggregation {
            state.toggleQuickAggregation(aggregation.id, selectChild: true)
            return
        }
        guard let clip = state.quickSelectedClip ?? state.quickClips.first else { return }
        perform(clip, plainText: plainText, paste: paste)
    }

    private func perform(_ clip: Clip, plainText: Bool, paste: Bool) {
        let target = targetApplication
        close()
        Task {
            do {
                let result = try await pasteCoordinator.perform(clip, plainText: plainText, paste: paste, target: target)
                switch result {
                case .pasted:
                    if await state.recordPaste(clip) { state.presentStatus("已粘贴") }
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
            if event.type == .keyDown {
                cancelPendingCommandHelp()
                if state.quickCommandKeyDown {
                    state.quickCommandKeyDown = false
                    hideCommandHelp()
                }
            }
            if TextEditingCommands.handle(event, in: self.panel) {
                state.quickCommandKeyDown = false
                hideCommandHelp()
                return nil
            }
            if event.type == .flagsChanged {
                let helpModifiers = modifiers.intersection([.command, .shift, .option, .control])
                let commandDown = helpModifiers.contains(.command)
                if !commandDown {
                    commandHelpArmed = true
                    cancelPendingCommandHelp()
                    state.quickCommandKeyDown = false
                    hideCommandHelp()
                } else if helpModifiers == .command,
                          commandHelpArmed,
                          !state.quickMetadataEditorActive,
                          !state.quickCollectionPickerActive,
                          !state.quickCollectionManagerActive,
                          !state.quickAggregationEditorActive,
                          !state.quickSearchFocused {
                    scheduleCommandHelp()
                } else {
                    cancelPendingCommandHelp()
                    state.quickCommandKeyDown = false
                    hideCommandHelp()
                }
                return event
            }
            if state.quickCollectionManagerActive {
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
            if state.quickAggregationEditorActive {
                if event.type == .rightMouseDown { return event }
                if event.keyCode == 36 || event.keyCode == 76 {
                    if self.textInputHasMarkedText { return event }
                    state.quickAggregationCommitRequestID = UUID()
                    return nil
                }
                if event.keyCode == 53 || (event.keyCode == 13 && modifiers.contains(.command)) {
                    state.quickAggregationDismissRequestID = UUID()
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
            let action = state.settings.quickAction(
                keyCode: UInt32(event.keyCode),
                modifiers: self.carbonModifiers(from: modifiers)
            )
            let numberKeyIndexes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if state.quickSearchFocused {
                switch event.keyCode {
                case 53:
                    if state.quickMultiSelectActive { state.exitQuickMultiSelect() }
                    else { self.close() }
                    return nil
                case 36, 76:
                    switch QuickSearchInputPolicy.returnDisposition(
                        hasMarkedText: self.textInputHasMarkedText,
                        hasConfiguredShortcut: action != nil
                    ) {
                    case .confirmMarkedText:
                        return event
                    case .performShortcut:
                        if let action { self.perform(action) }
                        return nil
                    case .consume:
                        return nil
                    }
                case 125: self.state.moveQuickSelection(by: 1); return nil
                case 126: self.state.moveQuickSelection(by: -1); return nil
                case 123, 124: return nil
                default: break
                }
                if modifiers.contains(.command) {
                    if let index = numberKeyIndexes[event.keyCode], state.quickClips.indices.contains(index) {
                        let numbered = state.quickNumberedClips
                        guard numbered.indices.contains(index) else { return nil }
                        state.quickSelectedAggregationID = nil
                        state.quickSelectionID = numbered[index].id
                        performSelected(plainText: false, paste: true)
                        return nil
                    }
                    if let action {
                        self.perform(action)
                        return nil
                    }
                }
                return event
            }
            if modifiers.contains(.command), let index = numberKeyIndexes[event.keyCode] {
                let numbered = state.quickNumberedClips
                guard numbered.indices.contains(index) else { return nil }
                state.quickSelectedAggregationID = nil
                state.quickSelectionID = numbered[index].id
                performSelected(plainText: false, paste: true)
                return nil
            }
            if let action {
                self.perform(action)
                return nil
            }
            switch event.keyCode {
            case 53:
                if state.quickMultiSelectActive { state.exitQuickMultiSelect() }
                else { self.close() }
                return nil
            case 125: self.state.moveQuickSelection(by: 1); return nil
            case 126: self.state.moveQuickSelection(by: -1); return nil
            case 123: Task { await self.state.moveQuickScope(by: -1) }; return nil
            case 124: Task { await self.state.moveQuickScope(by: 1) }; return nil
            case 115:
                if let first = self.state.quickListEntries.first { self.state.selectQuickEntry(first) }
                return nil
            default: return event
            }
        }
    }

    private func perform(_ action: QuickPanelAction) {
        switch action {
        case .openSelected:
            if state.quickMultiSelectActive {
                state.toggleQuickCurrentMultiSelection()
                return
            }
            if let aggregation = state.quickSelectedAggregation {
                state.toggleQuickAggregation(aggregation.id, selectChild: true)
                return
            }
            guard let clip = state.quickSelectedClip ?? state.quickClips.first else { return }
            hideCommandHelp()
            Task {
                do {
                    try await clipOpenCoordinator.open(clip)
                    close()
                } catch {
                    state.presentStatus(error.localizedDescription, kind: .warning, dismissAfter: 5)
                    showFallbackNotification()
                }
            }
        case .toggleSearch:
            hideCommandHelp()
            state.quickCommandKeyDown = false
            if state.quickMultiSelectActive { state.exitQuickMultiSelect() }
            state.quickSearchFocused.toggle()
            if !state.quickSearchFocused { panel.makeFirstResponder(nil) }
        case .directPaste:
            if state.quickMultiSelectActive { Task { await state.prepareQuickAggregation() } }
            else { performSelected(plainText: false, paste: true) }
        case .copyOnly: performSelected(plainText: false, paste: false)
        case .plainTextPaste: performSelected(plainText: true, paste: true)
        case .plainTextCopy: performSelected(plainText: true, paste: false)
        case .toggleFavorite:
            if let aggregation = state.quickSelectedAggregation {
                Task { await state.toggleAggregationFavorite(aggregation) }
            } else if let clip = state.quickSelectedClip { state.toggleFavorite(clip) }
        case .togglePinned:
            if let aggregation = state.quickSelectedAggregation {
                Task { await state.toggleAggregationPinned(aggregation) }
            } else if let clip = state.quickSelectedClip { state.togglePinned(clip) }
        case .editMetadata:
            hideCommandHelp()
            if state.quickSelectedAggregation != nil { Task { await state.prepareQuickAggregation() } }
            else { state.quickMetadataEditorOpenRequestID = UUID() }
        case .setCollection:
            hideCommandHelp()
            state.quickCollectionPickerOpenRequestID = UUID()
        case .aggregateContent:
            hideCommandHelp()
            Task { await state.prepareQuickAggregation() }
        case .expandAggregation:
            state.expandSelectedQuickAggregation()
        case .collapseAggregation:
            state.collapseSelectedQuickAggregation()
        case .moveToTrash:
            if let aggregation = state.quickSelectedAggregation {
                Task { await state.removeAggregation(aggregation) }
            } else if let clip = state.quickSelectedClip { state.moveToTrash(clip) }
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
        let edgeInset: CGFloat = 8
        let gap: CGFloat = 8
        let preferredWidth = min(220, max(200, panel.frame.width * 0.58))
        let rightSpace = max(0, visibleFrame.maxX - edgeInset - panel.frame.maxX - gap)
        let leftSpace = max(0, panel.frame.minX - gap - visibleFrame.minX - edgeInset)
        let useRightSide: Bool
        if rightSpace >= preferredWidth {
            useRightSide = true
        } else if leftSpace >= preferredWidth {
            useRightSide = false
        } else {
            useRightSide = rightSpace >= leftSpace
        }
        let availableWidth = useRightSide ? rightSpace : leftSpace
        let width = min(preferredWidth, availableWidth)
        guard width >= 180 else { return }
        let maxHeight = min(panel.frame.height, visibleFrame.height - edgeInset * 2)

        let helpPanel: NSPanel
        if let existing = commandHelpPanel {
            helpPanel = existing
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
            commandHelpPanel = helpPanel
        }

        helpPanel.contentViewController = NSHostingController(
            rootView: QuickCommandHelpView(settings: state.settings, scrollEnabled: false)
                .frame(width: width)
        )
        guard let contentView = helpPanel.contentViewController?.view else { return }
        contentView.layoutSubtreeIfNeeded()
        let naturalHeight = max(120, contentView.fittingSize.height)
        let scrollEnabled = naturalHeight > maxHeight
        let fittingHeight = min(naturalHeight, maxHeight)
        if scrollEnabled {
            helpPanel.contentViewController = NSHostingController(
                rootView: QuickCommandHelpView(settings: state.settings, scrollEnabled: true)
                    .frame(width: width, height: fittingHeight)
            )
        }
        helpPanel.setContentSize(NSSize(width: width, height: fittingHeight))

        let x = useRightSide ? panel.frame.maxX + gap : panel.frame.minX - gap - width
        let y = panel.frame.maxY - fittingHeight
        helpPanel.setFrameOrigin(NSPoint(x: x, y: y))
#if DEBUG
        print("quick-command-help-placement=\(useRightSide ? "right" : "left") scroll=\(scrollEnabled) frame=\(helpPanel.frame) panel=\(panel.frame)")
#endif

        if helpPanel.parent !== panel {
            helpPanel.parent?.removeChildWindow(helpPanel)
            panel.addChildWindow(helpPanel, ordered: .above)
        }
        helpPanel.orderFrontRegardless()
    }

    private func scheduleCommandHelp() {
        guard commandHelpTask == nil, !state.quickCommandKeyDown else { return }
        commandHelpTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self else { return }
            commandHelpTask = nil
            let modifiers = NSEvent.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .shift, .option, .control])
            guard panel.isVisible,
                  modifiers == .command,
                  commandHelpArmed,
                  !state.quickMetadataEditorActive,
                  !state.quickCollectionPickerActive,
                  !state.quickCollectionManagerActive,
                  !state.quickAggregationEditorActive,
                  !state.quickSearchFocused else { return }
            state.quickCommandKeyDown = true
            showCommandHelp()
        }
    }

    private func cancelPendingCommandHelp() {
        commandHelpTask?.cancel()
        commandHelpTask = nil
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
                      !self.state.quickCollectionPickerActive,
                      !self.state.quickCollectionManagerActive,
                      !self.state.quickAggregationEditorActive else { return }
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
