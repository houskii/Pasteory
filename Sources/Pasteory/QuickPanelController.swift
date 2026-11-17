import AppKit
import Carbon
import Combine
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
    private let prepareClipboard: @MainActor () async -> Void
    private var presentationTask: Task<Void, Never>?
    private let panel: PasteoryPanel
    private var commandHelpPanel: NSPanel?
    private var commandHelpArmed = false
    private var commandHelpTask: Task<Void, Never>?
    private var layoutObservation: AnyCancellable?
    private var appliedSidebarWidth: CGFloat = 0
    private var presentationObservation: AnyCancellable?
    private var eventMonitor: Any?
    private var globalMouseMonitor: Any?
    private let frameAutosaveName = "PasteoryQuickPanelWindow"
    private var hasInitialPlacement = false
    private var activatedApplicationForQuickPanel = false
    private weak var previousOwnWindow: NSWindow?
    private(set) var targetApplication: NSRunningApplication?

    init(
        state: AppState,
        updateService: UpdateService,
        pasteCoordinator: PasteCoordinator,
        targetProvider: @escaping () -> NSRunningApplication?,
        onOpenLibrary: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenUpdate: @escaping () -> Void,
        onCreateTextClip: @escaping () -> Void,
        prepareClipboard: @escaping @MainActor () async -> Void = {}
    ) {
        self.state = state; self.pasteCoordinator = pasteCoordinator; self.targetProvider = targetProvider
        self.clipOpenCoordinator = ClipOpenCoordinator(
            settings: state.settings,
            attachments: state.attachments,
            textPreview: state.textPreview,
            onCommandCompletion: { [weak state] execution in
                guard let state else { return }
                switch execution.status {
                case .running:
                    break
                case .succeeded:
                    state.presentStatus(L10n.tr("文件命令已完成，可在“设置 → 打开方式”查看本次命令输出"))
                case .failed(let exitCode):
                    state.presentStatus(
                        L10n.tr("文件命令执行失败（退出码 \(exitCode)），请在“设置 → 打开方式”查看本次命令输出"),
                        kind: .error,
                        dismissAfter: 6
                    )
                }
            }
        )
        self.onOpenLibrary = onOpenLibrary; self.onOpenSettings = onOpenSettings
        self.onCreateTextClip = onCreateTextClip
        self.prepareClipboard = prepareClipboard
#if DEBUG
        let isDebugUIQA = ProcessInfo.processInfo.arguments.contains("--debug-ui-qa")
        let panelStyleMask: NSWindow.StyleMask = isDebugUIQA
            ? [.borderless, .resizable]
            : [.nonactivatingPanel, .borderless, .resizable]
#else
        let panelStyleMask: NSWindow.StyleMask = [.nonactivatingPanel, .borderless, .resizable]
#endif
        let sidebarWidth = state.settings.groupSidebarWidth
        panel = PasteoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380 + sidebarWidth, height: 660),
            styleMask: panelStyleMask,
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = L10n.tr("Pasteory 快捷面板")
#if DEBUG
        if isDebugUIQA { state.quickPanelPinned = true }
        panel.allowsMainWindow = isDebugUIQA
        panel.isFloatingPanel = !isDebugUIQA; panel.level = isDebugUIQA ? .normal : .floating; panel.hidesOnDeactivate = false
