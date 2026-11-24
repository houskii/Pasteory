import AppKit
import Carbon
import Combine
import PasteoryCore
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let state: AppState
    private let settings: AppSettings
    private let pasteCoordinator: PasteCoordinator
    private let monitor: ClipboardMonitor
    private let hotKeyManager = GlobalHotKeyManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settingsNavigation: SettingsNavigation
    private let updateService: UpdateService
    private var updateWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
#if DEBUG
    private var debugQuickWindow: NSWindow?
#endif
    private var workspaceObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var windowCloseKeyMonitor: Any?
    private var languageObservation: AnyCancellable?
    private var maintenanceTimer: Timer?
    private var webCacheTimer: Timer?
    private var lastExternalApplication: NSRunningApplication?
    private lazy var quickPanel = QuickPanelController(
        state: state,
        updateService: updateService,
        pasteCoordinator: pasteCoordinator,
        targetProvider: { [weak self] in self?.lastExternalApplication },
        onOpenLibrary: { [weak self] in self?.openLibrary() },
        onOpenSettings: { [weak self] in self?.openSettings() },
        onOpenUpdate: { [weak self] in self?.updateService.checkForUpdates() },
        onCreateTextClip: { [weak self] in self?.createManualTextClip() },
        prepareClipboard: { [weak self] in
            guard let self else { return }
            let ready = await monitor.flushPendingCapture(maximumWait: .milliseconds(30))
            state.setQuickCapturePending(!ready)
        }
    )

    init(state: AppState, settings: AppSettings, attachments: AttachmentStore, defaults: UserDefaults = .standard) {
        self.state = state; self.settings = settings
        self.settingsNavigation = SettingsNavigation(defaults: settings.defaults)
        self.updateService = UpdateService(defaults: defaults)
        self.pasteCoordinator = PasteCoordinator(attachments: attachments)
        let sourceContextCapture = SourceContextCaptureCoordinator(settings: settings)
        self.monitor = ClipboardMonitor(settings: settings, sourceContextCapture: sourceContextCapture) { [weak state] capture in
            await state?.accept(capture)
        }
        super.init()
        monitor.onCaptureSettled = { [weak state] in state?.setQuickCapturePending(false) }
        updateService.onPresent = { [weak self] in self?.presentUpdateDialog() }
        updateService.onDismiss = { [weak self] in self?.updateWindow?.orderOut(nil) }
        languageObservation = settings.$appLanguage.dropFirst().sink { [weak self] language in
            L10n.activate(language)
            Task { @MainActor [weak self] in self?.refreshLanguage(language) }
        }
        pasteCoordinator.monitor = monitor
        state.quickTextActions.monitor = monitor
        hotKeyManager.onPress = { [weak self] in self?.quickPanel.toggle() }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let processIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @MainActor in
                guard let app = NSRunningApplication(processIdentifier: processIdentifier),
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self?.lastExternalApplication = app
            }
        }
        windowCloseKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.state.quickActionsMenu.isPresenting { return event }
            let eventWindow = event.window ?? NSApp.keyWindow
            if self.quickPanel.ownsKeyboardInput(in: eventWindow) { return event }
            if TextEditingCommands.handle(event, in: eventWindow) { return nil }
            if let settingsWindow = self.settingsWindow, eventWindow === settingsWindow,
               settingsWindow.attachedSheet == nil,
               !((settingsWindow.firstResponder as? ShortcutRecorderNSView)?.isRecordingShortcut ?? false) {
                if WindowInputScope.isPlainEscape(event),
                   !((self.settingsWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
                    if self.quickPanel.isPresented { self.quickPanel.close(restoreTargetApplication: false) }
                    else { self.settingsWindow?.performClose(nil) }
                    return nil
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let action = self.settings.quickAction(
                    keyCode: UInt32(event.keyCode), modifiers: self.carbonModifiers(from: modifiers)
                )
                if action == .openLibrary { self.openLibrary(); return nil }
                if action == .openSettings { self.openSettings(); return nil }
                if self.settingsNavigation.destination == .library {
                    switch action {
                    case .quickActions:
                        self.state.presentQuickActions(for: self.state.selectedClip, scope: .library, in: self.settingsWindow)
                        return nil
                    case .aggregateContent:
                        Task { self.state.libraryAggregationDraft = await self.state.makeLibraryAggregationDraft() }
                        return nil
                    case .expandAggregation where !(self.settingsWindow?.firstResponder is NSTextView):
                        self.state.expandSelectedLibraryAggregation()
                        return nil
                    case .collapseAggregation where !(self.settingsWindow?.firstResponder is NSTextView):
                        self.state.collapseSelectedLibraryAggregation()
                        return nil
                    default: break
                    }
                }
            }
            return TextEditingCommands.handleClose(event, in: eventWindow) ? nil : event
        }
    }

    func start() {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-theme-pink") {
            settings.themeColor = .pink
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--debug-theme=") }),
           let theme = PasteoryThemeColor(rawValue: String(argument.dropFirst("--debug-theme=".count))) {
            settings.themeColor = theme
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-ui-qa") {
            settings.completedOnboarding = true
        }
#endif
        configureStatusItem()
        updateService.start()
#if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--debug-disable-hotkey"), !updateService.isIntegrationFixture {
            registerHotKey()
        }
