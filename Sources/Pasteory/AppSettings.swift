import Combine
import Carbon
import Foundation
import PasteoryCore

enum ClipboardPollingInterval: Double, CaseIterable, Identifiable {
    case oneTenthSecond = 0.1
    case halfSecond = 0.5
    case oneSecond = 1

    var id: Double { rawValue }
    var title: String {
        switch self {
        case .oneTenthSecond: "0.1 秒"
        case .halfSecond: "0.5 秒"
        case .oneSecond: "1 秒"
        }
    }
}

enum SourceCaptureApplication: String, CaseIterable, Identifiable {
    case chrome
    case lark
    case wechat

    var id: String { rawValue }
    var sourceCategory: SourceContextSourceCategory {
        switch self {
        case .chrome: .browser
        case .lark, .wechat: .communication
        }
    }
    var title: String {
        switch self {
        case .chrome: "Google Chrome"
        case .wechat: "微信"
        case .lark: "飞书"
        }
    }
    var detail: String {
        switch self {
        case .chrome: "网页链接、标题、选区和关联元素"
        case .lark, .wechat: "对话类型｜对话标题"
        }
    }
    var iconResourceName: String {
        switch self {
        case .chrome: "chrome.icns"
        case .wechat: "wechat.icns"
        case .lark: "lark.icns"
        }
    }
    var bundleIdentifiers: Set<String> {
        switch self {
        case .chrome:
            ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary"]
        case .wechat:
            ["com.tencent.xinWeChat", "com.tencent.WeChat"]
        case .lark:
            ["com.electron.lark", "com.bytedance.ee.lark", "com.bytedance.ee.lark.mac"]
        }
    }

    static func application(for bundleIdentifier: String?) -> SourceCaptureApplication? {
        guard let bundleIdentifier else { return nil }
        return allCases.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }
}

enum SourceCapturePreferenceKey {
    static let enabledApplications = "sourceContextCaptureEnabledApplications"
}

enum PasteoryThemeColor: String, CaseIterable, Codable, Identifiable {
    case blueViolet
    case blue
    case purple
    case pink
    case orange
    case green
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blueViolet: "蓝紫"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .pink: "粉色"
        case .orange: "橙色"
        case .green: "绿色"
        case .graphite: "石墨"
        }
    }
}

enum QuickPanelAction: String, CaseIterable, Codable, Identifiable {
    case openSelected
    case toggleSearch
    case directPaste
    case copyOnly
    case plainTextPaste
    case plainTextCopy
    case toggleFavorite
    case togglePinned
    case editMetadata
    case setCollection
    case createCollection
    case aggregateContent
    case expandAggregation
    case collapseAggregation
    case moveToTrash
    case openLibrary
    case openSettings
    case closePanel

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openSelected: "打开所选内容"
        case .toggleSearch: "搜索"
        case .directPaste: "直接粘贴"
        case .copyOnly: "只复制"
        case .plainTextPaste: "纯文本粘贴"
        case .plainTextCopy: "纯文本复制"
        case .toggleFavorite: "收藏／取消收藏"
        case .togglePinned: "置顶／取消置顶"
        case .editMetadata: "编辑信息"
        case .setCollection: "设置分组"
        case .createCollection: "新建分组"
        case .aggregateContent: "聚合内容"
        case .expandAggregation: "展开聚合"
        case .collapseAggregation: "收起聚合"
        case .moveToTrash: "移到废纸篓"
        case .openLibrary: "打开资料库"
        case .openSettings: "打开设置"
        case .closePanel: "关闭快捷面板"
        }
    }
}

struct PasteoryShortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
}

enum FileCommandExecutionStatus: Equatable {
    case running
    case succeeded
    case failed(Int32)

    var displayName: String {
        switch self {
        case .running: "执行中"
        case .succeeded: "已完成"
        case .failed(let code): "失败（退出码 \(code)）"
        }
    }
}

