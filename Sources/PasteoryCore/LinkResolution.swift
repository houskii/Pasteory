import Foundation

public enum LinkRequestState: String, Codable, CaseIterable, Sendable {
    case pending
    case resolved
    case genericTitle
    case missingTitle
    case needsAuthentication
    case verificationRequired
    case forbidden
    case notFound
    case blockedByPolicy
    case networkError
    case timeout
    case parserError

    public var displayName: String {
        switch self {
        case .pending: L10n.tr("等待解析")
        case .resolved: L10n.tr("已解析")
        case .genericTitle: L10n.tr("只有通用标题")
        case .missingTitle: L10n.tr("没有找到标题")
        case .needsAuthentication: L10n.tr("需要登录")
        case .verificationRequired: L10n.tr("需要网页验证")
        case .forbidden: L10n.tr("没有访问权限")
        case .notFound: L10n.tr("页面不存在")
        case .blockedByPolicy: L10n.tr("已被安全策略拦截")
        case .networkError: L10n.tr("网络错误")
        case .timeout: L10n.tr("请求超时")
        case .parserError: L10n.tr("页面无法解析")
        }
    }

    public var needsAttention: Bool { self != .resolved && self != .pending }
}

public enum LinkTitleQuality: String, Codable, CaseIterable, Sendable {
    case verified
    case distinctive
    case identifierOnly
    case ambiguous
    case generic
    case loginOrError

    public var displayName: String {
        switch self {
        case .verified: L10n.tr("已验证")
        case .distinctive: L10n.tr("可区分资源")
        case .identifierOnly: L10n.tr("只有资源标识")
        case .ambiguous: L10n.tr("待确认")
        case .generic: L10n.tr("通用标题")
        case .loginOrError: L10n.tr("登录或错误页面")
        }
    }

    public var canReplaceFallback: Bool {
        self == .verified || self == .distinctive || self == .identifierOnly
    }
}

public enum LinkTitleCandidateSource: String, Codable, CaseIterable, Sendable {
    case siteAPI
    case siteAdapter
    case jsonLD
    case openGraph
    case twitterCard
    case mainHeading
    case documentTitle

    var priority: Int {
        switch self {
        case .siteAPI: 0
        case .siteAdapter: 1
        case .jsonLD: 2
        case .openGraph: 3
        case .twitterCard: 4
        case .mainHeading: 5
        case .documentTitle: 6
        }
    }
}

public struct LinkTitleCandidate: Codable, Hashable, Sendable {
    public var value: String
    public var source: LinkTitleCandidateSource

    public init(value: String, source: LinkTitleCandidateSource) {
        self.value = value
        self.source = source
    }
}

public enum LinkTitleEvidence: String, Codable, Hashable, Sendable {
    case adapterVerified
    case apiVerified
    case multipleSourcesAgree
    case containsResourceIdentifier
    case equalsSiteBrand
    case repeatedAcrossRoute
    case repeatedAcrossSite
    case redirectedToLogin
    case matchesErrorTitle
    case deepURLWithBrandOnlyTitle
    case meaningfulPageTitle
}

public struct LinkTitleAssessment: Codable, Hashable, Sendable {
    public var selectedTitle: String?
    public var candidateTitle: String?
    public var fingerprint: String?
    public var quality: LinkTitleQuality
    public var evidence: [LinkTitleEvidence]

    public init(
        selectedTitle: String?,
        candidateTitle: String?,
        fingerprint: String?,
        quality: LinkTitleQuality,
        evidence: [LinkTitleEvidence]
    ) {
        self.selectedTitle = selectedTitle
        self.candidateTitle = candidateTitle
        self.fingerprint = fingerprint
        self.quality = quality
        self.evidence = evidence
    }
}

public struct LinkTitleRepetitionStats: Codable, Hashable, Sendable {
    public var routeDistinctURLCount: Int
    public var routeFingerprintURLCount: Int
    public var hostDistinctURLCount: Int
    public var hostFingerprintURLCount: Int
    public var hostRouteCount: Int

