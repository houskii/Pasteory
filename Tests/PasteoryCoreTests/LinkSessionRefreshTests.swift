import AppKit
import Foundation
import PasteoryCore
import Testing
import WebKit
@testable import Pasteory

@MainActor
private final class SessionRefreshFixture {
    let suite = "Pasteory.LinkSessionRefreshTests.\(UUID())"
    let defaults: UserDefaults
    let target = LinkAuthenticationTarget.builtIn(.bits)
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var loads = [URL]()
    var networkAllowed = true
    var failure = false
    var snapshot: AuthenticatedPageSnapshot
    var hold: CheckedContinuation<Void, Never>?
    var shouldHold = false

    init() {
        defaults = UserDefaults(suiteName: suite)!
        snapshot = AuthenticatedPageSnapshot(
            finalURL: target.startURL, candidates: [.init(value: "BITS", source: .documentTitle)],
            durationMilliseconds: 10, httpStatusCode: 200
        )
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite) }

    func makeService() -> LinkSessionRefreshService {
        LinkSessionRefreshService(defaults: defaults, now: { self.now }) { url in
            self.loads.append(url)
            if self.shouldHold { await withCheckedContinuation { self.hold = $0 } }
            if self.failure { throw URLError(.notConnectedToInternet) }
            return self.snapshot
        }
    }

    func check(_ service: LinkSessionRefreshService) async {
        await service.check(targets: [target], networkAllowed: { self.networkAllowed })
    }
}

@Test @MainActor func sessionRefreshMigratesExistingLoginAndPersistsIndependentIntervals() async {
    let f = SessionRefreshFixture(); defer { f.cleanup() }
    LinkAuthenticationSession.markUpdated(f.target, at: f.now, defaults: f.defaults)
    let service = f.makeService()
    #expect(service.record(for: f.target).interval == .fourteenDays)
    #expect(service.nextRefreshAt(f.target) == f.now.addingTimeInterval(14 * 86_400))
    for interval in LinkSessionRefreshInterval.allCases {
        service.setInterval(interval, for: f.target)
        #expect(service.nextRefreshAt(f.target) == f.now.addingTimeInterval(interval.duration))
        #expect(f.makeService().record(for: f.target).interval == interval)
    }
    let other = LinkAuthenticationTarget.custom(AuthenticatedLinkRule(
        name: "Example", pattern: #"example\.com/.*"#, startURL: "https://example.com/"
    ))
    #expect(service.record(for: other).interval == .fourteenDays)
    #expect(service.lastSignedInAt(other) == nil)
    service.setAutomatic(false, for: f.target)
    #expect(f.makeService().nextRefreshAt(f.target) == nil)
}

@Test @MainActor func sessionRefreshWaitsForDueDateAndReschedulesFromCompletedVisit() async {
    let f = SessionRefreshFixture(); defer { f.cleanup() }
    let service = f.makeService()
    await f.check(service)
    #expect(f.loads.isEmpty)
    service.markSignedIn(f.target)
    f.now += 14 * 86_400 - 1
    await f.check(service)
    #expect(f.loads.isEmpty)
    f.now += 1
    f.networkAllowed = false
    await f.check(service)
    #expect(f.loads.isEmpty)
    f.networkAllowed = true
    await f.check(service)
    #expect(f.loads == [f.target.startURL])
    #expect(service.record(for: f.target).outcome == .pageLoaded)
    #expect(service.record(for: f.target).lastRefreshedAt == f.now)
    #expect(service.nextRefreshAt(f.target) == f.now.addingTimeInterval(14 * 86_400))
    await f.check(service)
    #expect(f.loads.count == 1)
}

@Test @MainActor func sessionRefreshRetriesNetworkFailureWithoutLosingTheLogin() async {
    let f = SessionRefreshFixture(); defer { f.cleanup() }
    var service = f.makeService()
    service.markSignedIn(f.target)
    let signedIn = service.lastSignedInAt(f.target)
    f.now += 14 * 86_400
    f.failure = true
    await f.check(service)
    #expect(service.record(for: f.target).outcome == .failed)
    #expect(service.lastSignedInAt(f.target) == signedIn)
    #expect(service.record(for: f.target).lastRefreshedAt == nil)
    service = f.makeService() // A restart must not bypass the failure cooldown.
    await f.check(service)
    #expect(f.loads.count == 1)
    f.now += LinkSessionRefreshService.retryDelay
    f.failure = false
    await f.check(service)
    #expect(f.loads.count == 2)
    #expect(service.record(for: f.target).outcome == .pageLoaded)
}

@Test @MainActor func sessionRefreshPausesAtLoginPageUntilUserSignsInAgain() async {
    let f = SessionRefreshFixture(); defer { f.cleanup() }
    let service = f.makeService()
    service.markSignedIn(f.target)
    f.snapshot.hasLoginForm = true
    await service.refresh(f.target)
    #expect(service.record(for: f.target).outcome == .needsAuthentication)
    #expect(service.nextRefreshAt(f.target) == nil)
    f.now += 90 * 86_400
    await f.check(service)
    #expect(f.loads.count == 1)
    service.markSignedIn(f.target)
    #expect(service.record(for: f.target).outcome == nil)
    #expect(service.nextRefreshAt(f.target) == f.now.addingTimeInterval(14 * 86_400))
}

