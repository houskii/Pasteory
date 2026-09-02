import AppKit
import Carbon
import PasteoryCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private enum Destination: String, CaseIterable, Identifiable {
        case general
        case privacy
        case shortcuts
        case openBehavior
        case linkResolution
        case storage
        case advanced
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "通用"
            case .privacy: "采集与隐私"
            case .shortcuts: "快捷键"
            case .openBehavior: "打开方式"
            case .linkResolution: "链接解析"
            case .storage: "存储与清理"
            case .advanced: "高级诊断"
            case .about: "关于"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "外观、启动和应用状态"
            case .privacy: "剪贴板检测、来源详情和排除应用"
            case .shortcuts: "快捷面板和内容操作"
            case .openBehavior: "浏览器、编辑器和文件规则"
            case .linkResolution: "网页标题、登录连接和兜底规则"
            case .storage: "归档、备份和恢复"
            case .advanced: "权限、插件连接和搜索索引"
            case .about: "版本和产品信息"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .privacy: "hand.raised"
            case .shortcuts: "command"
            case .openBehavior: "arrow.up.forward.app"
            case .linkResolution: "link"
            case .storage: "externaldrive"
            case .advanced: "stethoscope"
            case .about: "info.circle"
            }
        }
    }

    private struct DestinationGroup: Identifiable {
        let title: String
        let destinations: [Destination]
        var id: String { title }
    }

    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let pasteCoordinator: PasteCoordinator
    let onShortcutChange: () -> Void
    let onExport: () -> Void
    let onImport: () -> Void
    @State private var selectedDestination: Destination = .general
    @State private var knownApplications = [ApplicationReference]()
    @State private var showingExcludedApplicationPicker = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var shortcutError: String?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                settingsSidebar
                    .frame(width: 224, height: geometry.size.height, alignment: .top)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.55))
                    .frame(width: 1, height: geometry.size.height)
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedDestination.title)
                                .font(.system(size: 22, weight: .bold))
                            Text(selectedDestination.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)

                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.55))
                        .frame(height: 1)

                    destinationContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                }
                .frame(width: geometry.size.width - 225, height: geometry.size.height, alignment: .top)
                .clipped()
            }
        }
        .frame(width: 940, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .pasteoryTheme(settings.themeColor)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.reloadSourceCapturePreferences()
        }
#if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-privacy") { selectedDestination = .privacy }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-open") { selectedDestination = .openBehavior }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-links") { selectedDestination = .linkResolution }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-shortcuts") { selectedDestination = .shortcuts }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-advanced") { selectedDestination = .advanced }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-about") { selectedDestination = .about }
        }