    public init(
        routeDistinctURLCount: Int = 0,
        routeFingerprintURLCount: Int = 0,
        hostDistinctURLCount: Int = 0,
        hostFingerprintURLCount: Int = 0,
        hostRouteCount: Int = 0
    ) {
        self.routeDistinctURLCount = routeDistinctURLCount
        self.routeFingerprintURLCount = routeFingerprintURLCount
        self.hostDistinctURLCount = hostDistinctURLCount
        self.hostFingerprintURLCount = hostFingerprintURLCount
        self.hostRouteCount = hostRouteCount
    }
}

public struct URLRouteSignature: Codable, Hashable, Sendable {
    public var host: String
    public var pathTemplate: String
    public var requiredQueryKeys: [String]

    public init(host: String, pathTemplate: String, requiredQueryKeys: [String] = []) {
        self.host = host.lowercased()
        self.pathTemplate = pathTemplate.isEmpty ? "/" : pathTemplate
        self.requiredQueryKeys = requiredQueryKeys.sorted()
    }

    public var key: String {
        "\(host)\(pathTemplate)"
    }

    public var displayValue: String { key }
}

public enum URLFallbackRuleOrigin: String, Codable, CaseIterable, Sendable {
    case builtIn
    case user

    public var displayName: String { self == .builtIn ? L10n.tr("内置规则") : L10n.tr("用户规则") }
}

public struct URLFallbackRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var origin: URLFallbackRuleOrigin
    public var enabled: Bool
    public var hostPattern: String
    public var pathTemplate: String
    public var requiredQueryKeys: [String]
    public var titleTemplate: String
    public var priority: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        origin: URLFallbackRuleOrigin = .user,
        enabled: Bool = true,
        hostPattern: String,
        pathTemplate: String,
        requiredQueryKeys: [String] = [],
        titleTemplate: String,
        priority: Int = 100,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.enabled = enabled
        self.hostPattern = hostPattern.lowercased()
        self.pathTemplate = pathTemplate.isEmpty ? "/" : pathTemplate
        self.requiredQueryKeys = Array(Set(requiredQueryKeys)).sorted()
        self.titleTemplate = titleTemplate
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let builtIns: [URLFallbackRule] = [
        URLFallbackRule(
            id: UUID(uuidString: "A8A1E9AC-2C16-47F2-AC45-C970F38BA101")!,
            name: "BITS Merge Request",
            origin: .builtIn,
            hostPattern: "bits.bytedance.net",
            pathTemplate: "/devops/{projectID}/code/detail/{mergeRequestID}",
            titleTemplate: "BITS MR · {{path.mergeRequestID}}",
            priority: 10
        ),
        URLFallbackRule(
            id: UUID(uuidString: "A8A1E9AC-2C16-47F2-AC45-C970F38BA107")!,
            name: "Codebase Merge Request",
            origin: .builtIn,
            hostPattern: "code.byted.org",
            pathTemplate: "/{group}/{project}/merge_requests/{mergeRequestID}",
            titleTemplate: "{{path.project}} MR · !{{path.mergeRequestID}}",
            priority: 10
        ),
        URLFallbackRule(
            id: UUID(uuidString: "A8A1E9AC-2C16-47F2-AC45-C970F38BA102")!,
            name: "BITS 报告流水线",
            origin: .builtIn,
            hostPattern: "bits.bytedance.net",
            pathTemplate: "/space/legacy/build/logs",
            requiredQueryKeys: ["jobId"],
            titleTemplate: "报告流水线 · {{query.jobId}}",
            priority: 10
        ),
        URLFallbackRule(
            id: UUID(uuidString: "A8A1E9AC-2C16-47F2-AC45-C970F38BA103")!,
            name: "ByteCloud TOS Bucket",
            origin: .builtIn,
            hostPattern: "cloud.bytedance.net",
            pathTemplate: "/tos/bucket/{bucketID}/overview",
            titleTemplate: "TOS Bucket · {{path.bucketID}}",
            priority: 10
        ),
        URLFallbackRule(
            id: UUID(uuidString: "A8A1E9AC-2C16-47F2-AC45-C970F38BA104")!,
            name: "飞书 Wiki",
            origin: .builtIn,
            hostPattern: "*.larkoffice.com",
            pathTemplate: "/wiki/{wikiToken}",
            titleTemplate: "飞书 Wiki · {{path.wikiToken}}",
            priority: 20
        ),
        URLFallbackRule(
            id: UUID(uuidString: "A8A1E9AC-2C16-47F2-AC45-C970F38BA105")!,
            name: "知乎回答",
            origin: .builtIn,
            hostPattern: "www.zhihu.com",
            pathTemplate: "/question/{questionID}/answer/{answerID}",
            titleTemplate: "知乎回答 · {{path.answerID}}",
            priority: 20
        ),
        URLFallbackRule(
            id: UUID(uuidString: "A8A1E9AC-2C16-47F2-AC45-C970F38BA106")!,
            name: "微信公众号文章",
            origin: .builtIn,
            hostPattern: "mp.weixin.qq.com",
            pathTemplate: "/s/{articleToken}",
            titleTemplate: "微信公众号文章",
            priority: 20
        )
    ]
}