#else
        panel.allowsMainWindow = false
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
#endif
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 340 + sidebarWidth, height: 480)
        panel.maxSize = NSSize(width: 520 + sidebarWidth, height: 760)
        panel.isMovableByWindowBackground = true
        let view = QuickPanelView(
            state: state,
            updateService: updateService,
            onCopy: { [weak self] clip, plain, paste in self?.perform(clip, plainText: plain, paste: paste) },
            onOpenLibrary: { [weak self] in self?.close(restoreTargetApplication: false); onOpenLibrary() },
            onOpenSettings: { [weak self] in self?.close(restoreTargetApplication: false); onOpenSettings() },
            onOpenUpdate: { [weak self] in self?.close(restoreTargetApplication: false); onOpenUpdate() },
            onCreateTextClip: { [weak self] in self?.close(restoreTargetApplication: false); onCreateTextClip() }
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: 380 + sidebarWidth, height: 660))
        hasInitialPlacement = panel.setFrameUsingName(frameAutosaveName)
        panel.setFrameAutosaveName(frameAutosaveName)
        // Saved frames already include the sidebar width when that layout is active.
        appliedSidebarWidth = state.settings.groupSidebarWidth
        updateTabLayout(state.settings.quickTabLayout)
        layoutObservation = state.settings.$quickTabLayout.dropFirst().sink { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.updateTabLayout(self.state.settings.quickTabLayout) }
        }
        presentationObservation = state.settings.$groupPresentation.dropFirst().sink { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.updateTabLayout(self.state.settings.quickTabLayout) }
        }
    }

    private func updateTabLayout(_ layout: QuickTabLayout) {
        let sidebarWidth = state.settings.groupSidebarWidth
        let widthDelta = sidebarWidth - appliedSidebarWidth
        appliedSidebarWidth = sidebarWidth
        var frame = panel.frame
        let rightEdge = frame.maxX
        panel.minSize = NSSize(width: 340 + sidebarWidth, height: 480)
        panel.maxSize = NSSize(width: 520 + sidebarWidth, height: 760)
        frame.size.width = min(max(frame.width + widthDelta, panel.minSize.width), panel.maxSize.width)
        if layout == .right { frame.origin.x = rightEdge - frame.width }
        if let visible = panel.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        }
        panel.setFrame(frame, display: panel.isVisible)
    }

    func refreshLanguage() {
        panel.title = L10n.tr("Pasteory 快捷面板")
    }

    func prewarm() {
        guard !panel.isVisible, presentationTask == nil else { return }
        _ = state.prepareCachedQuickPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    var isPresented: Bool { panel.isVisible || presentationTask != nil }

    func ownsKeyboardInput(in window: NSWindow?) -> Bool {
        WindowInputScope.contains(window, root: panel)
    }

    func toggle() { isPresented ? close() : show() }

#if DEBUG
    private(set) var presentationMetrics: [[String: Double]] = []
    var debugWindow: NSWindow { panel }
    func debugOpenSelected() { perform(.openSelected) }
    func waitForPresentation() async { await presentationTask?.value }
#endif

    private func showQuickActions() {
        state.quickCommandKeyDown = false
        cancelPendingCommandHelp()
        hideCommandHelp()
        state.presentQuickActions(for: state.quickSelectedClip, scope: .quickPanel, in: panel)
    }

    func show() {
#if DEBUG
        let preparationStarted = ContinuousClock.now
#endif
        presentationTask?.cancel()
        activatedApplicationForQuickPanel = false
        previousOwnWindow = NSApp.isActive && NSApp.keyWindow !== panel ? NSApp.keyWindow : nil
        if state.quickCommandKeyDown { state.quickCommandKeyDown = false }
        if state.quickSearchFocused { state.quickSearchFocused = false }
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
        presentationTask = Task { [weak self] in
            guard let self else { return }
            // Capture the external app's clipboard and finish the initial page
            // while hidden. Showing cached rows first caused visible jumps.
            await prepareClipboard()
#if DEBUG
            let clipboardReady = ContinuousClock.now
#endif
            guard !Task.isCancelled else { return }
            await state.prepareQuickPanel()
            guard !Task.isCancelled else { return }
            presentationTask = nil
#if DEBUG
            let backgroundSnapshot = ProcessInfo.processInfo.arguments.contains("--debug-background-snapshot")
            let elapsed = preparationStarted.duration(to: .now)
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            print("quick-panel-preparation-ms=\(milliseconds) loaded=\(state.quickClips.count)")
#else
            let backgroundSnapshot = false
#endif
            if !backgroundSnapshot, !panel.styleMask.contains(.nonactivatingPanel), !NSApp.isActive {
                activatedApplicationForQuickPanel = true
                NSApp.activate(ignoringOtherApps: true)
            }
            let frameBeforeShow = panel.frame
            if backgroundSnapshot { panel.orderBack(nil) }
            else { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(nil) }
#if DEBUG
            func ms(_ duration: Duration) -> Double {
                Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            }
            var metrics = state.quickPreparationMetrics
            metrics["clipboard_ms"] = ms(preparationStarted.duration(to: clipboardReady))
            metrics["before_show_ms"] = milliseconds
            metrics["through_show_ms"] = ms(preparationStarted.duration(to: .now))
            let metricIndex = presentationMetrics.count
            presentationMetrics.append(metrics)
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]) {
                FileHandle.standardError.write(data + Data("\n".utf8))
            }
            DispatchQueue.main.async { [weak panel] in
                panel?.contentView?.layoutSubtreeIfNeeded()
                panel?.displayIfNeeded()
                self.presentationMetrics[metricIndex]["layout_ready_ms"] = ms(preparationStarted.duration(to: .now))
                print("quick-panel-is-key=\(panel?.isKeyWindow == true)")
                if ProcessInfo.processInfo.arguments.contains("--debug-panel-frame"), let panel {
                    print("quick-panel-frame-stable=\(panel.frame == frameBeforeShow) before=\(NSStringFromRect(frameBeforeShow)) after=\(NSStringFromRect(panel.frame))")
                }
            }
#endif
            installKeyMonitor()
            installOutsideClickMonitor()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                await state.refreshQuickPanelMetadataIfNeeded()
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--debug-command-help") {
                state.quickCommandKeyDown = true
                showCommandHelp()
            }
