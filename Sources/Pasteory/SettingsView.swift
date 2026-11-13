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
            case .linkResolution: "网页标题、登录规则和兜底规则"
            case .storage: "统计、占用、归档和备份"
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
    @State private var storageAnalyticsPeriod: StorageAnalyticsPeriod = .sevenDays

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
        .frame(width: 940, height: debugSettingsHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .pasteoryTheme(settings.themeColor)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.reloadSourceCapturePreferences()
        }
#if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-privacy") { selectedDestination = .privacy }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-open") { selectedDestination = .openBehavior }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-file-rules"),
               settings.fileOpenRules.isEmpty {
                settings.addCustomFileOpenRule()
                if let customRule = settings.fileOpenRules.last {
                    settings.updateFileOpenRuleExtension(id: customRule.id, fileExtension: "hap")
                }
                settings.addFileOpenRule()
                if let applicationRule = settings.fileOpenRules.last,
                   let pdf = FileIconResolver.fileExtension("pdf") {
                    settings.updateFileOpenRuleCatalogExtension(id: applicationRule.id, descriptor: pdf)
                    var applicationRule = settings.fileOpenRules.last!
                    applicationRule.bundleIdentifier = "com.apple.Preview"
                    settings.updateFileOpenRule(applicationRule)
                }
                settings.addFileOpenRule()
                if let commandRule = settings.fileOpenRules.last,
                   let swift = FileIconResolver.fileExtension("swift") {
                    settings.updateFileOpenRuleCatalogExtension(id: commandRule.id, descriptor: swift)
                    var commandRule = settings.fileOpenRules.last!
                    commandRule.action = .command
                    commandRule.command = "wc -l \"$file\""
                    settings.updateFileOpenRule(commandRule)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-file-rules"),
               settings.recentFileCommandExecution(for: "extension:swift") == nil,
               let (execution, handle) = settings.beginFileCommandLog(fileType: "extension:swift", shell: .zsh) {
                try? handle.write(contentsOf: Data("8 Sources/Pasteory/AppState.swift\n".utf8))
                try? handle.close()
                settings.finishFileCommandLog(execution: execution, exitCode: 0)
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-links") { selectedDestination = .linkResolution }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-shortcuts") { selectedDestination = .shortcuts }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-storage") { selectedDestination = .storage }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-storage-thirty-days") {
                selectedDestination = .storage
                storageAnalyticsPeriod = .thirtyDays
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-advanced") { selectedDestination = .advanced }
            if ProcessInfo.processInfo.arguments.contains("--debug-settings-about") { selectedDestination = .about }
        }
#endif
    }

    private var debugSettingsHeight: CGFloat {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--debug-settings-file-rules") ? 900 : 660
#else
        660
#endif
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: PasteoryBrand.appIconImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
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
            Section("快捷面板") {
                Picker("分组 Tab 位置", selection: $settings.quickTabLayout) {
                    ForEach(QuickTabLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                Text("两种布局均用 ↑↓ 选择内容、←→ 切换分组；搜索输入时保留文字编辑操作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                Text("默认每 1 秒检查一次，可调整为 0.5 秒或 0.1 秒。修改后会在下一轮检测生效；休眠和锁屏时停止检测。")
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
                LabeledContent("选择内容 / 切换分组", value: "↑↓ / ←→")
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
                Text("全局唤起恢复为 ⌘⇧V，打开内容恢复为空格，搜索恢复为 ⌘F，其余操作恢复为当前发布默认组合。")
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
        [
            .quickActions, .toggleFavorite, .togglePinned, .editMetadata, .setCollection,
            .createCollection, .aggregateContent, .expandAggregation, .collapseAggregation, .moveToTrash
        ]
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
            Section("内容统计") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("统计范围")
                        Text("按本机时区的自然日计算")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker("统计范围", selection: $storageAnalyticsPeriod) {
                        ForEach(StorageAnalyticsPeriod.allCases) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }

                if let snapshot = currentStorageSnapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("保存内容")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(snapshot.clipCount) 条")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                        }
                        HorizontalStackedTrendChart(
                            rows: trendRows(for: snapshot),
                            visibleRowCount: snapshot.period == .thirtyDays ? 7 : nil
                        )
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())],
                            alignment: .leading,
                            spacing: 9
                        ) {
                            ForEach(nonEmptyClipCounts(in: snapshot)) { item in
                                AnalyticsLegendRow(
                                    color: color(for: item.kind),
                                    title: item.kind.displayName,
                                    value: "\(item.count) 条 · \(percentage(item.count, of: snapshot.clipCount))"
                                )
                            }
                        }
                        if snapshot.clipCount == 0 {
                            Text("这个时间范围内还没有保存内容。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在统计…").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(minHeight: 72)
                }
            }

            Section("本地占用") {
                if let snapshot = currentStorageSnapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pasteory 数据")
                                if let diskShare = diskShareText(for: snapshot) {
                                    Text(diskShare)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(FileSizeFormatter.string(forByteCount: snapshot.totalStorageBytes))
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                        }
                        StorageStackedBar(segments: storageSegments(for: snapshot))
                        VStack(spacing: 8) {
                            ForEach(snapshot.storageUsage) { usage in
                                AnalyticsLegendRow(
                                    color: color(for: usage.category),
                                    title: usage.category.displayName,
                                    value: "\(FileSizeFormatter.string(forByteCount: usage.byteCount)) · \(percentage(usage.byteCount, of: snapshot.totalStorageBytes))"
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在读取存储空间…").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(minHeight: 72)
                }

                Text("包含 Pasteory 的剪贴板数据和网页缓存。直接复制的图片存为独立副本；文件引用指向的原文件不计入占用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                settingsActionRow {
                    Button {
                        Task { await state.refreshStorageAnalytics(period: storageAnalyticsPeriod) }
                    } label: {
                        Label("重新统计", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.storageAnalyticsLoading)
                }
            }
            WebCacheSettingsSection(settings: settings, cache: state.webCacheMaintenance)
            HistoryCleanupSection(state: state, period: storageAnalyticsPeriod)
            Section("自动归档") {
                Text("超过 30 天或热数据超过 10,000 条时归档。收藏、置顶和普通分组内容不会自动归档。")
                settingsActionRow {
                    Button("立即检查归档") {
                        Task {
                            await state.runArchive()
                            await state.refreshStorageAnalytics(period: storageAnalyticsPeriod)
                        }
                    }
                        .disabled(state.isBusy)
                }
            }
            Section("本地备份") {
                settingsActionRow {
                    Button("导出备份…", action: onExport).disabled(state.isBusy)
                    Button("导入备份…", action: onImport).disabled(state.isBusy)
                }
                Text("备份包含 Pasteory 内保存的内容和元数据，不复制原始文件实体。")
            }
            if let message = state.statusMessage { Text(message).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .task(id: storageAnalyticsPeriod) {
            await state.refreshStorageAnalytics(period: storageAnalyticsPeriod)
        }
    }

    private var currentStorageSnapshot: StorageAnalyticsSnapshot? {
        guard let snapshot = state.storageAnalyticsSnapshot,
              snapshot.period == storageAnalyticsPeriod else { return nil }
        return snapshot
    }

    private func nonEmptyClipCounts(in snapshot: StorageAnalyticsSnapshot) -> [ClipKindCount] {
        let counts = Dictionary(uniqueKeysWithValues: snapshot.clipCounts.map { ($0.kind, $0.count) })
        return ClipKind.allCases.compactMap { kind in
            let count = counts[kind, default: 0]
            return count > 0 ? ClipKindCount(kind: kind, count: count) : nil
        }
    }

    private func trendRows(for snapshot: StorageAnalyticsSnapshot) -> [AnalyticsTrendRow] {
        snapshot.clipBuckets.reversed().map { bucket in
            let segments: [AnalyticsBarSegment] = bucket.counts.compactMap { item in
                guard item.count > 0 else { return nil }
                return AnalyticsBarSegment(
                    id: item.kind.rawValue,
                    value: Double(item.count),
                    color: color(for: item.kind)
                )
            }
            return AnalyticsTrendRow(
                id: bucket.id,
                label: bucket.startDate.map(shortDateLabel) ?? "总共",
                totalCount: bucket.totalCount,
                segments: segments
            )
        }
    }

    private func shortDateLabel(_ date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }

    private func storageSegments(for snapshot: StorageAnalyticsSnapshot) -> [AnalyticsBarSegment] {
        snapshot.storageUsage.compactMap { usage in
            guard usage.byteCount > 0 else { return nil }
            return AnalyticsBarSegment(
                id: usage.category.rawValue,
                value: Double(usage.byteCount),
                color: color(for: usage.category)
            )
        }
    }

    private func color(for kind: ClipKind) -> Color {
        switch kind {
        case .text: .blue
        case .image: .pink
        case .link: .cyan
        case .color: .orange
        case .code: .purple
        case .file: .indigo
        case .mixed: .gray
        }
    }

    private func color(for category: PasteoryStorageCategory) -> Color {
        switch category {
        case .database: .blue
        case .attachments: .pink
        case .archives: .purple
        case .backups: .green
        case .logs: .teal
        case .webKitNetworkCache: .orange
        case .other: .gray
        }
    }

    private func percentage<T: BinaryInteger>(_ value: T, of total: T) -> String {
        guard total > 0, value > 0 else { return "0%" }
        let result = Double(value) / Double(total) * 100
        if result < 0.1 { return "<0.1%" }
        if result < 10 { return String(format: "%.1f%%", result) }
        return String(format: "%.0f%%", result)
    }

    private func diskShareText(for snapshot: StorageAnalyticsSnapshot) -> String? {
        guard let volumeTotal = snapshot.volumeTotalBytes, volumeTotal > 0 else { return nil }
        return "占本机磁盘 \(percentage(snapshot.totalStorageBytes, of: volumeTotal))"
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

private struct AnalyticsBarSegment: Identifiable {
    let id: String
    let value: Double
    let color: Color
}

private struct AnalyticsTrendRow: Identifiable {
    let id: Date
    let label: String
    let totalCount: Int
    let segments: [AnalyticsBarSegment]
}

private struct HorizontalStackedTrendChart: View {
    let rows: [AnalyticsTrendRow]
    let visibleRowCount: Int?

    var body: some View {
        Group {
            if let visibleRowCount, rows.count > visibleRowCount {
                VStack(spacing: 4) {
                    ScrollView(.vertical) {
                        rowList
                            .padding(.trailing, 8)
                    }
                    .scrollIndicators(.visible)
                    .frame(height: listHeight(for: visibleRowCount))
                    HStack(spacing: 4) {
                        Spacer()
                        Image(systemName: "chevron.down")
                        Text("向下滚动查看更早日期")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            } else {
                rowList
            }
        }
    }

    private var rowList: some View {
        let maximum = max(rows.map(\.totalCount).max() ?? 0, 1)
        return VStack(spacing: rowSpacing) {
            ForEach(rows) { row in
                HStack(spacing: 9) {
                    Text(row.label)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.08))
                            HStack(spacing: 0) {
                                ForEach(row.segments) { segment in
                                    segment.color.frame(
                                        width: geometry.size.width * CGFloat(segment.value) / CGFloat(maximum)
                                    )
                                }
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 13)

                    Text("\(row.totalCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
                .frame(height: rowHeight)
                .help("\(row.label) · \(row.totalCount) 条")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.label)，\(row.totalCount) 条")
            }
        }
    }

    private func listHeight(for count: Int) -> CGFloat {
        CGFloat(count) * rowHeight + CGFloat(max(count - 1, 0)) * rowSpacing
    }

    private var rowHeight: CGFloat { 20 }
    private var rowSpacing: CGFloat { 5 }
}

private struct StorageStackedBar: View {
    let segments: [AnalyticsBarSegment]

    var body: some View {
        GeometryReader { geometry in
            let total = segments.reduce(0) { $0 + $1.value }
            if total > 0 {
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        segment.color
                            .frame(width: max(0, (geometry.size.width - totalSpacing) * CGFloat(segment.value / total)))
                    }
                }
            } else {
                Color.secondary.opacity(0.12)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
    }

    private var totalSpacing: CGFloat {
        CGFloat(max(segments.count - 1, 0)) * 2
    }
}

private struct AnalyticsLegendRow: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
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
            48: "Tab", 49: "Space", 50: "`", 51: "⌫", 53: "Esc", 76: "Return",
            125: "↓", 126: "↑"
        ]
        return value + (names[keyCode] ?? "Key \(keyCode)")
    }
}
