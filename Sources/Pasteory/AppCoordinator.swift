import AppKit
import Carbon
import PasteoryCore
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, NSMenuDelegate {
    private let state: AppState
    private let settings: AppSettings
    private let pasteCoordinator: PasteCoordinator
    private let monitor: ClipboardMonitor
    private let hotKeyManager = GlobalHotKeyManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
#if DEBUG
    private var debugQuickWindow: NSWindow?
#endif
    private var workspaceObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var windowCloseKeyMonitor: Any?
    private var maintenanceTimer: Timer?
    private var webCacheTimer: Timer?
    private var lastExternalApplication: NSRunningApplication?
    private lazy var quickPanel = QuickPanelController(
        state: state,
        pasteCoordinator: pasteCoordinator,
        targetProvider: { [weak self] in self?.lastExternalApplication },
        onOpenLibrary: { [weak self] in self?.openLibrary() },
        onOpenSettings: { [weak self] in self?.openSettings() },
        onCreateTextClip: { [weak self] in self?.createManualTextClip() }
    )

    init(state: AppState, settings: AppSettings, attachments: AttachmentStore) {
        self.state = state; self.settings = settings
        self.pasteCoordinator = PasteCoordinator(attachments: attachments)
        let sourceContextCapture = SourceContextCaptureCoordinator(settings: settings)
        self.monitor = ClipboardMonitor(settings: settings, sourceContextCapture: sourceContextCapture) { [weak state] capture in
            await state?.accept(capture)
        }
        super.init()
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
            if TextEditingCommands.handle(event, in: NSApp.keyWindow) { return nil }
            if self.libraryWindow?.isKeyWindow == true,
               self.libraryWindow?.attachedSheet == nil {
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let action = self.settings.quickAction(
                    keyCode: UInt32(event.keyCode),
                    modifiers: self.carbonModifiers(from: modifiers)
                )
                switch action {
                case .quickActions:
                    self.state.presentQuickActions(for: self.state.selectedClip, scope: .library, in: self.libraryWindow)
                    return nil
                case .aggregateContent:
                    Task { self.state.libraryAggregationDraft = await self.state.makeLibraryAggregationDraft() }
                    return nil
                case .expandAggregation where !(self.libraryWindow?.firstResponder is NSTextView):
                    self.state.expandSelectedLibraryAggregation()
                    return nil
                case .collapseAggregation where !(self.libraryWindow?.firstResponder is NSTextView):
                    self.state.collapseSelectedLibraryAggregation()
                    return nil
                default: break
                }
            }
            guard event.keyCode == 13,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            let window: NSWindow?
            if self.settingsWindow?.isKeyWindow == true { window = self.settingsWindow }
            else if self.libraryWindow?.isKeyWindow == true { window = self.libraryWindow }
            else { window = nil }
            guard let window, window.attachedSheet == nil else { return event }
            if let recorder = window.firstResponder as? ShortcutRecorderNSView, recorder.isRecordingShortcut {
                return event
            }
            window.performClose(nil)
            return nil
        }
    }

    func start() {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-theme-pink") {
            settings.themeColor = .pink
        }
#endif
        configureStatusItem()
#if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--debug-disable-hotkey") {
            registerHotKey()
        }
#else
        registerHotKey()
#endif
        Task {
            await state.bootstrap(processExistingClips: !ProcessInfo.processInfo.arguments.contains("--skip-existing-maintenance"))
        }
        Task { await state.webCacheMaintenance.check() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak state] _ in
            Task { @MainActor in await state?.webCacheMaintenance.check() }
        }
        webCacheTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak state] _ in
            Task { @MainActor in await state?.webCacheMaintenance.check() }
        }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak state] _ in
            Task { @MainActor in await state?.runArchive() }
        }
        settings.monitoringEnabled = true
#if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--debug-disable-monitor") {
            monitor.start()
        }
#else
        monitor.start()