#else
        registerHotKey()
#endif
        Task {
            await state.bootstrap(processExistingClips: !ProcessInfo.processInfo.arguments.contains("--skip-existing-maintenance"))
            quickPanel.prewarm()
            if !ProcessInfo.processInfo.arguments.contains("--debug-ui-qa") {
                Task(priority: .utility) { await self.state.startStoryAutomation() }
            }
            Task(priority: .utility) { await self.state.refreshDueLinkSessions() }
        }
        Task { await state.webCacheMaintenance.check() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak state] _ in
            Task { @MainActor in
                await state?.webCacheMaintenance.check()
                await state?.refreshDueLinkSessions()
            }
        }
        webCacheTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak state] _ in
            Task { @MainActor in
                await state?.webCacheMaintenance.check()
                await state?.refreshDueLinkSessions()
            }
        }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak state] _ in
            Task { @MainActor in await state?.runArchive(automatic: true) }
        }
#if DEBUG
        settings.monitoringEnabled = !updateService.isIntegrationFixture
        if !ProcessInfo.processInfo.arguments.contains("--debug-disable-monitor"), !updateService.isIntegrationFixture {
            monitor.start()
        }
#else
        settings.monitoringEnabled = true
        monitor.start()
#endif
        if !settings.completedOnboarding {
            openOnboarding()
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-show-quick-window") {
            Task { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.arguments.contains("--debug-seed") || ProcessInfo.processInfo.arguments.contains("--debug-readme-seed") { await DebugClipboardFixtures(state: state, settings: settings).seed() }
                try? await Task.sleep(for: .milliseconds(600)); openDebugQuickWindow()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--debug-show-quick-panel") {
            Task { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.arguments.contains("--debug-seed") || ProcessInfo.processInfo.arguments.contains("--debug-readme-seed") { await DebugClipboardFixtures(state: state, settings: settings).seed() }
                try? await Task.sleep(for: .milliseconds(600)); quickPanel.show()
                if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--debug-snapshot-path"),
                   ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                    await quickPanel.waitForPresentation()
                    if ProcessInfo.processInfo.arguments.contains("--debug-open-selected") {
                        quickPanel.debugOpenSelected()
                        try? await Task.sleep(for: .milliseconds(350))
                        if let window = state.textPreview.debugWindow {
                            saveDebugSnapshot(of: window, to: ProcessInfo.processInfo.arguments[index + 1])
                        }
                        return
                    }
                    if ProcessInfo.processInfo.arguments.contains("--debug-repeat-quick-presentation") {
                        for _ in 0..<2 {
                            try? await Task.sleep(for: .milliseconds(250))
                            quickPanel.close(restoreTargetApplication: false)
                            quickPanel.show(); await quickPanel.waitForPresentation()
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    saveDebugSnapshot(of: quickPanel.debugWindow, to: ProcessInfo.processInfo.arguments[index + 1])
                }
                if ProcessInfo.processInfo.arguments.contains("--debug-open-metadata-editor") {
                    state.quickSelectionID = state.quickClips.first(where: {
                        $0.source.bundleIdentifier == "com.google.Chrome"
                            && $0.previewText.contains("abmock-kmp-manager-optimize")
                    })?.id ?? state.quickClips.first?.id
                    let initialField: QuickMetadataEditorField = ProcessInfo.processInfo.arguments.contains("--debug-open-metadata-collections")
                        ? .collections
                        : .title
                    try? await Task.sleep(for: .milliseconds(120))
                    if let clipID = state.quickSelectionID {
                        state.presentQuickMetadataEditor(for: clipID, initialField: initialField)
                    }
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-open-library") {
            Task { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.arguments.contains("--debug-seed") || ProcessInfo.processInfo.arguments.contains("--debug-readme-seed") { await DebugClipboardFixtures(state: state, settings: settings).seed() }
                try? await Task.sleep(for: .milliseconds(600))
                openLibrary()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-open-settings") {
            Task { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.arguments.contains("--debug-seed") || ProcessInfo.processInfo.arguments.contains("--debug-readme-seed") { await DebugClipboardFixtures(state: state, settings: settings).seed() }
                try? await Task.sleep(for: .milliseconds(300))
                openSettings()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-open-update") {
            updateService.checkForUpdates()
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--debug-window-input-check"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            Task { await verifyDebugWindowInput(to: path) }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-text-preview") {
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(700))
                let arguments = ProcessInfo.processInfo.arguments
                guard let input = arguments.firstIndex(of: "--debug-text-preview-file"), arguments.indices.contains(input + 1),
                      let source = try? String(contentsOfFile: arguments[input + 1], encoding: .utf8),
                      let clip = ClipClassifier.makeClip(from: PasteboardCapture(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data(source.utf8))])], source: .init(appName: "Markdown QA"))) else { return }
                state.textPreview.present(clip)
                try? await Task.sleep(for: .milliseconds(350))
                if let path = arguments.firstIndex(of: "--debug-snapshot-path"), arguments.indices.contains(path + 1), let window = state.textPreview.debugWindow {
                    saveDebugSnapshot(of: window, to: arguments[path + 1])
                }
            }
        }