@Test @MainActor func sessionRefreshCoalescesManualAndScheduledWorkAndIgnoresRemovedTargets() async {
    let f = SessionRefreshFixture(); defer { f.cleanup() }
    let service = f.makeService()
    service.markSignedIn(f.target)
    f.now += 14 * 86_400
    f.shouldHold = true
    let scheduled = Task { await f.check(service) }
    while f.hold == nil { await Task.yield() }
    let manual = Task { await service.refresh(f.target) }
    await Task.yield()
    #expect(f.loads.count == 1)
    #expect(service.refreshingTargetIDs.contains(f.target.id))
    service.remove(f.target)
    f.hold?.resume(); f.hold = nil
    await scheduled.value
    await manual.value
    #expect(f.loads.count == 1)
    #expect(service.record(for: f.target).lastAttemptAt == nil)
    #expect(service.lastSignedInAt(f.target) == nil)
    #expect(service.refreshingTargetIDs.isEmpty)
}

@Test @MainActor func sessionRefreshDoesNotOverwriteANewerLoginWithAnOlderRequest() async {
    let f = SessionRefreshFixture(); defer { f.cleanup() }
    let service = f.makeService()
    service.markSignedIn(f.target)
    f.shouldHold = true
    f.snapshot.hasLoginForm = true
    let oldRequest = Task { await service.refresh(f.target) }
    while f.hold == nil { await Task.yield() }
    f.now += 60
    service.markSignedIn(f.target)
    f.hold?.resume(); f.hold = nil
    await oldRequest.value
    #expect(service.record(for: f.target).outcome == nil)
    #expect(service.lastSignedInAt(f.target) == f.now)
    #expect(service.nextRefreshAt(f.target) == f.now.addingTimeInterval(14 * 86_400))
}

@Test @MainActor func sessionRefreshBlocksUnsafeURLsAndSeparatesLoginFromServerErrors() async {
    let f = SessionRefreshFixture(); defer { f.cleanup() }
    let service = f.makeService()
    for address in ["http://localhost/", "http://10.0.0.1/", "https://example.com/logout"] {
        let target = LinkAuthenticationTarget.custom(AuthenticatedLinkRule(name: "Blocked", pattern: ".*", startURL: address))
        service.markSignedIn(target)
        await service.refresh(target)
        #expect(service.record(for: target).outcome == .blocked)
        #expect(service.nextRefreshAt(target) == nil)
    }
    #expect(f.loads.isEmpty)
    f.snapshot.httpStatusCode = 503
    #expect(LinkSessionRefreshOutcome.assess(f.snapshot, requestedURL: f.target.startURL) == .failed)
    f.snapshot.httpStatusCode = 401
    #expect(LinkSessionRefreshOutcome.assess(f.snapshot, requestedURL: f.target.startURL) == .needsAuthentication)
    f.snapshot.httpStatusCode = 200
    f.snapshot.finalURL = URL(string: "https://example.com/login")!
    #expect(LinkSessionRefreshOutcome.assess(f.snapshot, requestedURL: f.target.startURL) == .needsAuthentication)
}

// Opt-in loopback fixture: /refresh runs page JS that renews an HttpOnly cookie;
// /login serves a visible password field. Uses an isolated WebKit data store.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PASTEORY_SESSION_QA_URL"] != nil))
@MainActor func sessionRefreshRunsWebsiteRenewalJavaScriptInTheExistingWebKitSession() async throws {
    let address = try #require(ProcessInfo.processInfo.environment["PASTEORY_SESSION_QA_URL"])
    let base = try #require(URL(string: address))
    try #require(base.host == "127.0.0.1")
    _ = NSApplication.shared
    let f = SessionRefreshFixture(); defer { f.cleanup() }
    let identifier = UUID()
    let store = WKWebsiteDataStore(forIdentifier: identifier)
    let cookie = try #require(HTTPCookie(properties: [
        .domain: "127.0.0.1", .path: "/", .name: "qa_session", .value: "existing-session"
    ]))
    await store.httpCookieStore.setCookie(cookie)
    let cache = WebCacheMaintenance(settings: AppSettings(defaults: f.defaults), measure: { 0 }, clear: {})
    let resolver = AuthenticatedLinkResolver(cache: cache, websiteDataStore: store)
    var destination = base.appendingPathComponent("refresh")
    var lastSnapshot: AuthenticatedPageSnapshot?
    let service = LinkSessionRefreshService(defaults: f.defaults) { _ in
        let snapshot = try await resolver.resolve(url: destination, minimumObservation: 5)
        lastSnapshot = snapshot
        return snapshot
    }
    service.markSignedIn(f.target)
    await service.refresh(f.target)
    #expect(service.record(for: f.target).outcome == .pageLoaded)
    #expect(lastSnapshot?.httpStatusCode == 200)
    #expect(lastSnapshot?.candidates.first?.value == "QA renewed session")
    #expect(await store.httpCookieStore.allCookies().contains { $0.name == "qa_session" && $0.value == "renewed-session" && $0.isHTTPOnly })
    destination = base.appendingPathComponent("login")
    await service.refresh(f.target)
    #expect(lastSnapshot?.hasLoginForm == true)
    #expect(service.record(for: f.target).outcome == .needsAuthentication)
    #expect(service.nextRefreshAt(f.target) == nil)
    destination = base.appendingPathComponent("unauthorized")
    await service.refresh(f.target)
    #expect(lastSnapshot?.httpStatusCode == 401)
    #expect(service.record(for: f.target).outcome == .needsAuthentication)
    await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    // WebKit may retain its network process until this test's final references
    // are released; the isolated store's data has already been cleared above.
    try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
}
