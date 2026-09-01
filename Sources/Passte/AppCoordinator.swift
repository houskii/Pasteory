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
        onOpenLibrary: { [weak self] in self?.openLibrary() }
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
    }

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
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Passte 资料库"; window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1120, height: 720)); window.minSize = NSSize(width: 900, height: 600)
            window.center(); window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
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
