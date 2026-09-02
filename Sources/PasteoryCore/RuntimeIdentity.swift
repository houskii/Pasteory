import Foundation

public enum PasteoryBuildVariant: String, Sendable {
    case production
    case qa
}

public struct PasteoryRuntimeIdentity: Equatable, Sendable {
    public static let production = PasteoryRuntimeIdentity(
        variant: .production,
        bundleIdentifier: "app.pasteory.Pasteory",
        displayName: "Pasteory",
        applicationSupportDirectoryName: "Pasteory",
        nativeMessagingHostName: "app.pasteory.web_context",
        chromeIntegrationEnabled: true
    )

    public static let qa = PasteoryRuntimeIdentity(
        variant: .qa,
        bundleIdentifier: "app.pasteory.Pasteory.qa",
        displayName: "Pasteory QA",
        applicationSupportDirectoryName: "Pasteory QA",
        nativeMessagingHostName: "app.pasteory.qa.web_context",
        chromeIntegrationEnabled: false
    )

    public let variant: PasteoryBuildVariant
    public let bundleIdentifier: String
    public let displayName: String
    public let applicationSupportDirectoryName: String
    public let nativeMessagingHostName: String
    public let chromeIntegrationEnabled: Bool

    public static var current: PasteoryRuntimeIdentity {
        identity(for: Bundle.main.bundleIdentifier)
    }

    public static func identity(for bundleIdentifier: String?) -> PasteoryRuntimeIdentity {
        bundleIdentifier == qa.bundleIdentifier ? qa : production
    }

    public static func validateCurrentBundleConfiguration(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) throws {
        guard let declaredVariant = infoDictionary?["PasteoryBuildVariant"] as? String else { return }
        guard let variant = PasteoryBuildVariant(rawValue: declaredVariant) else {
            throw PasteoryRuntimeIdentityError.invalidBuildVariant(declaredVariant)
        }
        let expected = variant == .qa ? qa : production
        guard bundleIdentifier == expected.bundleIdentifier else {
            throw PasteoryRuntimeIdentityError.bundleIdentifierMismatch(
                expected: expected.bundleIdentifier,
                actual: bundleIdentifier ?? "<missing>"
            )
        }

        let stringChecks: [(String, String)] = [
            ("CFBundleDisplayName", expected.displayName),
            ("PasteoryApplicationSupportDirectory", expected.applicationSupportDirectoryName),
            ("PasteoryNativeMessagingHostName", expected.nativeMessagingHostName)
        ]
        for (key, expectedValue) in stringChecks {
            let actual = infoDictionary?[key] as? String
            guard actual == expectedValue else {
                throw PasteoryRuntimeIdentityError.infoValueMismatch(
                    key: key,
                    expected: expectedValue,
                    actual: actual ?? "<missing>"
                )
            }
        }

        let chromeEnabled = infoDictionary?["PasteoryChromeIntegrationEnabled"] as? Bool
        guard chromeEnabled == expected.chromeIntegrationEnabled else {
            throw PasteoryRuntimeIdentityError.infoValueMismatch(
                key: "PasteoryChromeIntegrationEnabled",
                expected: String(expected.chromeIntegrationEnabled),
                actual: chromeEnabled.map(String.init) ?? "<missing>"
            )
        }
    }
}

public enum PasteoryRuntimeIdentityError: LocalizedError, Sendable {
    case invalidBuildVariant(String)
    case bundleIdentifierMismatch(expected: String, actual: String)
    case infoValueMismatch(key: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBuildVariant(let value):
            "未知的 Pasteory 构建类型：\(value)"
        case .bundleIdentifierMismatch(let expected, let actual):
            "构建身份不一致：Bundle ID 应为 \(expected)，实际为 \(actual)"
        case .infoValueMismatch(let key, let expected, let actual):
            "构建身份不一致：\(key) 应为 \(expected)，实际为 \(actual)"
        }
    }
}