public enum LinkFallbackState: String, Codable, CaseIterable, Sendable {
    case matchedBuiltInRule
    case matchedUserRule
    case genericURLFallback

    public var displayName: String {
        switch self {
        case .matchedBuiltInRule: L10n.tr("内置兜底")
        case .matchedUserRule: L10n.tr("用户兜底")
        case .genericURLFallback: L10n.tr("通用 URL 兜底")
        }
    }
}

public struct URLFallbackResult: Codable, Hashable, Sendable {
    public var title: String
    public var state: LinkFallbackState
    public var matchedRuleID: UUID?
    public var routeSignature: URLRouteSignature
    public var variables: [String: String]
}

public enum LinkResolutionSource: String, Codable, CaseIterable, Sendable {
    case anonymousHTTP
    case browserExtension
    case webKit
    case siteAPI
    case fallbackRule

    public var displayName: String {
        switch self {
        case .anonymousHTTP: L10n.tr("普通请求")
        case .browserExtension: "Chrome"
        case .webKit: L10n.tr("登录 WebKit")
        case .siteAPI: L10n.tr("站点 API")
        case .fallbackRule: L10n.tr("兜底规则")
        }
    }
}

public struct LinkResource: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var normalizedURL: String
    public var canonicalResourceKey: String?
    public var host: String
    public var routeSignature: URLRouteSignature
    public var fallbackTitle: String
    public var fallbackState: LinkFallbackState
    public var matchedFallbackRuleID: UUID?
    public var resolvedTitle: String?
    public var candidateTitle: String?
    public var titleQuality: LinkTitleQuality
    public var requestState: LinkRequestState
    public var resolutionSource: LinkResolutionSource?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastAttemptAt: Date?
    public var lastResolvedAt: Date?
    public var attemptCount: Int
    public var failedAttemptCount: Int

    public init(
        id: UUID = UUID(),
        normalizedURL: String,
        canonicalResourceKey: String? = nil,
        host: String,
        routeSignature: URLRouteSignature,
        fallbackTitle: String,
        fallbackState: LinkFallbackState,
        matchedFallbackRuleID: UUID? = nil,
        resolvedTitle: String? = nil,
        candidateTitle: String? = nil,
        titleQuality: LinkTitleQuality = .ambiguous,
        requestState: LinkRequestState = .pending,
        resolutionSource: LinkResolutionSource? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastAttemptAt: Date? = nil,
        lastResolvedAt: Date? = nil,
        attemptCount: Int = 0,
        failedAttemptCount: Int = 0
    ) {
        self.id = id
        self.normalizedURL = normalizedURL
        self.canonicalResourceKey = canonicalResourceKey
            ?? URLFallbackEngine.normalizedWebURL(normalizedURL).map(URLFallbackEngine.canonicalResourceKey(for:))
        self.host = host
        self.routeSignature = routeSignature
        self.fallbackTitle = fallbackTitle
        self.fallbackState = fallbackState
        self.matchedFallbackRuleID = matchedFallbackRuleID
        self.resolvedTitle = resolvedTitle
        self.candidateTitle = candidateTitle
        self.titleQuality = titleQuality
        self.requestState = requestState
        self.resolutionSource = resolutionSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAttemptAt = lastAttemptAt
        self.lastResolvedAt = lastResolvedAt
        self.attemptCount = attemptCount
        self.failedAttemptCount = failedAttemptCount
    }

    public var displayTitle: String { resolvedTitle ?? fallbackTitle }

    public var effectiveCanonicalResourceKey: String {
        canonicalResourceKey
            ?? URLFallbackEngine.normalizedWebURL(normalizedURL).map(URLFallbackEngine.canonicalResourceKey(for:))
            ?? normalizedURL
    }
}