struct FileCommandExecution: Identifiable, Equatable {
    var id: UUID
    var fileType: String
    var startedAt: Date
    var finishedAt: Date?
    var status: FileCommandExecutionStatus
    var logURL: URL
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let completedOnboarding = "completedOnboarding"
        static let monitoringEnabled = "monitoringEnabled"
        static let monitoringDefaultVersion = "monitoringDefaultVersion"
        static let clipboardPollingInterval = "clipboardPollingInterval"
        static let defaultDirectPaste = "defaultDirectPaste"
        static let excludedApps = "excludedApps"
        static let shortcutKeyCode = "shortcutKeyCode"
        static let shortcutModifiers = "shortcutModifiers"
        static let globalShortcutEnabled = "globalShortcutEnabled"
        static let shortcutDefaultVersion = "shortcutDefaultVersion"
        static let quickActionShortcuts = "quickActionShortcuts"
        static let disabledQuickActions = "disabledQuickActions"
        static let linkResolutionEnabled = "linkResolutionEnabled"
        static let themeColor = "themeColor"
        static let browserBundleIdentifier = "browserBundleIdentifier"
        static let codeEditorBundleIdentifier = "codeEditorBundleIdentifier"
        static let fileOpenRules = "fileOpenRules"
        static let fileCommandShell = "fileCommandShell"
        static let fileCommandPresentation = "fileCommandPresentation"
        static let authenticatedLinkRules = "authenticatedLinkRules"
    }

    @Published var completedOnboarding: Bool { didSet { defaults.set(completedOnboarding, forKey: Key.completedOnboarding) } }
    @Published var monitoringEnabled: Bool { didSet { defaults.set(monitoringEnabled, forKey: Key.monitoringEnabled) } }
    @Published var clipboardPollingInterval: ClipboardPollingInterval {
        didSet { defaults.set(clipboardPollingInterval.rawValue, forKey: Key.clipboardPollingInterval) }
    }
    @Published var defaultDirectPaste: Bool { didSet { defaults.set(defaultDirectPaste, forKey: Key.defaultDirectPaste) } }
    @Published var linkResolutionEnabled: Bool { didSet { defaults.set(linkResolutionEnabled, forKey: Key.linkResolutionEnabled) } }
    @Published var themeColor: PasteoryThemeColor {
        didSet { defaults.set(themeColor.rawValue, forKey: Key.themeColor) }
    }
    @Published var browserBundleIdentifier: String {
        didSet { defaults.set(browserBundleIdentifier, forKey: Key.browserBundleIdentifier) }
    }
    @Published var codeEditorBundleIdentifier: String {
        didSet { defaults.set(codeEditorBundleIdentifier, forKey: Key.codeEditorBundleIdentifier) }
    }
    @Published private(set) var fileOpenRules: [FileOpenRule] {
        didSet { persistFileOpenRules() }
    }
    @Published var fileCommandShell: FileCommandShell {
        didSet { defaults.set(fileCommandShell.rawValue, forKey: Key.fileCommandShell) }
    }
    @Published var fileCommandPresentation: FileCommandPresentation {
        didSet { defaults.set(fileCommandPresentation.rawValue, forKey: Key.fileCommandPresentation) }
    }
    @Published private(set) var authenticatedLinkRules: [AuthenticatedLinkRule] {
        didSet { persistAuthenticatedLinkRules() }
    }
    @Published var excludedBundleIdentifiers: Set<String> { didSet { defaults.set(Array(excludedBundleIdentifiers).sorted(), forKey: Key.excludedApps) } }
    @Published private(set) var enabledSourceCaptureApplications: Set<SourceCaptureApplication> {
        didSet { defaults.set(enabledSourceCaptureApplications.map(\.rawValue).sorted(), forKey: SourceCapturePreferenceKey.enabledApplications) }
    }
    @Published var shortcutKeyCode: UInt32 { didSet { defaults.set(Int(shortcutKeyCode), forKey: Key.shortcutKeyCode) } }
    @Published var shortcutModifiers: UInt32 { didSet { defaults.set(Int(shortcutModifiers), forKey: Key.shortcutModifiers) } }
    @Published private(set) var globalShortcutEnabled: Bool {
        didSet { defaults.set(globalShortcutEnabled, forKey: Key.globalShortcutEnabled) }
    }
    @Published private(set) var quickActionShortcuts: [QuickPanelAction: PasteoryShortcut] {
        didSet { persistQuickActionShortcuts() }
    }
    @Published private(set) var disabledQuickActions: Set<QuickPanelAction> {
        didSet { defaults.set(disabledQuickActions.map(\.rawValue).sorted(), forKey: Key.disabledQuickActions) }
    }
    @Published private(set) var recentFileCommandExecutions: [String: FileCommandExecution] = [:]

    private let defaults: UserDefaults
    let fileCommandLogsDirectory: URL?

    init(defaults: UserDefaults = .standard, logsDirectory: URL? = nil) {
        self.defaults = defaults
        fileCommandLogsDirectory = logsDirectory?.appendingPathComponent("FileCommands", isDirectory: true)
        completedOnboarding = defaults.bool(forKey: Key.completedOnboarding)
        if defaults.integer(forKey: Key.monitoringDefaultVersion) < 2 {
            monitoringEnabled = true
            defaults.set(true, forKey: Key.monitoringEnabled)
            defaults.set(2, forKey: Key.monitoringDefaultVersion)
        } else {
            monitoringEnabled = defaults.object(forKey: Key.monitoringEnabled) as? Bool ?? true
        }
        clipboardPollingInterval = ClipboardPollingInterval(
            rawValue: defaults.double(forKey: Key.clipboardPollingInterval)
        ) ?? .oneSecond
        defaultDirectPaste = defaults.object(forKey: Key.defaultDirectPaste) as? Bool ?? true
        linkResolutionEnabled = defaults.object(forKey: Key.linkResolutionEnabled) as? Bool ?? false
        themeColor = PasteoryThemeColor(rawValue: defaults.string(forKey: Key.themeColor) ?? "") ?? .blueViolet
        browserBundleIdentifier = defaults.string(forKey: Key.browserBundleIdentifier) ?? ""
        codeEditorBundleIdentifier = defaults.string(forKey: Key.codeEditorBundleIdentifier) ?? ""
        if let data = defaults.data(forKey: Key.fileOpenRules),
           let stored = try? JSONDecoder().decode([FileOpenRule].self, from: data) {
            var seenMatches = Set<String>()
            fileOpenRules = stored
                .map(Self.migrateFileTypeRuleToExtension)
                .filter { seenMatches.insert($0.matchIdentifier).inserted }
        } else {
            fileOpenRules = []
        }
        fileCommandShell = FileCommandShell(
            rawValue: defaults.string(forKey: Key.fileCommandShell) ?? ""
        ) ?? .zsh
        fileCommandPresentation = FileCommandPresentation(
            rawValue: defaults.string(forKey: Key.fileCommandPresentation) ?? ""
        ) ?? .terminalWindow
        if let data = defaults.data(forKey: Key.authenticatedLinkRules),
           let stored = try? JSONDecoder().decode([AuthenticatedLinkRule].self, from: data) {
            authenticatedLinkRules = stored
        } else {
            authenticatedLinkRules = []
        }
        excludedBundleIdentifiers = Set(defaults.stringArray(forKey: Key.excludedApps) ?? [])
        enabledSourceCaptureApplications = Set(
            (defaults.stringArray(forKey: SourceCapturePreferenceKey.enabledApplications) ?? [])
                .compactMap(SourceCaptureApplication.init(rawValue:))
        )
        let storedKeyCode = defaults.object(forKey: Key.shortcutKeyCode) as? Int
        let storedModifiers = defaults.object(forKey: Key.shortcutModifiers) as? Int
        globalShortcutEnabled = defaults.object(forKey: Key.globalShortcutEnabled) as? Bool ?? true
        shortcutKeyCode = UInt32(storedKeyCode ?? Int(Self.defaultGlobalShortcut.keyCode))
        shortcutModifiers = UInt32(storedModifiers ?? Int(Self.defaultGlobalShortcut.modifiers))
        defaults.set(4, forKey: Key.shortcutDefaultVersion)
        var disabledActions = Set(
            (defaults.stringArray(forKey: Key.disabledQuickActions) ?? []).compactMap(QuickPanelAction.init(rawValue:))
        )
        if let data = defaults.data(forKey: Key.quickActionShortcuts),
           let stored = try? JSONDecoder().decode([String: PasteoryShortcut].self, from: data) {
            var values = Self.defaultQuickActionShortcuts
            for (rawAction, shortcut) in stored {
                if let action = QuickPanelAction(rawValue: rawAction) { values[action] = shortcut }
            }
            let newlyAddedActions: [QuickPanelAction] = [
                .createCollection, .aggregateContent, .expandAggregation, .collapseAggregation
            ]
            for action in newlyAddedActions where stored[action.rawValue] == nil {
                guard let proposed = Self.defaultQuickActionShortcuts[action],
                      stored.contains(where: { rawAction, shortcut in
                          rawAction != action.rawValue && shortcut == proposed
                      }) else { continue }
                values.removeValue(forKey: action)
                disabledActions.insert(action)
            }
            defaults.set(disabledActions.map(\.rawValue).sorted(), forKey: Key.disabledQuickActions)
            quickActionShortcuts = values
        } else {
            quickActionShortcuts = Self.defaultQuickActionShortcuts
        }
        disabledQuickActions = disabledActions
        defaults.set(
            enabledSourceCaptureApplications.map(\.rawValue).sorted(),
            forKey: SourceCapturePreferenceKey.enabledApplications
        )
    }

    var capturePolicy: CapturePolicy {
        var policy = CapturePolicy.default
        policy.excludedBundleIdentifiers.formUnion(excludedBundleIdentifiers)
        return policy
    }

    var globalShortcut: PasteoryShortcut? {
        guard globalShortcutEnabled else { return nil }
        return PasteoryShortcut(keyCode: shortcutKeyCode, modifiers: shortcutModifiers)
    }

    func isSourceCaptureEnabled(for application: SourceCaptureApplication) -> Bool {
        enabledSourceCaptureApplications.contains(application)
    }

    func isSourceCaptureEnabled(for bundleIdentifier: String?) -> Bool {
        guard let application = SourceCaptureApplication.application(for: bundleIdentifier) else { return false }
        return isSourceCaptureEnabled(for: application)
    }

    func setSourceCaptureEnabled(_ enabled: Bool, for application: SourceCaptureApplication) {
        if enabled { enabledSourceCaptureApplications.insert(application) }
        else { enabledSourceCaptureApplications.remove(application) }
    }

    func reloadSourceCapturePreferences() {
        defaults.synchronize()
        enabledSourceCaptureApplications = Set(
            (defaults.stringArray(forKey: SourceCapturePreferenceKey.enabledApplications) ?? [])
                .compactMap(SourceCaptureApplication.init(rawValue:))
        )
    }

    func quickShortcut(for action: QuickPanelAction) -> PasteoryShortcut? {
        guard !disabledQuickActions.contains(action) else { return nil }
        return quickActionShortcuts[action] ?? Self.defaultQuickActionShortcuts[action]
    }

    func quickAction(keyCode: UInt32, modifiers: UInt32) -> QuickPanelAction? {
        let normalizedKeyCode: UInt32 = keyCode == 76 ? 36 : keyCode
        return QuickPanelAction.allCases.first {
            quickShortcut(for: $0) == PasteoryShortcut(keyCode: normalizedKeyCode, modifiers: modifiers)
        }
    }

    func setQuickShortcut(_ shortcut: PasteoryShortcut, for action: QuickPanelAction) -> String? {
        let normalized = PasteoryShortcut(keyCode: shortcut.keyCode == 76 ? 36 : shortcut.keyCode, modifiers: shortcut.modifiers)
        if let message = shortcutValidationMessage(normalized, for: action) { return message }
        var values = quickActionShortcuts
        values[action] = normalized
        quickActionShortcuts = values
        disabledQuickActions.remove(action)
        return nil
    }

    func clearQuickShortcut(for action: QuickPanelAction) {
        disabledQuickActions.insert(action)
    }

    func setGlobalShortcut(_ shortcut: PasteoryShortcut) {
        shortcutKeyCode = shortcut.keyCode
        shortcutModifiers = shortcut.modifiers
        globalShortcutEnabled = true
    }

    func clearGlobalShortcut() {
        globalShortcutEnabled = false
    }

    func resetAllShortcuts() {
        shortcutKeyCode = Self.defaultGlobalShortcut.keyCode
        shortcutModifiers = Self.defaultGlobalShortcut.modifiers
        globalShortcutEnabled = true
        quickActionShortcuts = Self.defaultQuickActionShortcuts
        disabledQuickActions.removeAll()
    }

    func addFileOpenRule() {
        let configuredExtensions = Set(fileOpenRules.map(\.normalizedFileExtension))
        guard let next = FileIconResolver.allFileExtensions.first(where: {
            !configuredExtensions.contains($0.fileExtension)
        }) else { return }
        fileOpenRules.append(FileOpenRule(
            matchKind: .catalogExtension,
            fileType: next.assetName,
            fileExtension: next.fileExtension
        ))
    }

    func addCustomFileOpenRule() {
        guard !fileOpenRules.contains(where: {
            $0.matchKind == .fileExtension && $0.normalizedFileExtension.isEmpty
        }) else { return }
        fileOpenRules.append(FileOpenRule(matchKind: .fileExtension))
    }

    func updateFileOpenRule(_ rule: FileOpenRule) {
        guard let index = fileOpenRules.firstIndex(where: { $0.id == rule.id }) else { return }
        var normalized = rule
        if !FileIconResolver.allAssetNames.contains(normalized.fileType) {
            normalized.fileType = "generic"
        }
        fileOpenRules[index] = normalized
    }

    func updateFileOpenRuleType(id: UUID, fileType: String) {
        guard let index = fileOpenRules.firstIndex(where: { $0.id == id }),
              FileIconResolver.allAssetNames.contains(fileType) else { return }
        fileOpenRules[index].matchKind = .fileType
        fileOpenRules[index].fileType = fileType
    }

    func updateFileOpenRuleCatalogExtension(id: UUID, descriptor: FileExtensionDescriptor) {
        guard let index = fileOpenRules.firstIndex(where: { $0.id == id }) else { return }
        fileOpenRules[index].matchKind = .catalogExtension
        fileOpenRules[index].fileType = descriptor.assetName
        fileOpenRules[index].fileExtension = descriptor.fileExtension
    }

    func updateFileOpenRuleExtension(id: UUID, fileExtension: String) {
        guard let index = fileOpenRules.firstIndex(where: { $0.id == id }) else { return }
        fileOpenRules[index].matchKind = .fileExtension
        fileOpenRules[index].fileExtension = fileExtension
    }

    func updateFileOpenRuleCommand(id: UUID, command: String) {
        guard let index = fileOpenRules.firstIndex(where: { $0.id == id }) else { return }
        fileOpenRules[index].command = command
    }

    func removeFileOpenRule(id: UUID) {
        fileOpenRules.removeAll { $0.id == id }
    }

    func saveAuthenticatedLinkRule(_ rule: AuthenticatedLinkRule) {
        if let index = authenticatedLinkRules.firstIndex(where: { $0.id == rule.id }) {
            authenticatedLinkRules[index] = rule
        } else {
            authenticatedLinkRules.append(rule)
        }
    }

    func removeAuthenticatedLinkRule(id: UUID) {
        authenticatedLinkRules.removeAll { $0.id == id }
    }

    func fileOpenRule(fileName: String, uti: String?) -> FileOpenRule? {
        if let customRule = fileOpenRules.first(where: {
            $0.matchKind == .fileExtension && $0.matches(fileName: fileName, uti: uti)
        }) {
            return customRule
        }
        if let catalogRule = fileOpenRules.first(where: {
            $0.matchKind == .catalogExtension && $0.matches(fileName: fileName, uti: uti)
        }) {
            return catalogRule
        }
        return fileOpenRules.first {
            $0.matchKind == .fileType && $0.matches(fileName: fileName, uti: uti)
        }
    }

    func beginFileCommandLog(fileType: String, shell: FileCommandShell) -> (FileCommandExecution, FileHandle)? {
        guard let fileCommandLogsDirectory else { return nil }
        do {
            try FileManager.default.createDirectory(at: fileCommandLogsDirectory, withIntermediateDirectories: true)
            let execution = FileCommandExecution(
                id: UUID(),
                fileType: fileType,
                startedAt: Date(),
                finishedAt: nil,
                status: .running,
                logURL: fileCommandLogsDirectory.appendingPathComponent(
                    "\(Self.logTimestamp.string(from: Date()))-\(fileType)-\(UUID().uuidString.prefix(8)).log"
                )
            )
            let header = "Pasteory 文件命令\n类型：\(fileType)\nShell：\(shell.displayName)\n开始：\(execution.startedAt.formatted(.iso8601))\n\n"
            try Data(header.utf8).write(to: execution.logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: execution.logURL)
            try handle.seekToEnd()
            recentFileCommandExecutions[fileType] = execution
            trimFileCommandLogs()
            return (execution, handle)
        } catch {
            return nil
        }
    }

    @discardableResult
    func finishFileCommandLog(
        execution: FileCommandExecution,
        exitCode: Int32
    ) -> FileCommandExecution {
        var finished = execution
        finished.finishedAt = Date()
        finished.status = exitCode == 0 ? .succeeded : .failed(exitCode)
        recentFileCommandExecutions[execution.fileType] = finished
        return finished
    }

    func recentFileCommandExecution(for fileType: String) -> FileCommandExecution? {
        recentFileCommandExecutions[fileType]
    }

    func globalShortcutConflict(keyCode: UInt32, modifiers: UInt32) -> String? {
        guard let action = quickAction(keyCode: keyCode, modifiers: modifiers) else { return nil }
        return "与“\(action.title)”的快捷键重复"
    }

    private func shortcutValidationMessage(_ shortcut: PasteoryShortcut, for action: QuickPanelAction) -> String? {
        guard Self.menuRenderableKeyCodes.contains(shortcut.keyCode) else {
            return "该按键无法在 macOS 右键菜单中显示，请换一个按键"
        }
        if globalShortcutEnabled,
           shortcut.keyCode == shortcutKeyCode, shortcut.modifiers == shortcutModifiers {
            return "与“打开快捷面板”的全局快捷键重复"
        }
        if shortcut.keyCode == 53 { return "Esc 固定用于关闭快捷面板" }
        if [123, 124, 115].contains(shortcut.keyCode) { return "左右方向键和 Home 固定用于列表导航" }
        if [125, 126].contains(shortcut.keyCode),
           ![QuickPanelAction.expandAggregation, .collapseAggregation].contains(action) {
            return "上下方向键只用于聚合展开或收起"
        }
        let command = UInt32(cmdKey)
        if shortcut.modifiers == command,
           [4, 12, 46, 48, 49, 50].contains(shortcut.keyCode) {
            return "该组合由 macOS 保留，请换一个快捷键"
        }
        if shortcut.modifiers == (command | UInt32(optionKey)), shortcut.keyCode == 53 {
            return "Command-Option-Esc 由 macOS 保留"
        }
        if shortcut.modifiers & command != 0,
           [18, 19, 20, 21, 23, 22, 26, 28, 25].contains(shortcut.keyCode) {
            return "Command-1～9 固定用于快速粘贴对应项目"
        }
        if shortcut.modifiers == 0, action != .openSelected, ![36, 76].contains(shortcut.keyCode) {
            return "除“打开所选内容”和 Return 操作外，请至少加入一个修饰键"
        }
        if let duplicate = QuickPanelAction.allCases.first(where: {
            $0 != action && quickShortcut(for: $0) == shortcut
        }) {
            return "与“\(duplicate.title)”的快捷键重复"
        }
        return nil
    }

    private func persistQuickActionShortcuts() {
        let stored = Dictionary(uniqueKeysWithValues: quickActionShortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Key.quickActionShortcuts) }
    }

    private func persistFileOpenRules() {
        if let data = try? JSONEncoder().encode(fileOpenRules) {
            defaults.set(data, forKey: Key.fileOpenRules)
        }
    }

    private static func migrateFileTypeRuleToExtension(_ storedRule: FileOpenRule) -> FileOpenRule {
        guard storedRule.matchKind == .fileType,
              let descriptor = FileIconResolver.preferredFileExtension(assetName: storedRule.fileType) else {
            return storedRule
        }
        var rule = storedRule
        rule.matchKind = .catalogExtension
        rule.fileExtension = descriptor.fileExtension
        rule.fileType = descriptor.assetName
        return rule
    }

    private func persistAuthenticatedLinkRules() {
        if let data = try? JSONEncoder().encode(authenticatedLinkRules) {
            defaults.set(data, forKey: Key.authenticatedLinkRules)
        }
    }

    private static var defaultGlobalShortcut: PasteoryShortcut {
        PasteoryShortcut(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey))
    }

    private func trimFileCommandLogs() {
        guard let fileCommandLogsDirectory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: fileCommandLogsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ), urls.count > 20 else { return }
        let sorted = urls.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for url in sorted.dropFirst(20) { try? FileManager.default.removeItem(at: url) }
    }

    private static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static var defaultQuickActionShortcuts: [QuickPanelAction: PasteoryShortcut] {
        let command = UInt32(cmdKey), option = UInt32(optionKey), shift = UInt32(shiftKey)
        return [
            .openSelected: PasteoryShortcut(keyCode: 49, modifiers: 0),
            .toggleSearch: PasteoryShortcut(keyCode: 3, modifiers: command),
            .directPaste: PasteoryShortcut(keyCode: 36, modifiers: 0),
            .copyOnly: PasteoryShortcut(keyCode: 8, modifiers: command),
            .plainTextPaste: PasteoryShortcut(keyCode: 36, modifiers: option),
            .plainTextCopy: PasteoryShortcut(keyCode: 8, modifiers: command | option),
            .toggleFavorite: PasteoryShortcut(keyCode: 3, modifiers: command | shift),
            .togglePinned: PasteoryShortcut(keyCode: 17, modifiers: command),
            .editMetadata: PasteoryShortcut(keyCode: 14, modifiers: command),
            .setCollection: PasteoryShortcut(keyCode: 5, modifiers: command),
            .createCollection: PasteoryShortcut(keyCode: 45, modifiers: command | shift),
            .aggregateContent: PasteoryShortcut(keyCode: 11, modifiers: command),
            .expandAggregation: PasteoryShortcut(keyCode: 125, modifiers: command),
            .collapseAggregation: PasteoryShortcut(keyCode: 126, modifiers: command),
            .moveToTrash: PasteoryShortcut(keyCode: 51, modifiers: command),
            .openLibrary: PasteoryShortcut(keyCode: 37, modifiers: command),
            .openSettings: PasteoryShortcut(keyCode: 43, modifiers: command),
            .closePanel: PasteoryShortcut(keyCode: 13, modifiers: command)
        ]
    }

    private static let menuRenderableKeyCodes: Set<UInt32> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44,
        45, 46, 47, 48, 49, 50, 51, 53, 76
    ]
}