#endif
        if !settings.completedOnboarding {
            openOnboarding()
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-show-quick-window") {
            Task { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.arguments.contains("--debug-seed") { await seedDebugData() }
                try? await Task.sleep(for: .milliseconds(600)); openDebugQuickWindow()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--debug-show-quick-panel") {
            Task { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.arguments.contains("--debug-seed") { await seedDebugData() }
                try? await Task.sleep(for: .milliseconds(600)); quickPanel.show()
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
                if ProcessInfo.processInfo.arguments.contains("--debug-seed") { await seedDebugData() }
                try? await Task.sleep(for: .milliseconds(600))
                openLibrary()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-open-settings") {
            Task { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.arguments.contains("--debug-seed") { await seedDebugData() }
                try? await Task.sleep(for: .milliseconds(300))
                openSettings()
            }
        }
#endif
    }

    func showSettings() {
        openSettings()
    }

#if DEBUG
    private func openDebugQuickWindow() {
        let view = QuickPanelView(
            state: state,
            onCopy: { _, _, _ in },
            onOpenLibrary: {},
            onOpenSettings: {},
            onCreateTextClip: {}
        )
        let panelWidth = 380 + state.settings.quickTabLayout.sidebarWidth
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pasteory 快捷面板实际测试"
        window.contentViewController = NSHostingController(rootView: view.frame(width: panelWidth, height: 660))
        window.setContentSize(NSSize(width: panelWidth, height: 660))
        window.center()
        window.isReleasedWhenClosed = false
        debugQuickWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func seedDebugData() async {
        let samples = [
            ("这是一条用于验证超长文本截断和布局边界的剪贴板内容，它不应该把时间、来源应用或快捷键挤出卡片，也不能覆盖相邻的条目。", "com.apple.Terminal", "一个名称同样非常长的测试来源应用"),
            ("What was broken", "com.apple.Terminal", "终端"),
            ("你要解决一下这个问题，无论是用户切换", "com.openai.chat", "ChatGPT"),
            ("Lark Open API 调试记录", "com.google.Chrome", "Google Chrome"),
            ("KMP 构建命令与排查结果", "com.googlecode.iterm2", "iTerm2"),
            ("左边来源 App 和类型保持不变", "com.openai.chat", "ChatGPT")
        ]
        for sample in samples {
            let capture = PasteboardCapture(
                items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(sample.0.utf8))])],
                source: ClipSource(appName: sample.2, bundleIdentifier: sample.1, confidence: .high)
            )
            await state.accept(capture)
        }
        if var metadataSample = state.quickClips.first {
            if ProcessInfo.processInfo.arguments.contains("--debug-screenshot-seed") {
                metadataSample.title = "快捷面板类型标识实际测试：超长标题需要在标签前截断"
                metadataSample.note = "备注、正文、类型标签和复制次数不能互相覆盖"
            } else {
                metadataSample.title = String(repeating: "这是一个很长的用户标题，用来验证标题会在卡片边界内截断。", count: 5)
                metadataSample.note = String(repeating: "这是一条很长的备注，用于确认标题、正文、备注、复制次数和图钉同时存在时仍然清晰。", count: 10)
            }
            metadataSample.isPinned = true
            metadataSample.copyCount = 128
            metadataSample.pasteCount = 37
            state.update(metadataSample)
        }
        if let longSampleIndex = state.quickClips.firstIndex(where: { $0.source.appName.contains("名称同样非常长") }) {
            var longSample = state.quickClips[longSampleIndex]
            longSample.copyCount = 9_999
            longSample.pasteCount = 888
            state.update(longSample)
        }
        let colorCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("#7C3AED".utf8))])],
            source: ClipSource(appName: "设计工具", bundleIdentifier: "com.apple.Preview", confidence: .high)
        )
        await state.accept(colorCapture)
        if let image = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil), let data = image.tiffRepresentation {
            let capture = PasteboardCapture(
                items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.tiff", data: data)])],
                source: ClipSource(appName: "预览", bundleIdentifier: "com.apple.Preview", confidence: .high)
            )
            await state.accept(capture)
        }
        let linkCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.url", data: Data("https://pasteory.app/design/type-marker".utf8))])],
            source: ClipSource(appName: "Safari", bundleIdentifier: "com.apple.Safari", confidence: .high)
        )
        await state.accept(linkCapture)
        let codeCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [CapturedRepresentation(
                uti: "public.swift-source",
                data: Data("import SwiftUI\n\nstruct CodePreview: View {\n    var body: some View { Text(\"Hello, Pasteory\") }\n}".utf8)
            )])],
            source: ClipSource(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", confidence: .high)
        )
        await state.accept(codeCapture)
        let debugFileDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Pasteory-File-Preview-QA", isDirectory: true)
        try? FileManager.default.createDirectory(at: debugFileDirectory, withIntermediateDirectories: true)
        let debugFileURL = debugFileDirectory.appendingPathComponent("mac_lock_screen.txt")
        try? Data("⌃⌘Q\n".utf8).write(to: debugFileURL, options: .atomic)
        var debugFileRepresentations = [
            CapturedRepresentation(uti: "public.file-url", data: Data(debugFileURL.absoluteString.utf8)),
            CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(debugFileURL.lastPathComponent.utf8))
        ]
        if let icon = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil),
           let iconData = icon.tiffRepresentation {
            debugFileRepresentations.insert(CapturedRepresentation(uti: "com.apple.icns", data: iconData), at: 0)
        }
        let fileCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: debugFileRepresentations)],
            source: ClipSource(appName: "访达", bundleIdentifier: "com.apple.finder", confidence: .high)
        )
        await state.accept(fileCapture)
        if ProcessInfo.processInfo.arguments.contains("--debug-seed-multi-file") {
            let packageURL = debugFileDirectory.appendingPathComponent("entry-default-signed.hap")
            let logURL = debugFileDirectory.appendingPathComponent("install-result.log")
            try? Data("debug hap".utf8).write(to: packageURL, options: .atomic)
            try? Data("install succeeded".utf8).write(to: logURL, options: .atomic)
            if let fileList = try? PropertyListSerialization.data(
                fromPropertyList: [packageURL.path, logURL.path, debugFileURL.path],
                format: .binary,
                options: 0
            ) {
                let capture = PasteboardCapture(
                    items: [CapturedItem(order: 0, representations: [
                        CapturedRepresentation(uti: "NSFilenamesPboardType", data: fileList)
                    ])],
                    source: ClipSource(appName: "访达", bundleIdentifier: "com.apple.finder", confidence: .high)
                )
                await state.accept(capture)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-seed-missing-file") {
            try? FileManager.default.removeItem(at: debugFileURL)
        }
        _ = await state.addCollection(name: "开发资料", smart: false)
        _ = await state.addCollection(name: "Lark Open API", smart: false)
        _ = await state.addCollection(name: "KMP", smart: false)
        _ = await state.addCollection(name: "最近来源", smart: true)
        let sourceContext = CapturedSourceContext(
            kind: .webPage,
            strategyIdentifier: "chrome.extension.web-context.v1",
            summary: "BITS · [Feature] Android KMP ABMock 优化·合码请求",
            payload: [
                "url": "https://bits.bytedance.net/devops/1486828802/code/detail/8376268",
                "pageTitle": "[Feature] Android KMP ABMock 优化·合码请求",
                "repository": "Douyin",
                "branch": "p/pengzipei/abmock-kmp-manager-optimize",
                "targetBranch": "rc/develop",
                "selectedText": "p/pengzipei/abmock-kmp-manager-optimize",
                "relatedText": "Douyin · 源分支 · 目标分支"
            ]
        )
        let contextCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [
                CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("p/pengzipei/abmock-kmp-manager-optimize".utf8))
            ])],
            source: ClipSource(appName: "Google Chrome", bundleIdentifier: "com.google.Chrome", confidence: .high),
            sourceContext: sourceContext
        )
        await state.accept(contextCapture)
        if ProcessInfo.processInfo.arguments.contains("--debug-seed-aggregation") {
            let members = Array(state.quickClips.prefix(3).map(\.id))
            if members.count >= 2 {
                let aggregation = ClipAggregation(
                    title: "abmock 相关内容",
                    note: "",
                    memberClipIDs: members,
                    origin: .search(query: "abmock")
                )
                _ = try? await state.repository.saveAggregation(aggregation)
                await state.refreshAggregations()
                state.quickExpandedAggregationIDs.insert(aggregation.id)
                state.libraryExpandedAggregationIDs.insert(aggregation.id)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-settings-storage")
            || ProcessInfo.processInfo.arguments.contains("--debug-settings-storage-thirty-days") {
            let calendar = Calendar.autoupdatingCurrent
            let todayStart = calendar.startOfDay(for: Date())
            let distributed = state.quickClips.enumerated().map { index, clip in
                var value = clip
                let dayOffset = -(index % 7)
                value.lastCopiedAt = calendar.date(
                    byAdding: .hour,
                    value: 10,
                    to: calendar.date(byAdding: .day, value: dayOffset, to: todayStart) ?? todayStart
                ) ?? value.lastCopiedAt
                return value
            }
            try? await state.repository.saveBatch(distributed)
            await state.refreshQuick()
            await state.refreshLibrary()
        }
        state.quickSelectionID = state.quickClips.first?.id
    }
#endif

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = PasteoryBrand.menuBarImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = PasteoryBrand.name
        }
        let menu = NSMenu(); menu.delegate = self
        menu.addItem(menuItem("打开快捷面板", action: #selector(toggleQuickPanel), key: ""))
        menu.addItem(menuItem("打开资料库", action: #selector(openLibraryAction), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("设置…", action: #selector(openSettingsAction), key: ","))
        menu.addItem(menuItem("退出 Pasteory", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let shortcut = settings.globalShortcut {
            menu.items.first?.title = "打开快捷面板（\(ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))）"
        } else {
            menu.items.first?.title = "打开快捷面板（未设置快捷键）"
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
            state.presentStatus(hotKeyManager.lastError ?? "快捷键注册失败", kind: .error, dismissAfter: 5)
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
            window.title = "欢迎使用 Pasteory"; window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 780, height: 590)); window.center(); window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        activateAndShow(onboardingWindow)
    }

    func openLibrary() {
        if libraryWindow == nil {
            let view = LibraryView(state: state, onPaste: { [weak self] clip, plain, paste in self?.performFromLibrary(clip, plainText: plain, paste: paste) }, onOpenSettings: { [weak self] in self?.openSettings() })
            let hostingController = NSHostingController(rootView: view)
            hostingController.sizingOptions = []
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Pasteory 资料库"; window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1120, height: 720)); window.minSize = NSSize(width: 900, height: 600)
            window.center(); window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
            window.setFrameAutosaveName("PasteoryLibraryWindow")
            libraryWindow = window
        }
        activateAndShow(libraryWindow)
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let window = libraryWindow,
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
                    of: arguments.contains("--debug-edit-smart-rules") ? (window.attachedSheet ?? window) : window,
                    to: arguments[index + 1]
                )
            }
        }
#endif
    }

    private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                state: state, settings: settings, pasteCoordinator: pasteCoordinator,
                onShortcutChange: { [weak self] in self?.registerHotKey() },
                onExport: { [weak self] in self?.exportBackup() },
                onImport: { [weak self] in self?.importBackup() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Pasteory 设置"; window.styleMask = [.titled, .closable]
            let debugShowsFileRules = ProcessInfo.processInfo.arguments.contains("--debug-settings-file-rules")
            window.setContentSize(NSSize(width: 940, height: debugShowsFileRules ? 900 : 660)); window.center(); window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        activateAndShow(settingsWindow)
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let window = settingsWindow,
           let index = arguments.firstIndex(of: "--debug-snapshot-path"), arguments.indices.contains(index + 1) {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                saveDebugSnapshot(of: window.attachedSheet ?? window, to: arguments[index + 1])
            }
        }
#endif
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
                switch result {
                case .pasted:
                    if await state.recordPaste(clip) { state.presentStatus("已粘贴") }
                case .copied: state.presentStatus("已复制")
                case .copiedFallback: state.presentStatus("已复制，请手动粘贴", kind: .warning, dismissAfter: 5)
                case .copiedPermissionRequired: state.presentStatus("已复制；请允许 Pasteory 使用辅助功能后重试", kind: .warning, dismissAfter: 5)
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
        NSApplication.shared.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
}