#endif
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(settings.themeColor.gradient)
                    Image(nsImage: PasteoryBrand.menuBarImage())
                        .renderingMode(.template)
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pasteory").font(.system(size: 15, weight: .semibold))
                    Text("设置").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(destinationGroups) { group in
                        Text(group.title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                        ForEach(group.destinations) { destination in
                            Button {
                                selectedDestination = destination
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: destination.symbol)
                                        .frame(width: 18)
                                    Text(destination.title)
                                    Spacer()
                                }
                                .font(.system(size: 12.5, weight: selectedDestination == destination ? .semibold : .medium))
                                .foregroundStyle(selectedDestination == destination ? settings.themeColor.accentColor : Color.primary)
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(
                                    selectedDestination == destination ? settings.themeColor.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch selectedDestination {
        case .general: general
        case .privacy: privacy
        case .shortcuts: shortcuts
        case .openBehavior: openBehavior
        case .linkResolution: linkResolution
        case .storage: storage
        case .advanced: advanced
        case .about: about
        }
    }

    private var destinationGroups: [DestinationGroup] {
        [
            DestinationGroup(title: "基础设置", destinations: [.general, .privacy]),
            DestinationGroup(title: "交互与内容", destinations: [.shortcuts, .openBehavior, .linkResolution]),
            DestinationGroup(title: "数据与支持", destinations: [.storage, .advanced, .about])
        ]
    }

    private var linkResolution: some View {
        LinkResolutionSettingsView(
            state: state,
            settings: settings,
            onPrepareChrome: prepareChromeExtension
        )
        .padding(20)
    }

    private var openBehavior: some View {
        OpenBehaviorSettingsView(settings: settings)
    }

    private func settingsActionRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private var general: some View {
        Form {
            Section("外观") {
                HStack(spacing: 14) {
                    Text("主题色")
                    Spacer(minLength: 12)
                    ForEach(PasteoryThemeColor.allCases) { theme in
                        Button {
                            settings.themeColor = theme
                        } label: {
                            ZStack {
                                Circle().fill(theme.gradient)
                                if settings.themeColor == theme {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help(theme.title)
                        .accessibilityLabel("主题色：\(theme.title)")
                        .accessibilityAddTraits(settings.themeColor == theme ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Section("运行") {
                SettingsSwitchRow(isOn: Binding(get: { loginEnabled }, set: { enabled in updateLoginItem(enabled) })) {
                    Text("登录时启动 Pasteory")
                }
            }
            Section("状态") {
                LabeledContent("运行形态", value: "仅菜单栏")
                LabeledContent(
                    "数据位置",
                    value: "~/Library/Application Support/\(PasteoryRuntimeIdentity.current.applicationSupportDirectoryName)"
                )
            }
            Section("应用") {
                settingsActionRow {
                    Button("重启 Pasteory") {
                        do { try ApplicationLifecycle.restart() }
                        catch { state.show(error) }
                    }
                    Button("退出 Pasteory", role: .destructive) {
                        NSApp.terminate(nil)
                    }
                }
                .buttonStyle(.bordered)
            }
        }.formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("剪贴板检测") {
                Picker("检测频率", selection: $settings.clipboardPollingInterval) {
                    ForEach(ClipboardPollingInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                Text("默认每 1 秒检查一次。频率修改后会在下一轮检测生效；休眠和锁屏时停止检测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("默认保护") {
                Label("自动忽略“钥匙串访问”和“密码”应用", systemImage: "lock.shield")
                Label("自动忽略 Concealed、Transient 和 AutoGenerated 内容", systemImage: "eye.slash")
                Label("单项内容上限为 10 MB", systemImage: "gauge.with.dots.needle.33percent")
            }
            Section("来源详情采集") {
                ForEach(SourceContextSourceCategory.allCases, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(category.displayName)
                            .font(.subheadline.weight(.semibold))
                        ForEach(SourceCaptureApplication.allCases.filter { $0.sourceCategory == category }) { application in
                            sourceCaptureApplicationRow(application)
                        }
                        if category == .browser, settings.isSourceCaptureEnabled(for: .chrome) {
                            Text("默认采集所有网站。如需关闭某个网站，请在 Chrome 工具栏中打开 Pasteory 插件进行设置。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 38)
                        }
                    }
                }

                if SourceCaptureApplication.allCases
                    .filter({ $0 != .chrome })
                    .contains(where: settings.isSourceCaptureEnabled(for:)) {
                    Label(
                        pasteCoordinator.accessibilityTrusted() ? "辅助功能权限已就绪" : "微信和飞书需要辅助功能权限；未授权时只保存普通来源应用",
                        systemImage: pasteCoordinator.accessibilityTrusted() ? "checkmark.shield" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(pasteCoordinator.accessibilityTrusted() ? Color.secondary : Color.orange)
                }
                Text("这些开关只影响之后的复制。已保存的来源详情不会随开关关闭而删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("排除应用") {
                ForEach(settings.excludedBundleIdentifiers.sorted(), id: \.self) { bundle in
                    HStack(spacing: 10) {
                        ApplicationIdentityView(application: applicationReference(for: bundle), compact: true)
                        Spacer()
                        Button("移除") { settings.excludedBundleIdentifiers.remove(bundle) }
                    }
                }
                settingsActionRow {
                    Button("选择应用…") { showingExcludedApplicationPicker = true }
                        .sheet(isPresented: $showingExcludedApplicationPicker) {
                            ApplicationPickerSheet(
                                title: "选择要排除的应用",
                                selectedBundleIdentifiers: settings.excludedBundleIdentifiers,
                                additionalApplications: knownApplications
                            ) { application in
                                settings.excludedBundleIdentifiers.insert(application.bundleIdentifier)
                                if !knownApplications.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) {
                                    knownApplications.append(application)
                                }
                            }
                        }
                }
                Text("选择器会读取 /Applications、~/Applications，也可以从其他路径选择 .app。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { knownApplications = await ApplicationCatalog.discover() }
    }

    private func applicationReference(for bundleIdentifier: String) -> ApplicationReference {
        knownApplications.first { $0.bundleIdentifier == bundleIdentifier }
            ?? ApplicationReference(bundleIdentifier: bundleIdentifier, name: bundleIdentifier, url: nil)
    }

    private func isExcluded(_ application: SourceCaptureApplication) -> Bool {
        !settings.excludedBundleIdentifiers.isDisjoint(with: application.bundleIdentifiers)
    }

    private func sourceCaptureApplicationRow(_ application: SourceCaptureApplication) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSwitchRow(isOn: Binding(
                get: { settings.isSourceCaptureEnabled(for: application) },
                set: { settings.setSourceCaptureEnabled($0, for: application) }
            )) {
                HStack(spacing: 10) {
                    SourceCaptureApplicationIcon(application: application)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(application.title)
                        Text(application.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isExcluded(application))
            if isExcluded(application) {
                Text("此应用已在“排除应用”中，不会保存剪贴板内容或来源详情。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var shortcuts: some View {
        Form {
            Section("打开快捷面板") {
                let shortcut = settings.globalShortcut
                shortcutSettingRow(
                    title: "全局唤起",
                    detail: "从任意 App 打开快捷面板",
                    isConfigured: shortcut != nil,
                    onClear: {
                        settings.clearGlobalShortcut()
                        onShortcutChange()
                        shortcutError = nil
                    }
                ) {
                    ShortcutRecorder(
                        keyCode: shortcut?.keyCode ?? 0,
                        modifiers: shortcut?.modifiers ?? 0,
                        isConfigured: shortcut != nil
                    ) { keyCode, modifiers in
                        if let message = settings.globalShortcutConflict(keyCode: keyCode, modifiers: modifiers) {
                            shortcutError = message
                            return false
                        }
                        settings.setGlobalShortcut(PasteoryShortcut(keyCode: keyCode, modifiers: modifiers))
                        onShortcutChange()
                        shortcutError = nil
                        return true
                    }
                }
            }
            Section("粘贴与复制") {
                ForEach(pasteActions) { action in quickShortcutSettingRow(action) }
            }
            Section("内容打开") {
                quickShortcutSettingRow(.openSelected)
                Text("默认使用空格打开当前项目；网页、代码和文件需要先在“打开方式”中完成配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("搜索") {
                quickShortcutSettingRow(.toggleSearch)
                Text("默认使用 ⌘F 聚焦搜索；再次使用会退出搜索输入。打开面板时默认不聚焦搜索。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("整理当前项目") {
                ForEach(organizeActions) { action in quickShortcutSettingRow(action) }
            }
            Section("窗口与页面") {
                ForEach(windowActions) { action in quickShortcutSettingRow(action) }
            }
            Section("固定导航快捷键") {
                LabeledContent("选择项目和分组", value: "↑↓←→")
                LabeledContent("快速粘贴前 9 项", value: "⌘1～⌘9")
                LabeledContent("关闭当前编辑层", value: "Esc")
            }
            Section {
                settingsActionRow {
                    Button("恢复全部默认快捷键") {
                        settings.resetAllShortcuts()
                        onShortcutChange()
                        shortcutError = nil
                    }
                }
                Text("全局唤起恢复为 ⌘⇧C，打开内容恢复为空格，搜索恢复为 ⌘F，其余操作恢复为各自默认组合。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let shortcutError {
                Section {
                    Label(shortcutError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }.formStyle(.grouped)
    }

    private var pasteActions: [QuickPanelAction] {
        [.directPaste, .copyOnly, .plainTextPaste, .plainTextCopy]
    }

    private var organizeActions: [QuickPanelAction] {
        [.toggleFavorite, .togglePinned, .editMetadata, .setCollection, .moveToTrash]
    }

    private var windowActions: [QuickPanelAction] {
        [.openLibrary, .openSettings, .closePanel]
    }

    private func quickShortcutSettingRow(_ action: QuickPanelAction) -> some View {
        let shortcut = settings.quickShortcut(for: action)
        return shortcutSettingRow(
            title: action.title,
            isConfigured: shortcut != nil,
            onClear: {
                settings.clearQuickShortcut(for: action)
                shortcutError = nil
            }
        ) {
            ShortcutRecorder(
                keyCode: shortcut?.keyCode ?? 0,
                modifiers: shortcut?.modifiers ?? 0,
                isConfigured: shortcut != nil,
                allowsUnmodified: true
            ) { keyCode, modifiers in
                let message = settings.setQuickShortcut(
                    PasteoryShortcut(keyCode: keyCode, modifiers: modifiers),
                    for: action
                )
                shortcutError = message
                return message == nil
            }
        }
    }

    private func shortcutSettingRow<Recorder: View>(
        title: String,
        detail: String? = nil,
        isConfigured: Bool,
        onClear: @escaping () -> Void,
        @ViewBuilder recorder: () -> Recorder
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 230, alignment: .leading)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                recorder()
                    .frame(width: 210, height: 32)
                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary.opacity(isConfigured ? 1 : 0.4))
                .disabled(!isConfigured)
                .help("移除快捷键")
                .accessibilityLabel("移除\(title)快捷键")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var storage: some View {
        Form {
            Section("自动归档") {
                Text("超过 30 天或热数据超过 10,000 条时归档。收藏、置顶和普通分组内容不会自动归档。")
                settingsActionRow {
                    Button("立即检查归档") { Task { await state.runArchive() } }
                        .disabled(state.isBusy)
                }
            }
            Section("本地备份") {
                settingsActionRow {
                    Button("导出备份…", action: onExport)
                    Button("导入备份…", action: onImport)
                }
                Text("备份包含 Pasteory 内保存的内容和元数据，不复制原始文件实体。")
            }
            if let message = state.statusMessage { Text(message).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            Section("辅助功能") {
                let accessibilityTrusted = pasteCoordinator.accessibilityTrusted()
                LabeledContent("直接粘贴与会话识别", value: accessibilityTrusted ? "已授权" : "未授权")
                if !accessibilityTrusted {
                    settingsActionRow {
                        Button("打开授权提示并退出 Pasteory") {
                            pasteCoordinator.requestAccessibilityPermissionAndTerminate()
                        }
                    }
                    Text("系统弹出授权提示后，Pasteory 会退出。完成授权再重新打开，微信和飞书的会话识别才能稳定生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("辅助功能权限已经生效", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Section("Chrome 插件") {
                let chromeStatus = ChromeExtensionIntegration.status()
                LabeledContent("插件文件", value: chromeStatus.extensionAvailable ? "已准备" : "缺失")
                LabeledContent("原生消息桥", value: chromeStatus.nativeHostRegistered ? "已注册" : "未注册")
                if let lastContactAt = chromeStatus.lastContactAt {
                    LabeledContent("最近连接", value: lastContactAt.formatted(date: .abbreviated, time: .standard))
                } else {
                    LabeledContent("最近连接", value: "尚未连接")
                }
                settingsActionRow {
                    Button("前往链接解析设置") { selectedDestination = .linkResolution }
                }
                Text("插件安装、浏览器连接和网站解析授权统一在“链接解析”中管理。这里仅保留连接诊断。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("搜索索引") {
                settingsActionRow {
                    Button("重建搜索索引") {
                        Task {
                            do {
                                try await state.repository.rebuildSearchIndex()
                                state.presentStatus("搜索索引已重建")
                            } catch { state.show(error) }
                        }
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private func prepareChromeExtension() {
        do {
            let changeCount = try ChromeExtensionIntegration.prepareInteractiveInstall()
            pasteCoordinator.monitor?.markOwnWrite(changeCount: changeCount)
            state.presentStatus("已注册原生消息桥、复制插件目录并打开 Chrome 扩展程序页面", dismissAfter: 6)
        } catch { state.show(error) }
    }

    private var about: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Pasteory").font(.largeTitle.bold())
            Text(versionLabel)
            Text(PasteoryBrand.tagline).foregroundStyle(.secondary)
            Text(PasteoryBrand.taglineChinese).foregroundStyle(.secondary)
            Text("Pasteory v0.1 不包含网络、AI 分析或云同步功能。").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "版本 \(version)（Build \(build)）"
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = enabled
        } catch { state.show(error); loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}

@MainActor
private enum ApplicationLifecycle {
    static func restart() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        try process.run()
        NSApp.terminate(nil)
    }
}

private struct SourceCaptureApplicationIcon: View {
    let application: SourceCaptureApplication

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(.secondary).padding(3)
            }
        }
        .accessibilityHidden(true)
    }

    private var icon: NSImage? {
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("SourceAppIcons", isDirectory: true)
            .appendingPathComponent(application.iconResourceName),
           let image = NSImage(contentsOf: resourceURL) {
            return image
        }
        for bundleIdentifier in application.bundleIdentifiers {
            if let image = ApplicationCatalog.icon(for: bundleIdentifier, fallbackName: application.title) {
                return image
            }
        }
        return nil
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let keyCode: UInt32
    let modifiers: UInt32
    var isConfigured = true
    var allowsUnmodified = false
    let onChange: (UInt32, UInt32) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        ShortcutRecorderNSView(keyCode: keyCode, modifiers: modifiers, isConfigured: isConfigured, allowsUnmodified: allowsUnmodified, onChange: onChange)
    }
    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.update(keyCode: keyCode, modifiers: modifiers, isConfigured: isConfigured)
    }
}

final class ShortcutRecorderNSView: NSView {
    private var keyCode: UInt32
    private var modifiers: UInt32
    private var isConfigured: Bool
    private let allowsUnmodified: Bool
    private let onChange: (UInt32, UInt32) -> Bool
    private var recording = false
    var isRecordingShortcut: Bool { recording }

    init(keyCode: UInt32, modifiers: UInt32, isConfigured: Bool, allowsUnmodified: Bool, onChange: @escaping (UInt32, UInt32) -> Bool) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.isConfigured = isConfigured
        self.allowsUnmodified = allowsUnmodified; self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 210, height: 32))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 210, height: 32) }
    override func resignFirstResponder() -> Bool {
        recording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }
    override func mouseDown(with event: NSEvent) { recording = true; window?.makeFirstResponder(self); needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        guard carbon != 0 || allowsUnmodified else { NSSound.beep(); return }
        let candidateKeyCode = UInt32(event.keyCode)
        guard onChange(candidateKeyCode, carbon) else {
            recording = false; NSSound.beep(); needsDisplay = true; return
        }
        keyCode = candidateKeyCode; modifiers = carbon; isConfigured = true; recording = false; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill(); path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); path.stroke()
        let text = recording ? "请按新的快捷键…" : (isConfigured ? ShortcutFormatter.display(keyCode: keyCode, modifiers: modifiers) : "未设置")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    func update(keyCode: UInt32, modifiers: UInt32, isConfigured: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isConfigured = isConfigured
        if !isConfigured { recording = false }
        needsDisplay = true
    }
}

enum ShortcutFormatter {
    static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J",
            39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "Tab", 49: "Space", 50: "`", 51: "⌫", 53: "Esc", 76: "Return"
        ]
        return value + (names[keyCode] ?? "Key \(keyCode)")
    }
}