#endif
    }

    func showSettings() {
        openSettings()
    }

    func prepareToTerminate() async {
        state.stopLocalOCR()
        await monitor.flushPendingCapture()
        monitor.stop()
        await state.waitForCapturedWrites()
    }

#if DEBUG
    private func openDebugQuickWindow() {
        let width: CGFloat = ProcessInfo.processInfo.arguments.contains("--debug-panel-narrow") ? 340 : 380
        let view = QuickPanelView(
            state: state,
            updateService: updateService,
            onCopy: { _, _, _ in },
            onOpenLibrary: {},
            onOpenSettings: {},
            onOpenUpdate: { [weak self] in self?.updateService.checkForUpdates() },
            onCreateTextClip: {}
        )
        let panelWidth = width + state.settings.groupSidebarWidth
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Pasteory 快捷面板实际测试")
        window.contentViewController = NSHostingController(rootView: view.frame(width: panelWidth, height: 660))
        window.setContentSize(NSSize(width: panelWidth, height: 660))
        window.center()
        window.isReleasedWhenClosed = false
        debugQuickWindow = window
        if ProcessInfo.processInfo.arguments.contains("--debug-background-snapshot") { window.orderBack(nil) }
        else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        Task {
            await state.prepareQuickPanel()
            if ProcessInfo.processInfo.arguments.contains("--debug-quick-actions") {
                state.presentQuickActions(for: state.quickSelectedClip, scope: .quickPanel, in: window)
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-open-aggregation-editor"),
               let aggregation = state.aggregations.first {
                state.quickSelectedAggregationID = aggregation.id
                state.quickSelectionID = nil
                await state.prepareQuickAggregation()
                try? await Task.sleep(for: .milliseconds(150))
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-select-quick-image") {
                state.quickClips = state.quickClips.filter { $0.primaryKind == .image }
                state.quickSelectionID = state.quickClips.first?.id
                try? await Task.sleep(for: .milliseconds(150))
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-open-metadata-editor") {
                state.quickSelectionID = state.quickClips.first(where: {
                    $0.source.bundleIdentifier == "com.google.Chrome"
                        && $0.previewText.contains("abmock-kmp-manager-optimize")
                })?.id
                let initialField: QuickMetadataEditorField = ProcessInfo.processInfo.arguments.contains("--debug-open-metadata-collections")
                    ? .collections
                    : .title
                try? await Task.sleep(for: .milliseconds(120))
                if let clipID = state.quickSelectionID {
                    state.presentQuickMetadataEditor(for: clipID, initialField: initialField)
                }
                if ProcessInfo.processInfo.arguments.contains("--debug-dismiss-metadata-editor") {
                    try? await Task.sleep(for: .milliseconds(180))
                    state.quickMetadataEditorDismissRequestID = UUID()
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-command-help") {
                state.quickCommandKeyDown = true
            }
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--debug-snapshot-path"), arguments.indices.contains(index + 1) {
                try? await Task.sleep(for: .milliseconds(500))
                let popoverWindow = NSApp.windows.first {
                    $0 !== window
                        && $0.isVisible
                        && NSStringFromClass(type(of: $0)).localizedCaseInsensitiveContains("popover")
                }
                let snapshotWindow = arguments.contains("--debug-show-collection-overview")
                    ? (popoverWindow ?? window.childWindows?.last ?? window)
                    : window
                saveDebugSnapshot(of: snapshotWindow, to: arguments[index + 1])
            }
        }
    }

    private func saveDebugSnapshot(of window: NSWindow, to path: String) {
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--debug-switch-language=") }),
           let language = AppLanguage(rawValue: String(argument.dropFirst("--debug-switch-language=".count))),
           settings.appLanguage != language {
            settings.appLanguage = language
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                saveDebugSnapshot(of: window, to: path)
            }
            return
        }
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        let metadata: [String: Any] = [
            "language": settings.appLanguage.rawValue,
            "textLabel": ClipKind.text.displayName,
            "editMenuTitle": NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
                menu.items.contains { $0.action == #selector(NSText.copy(_:)) }
            })?.title ?? "",
            "windowTitle": window.title,
            "quickLoadedCount": state.quickClips.count,
            "libraryLoadedCount": state.clips.count,
            "quickHasMore": state.quickHasMore,
            "libraryHasMore": state.libraryHasMore,
            "organizationRunning": state.intelligence.running,
            "organizationProgress": state.intelligence.checkpointProgress,
            "aiIndexCount": state.intelligence.clipIndex.count,
            "aiIndexRepresentationCount": state.intelligence.clipIndex.values.reduce(0) { $0 + $1.items.count },
            "aiEligibleCount": state.intelligence.eligibleClipIDs.count,
            "aiGroupedCount": state.intelligence.groupedContentCount,
            "aiRecentScopeCount": state.intelligence.recentRegroupIDs.count,
            "aiRecentEligibleCount": Set(state.intelligence.recentRegroupIDs).intersection(state.intelligence.eligibleClipIDs).count,
            "localOCRRunning": state.localOCRRunning,
            "localOCRCompleted": state.localOCRCompleted,
            "storyEntryVisible": settings.aiConfiguration.storyEnabled == true,
            "storyReportCount": state.story.reports.count,
            "settingsDestination": settingsNavigation.destination.rawValue,
            "sessionRefreshIntervals": LinkAuthenticationTarget.all(customRules: settings.authenticatedLinkRules)
                .map { state.linkSessionRefresh.record(for: $0).interval.rawValue },
            "presentationMetrics": quickPanel.presentationMetrics,
            "sampleTitles": state.quickClips.map(\.title)
        ]
        Task {
            var captured = metadata
            if let repository = state.repository as? SQLiteClipRepository { captured["metadataCacheBuildCount"] = await repository.metadataCacheBuildCount() }
            captured["textPreviewParseCount"] = await TextPreviewLoader.shared.parseCount
            if let metadataData = try? JSONSerialization.data(withJSONObject: captured, options: [.prettyPrinted, .sortedKeys]) {
                try? metadataData.write(to: URL(fileURLWithPath: path + ".json"), options: .atomic)
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }

    private func verifyDebugWindowInput(to path: String) async {
        func escape(_ window: NSWindow) async {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return }
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(180))
        }
        var checks = [String: Bool]()
        openSettings()
        guard let settingsWindow else { return }
        quickPanel.show(); await quickPanel.waitForPresentation()
        checks["both_windows_can_be_visible"] = settingsWindow.isVisible && quickPanel.isPresented
        await escape(quickPanel.debugWindow)
        checks["escape_panel_preserves_settings"] = !quickPanel.isPresented && settingsWindow.isVisible
        await escape(settingsWindow)
        checks["escape_settings_after_panel_hidden"] = !settingsWindow.isVisible && !quickPanel.isPresented
        hotKeyManager.onPress?(); await quickPanel.waitForPresentation()
        checks["global_shortcut_only_shows_panel"] = quickPanel.isPresented && !settingsWindow.isVisible
        hotKeyManager.onPress?()
        checks["global_shortcut_only_hides_panel"] = !quickPanel.isPresented && !settingsWindow.isVisible
        quickPanel.show(); await quickPanel.waitForPresentation()
        openSettings()
        checks["opening_settings_dismisses_panel"] = settingsWindow.isVisible && !quickPanel.isPresented
        quickPanel.show(); await quickPanel.waitForPresentation()
        await escape(settingsWindow)
        checks["escape_does_not_close_both_windows"] = settingsWindow.isVisible && !quickPanel.isPresented
        await escape(settingsWindow)
        checks["second_escape_closes_settings"] = !settingsWindow.isVisible
        let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 },
            "bundle_identifier": Bundle.main.bundleIdentifier ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Public demo content only, used for README screenshots in the isolated QA app.
