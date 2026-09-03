import Foundation
import PasteoryCore
import SwiftUI
import WebKit

@MainActor
enum LinkWebKitConfiguration {
    // WKWebsiteDataStore.default() is scoped by the containing app's Bundle ID.
    // Production and QA therefore keep independent cookies, IndexedDB and
    // WebCrypto keychain accounts while retaining the state required by SSO.
    private static let sessionDataStore = WKWebsiteDataStore.default()

    static func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sessionDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    static func applyCompatibilityUserAgent(to webView: WKWebView) {
        webView.customUserAgent = compatibilityUserAgent
    }

    nonisolated static var compatibilityUserAgent: String {
        let chromeVersion = (Bundle(path: "/Applications/Google Chrome.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .filter { $0.isNumber || $0 == "." } ?? "140.0.0.0"
        let pasteoryVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.1.10"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeVersion) "
            + "Safari/537.36 Pasteory/\(pasteoryVersion)"
    }
}

enum LinkAuthenticationSite: String, CaseIterable, Identifiable, Sendable {
    case bits
    case lark
    case codebase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bits: "BITS"
        case .lark: "飞书"
        case .codebase: "Codebase"
        }
    }

    var startURL: URL {
        switch self {
        case .bits: URL(string: "https://bits.bytedance.net/")!
        case .lark: URL(string: "https://bytedance.larkoffice.com/")!
        case .codebase: URL(string: "https://code.byted.org/")!
        }
    }

    var domainDescription: String {
        switch self {
        case .bits: "bits.bytedance.net"
        case .lark: "*.larkoffice.com"
        case .codebase: "code.byted.org"
        }
    }

    func matches(host: String) -> Bool {
        let value = host.lowercased()
        switch self {
        case .bits: return value == "bits.bytedance.net"
        case .lark: return value == "larkoffice.com" || value.hasSuffix(".larkoffice.com")
        case .codebase: return value == "code.byted.org"
        }
    }
}

enum LinkAuthenticationTarget: Identifiable, Hashable, Sendable {
    case builtIn(LinkAuthenticationSite)
    case custom(AuthenticatedLinkRule)

    var id: String {
        switch self {
        case .builtIn(let site): site.rawValue
        case .custom(let rule): "custom.\(rule.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .builtIn(let site): site.title
        case .custom(let rule): rule.name
        }
    }

    var startURL: URL {
        switch self {
        case .builtIn(let site): site.startURL
        case .custom(let rule): URLFallbackEngine.normalizedWebURL(rule.startURL) ?? URL(string: "https://example.com/")!
        }
    }

    var domainDescription: String {
        switch self {
        case .builtIn(let site): site.domainDescription
        case .custom(let rule): rule.pattern
        }
    }

    var customRule: AuthenticatedLinkRule? {
        guard case .custom(let rule) = self else { return nil }
        return rule
    }

    func matches(_ url: URL) -> Bool {
        switch self {
        case .builtIn(let site): site.matches(host: url.host ?? "")
        case .custom(let rule): rule.matches(url)
        }
    }

    static func all(customRules: [AuthenticatedLinkRule]) -> [LinkAuthenticationTarget] {
        LinkAuthenticationSite.allCases.map(LinkAuthenticationTarget.builtIn)
            + customRules.filter(\.enabled).map(LinkAuthenticationTarget.custom)
    }

    static func matching(url: URL, customRules: [AuthenticatedLinkRule]) -> LinkAuthenticationTarget? {
        let custom = customRules.first { $0.matches(url) }.map(LinkAuthenticationTarget.custom)
        return custom ?? LinkAuthenticationSite.allCases.first { $0.matches(host: url.host ?? "") }.map(LinkAuthenticationTarget.builtIn)
    }
}

struct LinkAuthenticationRequest: Identifiable {
    let id = UUID()
    let target: LinkAuthenticationTarget
    let group: LinkFailureGroup?
}

@MainActor
enum LinkAuthenticationSession {
    static func markUpdated(_ target: LinkAuthenticationTarget) {
        UserDefaults.standard.set(Date(), forKey: key(for: target))
    }

    static func lastUpdatedAt(_ target: LinkAuthenticationTarget) -> Date? {
        UserDefaults.standard.object(forKey: key(for: target)) as? Date
    }

    static func clear(_ target: LinkAuthenticationTarget) {
        UserDefaults.standard.removeObject(forKey: key(for: target))
    }

    private static func key(for target: LinkAuthenticationTarget) -> String {
        "linkAuthenticationSessionUpdatedAt.\(target.id)"
    }
}

