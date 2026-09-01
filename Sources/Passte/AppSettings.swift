import Combine
import Carbon
import Foundation
import PassteCore

enum ClipboardPollingInterval: Double, CaseIterable, Identifiable {
    case halfSecond = 0.5
    case oneSecond = 1
    case threeSeconds = 3

    var id: Double { rawValue }
    var title: String {
        switch self {
        case .halfSecond: "0.5 秒"
        case .oneSecond: "1 秒"
        case .threeSeconds: "3 秒"
        }
    }
}

enum QuickPanelAction: String, CaseIterable, Codable, Identifiable {
    case directPaste
    case copyOnly
    case plainTextPaste
    case plainTextCopy
    case toggleFavorite
    case togglePinned
    case editMetadata
    case setCollection
    case moveToTrash
    case openLibrary
    case openSettings
    case closePanel

    var id: String { rawValue }
    var title: String {
        switch self {
        case .directPaste: "直接粘贴"
        case .copyOnly: "只复制"
        case .plainTextPaste: "纯文本粘贴"
        case .plainTextCopy: "纯文本复制"
        case .toggleFavorite: "收藏／取消收藏"
        case .togglePinned: "置顶／取消置顶"
        case .editMetadata: "编辑标题与备注"
        case .setCollection: "设置分组"
        case .moveToTrash: "移到废纸篓"
        case .openLibrary: "打开资料库"
        case .openSettings: "打开设置"
        case .closePanel: "关闭快捷面板"
        }
    }
}

