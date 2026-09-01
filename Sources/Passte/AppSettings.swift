import Combine
import Foundation
import PassteCore

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let completedOnboarding = "completedOnboarding"
        static let monitoringEnabled = "monitoringEnabled"
        static let monitoringDefaultVersion = "monitoringDefaultVersion"
        static let defaultDirectPaste = "defaultDirectPaste"
        static let excludedApps = "excludedApps"
        static let shortcutKeyCode = "shortcutKeyCode"
        static let shortcutModifiers = "shortcutModifiers"
        static let shortcutDefaultVersion = "shortcutDefaultVersion"
    }

    @Published var completedOnboarding: Bool { didSet { defaults.set(completedOnboarding, forKey: Key.completedOnboarding) } }
    @Published var monitoringEnabled: Bool { didSet { defaults.set(monitoringEnabled, forKey: Key.monitoringEnabled) } }
    @Published var defaultDirectPaste: Bool { didSet { defaults.set(defaultDirectPaste, forKey: Key.defaultDirectPaste) } }
    @Published var excludedBundleIdentifiers: Set<String> { didSet { defaults.set(Array(excludedBundleIdentifiers).sorted(), forKey: Key.excludedApps) } }
    @Published var shortcutKeyCode: UInt32 { didSet { defaults.set(Int(shortcutKeyCode), forKey: Key.shortcutKeyCode) } }
    @Published var shortcutModifiers: UInt32 { didSet { defaults.set(Int(shortcutModifiers), forKey: Key.shortcutModifiers) } }

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
        defaultDirectPaste = defaults.object(forKey: Key.defaultDirectPaste) as? Bool ?? true
        excludedBundleIdentifiers = Set(defaults.stringArray(forKey: Key.excludedApps) ?? [])
        let storedKeyCode = defaults.object(forKey: Key.shortcutKeyCode) as? Int
        let storedModifiers = defaults.object(forKey: Key.shortcutModifiers) as? Int
        if defaults.integer(forKey: Key.shortcutDefaultVersion) < 2,
           (storedKeyCode == nil || storedKeyCode == 9),
           (storedModifiers == nil || storedModifiers == 768) {
            shortcutKeyCode = 11
            shortcutModifiers = 768
            defaults.set(11, forKey: Key.shortcutKeyCode)
            defaults.set(768, forKey: Key.shortcutModifiers)
        } else {
            shortcutKeyCode = UInt32(storedKeyCode ?? 11)
            shortcutModifiers = UInt32(storedModifiers ?? 768)
        }
        defaults.set(2, forKey: Key.shortcutDefaultVersion)
    }

    var capturePolicy: CapturePolicy {
        var policy = CapturePolicy.default
        policy.excludedBundleIdentifiers.formUnion(excludedBundleIdentifiers)
        return policy
    }

    func resetShortcut() {
        shortcutKeyCode = 11
        shortcutModifiers = 768
    }
}
