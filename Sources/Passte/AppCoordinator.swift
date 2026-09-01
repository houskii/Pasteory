import AppKit
import PassteCore
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, NSMenuDelegate {
    private let state: AppState
    private let settings: AppSettings
    private let pasteCoordinator: PasteCoordinator
    private let monitor: ClipboardMonitor
    private let hotKeyManager = GlobalHotKeyManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var workspaceObserver: NSObjectProtocol?
    private var maintenanceTimer: Timer?
    private var lastExternalApplication: NSRunningApplication?
    private lazy var quickPanel = QuickPanelController(
        state: state,
        pasteCoordinator: pasteCoordinator,
        targetProvider: { [weak self] in self?.lastExternalApplication },
        onOpenLibrary: { [weak self] in self?.openLibrary() },
        onOpenSettings: { [weak self] in self?.openSettings() },
        onCreateTextClip: { [weak self] in self?.createManualTextClip() },
        onCreateCollection: { [weak self] smart in self?.promptCreateCollection(smart: smart) },
        onEditCollection: { [weak self] collection in self?.editCollection(collection) },
        onDeleteCollection: { [weak self] collection in self?.confirmDeleteCollection(collection) }
    )

    init(state: AppState, settings: AppSettings, attachments: AttachmentStore) {
        self.state = state; self.settings = settings
        self.pasteCoordinator = PasteCoordinator(attachments: attachments)
        self.monitor = ClipboardMonitor(settings: settings) { [weak state] capture in await state?.accept(capture) }
        super.init()
        pasteCoordinator.monitor = monitor
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
    }

    func start() {
        configureStatusItem()
        registerHotKey()
        Task { await state.bootstrap() }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak state] _ in
            Task { @MainActor in await state?.runArchive() }
        }
        if settings.completedOnboarding {
            applyMonitoringState()
        } else {
            settings.monitoringEnabled = true
            applyMonitoringState()
            openOnboarding()
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-show-quick-panel") {
            Task { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.arguments.contains("--debug-seed") { await seedDebugData() }
                try? await Task.sleep(for: .milliseconds(600)); quickPanel.show()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-open-library") {
            DispatchQueue.main.async { [weak self] in self?.openLibrary() }
        }
#endif
    }

#if DEBUG
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
        _ = await state.addCollection(name: "开发资料", smart: false)
        _ = await state.addCollection(name: "Lark Open API", smart: false)
        _ = await state.addCollection(name: "KMP", smart: false)
        _ = await state.addCollection(name: "最近来源", smart: true)
    }
#endif

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Passte")
            button.toolTip = "Passte"
        }
        let menu = NSMenu(); menu.delegate = self
        menu.addItem(menuItem("打开快捷面板", action: #selector(toggleQuickPanel), key: ""))
        menu.addItem(menuItem("打开资料库", action: #selector(openLibraryAction), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("暂停监控", action: #selector(toggleMonitoring), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("设置…", action: #selector(openSettingsAction), key: ","))
        menu.addItem(menuItem("退出 Passte", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first?.title = "打开快捷面板（\(ShortcutFormatter.display(keyCode: settings.shortcutKeyCode, modifiers: settings.shortcutModifiers))）"
        if menu.items.count > 3 { menu.items[3].title = settings.monitoringEnabled ? "暂停监控" : "恢复监控" }
        statusItem.button?.image = NSImage(systemSymbolName: settings.monitoringEnabled ? "clipboard" : "clipboard.fill", accessibilityDescription: settings.monitoringEnabled ? "Passte 正在监控" : "Passte 监控已暂停")
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }

    @objc private func toggleQuickPanel() { quickPanel.toggle() }
    @objc private func openLibraryAction() { openLibrary() }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func toggleMonitoring() { settings.monitoringEnabled.toggle(); applyMonitoringState() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func registerHotKey() {
        if !hotKeyManager.register(keyCode: settings.shortcutKeyCode, modifiers: settings.shortcutModifiers) {
            state.statusMessage = hotKeyManager.lastError
        }
    }

    private func applyMonitoringState() {
        if settings.monitoringEnabled { monitor.start() } else { monitor.stop() }
    }

    private func openOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(settings: settings, onStart: { [weak self] in
                self?.onboardingWindow?.close(); self?.onboardingWindow = nil; self?.quickPanel.show()
            }, onTestShortcut: { [weak self] in self?.quickPanel.show() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "欢迎使用 Passte"; window.styleMask = [.titled, .closable, .miniaturizable]
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
            window.title = "Passte 资料库"; window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1120, height: 720)); window.minSize = NSSize(width: 900, height: 600)
            window.center(); window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
            window.setFrameAutosaveName("PassteLibraryWindow")
            libraryWindow = window
        }
        activateAndShow(libraryWindow)
    }

    private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                state: state, settings: settings, pasteCoordinator: pasteCoordinator,
                onMonitoringChange: { [weak self] in self?.applyMonitoringState() },
                onShortcutChange: { [weak self] in self?.registerHotKey() },
                onExport: { [weak self] in self?.exportBackup() },
                onImport: { [weak self] in self?.importBackup() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Passte 设置"; window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 720, height: 560)); window.center(); window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        activateAndShow(settingsWindow)
    }

    private func createManualTextClip() {
        Task {
            guard await state.createManualTextClip() != nil else { return }
            openLibrary()
        }
    }

    private func promptCreateCollection(smart: Bool) {
        let alert = NSAlert()
        alert.messageText = smart ? "创建智能列表" : "创建普通列表"
        alert.informativeText = smart ? "先创建列表，之后可以在资料库中补充匹配规则。" : "列表会直接显示在快捷面板的横向标签中。"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = smart ? "智能列表名称" : "列表名称"
        alert.accessoryView = input
        alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            guard let collection = await state.addCollection(name: name, smart: smart) else {
                quickPanel.show()
                return
            }
            state.quickScope = .collection(collection.id)
            await state.refreshQuick(resetSelection: true)
            quickPanel.show()
        }
    }

    private func editCollection(_ collection: ClipCollection) {
        state.requestedCollectionEditorID = collection.id
        openLibrary()
    }

    private func confirmDeleteCollection(_ collection: ClipCollection) {
        let alert = NSAlert()
        alert.messageText = "删除“\(collection.name)”？"
        alert.informativeText = "剪贴板内容不会被删除。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { quickPanel.show(); return }
        Task {
            await state.deleteCollection(collection)
            quickPanel.show()
        }
    }

    private func performFromLibrary(_ clip: Clip, plainText: Bool, paste: Bool) {
        let target = lastExternalApplication
        Task {
            do {
                let result = try await pasteCoordinator.perform(clip, plainText: plainText, paste: paste, target: target)
                var updated = clip; updated.lastCopiedAt = Date(); updated.copyCount += 1; state.update(updated)
                switch result {
                case .pasted: state.statusMessage = "已粘贴"
                case .copied: state.statusMessage = "已复制"
                case .copiedFallback: state.statusMessage = "已复制，请手动粘贴"
                case .copiedPermissionRequired: state.statusMessage = "已复制；请允许 Passte 使用辅助功能后重试"
                }
            } catch { state.show(error) }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Passte-\(Date().formatted(.iso8601.year().month().day())).passtebackup"; panel.canCreateDirectories = true
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