struct PassteShortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
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
    }

    @Published var completedOnboarding: Bool { didSet { defaults.set(completedOnboarding, forKey: Key.completedOnboarding) } }
    @Published var monitoringEnabled: Bool { didSet { defaults.set(monitoringEnabled, forKey: Key.monitoringEnabled) } }
    @Published var clipboardPollingInterval: ClipboardPollingInterval {
        didSet { defaults.set(clipboardPollingInterval.rawValue, forKey: Key.clipboardPollingInterval) }
    }
    @Published var defaultDirectPaste: Bool { didSet { defaults.set(defaultDirectPaste, forKey: Key.defaultDirectPaste) } }
    @Published var excludedBundleIdentifiers: Set<String> { didSet { defaults.set(Array(excludedBundleIdentifiers).sorted(), forKey: Key.excludedApps) } }
    @Published var shortcutKeyCode: UInt32 { didSet { defaults.set(Int(shortcutKeyCode), forKey: Key.shortcutKeyCode) } }
    @Published var shortcutModifiers: UInt32 { didSet { defaults.set(Int(shortcutModifiers), forKey: Key.shortcutModifiers) } }
    @Published private(set) var globalShortcutEnabled: Bool {
        didSet { defaults.set(globalShortcutEnabled, forKey: Key.globalShortcutEnabled) }
    }
    @Published private(set) var quickActionShortcuts: [QuickPanelAction: PassteShortcut] {
        didSet { persistQuickActionShortcuts() }
    }
    @Published private(set) var disabledQuickActions: Set<QuickPanelAction> {
        didSet { defaults.set(disabledQuickActions.map(\.rawValue).sorted(), forKey: Key.disabledQuickActions) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        excludedBundleIdentifiers = Set(defaults.stringArray(forKey: Key.excludedApps) ?? [])
        let storedKeyCode = defaults.object(forKey: Key.shortcutKeyCode) as? Int
        let storedModifiers = defaults.object(forKey: Key.shortcutModifiers) as? Int
        globalShortcutEnabled = defaults.object(forKey: Key.globalShortcutEnabled) as? Bool ?? true
        if defaults.integer(forKey: Key.shortcutDefaultVersion) < 3,
           (storedKeyCode == nil || storedKeyCode == 9 || storedKeyCode == 11),
           (storedModifiers == nil || storedModifiers == 768) {
            shortcutKeyCode = 8
            shortcutModifiers = 768
            defaults.set(8, forKey: Key.shortcutKeyCode)
            defaults.set(768, forKey: Key.shortcutModifiers)
        } else {
            shortcutKeyCode = UInt32(storedKeyCode ?? 8)
            shortcutModifiers = UInt32(storedModifiers ?? 768)
        }
        defaults.set(3, forKey: Key.shortcutDefaultVersion)
        disabledQuickActions = Set(
            (defaults.stringArray(forKey: Key.disabledQuickActions) ?? []).compactMap(QuickPanelAction.init(rawValue:))
        )
        if let data = defaults.data(forKey: Key.quickActionShortcuts),
           let stored = try? JSONDecoder().decode([String: PassteShortcut].self, from: data) {
            var values = Self.defaultQuickActionShortcuts
            for (rawAction, shortcut) in stored {
                if let action = QuickPanelAction(rawValue: rawAction) { values[action] = shortcut }
            }
            quickActionShortcuts = values
        } else {
            quickActionShortcuts = Self.defaultQuickActionShortcuts
        }
    }

    var capturePolicy: CapturePolicy {
        var policy = CapturePolicy.default
        policy.excludedBundleIdentifiers.formUnion(excludedBundleIdentifiers)
        return policy
    }

    var globalShortcut: PassteShortcut? {
        guard globalShortcutEnabled else { return nil }
        return PassteShortcut(keyCode: shortcutKeyCode, modifiers: shortcutModifiers)
    }

    func quickShortcut(for action: QuickPanelAction) -> PassteShortcut? {
        guard !disabledQuickActions.contains(action) else { return nil }
        return quickActionShortcuts[action] ?? Self.defaultQuickActionShortcuts[action]
    }

    func quickAction(keyCode: UInt32, modifiers: UInt32) -> QuickPanelAction? {
        let normalizedKeyCode: UInt32 = keyCode == 76 ? 36 : keyCode
        return QuickPanelAction.allCases.first {
            quickShortcut(for: $0) == PassteShortcut(keyCode: normalizedKeyCode, modifiers: modifiers)
        }
    }

    func setQuickShortcut(_ shortcut: PassteShortcut, for action: QuickPanelAction) -> String? {
        let normalized = PassteShortcut(keyCode: shortcut.keyCode == 76 ? 36 : shortcut.keyCode, modifiers: shortcut.modifiers)
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

    func setGlobalShortcut(_ shortcut: PassteShortcut) {
        shortcutKeyCode = shortcut.keyCode
        shortcutModifiers = shortcut.modifiers
        globalShortcutEnabled = true
    }

    func clearGlobalShortcut() {
        globalShortcutEnabled = false
    }

    func resetAllShortcuts() {
        shortcutKeyCode = 8
        shortcutModifiers = UInt32(cmdKey | shiftKey)
        globalShortcutEnabled = true
        quickActionShortcuts = Self.defaultQuickActionShortcuts
        disabledQuickActions.removeAll()
    }

    func globalShortcutConflict(keyCode: UInt32, modifiers: UInt32) -> String? {
        guard let action = quickAction(keyCode: keyCode, modifiers: modifiers) else { return nil }
        return "与“\(action.title)”的快捷键重复"
    }

    private func shortcutValidationMessage(_ shortcut: PassteShortcut, for action: QuickPanelAction) -> String? {
        guard Self.menuRenderableKeyCodes.contains(shortcut.keyCode) else {
            return "该按键无法在 macOS 右键菜单中显示，请换一个按键"
        }
        if globalShortcutEnabled,
           shortcut.keyCode == shortcutKeyCode, shortcut.modifiers == shortcutModifiers {
            return "与“打开快捷面板”的全局快捷键重复"
        }
        if shortcut.keyCode == 53 { return "Esc 固定用于关闭快捷面板" }
        if [123, 124, 125, 126, 115].contains(shortcut.keyCode) { return "方向键和 Home 固定用于列表导航" }
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
        if shortcut.modifiers == 0, ![36, 76].contains(shortcut.keyCode) {
            return "未加修饰键的按键会用于搜索；除 Return 外请至少加入一个修饰键"
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

    private static var defaultQuickActionShortcuts: [QuickPanelAction: PassteShortcut] {
        let command = UInt32(cmdKey), option = UInt32(optionKey), shift = UInt32(shiftKey)
        return [
            .directPaste: PassteShortcut(keyCode: 36, modifiers: 0),
            .copyOnly: PassteShortcut(keyCode: 36, modifiers: command),
            .plainTextPaste: PassteShortcut(keyCode: 36, modifiers: option),
            .plainTextCopy: PassteShortcut(keyCode: 36, modifiers: command | option),
            .toggleFavorite: PassteShortcut(keyCode: 3, modifiers: command | shift),
            .togglePinned: PassteShortcut(keyCode: 35, modifiers: command | shift),
            .editMetadata: PassteShortcut(keyCode: 14, modifiers: command | shift),
            .setCollection: PassteShortcut(keyCode: 5, modifiers: command | shift),
            .moveToTrash: PassteShortcut(keyCode: 51, modifiers: command),
            .openLibrary: PassteShortcut(keyCode: 37, modifiers: command),
            .openSettings: PassteShortcut(keyCode: 43, modifiers: command),
            .closePanel: PassteShortcut(keyCode: 13, modifiers: command)
        ]
    }

    private static let menuRenderableKeyCodes: Set<UInt32> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44,
        45, 46, 47, 48, 49, 50, 51, 53, 76
    ]
}