public struct ResolvedLinkSummary: Hashable, Identifiable, Sendable {
    public var resource: LinkResource
    public var clipCount: Int
    public var copyCount: Int

    public init(resource: LinkResource, clipCount: Int, copyCount: Int) {
        self.resource = resource
        self.clipCount = clipCount
        self.copyCount = copyCount
    }

    public var id: UUID { resource.id }
}

public enum LinkCacheRefreshPolicy {
    public static let resolvedCacheLifetime: TimeInterval = 24 * 60 * 60
    public static let scanLimit = 100
    public static let resourceLimit = 10

    public static func maintenanceCandidates(from orderedClips: [Clip]) -> [Clip] {
        var seen = Set<String>()
        return Array(orderedClips.prefix(scanLimit).compactMap { clip -> Clip? in
            guard clip.primaryKind == .link,
                  let url = URLFallbackEngine.normalizedWebURL(clip.previewText),
                  seen.insert(URLFallbackEngine.canonicalResourceKey(for: url)).inserted else { return nil }
            return clip
        }.prefix(resourceLimit))
    }
}

public struct LinkResolutionAttempt: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var linkResourceID: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var resolver: LinkResolutionSource
    public var requestState: LinkRequestState
    public var httpStatus: Int?
    public var finalURL: String?
    public var candidateTitle: String?
    public var candidateFingerprint: String?
    public var quality: LinkTitleQuality
    public var evidence: [LinkTitleEvidence]
    public var durationMilliseconds: Int
    public var errorCode: String?

    public init(
        id: UUID = UUID(),
        linkResourceID: UUID,
        startedAt: Date,
        finishedAt: Date = Date(),
        resolver: LinkResolutionSource,
        requestState: LinkRequestState,
        httpStatus: Int? = nil,
        finalURL: String? = nil,
        candidateTitle: String? = nil,
        candidateFingerprint: String? = nil,
        quality: LinkTitleQuality,
        evidence: [LinkTitleEvidence] = [],
        durationMilliseconds: Int,
        errorCode: String? = nil
    ) {
        self.id = id
        self.linkResourceID = linkResourceID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.resolver = resolver
        self.requestState = requestState
        self.httpStatus = httpStatus
        self.finalURL = finalURL
        self.candidateTitle = candidateTitle
        self.candidateFingerprint = candidateFingerprint
        self.quality = quality
        self.evidence = evidence
        self.durationMilliseconds = durationMilliseconds
        self.errorCode = errorCode
    }
}

public struct LinkFailureGroup: Codable, Hashable, Identifiable, Sendable {
    public var routeSignature: URLRouteSignature
    public var uniqueURLCount: Int
    public var clipCount: Int
    public var copyCount: Int
    public var attemptCount: Int
    public var failedAttemptCount: Int
    public var latestRequestState: LinkRequestState
    public var latestTitleQuality: LinkTitleQuality
    public var currentFallbackTitle: String
    public var currentFallbackState: LinkFallbackState
    public var sampleURL: String
    public var lastSeenAt: Date
    public var lastAttemptAt: Date?