#endif
        }
    }

    func close(restoreTargetApplication: Bool = true) {
        let returnWindow = previousOwnWindow
        previousOwnWindow = nil
        presentationTask?.cancel(); presentationTask = nil
        panel.orderOut(nil)
        if state.quickCommandKeyDown { state.quickCommandKeyDown = false }
        if state.quickSearchFocused { state.quickSearchFocused = false }
        if !state.quickQuery.isEmpty { state.quickQuery = "" }
        state.setQuickCapturePending(false)
        state.quickActionsMenu.cancel()
        commandHelpArmed = false
        cancelPendingCommandHelp()
        hideCommandHelp()
        state.quickHoveredClipID = nil
        state.dismissQuickMetadataEditor()
        if state.quickCollectionPickerActive { state.quickCollectionPickerActive = false }
        if state.quickNewNormalCollectionActive { state.quickNewNormalCollectionActive = false }
        if state.quickCollectionManagerActive { state.quickCollectionManagerActive = false }
        state.dismissQuickAggregationDraft()
        state.exitQuickMultiSelect()
        panel.saveFrame(usingName: frameAutosaveName)
        _ = state.prepareCachedQuickPanel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
        if restoreTargetApplication, let returnWindow, returnWindow.isVisible {
            returnWindow.makeKeyAndOrderFront(nil)
        } else if activatedApplicationForQuickPanel,
           restoreTargetApplication,
           let targetApplication,
           !targetApplication.isTerminated {
            targetApplication.activate()
        }
        activatedApplicationForQuickPanel = false
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
        close(restoreTargetApplication: false)
        Task {
            do {
                let result = try await pasteCoordinator.perform(clip, plainText: plainText, paste: paste, target: target)
                if result != .pasted { await state.recordHumanUse(clip, event: .copy) }
                switch result {
                case .pasted:
                    if await state.recordPaste(clip) { state.presentStatus(L10n.tr("已粘贴")) }
                case .copied: state.presentStatus(L10n.tr("已复制"))
                case .copiedFallback: state.presentStatus(L10n.tr("目标应用未能恢复，内容已复制，请手动粘贴"), kind: .warning, dismissAfter: 5); showFallbackNotification()
                case .copiedPermissionRequired: state.presentStatus(L10n.tr("已复制；请在系统设置中允许辅助功能后再次按 Return"), kind: .warning, dismissAfter: 5); showFallbackNotification()
                }
            } catch { state.show(error); showFallbackNotification() }
        }
    }

    private func showFallbackNotification() {
        NSSound.beep()
    }

    private func installKeyMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if self.state.quickActionsMenu.isPresenting { return event }
            let eventWindow = event.window ?? NSApp.keyWindow
            guard self.ownsKeyboardInput(in: eventWindow) else {
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.close(restoreTargetApplication: false)
                }
                return event
            }
            if event.type == .leftMouseDown { return event }
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
                let editorAction = QuickMetadataEditorNavigation.keyboardAction(
                    keyCode: event.keyCode,
                    command: modifiers.contains(.command),
                    shift: modifiers.contains(.shift),
                    option: modifiers.contains(.option),
                    control: modifiers.contains(.control),
                    focusedField: state.quickMetadataEditorFocusedField,
                    hasMarkedText: textInputHasMarkedText
                )
                switch editorAction {
                case .moveFocus(let backwards):
                    state.quickMetadataEditorKeyCommand = .moveFocus(
                        id: UUID(),
                        backwards: backwards
                    )
                    return nil
                case .moveCollection(let offset):
                    state.quickMetadataEditorKeyCommand = .moveCollection(id: UUID(), offset: offset)
                    return nil
                case .toggleCollection:
                    state.quickMetadataEditorKeyCommand = .toggleCollection(id: UUID())
                    return nil
                case .commit:
                    state.quickMetadataEditorCommitRequestID = UUID()
                    return nil
                case .dismiss:
                    state.quickMetadataEditorDismissRequestID = UUID()
                    return nil
                case .passThrough:
                    return event
                }
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
            if event.window === panel, !textInputHasMarkedText,
               let action = state.settings.groupNavigationAction(keyCode: UInt32(event.keyCode), modifiers: self.carbonModifiers(from: modifiers)) {
                Task { await self.state.navigateGroup(action, quick: true) }
                return nil
            }
            let action = state.settings.quickAction(
                keyCode: UInt32(event.keyCode),
                modifiers: self.carbonModifiers(from: modifiers)
            )
            let numberKeyIndexes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if state.quickSearchFocused {
                if self.textInputHasMarkedText { return event }
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
                case 123, 124: return event
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
            if let offset = QuickPanelNavigation.scopeOffset(
                forKeyCode: event.keyCode,
                command: modifiers.contains(.command),
                shift: modifiers.contains(.shift),
                option: modifiers.contains(.option),
                control: modifiers.contains(.control)
            ) {
                Task { await self.state.moveQuickScope(by: offset) }
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
                    await state.recordHumanUse(clip, event: .open)
                    close(restoreTargetApplication: false)
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
        case .quickActions:
            showQuickActions()
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
            else if let clip = state.quickSelectedClip {
                state.presentQuickMetadataEditor(for: clip.id, initialField: .title)
            }
        case .setCollection:
            hideCommandHelp()
            if state.quickSelectedAggregation != nil {
                state.quickCollectionPickerOpenRequestID = UUID()
            } else if let clip = state.quickSelectedClip {
                state.presentQuickMetadataEditor(for: clip.id, initialField: .collections)
            }
        case .createCollection:
            hideCommandHelp()
            state.quickNewNormalCollectionActive = true
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
            close(restoreTargetApplication: false)
            onOpenLibrary()
        case .openSettings:
            close(restoreTargetApplication: false)
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
                  !state.quickActionsMenu.isPresenting,
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
                      !self.state.quickActionsMenu.isPresenting,
                      !self.state.quickMetadataEditorActive,
                      !self.state.quickCollectionPickerActive,
                      !self.state.quickCollectionManagerActive,
                      !self.state.quickAggregationEditorActive else { return }
                self.close(restoreTargetApplication: false)
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
