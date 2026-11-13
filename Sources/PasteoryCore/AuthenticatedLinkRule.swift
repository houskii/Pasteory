import Foundation

public struct AuthenticatedLinkRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var startURL: String
    public var enabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        startURL: String,
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.pattern = AuthenticatedLinkPattern.normalized(pattern)
        self.startURL = startURL
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func matches(_ url: URL) -> Bool {
        enabled && AuthenticatedLinkPattern.matches(pattern, url: url)
    }
}

public enum AuthenticatedLinkPattern {
    public static func normalized(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["^https://", "^http://", "https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        for prefix in [#"^https?:\/\/"#, #"https?:\/\/"#] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        return value
    }

    public static func validationError(_ rawValue: String) -> String? {
        let value = normalized(rawValue)
        guard !value.isEmpty else { return L10n.tr("匹配规则不能为空") }
        do {
            _ = try NSRegularExpression(pattern: value, options: [.caseInsensitive])
            return nil
        } catch {
            return L10n.tr("正则表达式无效：\(error.localizedDescription)")
        }
    }

    public static func matches(_ pattern: String, url: URL) -> Bool {
        let value = normalized(pattern)
        guard validationError(value) == nil,
              let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { return false }
        let target = matchValue(for: url)
        let range = NSRange(target.startIndex..<target.endIndex, in: target)
        return regex.firstMatch(in: target, range: range) != nil
    }

    public static func matchValue(for url: URL) -> String {
        var value = (url.host ?? "").lowercased() + url.path
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
           !query.isEmpty {
            value += "?\(query)"
        }
        return value
    }

    public static func suggestedPattern(for signature: URLRouteSignature) -> String {
        let escapedHost = NSRegularExpression.escapedPattern(for: signature.host)
        let segments = signature.pathTemplate
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment -> String in
                let value = String(segment)
                if value.hasPrefix("{"), value.hasSuffix("}") { return "[^/]+" }
                return NSRegularExpression.escapedPattern(for: value)
            }
        let path = segments.isEmpty ? "/?" : "/" + segments.joined(separator: "/")
        return "^\(escapedHost)\(path)$"
    }

    public static func inferredStartURL(pattern rawPattern: String, sampleURLs: [String]) -> URL? {
        let pattern = normalized(rawPattern)
        for rawURL in sampleURLs {
            guard let url = URLFallbackEngine.normalizedWebURL(rawURL), matches(pattern, url: url) else { continue }
            var components = URLComponents()
            components.scheme = "https"
            components.host = url.host
            components.path = "/"
            if let origin = components.url { return origin }
        }

        let readable = pattern.replacingOccurrences(of: #"\."#, with: ".")
        let domainPattern = #"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+"#
        guard let regex = try? NSRegularExpression(pattern: domainPattern),
              let match = regex.firstMatch(
                in: readable,
                range: NSRange(readable.startIndex..<readable.endIndex, in: readable)
              ),
              let range = Range(match.range, in: readable) else { return nil }
        return URL(string: "https://\(readable[range])/")
    }
}