    public init(
        routeSignature: URLRouteSignature,
        uniqueURLCount: Int,
        clipCount: Int,
        copyCount: Int,
        attemptCount: Int,
        failedAttemptCount: Int,
        latestRequestState: LinkRequestState,
        latestTitleQuality: LinkTitleQuality,
        currentFallbackTitle: String,
        currentFallbackState: LinkFallbackState,
        sampleURL: String,
        lastSeenAt: Date,
        lastAttemptAt: Date?
    ) {
        self.routeSignature = routeSignature
        self.uniqueURLCount = uniqueURLCount
        self.clipCount = clipCount
        self.copyCount = copyCount
        self.attemptCount = attemptCount
        self.failedAttemptCount = failedAttemptCount
        self.latestRequestState = latestRequestState
        self.latestTitleQuality = latestTitleQuality
        self.currentFallbackTitle = currentFallbackTitle
        self.currentFallbackState = currentFallbackState
        self.sampleURL = sampleURL
        self.lastSeenAt = lastSeenAt
        self.lastAttemptAt = lastAttemptAt
    }

    public var id: String { routeSignature.key }
}

public enum URLFallbackEngine {
    private static let trackingQueryPrefixes = ["utm_", "from", "source", "spm", "share_"]
    private static let sensitiveQueryNames = ["token", "access_token", "code", "ticket", "signature", "sign", "auth", "session", "key", "credential"]

    public static func normalizedWebURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    public static func canonicalResourceKey(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        var path = rawPath.isEmpty ? "/" : rawPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return "\(host):\(path)"
    }

    public static func fallback(for url: URL, rules userRules: [URLFallbackRule]) -> URLFallbackResult {
        let rules = (userRules.filter { $0.origin == .user } + URLFallbackRule.builtIns)
            .filter(\.enabled)
            .sorted {
                if $0.origin != $1.origin { return $0.origin == .user }
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.updatedAt > $1.updatedAt
            }
        for rule in rules {
            if let match = match(rule: rule, url: url) {
                let title = render(rule.titleTemplate, variables: match.variables)
                return URLFallbackResult(
                    title: title.isEmpty ? genericTitle(for: url) : title,
                    state: rule.origin == .user ? .matchedUserRule : .matchedBuiltInRule,
                    matchedRuleID: rule.id,
                    routeSignature: URLRouteSignature(
                        host: url.host ?? rule.hostPattern,
                        pathTemplate: rule.pathTemplate,
                        requiredQueryKeys: inferredRouteSignature(for: url).requiredQueryKeys
                    ),
                    variables: match.variables
                )
            }
        }
        return URLFallbackResult(
            title: genericTitle(for: url),
            state: .genericURLFallback,
            matchedRuleID: nil,
            routeSignature: inferredRouteSignature(for: url),
            variables: [:]
        )
    }

