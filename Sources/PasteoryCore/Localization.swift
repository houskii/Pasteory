import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }
    public var nativeName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
    public var locale: Locale { Locale(identifier: rawValue) }
}

/// Interpolations are kept separate from the translation key. Clipboard content is never translated.
public struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    let key: String
    let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

public enum L10n {
    private final class Selection: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AppLanguage = .english
        func get() -> AppLanguage { lock.withLock { value } }
        func set(_ language: AppLanguage) { lock.withLock { value = language } }
    }
    private static let selection = Selection()
    // Tests can select a language without changing concurrent tests or the application preference.
    @TaskLocal public static var languageOverride: AppLanguage?
    public static var language: AppLanguage { languageOverride ?? selection.get() }
    public static func activate(_ language: AppLanguage) { selection.set(language) }

    static let english: [String: String] = {
        // Installed apps use the copied resource bundle; SwiftPM tests use Bundle.module.
        let embedded = Bundle.main.resourceURL?
            .appendingPathComponent("Pasteory_PasteoryCore.bundle")
        let bundle = embedded.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = bundle.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else {
            preconditionFailure("The English localization catalog is missing or invalid")
        }
        return catalog
    }()

    public static func text(_ key: String, language: AppLanguage? = nil) -> String {
        (language ?? self.language) == .english ? (english[key] ?? key) : key
    }

    public static func tr(_ value: LocalizedText) -> String {
        render(text(value.key), arguments: value.arguments)
    }

    static func render(_ template: String, arguments: [String]) -> String {
        // Replace only placeholders in the template, never text inside an inserted user value.
        guard !arguments.isEmpty else { return template }
        var result = ""
        var cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{",
               let end = template[cursor...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: cursor)..<end]),
               arguments.indices.contains(index) {
                result += arguments[index]
                cursor = template.index(after: end)
            } else {
                result.append(template[cursor])
                cursor = template.index(after: cursor)
            }
        }
        return result
    }
}