#endif

    private func refreshLanguage(_ language: AppLanguage) {
        L10n.activate(language)
        TextEditingCommands.installMainMenu(on: NSApp)
        configureStatusItem()
        settingsWindow?.title = L10n.tr("Pasteory 设置")
        onboardingWindow?.title = L10n.tr("欢迎使用 Pasteory")
        updateWindow?.title = L10n.tr("Pasteory 更新")
        quickPanel.refreshLanguage()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = PasteoryBrand.menuBarImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = PasteoryBrand.name
        }
        let menu = NSMenu(); menu.delegate = self
        menu.addItem(menuItem(L10n.tr("打开快捷面板"), action: #selector(toggleQuickPanel), key: ""))
        menu.addItem(menuItem(L10n.tr("打开资料库"), action: #selector(openLibraryAction), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.tr("设置…"), action: #selector(openSettingsAction), key: ","))
        menu.addItem(menuItem(L10n.tr("退出 Pasteory"), action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let shortcut = settings.globalShortcut {
            menu.items.first?.title = L10n.tr("打开快捷面板（\(ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))）")
        } else {
            menu.items.first?.title = L10n.tr("打开快捷面板（未设置快捷键）")
        }
        statusItem.button?.image = PasteoryBrand.menuBarImage()
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }

    private func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    @objc private func toggleQuickPanel() { quickPanel.toggle() }
    @objc private func openLibraryAction() { openLibrary() }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func registerHotKey() {
        guard let shortcut = settings.globalShortcut else {
            hotKeyManager.unregister()
            return
        }
        if !hotKeyManager.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {
            state.presentStatus(hotKeyManager.lastError ?? L10n.tr("快捷键注册失败"), kind: .error, dismissAfter: 5)
        }
    }

    private func openOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(settings: settings, onStart: { [weak self] in
                self?.onboardingWindow?.close(); self?.onboardingWindow = nil; self?.quickPanel.show()
            }, onTestShortcut: { [weak self] in self?.quickPanel.show() })
            let hostingController = NSHostingController(rootView: view)
            hostingController.sizingOptions = []
            let window = NSWindow(contentViewController: hostingController)
            window.title = L10n.tr("欢迎使用 Pasteory"); window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 780, height: 590)); window.center(); window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        activateAndShow(onboardingWindow)
    }

    func openLibrary() {
        openSettings(destination: .library)
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let window = settingsWindow,
           let index = arguments.firstIndex(of: "--debug-snapshot-path"), arguments.indices.contains(index + 1) {
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if arguments.contains("--debug-ui-qa") {
                    state.libraryQuery = ""
                    await state.refreshLibrary()
                }
                if arguments.contains("--debug-edit-smart-rules"),
                   var smartCollection = state.collections.first(where: { $0.kind == .smart }) {
                    smartCollection.ruleSet = SmartRuleSet(
                        mode: .any,
                        conditions: [
                            SmartCondition(field: .body, operation: .contains, value: "Pasteory")
                        ],
                        groups: [
                            SmartRuleGroup(
                                mode: .all,
                                conditions: [
                                    SmartCondition(field: .kind, operation: .equals, value: ClipKind.code.rawValue),
                                    SmartCondition(field: .sourceApp, operation: .equals, value: "com.apple.dt.Xcode")
                                ]
                            )
                        ]
                    )
                    if await state.saveCollection(smartCollection) {
                        state.requestedCollectionEditorID = smartCollection.id
                        try? await Task.sleep(for: .milliseconds(900))
                    }
                }
                if arguments.contains("--debug-select-code") {
                    state.selectedClipID = state.clips.first(where: { $0.primaryKind == .code })?.id
                }
                if arguments.contains("--debug-select-source-context") {
                    state.selectedClipID = state.clips.first(where: {
                        $0.source.bundleIdentifier == "com.google.Chrome"
                            && $0.previewText.contains("abmock-kmp-manager-optimize")
                    })?.id
                }
                if arguments.contains("--debug-select-link") {
                    state.selectedClipID = state.clips.first(where: { $0.primaryKind == .link })?.id
                }
                if arguments.contains("--debug-select-color") {
                    state.selectedClipID = state.clips.first(where: { $0.primaryKind == .color })?.id
                }
                if arguments.contains("--debug-select-aggregation"), let aggregation = state.aggregations.first {
                    state.selectedAggregationID = aggregation.id
                    state.selectedClipID = nil
                }
                if arguments.contains("--debug-select-image") {
                    state.libraryFilter = .kind(.image)
                    await state.refreshLibrary()
                    state.selectedClipID = state.clips.first(where: { $0.primaryKind == .image })?.id
                }
                if arguments.contains("--debug-select-file") {
                    state.libraryFilter = .kind(.file)
                    await state.refreshLibrary()
                    state.selectedClipID = state.clips.first(where: { $0.primaryKind == .file })?.id
                }
                try? await Task.sleep(for: .milliseconds(200))
                window.makeFirstResponder(nil)
                saveDebugSnapshot(
                    of: (arguments.contains("--debug-edit-smart-rules") || arguments.contains("--debug-snapshot-sheet")) ? (window.attachedSheet ?? window) : window,
                    to: arguments[index + 1]
                )
            }
        }
#endif
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { settingsNavigation.close() }
    }

    private func openSettings(destination: SettingsDestination? = nil) {
        if quickPanel.isPresented { quickPanel.close(restoreTargetApplication: false) }
        guard settingsWindow?.attachedSheet == nil else {
            activateAndShow(settingsWindow)
            return
        }
        settingsNavigation.open(requested: destination, storyEnabled: settings.aiConfiguration.storyEnabled == true,
                                latestStoryID: state.story.reports.first?.id,
                                newOpening: !(settingsWindow?.isKeyWindow == true && NSApp.isActive))
        if settingsWindow == nil {
            let view = SettingsView(
                state: state, settings: settings, navigation: settingsNavigation, updateService: updateService,
                onPaste: { [weak self] clip, plain, paste in
                    self?.performFromLibrary(clip, plainText: plain, paste: paste)
                },
                pasteCoordinator: pasteCoordinator,
                onShortcutChange: { [weak self] in self?.registerHotKey() },
                onExport: { [weak self] in self?.exportBackup() },
                onImport: { [weak self] in self?.importBackup() }
            )
            let hostingController = NSHostingController(rootView: view)
            hostingController.sizingOptions = []
#if DEBUG
            let window = SettingsSnapshotWindow(contentViewController: hostingController)
            window.allowsOffscreenSnapshot = ProcessInfo.processInfo.arguments.contains("--debug-settings-wide")
                || ProcessInfo.processInfo.arguments.contains("--debug-settings-narrow")
#else
            let window = NSWindow(contentViewController: hostingController)
#endif
            window.title = L10n.tr("Pasteory 设置")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            let visibleSize = (NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900))
            let availableSize = NSSize(width: max(980, visibleSize.width - 40), height: max(620, visibleSize.height - 60))
            window.contentMinSize = NSSize(width: min(1120, availableSize.width), height: min(720, availableSize.height))
            window.setContentSize(NSSize(width: min(1360, availableSize.width), height: min(820, availableSize.height)))
            window.isReleasedWhenClosed = false
            window.delegate = self
            if !window.setFrameUsingName("PasteorySettingsWindow") { window.center() }
            window.setFrameAutosaveName("PasteorySettingsWindow")
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-wide") {
                window.setContentSize(NSSize(width: 1360, height: 820))
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-narrow") {
                window.setContentSize(NSSize(width: 1120, height: 720))
            }
#endif
            settingsWindow = window
        }
        activateAndShow(settingsWindow)
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if destination != .library, let window = settingsWindow,
           let index = arguments.firstIndex(of: "--debug-snapshot-path"), arguments.indices.contains(index + 1) {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                saveDebugSnapshot(of: window.attachedSheet ?? window, to: arguments[index + 1])
            }
        }