    public static func inferredRouteSignature(for url: URL) -> URLRouteSignature {
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true)
        let templated = segments.enumerated().map { index, segment -> String in
            let value = String(segment)
            if isVariablePathSegment(value) { return "{segment\(index + 1)}" }
            return value
        }
        let path = "/" + templated.joined(separator: "/")
        let queryItems: [String] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.compactMap { item -> String? in
            let lower = item.name.lowercased()
            guard !trackingQueryPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
            return item.name
        } ?? []
        let queryKeys = Set(queryItems)
        return URLRouteSignature(host: url.host ?? "", pathTemplate: path.isEmpty ? "/" : path, requiredQueryKeys: Array(queryKeys))
    }

    public static func genericTitle(for url: URL) -> String {
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        let last = url.path.split(separator: "/").last.map(String.init)
        guard let last, !last.isEmpty, last != "/" else { return host }
        let visible = last.count > 48 ? String(last.prefix(45)) + "…" : last
        return "\(host) · \(visible)"
    }

    public static func suggestedRule(for group: LinkFailureGroup, name: String, titleTemplate: String) -> URLFallbackRule {
        let referencedQueryKeys = queryVariables(in: titleTemplate)
        return URLFallbackRule(
            name: name,
            hostPattern: group.routeSignature.host,
            pathTemplate: group.routeSignature.pathTemplate,
            requiredQueryKeys: group.routeSignature.requiredQueryKeys.filter(referencedQueryKeys.contains),
            titleTemplate: titleTemplate
        )
    }

    public static func queryVariables(in titleTemplate: String) -> Set<String> {
        let pattern = #"\{\{query\.([^}]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(titleTemplate.startIndex..<titleTemplate.endIndex, in: titleTemplate)
        return Set(regex.matches(in: titleTemplate, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: titleTemplate) else { return nil }
            return String(titleTemplate[range])
        })
    }

    public static func isSensitiveQueryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return sensitiveQueryNames.contains { lower == $0 || lower.contains($0) }
    }

    public static func redactedDisplayURL(_ rawValue: String) -> String {
        guard let url = URL(string: rawValue), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return String(rawValue.prefix(512))
        }
        components.queryItems = components.queryItems?.map { item in
            isSensitiveQueryName(item.name) ? URLQueryItem(name: item.name, value: "••••") : item
        }
        let encoded = components.string ?? rawValue
        let visible = encoded.replacingOccurrences(of: "%E2%80%A2%E2%80%A2%E2%80%A2%E2%80%A2", with: "••••")
        return String(visible.prefix(512))
    }

    private struct RuleMatch {
        var variables: [String: String]
    }

    private static func match(rule: URLFallbackRule, url: URL) -> RuleMatch? {
        guard let host = url.host?.lowercased(), hostMatches(host, pattern: rule.hostPattern) else { return nil }
        let actual = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let template = rule.pathTemplate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard actual.count == template.count else { return nil }
        var variables = [String: String]()
        for (actualPart, templatePart) in zip(actual, template) {
            if templatePart.hasPrefix("{"), templatePart.hasSuffix("}"), templatePart.count > 2 {
                let name = String(templatePart.dropFirst().dropLast())
                variables["path.\(name)"] = actualPart.removingPercentEncoding ?? actualPart
            } else if actualPart != templatePart {
                return nil
            }
        }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        for key in rule.requiredQueryKeys {
            guard let value = query[key], !value.isEmpty else { return nil }
            variables["query.\(key)"] = isSensitiveQueryName(key) ? "••••" : value
        }
        variables["host"] = host
        return RuleMatch(variables: variables)
    }

    private static func render(_ template: String, variables: [String: String]) -> String {
        variables.reduce(template) { result, pair in
            result.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hostMatches(_ host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }

    private static func isVariablePathSegment(_ value: String) -> Bool {
        if !value.isEmpty, value.allSatisfy(\.isNumber) { return true }
        if UUID(uuidString: value) != nil { return true }
        return value.count >= 20 && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}

public enum HTMLTitleExtractor {
    public static func candidates(from data: Data) -> [LinkTitleCandidate] {
        guard let html = decode(data) else { return [] }
        var values = [LinkTitleCandidate]()
        for meta in matches(#"(?is)<meta\b[^>]*>"#, in: html) {
            let attributes = parseAttributes(meta)
            let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
            guard let content = attributes["content"], !content.isEmpty else { continue }
            switch key {
            case "og:title": values.append(LinkTitleCandidate(value: clean(content), source: .openGraph))
            case "twitter:title": values.append(LinkTitleCandidate(value: clean(content), source: .twitterCard))
            default: break
            }
        }
        let jsonLDScripts = matches(#"(?is)<script\b[^>]*type\s*=\s*[\"']application/ld\+json[\"'][^>]*>(.*?)</script>"#, in: html, capture: 1)
        for script in jsonLDScripts {
            for headline in matches(#"(?is)\"(?:headline|name)\"\s*:\s*\"((?:\\.|[^\"])*)\""#, in: script, capture: 1).prefix(3) {
                let decoded = headline.replacingOccurrences(of: #"\""#, with: "\"")
                    .replacingOccurrences(of: #"\\"#, with: #"\"#)
                values.append(LinkTitleCandidate(value: clean(decoded), source: .jsonLD))
            }
        }
        if let heading = matches(#"(?is)<h1\b[^>]*>(.*?)</h1>"#, in: html, capture: 1).first {
            values.append(LinkTitleCandidate(value: clean(stripTags(heading)), source: .mainHeading))
        }
        if let title = matches(#"(?is)<title\b[^>]*>(.*?)</title>"#, in: html, capture: 1).first {
            values.append(LinkTitleCandidate(value: clean(stripTags(title)), source: .documentTitle))
        }
        var seen = Set<String>()
        return values.filter { candidate in
            let fingerprint = LinkTitleQualityEvaluator.fingerprint(candidate.value)
            guard !fingerprint.isEmpty, !seen.contains("\(candidate.source.rawValue)|\(fingerprint)") else { return false }
            seen.insert("\(candidate.source.rawValue)|\(fingerprint)")
            return true
        }
    }

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .utf16)
    }

    private static func parseAttributes(_ tag: String) -> [String: String] {
        var attributes = [String: String]()
        let pattern = #"(?is)([A-Za-z_:][A-Za-z0-9_:\.-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributes }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        for match in regex.matches(in: tag, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: tag) else { continue }
            let valueRange = (2...4).compactMap { Range(match.range(at: $0), in: tag) }.first
            guard let valueRange else { continue }
            attributes[String(tag[keyRange]).lowercased()] = clean(String(tag[valueRange]))
        }
        return attributes
    }

    private static func matches(_ pattern: String, in value: String, capture: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > capture, let range = Range(match.range(at: capture), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func stripTags(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private static func clean(_ value: String) -> String {
        var result = value
        let replacements = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for pair in replacements { result = result.replacingOccurrences(of: pair.key, with: pair.value) }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024))
    }
}

public enum LinkTitleQualityEvaluator {
    private static let errorWords = [
        "登录", "统一身份认证", "安全验证", "验证码", "access denied", "forbidden", "403", "404", "页面不存在", "请求异常", "sign in", "log in"
    ]
    private static let loginHosts = ["accounts.feishu.cn", "login.bytedance.com", "sso.bytedance.com"]
    private static let genericTitles: [String: Set<String>] = [
        "bits.bytedance.net": ["bits"],
        "cloud.bytedance.net": ["bytecloud", "bytecloud - one-stop development platform for bytedancer"]
    ]
    private static let larkGenericTitles: Set<String> = ["docs", "lark", "feishu", "飞书", "飞书云文档"]

    public static func assess(
        candidates: [LinkTitleCandidate],
        requestedURL: URL,
        finalURL: URL?,
        repetition: LinkTitleRepetitionStats = LinkTitleRepetitionStats()
    ) -> LinkTitleAssessment {
        let cleaned = candidates
            .map { LinkTitleCandidate(value: clean($0.value), source: $0.source) }
            .filter { !$0.value.isEmpty }
            .sorted { $0.source.priority < $1.source.priority }
        let finalHost = finalURL?.host?.lowercased()
        let redirectedToLogin = finalHost.map(loginHosts.contains) == true
        if redirectedToLogin {
            return LinkTitleAssessment(
                selectedTitle: nil,
                candidateTitle: cleaned.first?.value,
                fingerprint: cleaned.first.map { fingerprint($0.value) },
                quality: .loginOrError,
                evidence: [.redirectedToLogin]
            )
        }
        guard !cleaned.isEmpty else {
            return LinkTitleAssessment(selectedTitle: nil, candidateTitle: nil, fingerprint: nil, quality: .generic, evidence: [])
        }
        let host = requestedURL.host?.lowercased() ?? ""
        let primary = cleaned.first(where: { !isKnownGeneric(fingerprint($0.value), host: host) }) ?? cleaned[0]
        let titleFingerprint = fingerprint(primary.value)
        let matchesError = errorWords.contains(where: { titleFingerprint.contains($0) })
        if matchesError {
            return LinkTitleAssessment(
                selectedTitle: nil,
                candidateTitle: primary.value,
                fingerprint: titleFingerprint,
                quality: .loginOrError,
                evidence: [.matchesErrorTitle]
            )
        }
        let knownGeneric = isKnownGeneric(titleFingerprint, host: host)
        let isDeepURL = requestedURL.path.split(separator: "/").count > 1 || URLComponents(url: requestedURL, resolvingAgainstBaseURL: false)?.query != nil
        let brandOnly = knownGeneric || equalsHostBrand(titleFingerprint, host: host)
        if knownGeneric || (isDeepURL && brandOnly) {
            return LinkTitleAssessment(
                selectedTitle: nil,
                candidateTitle: primary.value,
                fingerprint: titleFingerprint,
                quality: .generic,
                evidence: knownGeneric ? [.equalsSiteBrand] : [.deepURLWithBrandOnlyTitle]
            )
        }
        let routeCount = repetition.routeDistinctURLCount + 1
        let routeFingerprintCount = repetition.routeFingerprintURLCount + 1
        if routeCount >= 5, Double(routeFingerprintCount) / Double(routeCount) >= 0.8 {
            return LinkTitleAssessment(
                selectedTitle: nil,
                candidateTitle: primary.value,
                fingerprint: titleFingerprint,
                quality: .generic,
                evidence: [.repeatedAcrossRoute]
            )
        }
        let hostCount = repetition.hostDistinctURLCount + 1
        let hostFingerprintCount = repetition.hostFingerprintURLCount + 1
        if hostCount >= 10, repetition.hostRouteCount >= 2, Double(hostFingerprintCount) / Double(hostCount) >= 0.8 {
            return LinkTitleAssessment(
                selectedTitle: nil,
                candidateTitle: primary.value,
                fingerprint: titleFingerprint,
                quality: .generic,
                evidence: [.repeatedAcrossSite]
            )
        }
        if primary.source == .siteAPI || primary.source == .siteAdapter {
            return LinkTitleAssessment(
                selectedTitle: primary.value,
                candidateTitle: primary.value,
                fingerprint: titleFingerprint,
                quality: .verified,
                evidence: [primary.source == .siteAPI ? .apiVerified : .adapterVerified]
            )
        }
        let agreeingSources = Set(cleaned.filter { fingerprint($0.value) == titleFingerprint }.map(\.source))
        if agreeingSources.count >= 2 {
            return LinkTitleAssessment(
                selectedTitle: primary.value,
                candidateTitle: primary.value,
                fingerprint: titleFingerprint,
                quality: .distinctive,
                evidence: [.multipleSourcesAgree]
            )
        }
        if resourceIdentifiers(in: requestedURL).contains(where: { primary.value.localizedCaseInsensitiveContains($0) }) {
            return LinkTitleAssessment(
                selectedTitle: primary.value,
                candidateTitle: primary.value,
                fingerprint: titleFingerprint,
                quality: .identifierOnly,
                evidence: [.containsResourceIdentifier]
            )
        }
        return LinkTitleAssessment(
            selectedTitle: primary.value,
            candidateTitle: primary.value,
            fingerprint: titleFingerprint,
            quality: primary.value.count >= 4 ? .distinctive : .ambiguous,
            evidence: primary.value.count >= 4 ? [.meaningfulPageTitle] : []
        )
    }

    public static func fingerprint(_ title: String) -> String {
        clean(title)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: #"\p{Cf}+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func equalsHostBrand(_ title: String, host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return false }
        let brand = String(parts[parts.count - 2]).lowercased()
        return title == brand || title == host || title == host.replacingOccurrences(of: "www.", with: "")
    }

    private static func isKnownGeneric(_ title: String, host: String) -> Bool {
        if genericTitles[host]?.contains(title) == true { return true }
        if host == "larkoffice.com" || host.hasSuffix(".larkoffice.com") {
            return larkGenericTitles.contains(title)
        }
        return false
    }

    private static func resourceIdentifiers(in url: URL) -> [String] {
        var values = url.path.split(separator: "/").map(String.init).filter { part in
            part.count >= 4 && (part.allSatisfy(\.isNumber) || UUID(uuidString: part) != nil)
        }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        values += queryItems.compactMap { item in
            guard !URLFallbackEngine.isSensitiveQueryName(item.name), let value = item.value, value.count >= 4 else { return nil }
            return value
        }
        return values
    }
}