struct AuthenticatedPageSnapshot: Sendable {
    var finalURL: URL
    var candidates: [LinkTitleCandidate]
    var durationMilliseconds: Int
}

enum AuthenticatedLinkResolverError: LocalizedError {
    case invalidPage
    case navigation(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidPage: "登录会话没有返回可解析的页面"
        case .navigation(let message): "页面加载失败：\(message)"
        case .timeout: "登录会话加载超时"
        }
    }
}

@MainActor
final class AuthenticatedLinkResolver {
    private var inFlight = [String: Task<AuthenticatedPageSnapshot, Error>]()

    func resolve(url: URL) async throws -> AuthenticatedPageSnapshot {
        let key = URLFallbackEngine.canonicalResourceKey(for: url)
        if let task = inFlight[key] { return try await task.value }
        let task = Task { @MainActor in
            let load = AuthenticatedPageLoad(url: url)
            return try await load.run()
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

@MainActor
private final class AuthenticatedPageLoad: NSObject, WKNavigationDelegate {
    private let url: URL
    private let webView: WKWebView
    private let hostPanel: NSPanel
    private var continuation: CheckedContinuation<AuthenticatedPageSnapshot, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false
    private var extracting = false
    private let startedAt = Date()

    init(url: URL) {
        self.url = url
        let configuration = LinkWebKitConfiguration.makeWebViewConfiguration()
        self.webView = WKWebView(frame: .init(x: 0, y: 0, width: 1_280, height: 800), configuration: configuration)
        self.hostPanel = NSPanel(
            contentRect: .init(x: -20_000, y: -20_000, width: 1_280, height: 800),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        LinkWebKitConfiguration.applyCompatibilityUserAgent(to: webView)
        webView.navigationDelegate = self
        hostPanel.contentView = webView
        hostPanel.ignoresMouseEvents = true
        hostPanel.hasShadow = false
        hostPanel.alphaValue = 0.01
        if let visibleFrame = NSScreen.main?.visibleFrame {
            hostPanel.setFrameOrigin(visibleFrame.origin)
        }
        hostPanel.orderFrontRegardless()
    }

    func run() async throws -> AuthenticatedPageSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.finish(.failure(AuthenticatedLinkResolverError.timeout))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !completed, !extracting else { return }
        extracting = true
        Task { [weak self] in
            await self?.extractStablePage()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(AuthenticatedLinkResolverError.navigation(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(AuthenticatedLinkResolverError.navigation(error.localizedDescription)))
    }

    private func extractStablePage() async {
        var bestSnapshot: AuthenticatedPageSnapshot?
        let observationStartedAt = Date()
        let tiers: [(interval: Duration, requiredMatches: Int)] = [
            (.milliseconds(600), 3),
            (.milliseconds(2_500), 2)
        ]

        for tier in tiers {
            var repeatedTitle: String?
            var repeatedCount = 0
            for _ in 0..<tier.requiredMatches {
                guard !completed else { return }
                try? await Task.sleep(for: tier.interval)
                guard !completed else { return }
                do {
                    let snapshot = try await pageSnapshot()
                    bestSnapshot = snapshot
                    let title = snapshot.candidates.first?.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let title, !title.isEmpty else {
                        repeatedTitle = nil
                        repeatedCount = 0
                        continue
                    }
                    let fingerprint = LinkTitleQualityEvaluator.fingerprint(title)
                    repeatedCount = fingerprint == repeatedTitle ? repeatedCount + 1 : 1
                    repeatedTitle = fingerprint
                    if repeatedCount >= tier.requiredMatches {
                        finish(.success(snapshot))
                        return
                    }
                } catch {
                    if bestSnapshot == nil {
                        finish(.failure(AuthenticatedLinkResolverError.navigation(error.localizedDescription)))
                        return
                    }
                }
            }
        }

        let remaining = max(0, 10 - Date().timeIntervalSince(observationStartedAt))
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        guard !completed else { return }
        if let snapshot = try? await pageSnapshot(), !snapshot.candidates.isEmpty {
            finish(.success(snapshot))
        } else if let bestSnapshot {
            finish(.success(bestSnapshot))
        } else {
            finish(.failure(AuthenticatedLinkResolverError.invalidPage))
        }
    }

    private func pageSnapshot() async throws -> AuthenticatedPageSnapshot {
        let script = """
        (() => ({
          title: document.title || ''
        }))()
        """
        guard let value = try await webView.evaluateJavaScript(script) as? [String: Any],
              let finalURL = webView.url else {
            throw AuthenticatedLinkResolverError.invalidPage
        }
        let title = (value["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = title.isEmpty ? [] : [LinkTitleCandidate(value: title, source: .documentTitle)]
        return AuthenticatedPageSnapshot(
            finalURL: finalURL,
            candidates: candidates,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        )
    }

    private func finish(_ result: Result<AuthenticatedPageSnapshot, Error>) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        webView.navigationDelegate = nil
        webView.stopLoading()
        hostPanel.orderOut(nil)
        hostPanel.contentView = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

struct SiteLoginSheet: View {
    let request: LinkAuthenticationRequest
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentURL = ""
    @State private var pageTitle = ""
    @State private var address: String
    @State private var requestedURL: URL
    @State private var backRevision = UUID()
    @State private var reloadRevision = UUID()

    init(request: LinkAuthenticationRequest, onComplete: @escaping () -> Void) {
        self.request = request
        self.onComplete = onComplete
        _address = State(initialValue: request.target.startURL.absoluteString)
        _requestedURL = State(initialValue: request.target.startURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("登录 \(request.target.title)").font(.title2.bold())
                    Text("这是 Pasteory 独立的 WebKit 会话，不读取 Chrome Cookie；登录数据按当前 Bundle ID 隔离，网页使用 WebCrypto 时 macOS WebKit 可能访问登录钥匙串。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button { backRevision = UUID() } label: { Image(systemName: "chevron.left") }
                    .help("后退")
                Button { reloadRevision = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .help("重新加载")
                Image(systemName: "lock.shield")
                TextField("登录地址", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { navigateToAddress() }
                Button("打开") { navigateToAddress() }
            }
            SiteLoginWebView(
                requestedURL: requestedURL,
                backRevision: backRevision,
                reloadRevision: reloadRevision,
                currentURL: $currentURL,
                pageTitle: $pageTitle
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            HStack {
                Text(request.group == nil
                     ? "完成登录后，会话会保存在当前 Pasteory 包专属的 WebKit 数据域中，正式包与 QA 包互不共享。"
                     : "完成登录后，Pasteory 会用该会话重新解析当前失败路由。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button(request.group == nil ? "完成登录" : "完成登录并重新解析") {
                    LinkAuthenticationSession.markUpdated(request.target)
                    onComplete()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 900, height: 680)
        .onChange(of: currentURL) { _, value in
            if !value.isEmpty { address = value }
        }
    }

    private func navigateToAddress() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URLFallbackEngine.normalizedWebURL(candidate) else { return }
        requestedURL = url
    }
}

private struct SiteLoginWebView: NSViewRepresentable {
    let requestedURL: URL
    let backRevision: UUID
    let reloadRevision: UUID
    @Binding var currentURL: String
    @Binding var pageTitle: String

    func makeCoordinator() -> Coordinator {
        Coordinator(
            requestedURL: requestedURL,
            backRevision: backRevision,
            reloadRevision: reloadRevision,
            currentURL: $currentURL,
            pageTitle: $pageTitle
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = LinkWebKitConfiguration.makeWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        LinkWebKitConfiguration.applyCompatibilityUserAgent(to: webView)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: requestedURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.requestedURL != requestedURL {
            context.coordinator.requestedURL = requestedURL
            webView.load(URLRequest(url: requestedURL))
        }
        if context.coordinator.backRevision != backRevision {
            context.coordinator.backRevision = backRevision
            if webView.canGoBack { webView.goBack() }
        }
        if context.coordinator.reloadRevision != reloadRevision {
            context.coordinator.reloadRevision = reloadRevision
            webView.reload()
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var currentURL: Binding<String>
        private var pageTitle: Binding<String>
        var requestedURL: URL
        var backRevision: UUID
        var reloadRevision: UUID

        init(
            requestedURL: URL,
            backRevision: UUID,
            reloadRevision: UUID,
            currentURL: Binding<String>,
            pageTitle: Binding<String>
        ) {
            self.requestedURL = requestedURL
            self.backRevision = backRevision
            self.reloadRevision = reloadRevision
            self.currentURL = currentURL
            self.pageTitle = pageTitle
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            currentURL.wrappedValue = webView.url?.absoluteString ?? ""
            pageTitle.wrappedValue = webView.title ?? ""
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let requestURL = navigationAction.request.url {
                webView.load(URLRequest(url: requestURL))
            }
            return nil
        }
    }
}