#endif
    }

    private func presentUpdateDialog() {
        if quickPanel.isPresented { quickPanel.close(restoreTargetApplication: false) }
        if updateWindow == nil {
            let controller = NSHostingController(rootView: UpdateDialogView(service: updateService, settings: settings))
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.title = L10n.tr("Pasteory 更新")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 560, height: 540))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            updateWindow = window
        }
        activateAndShow(updateWindow)
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--debug-open-update"), let window = updateWindow,
           let index = arguments.firstIndex(of: "--debug-snapshot-path"), arguments.indices.contains(index + 1) {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                saveDebugSnapshot(of: window, to: arguments[index + 1])
            }
        }
#endif
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender !== updateWindow || updateService.closeDialog()
    }

    private func createManualTextClip() {
        Task {
            guard await state.createManualTextClip() != nil else { return }
            openLibrary()
        }
    }

    private func performFromLibrary(_ clip: Clip, plainText: Bool, paste: Bool) {
        let target = lastExternalApplication
        Task {
            do {
                let result = try await pasteCoordinator.perform(clip, plainText: plainText, paste: paste, target: target)
                if result != .pasted { await state.recordHumanUse(clip, event: .copy) }
                switch result {
                case .pasted:
                    if await state.recordPaste(clip) { state.presentStatus(L10n.tr("已粘贴")) }
                case .copied: state.presentStatus(L10n.tr("已复制"))
                case .copiedFallback: state.presentStatus(L10n.tr("已复制，请手动粘贴"), kind: .warning, dismissAfter: 5)
                case .copiedPermissionRequired: state.presentStatus(L10n.tr("已复制；请允许 Pasteory 使用辅助功能后重试"), kind: .warning, dismissAfter: 5)
                }
            } catch { state.show(error) }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Pasteory-\(Date().formatted(.iso8601.year().month().day())).pasteorybackup"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.exportBackup(to: url) }
    }

    private func importBackup() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.importBackup(from: url) }
    }

    private func activateAndShow(_ window: NSWindow?) {
        guard let window else { return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-background-snapshot") { window.orderBack(nil); return }
#endif
        NSApplication.shared.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
}

#if DEBUG
/// Render the requested QA layout even when the hosted runner has a small virtual display.
@MainActor
private final class SettingsSnapshotWindow: NSWindow {
    var allowsOffscreenSnapshot = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreenSnapshot ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}
#endif
