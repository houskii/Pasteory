import Combine
import Foundation
import PasteoryCore

enum LinkSessionRefreshInterval: Int, CaseIterable, Codable, Identifiable {
    case threeDays = 3
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    var id: Int { rawValue }
    var duration: TimeInterval { Double(rawValue) * 86_400 }
    var title: String { L10n.tr("\(rawValue) 天") }
}

enum LinkSessionRefreshOutcome: String, Codable {
    case pageLoaded
    case needsAuthentication
    case failed
    case blocked

    var title: String {
        switch self {
        case .pageLoaded: L10n.tr("页面已刷新")
        case .needsAuthentication: L10n.tr("需要重新登录")
        case .failed: L10n.tr("刷新失败，将稍后重试")
        case .blocked: L10n.tr("刷新地址已被安全策略拦截")
        }
    }

    static func assess(_ snapshot: AuthenticatedPageSnapshot, requestedURL: URL) -> Self {
        let assessment = LinkTitleQualityEvaluator.assess(
            candidates: snapshot.candidates, requestedURL: requestedURL, finalURL: snapshot.finalURL
        )
        let loginPaths = Set(["login", "signin", "sign-in", "log-in", "login.html", "authorize"])
        let path = snapshot.finalURL.path.lowercased().split(separator: "/").map(String.init)
        let title = snapshot.candidates.first?.value.lowercased() ?? ""
        let loginTitle = ["登录", "统一身份认证", "安全验证", "验证码", "sign in", "log in", "login", "authentication required"]
            .contains { title.contains($0) }
        if snapshot.httpStatusCode == 401 || snapshot.hasLoginForm || loginTitle ||
            assessment.evidence.contains(.redirectedToLogin) || !loginPaths.isDisjoint(with: path) {
            return .needsAuthentication
        }
        if let status = snapshot.httpStatusCode, status >= 400 { return .failed }
        guard assessment.quality != .loginOrError, !snapshot.candidates.isEmpty else { return .failed }
        // Loading a page lets its own JS/SSO renew the session. It does not prove
        // that the website issued a new token, or reveal that token's lifetime.
        return .pageLoaded
    }
}

struct LinkSessionRefreshRecord: Codable {
    var interval: LinkSessionRefreshInterval = .fourteenDays
    var automatic = true
    var lastAttemptAt: Date?
    var lastRefreshedAt: Date?
    var outcome: LinkSessionRefreshOutcome?
}

@MainActor
final class LinkSessionRefreshService: ObservableObject {
    static let retryDelay: TimeInterval = 3_600
    private static let preferenceKey = "linkSessionRefresh.v1"
    private let defaults: UserDefaults
    private let now: () -> Date
    private let load: (URL) async throws -> AuthenticatedPageSnapshot
    @Published private var records: [String: LinkSessionRefreshRecord]
    @Published private(set) var refreshingTargetIDs = Set<String>()
    private var inFlight = [String: Task<Void, Never>]()
    private var generations = [String: UUID]()
    private var checking = false

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        load: @escaping (URL) async throws -> AuthenticatedPageSnapshot
    ) {
        self.defaults = defaults
        self.now = now
        self.load = load
        records = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode([String: LinkSessionRefreshRecord].self, from: $0) } ?? [:]
    }

    func record(for target: LinkAuthenticationTarget) -> LinkSessionRefreshRecord {
        records[target.id] ?? LinkSessionRefreshRecord()
    }

    func lastSignedInAt(_ target: LinkAuthenticationTarget) -> Date? {
        LinkAuthenticationSession.lastUpdatedAt(target, defaults: defaults)
    }

    func setInterval(_ interval: LinkSessionRefreshInterval, for target: LinkAuthenticationTarget) {
        var value = record(for: target)
        value.interval = interval
        save(value, for: target)
    }

    func setAutomatic(_ enabled: Bool, for target: LinkAuthenticationTarget) {
        var value = record(for: target)
        value.automatic = enabled
        save(value, for: target)
    }

    func markSignedIn(_ target: LinkAuthenticationTarget) {
        generations[target.id] = UUID()
        LinkAuthenticationSession.markUpdated(target, at: now(), defaults: defaults)
        var value = record(for: target)
        value.outcome = nil
        value.lastAttemptAt = nil
        value.lastRefreshedAt = nil
        save(value, for: target)
    }

    func remove(_ target: LinkAuthenticationTarget) {
        generations[target.id] = UUID()
        LinkAuthenticationSession.clear(target, defaults: defaults)
        records.removeValue(forKey: target.id)
        persist()
    }

    func nextRefreshAt(_ target: LinkAuthenticationTarget) -> Date? {
        let value = record(for: target)
        guard value.automatic, let signedIn = lastSignedInAt(target),
              value.outcome != .needsAuthentication, value.outcome != .blocked else { return nil }
        let anchor = max(signedIn, value.lastRefreshedAt ?? signedIn)
        let due = anchor.addingTimeInterval(value.interval.duration)
        if let attempted = value.lastAttemptAt, attempted >= due {
            return max(due, attempted.addingTimeInterval(Self.retryDelay))
        }
        return due
    }

    func check(targets: [LinkAuthenticationTarget], networkAllowed: () -> Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        for target in targets {
            guard networkAllowed(), !Task.isCancelled else { return }
            guard let due = nextRefreshAt(target), due <= now() else { continue }
            await refresh(target)
        }
    }

    func refresh(_ target: LinkAuthenticationTarget) async {
        if let existing = inFlight[target.id] { await existing.value; return }
        guard lastSignedInAt(target) != nil else { return }
        let generation = UUID()
        generations[target.id] = generation
        var value = record(for: target)
        value.lastAttemptAt = now()
        save(value, for: target)
        refreshingTargetIDs.insert(target.id)
        let task = Task { @MainActor [self] in
            let outcome: LinkSessionRefreshOutcome
            if !LinkResolutionService.isAllowed(target.startURL) {
                outcome = .blocked
            } else {
                do {
                    let snapshot = try await load(target.startURL)
                    outcome = .assess(snapshot, requestedURL: target.startURL)
                } catch {
                    outcome = .failed
                }
            }
            // Login or removal can happen while WebKit is awaiting a response.
            guard generations[target.id] == generation else { return }
            var updated = record(for: target)
            updated.outcome = outcome
            if outcome == .pageLoaded { updated.lastRefreshedAt = now() }
            save(updated, for: target)
        }
        inFlight[target.id] = task
        await task.value
        inFlight[target.id] = nil
        refreshingTargetIDs.remove(target.id)
    }

    private func save(_ value: LinkSessionRefreshRecord, for target: LinkAuthenticationTarget) {
        records[target.id] = value
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.preferenceKey) }
    }
}
