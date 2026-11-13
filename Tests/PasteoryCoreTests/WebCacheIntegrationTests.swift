import AppKit
import PasteoryCore
import Testing
import WebKit
@testable import Pasteory

// Run with a loopback fixture serving a cacheable HTML page with
// <title>QA cache proof</title>, qa_login=kept and localStorage proof=kept.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PASTEORY_CACHE_QA_URL"] != nil))
@MainActor func diskCacheClearancePreservesWebKitSessionAndStoredTitle() async throws {
    let address = try #require(ProcessInfo.processInfo.environment["PASTEORY_CACHE_QA_URL"])
    let url = try #require(URL(string: address))
    #expect(url.host == "127.0.0.1")
    guard url.host == "127.0.0.1" else { return }
    _ = NSApplication.shared
    let identifier = UUID()
    let store = WKWebsiteDataStore(forIdentifier: identifier)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryCacheQA-\(identifier)")
    defer {
        try? FileManager.default.removeItem(at: root)
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: identifier) }
    }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = store
    let view = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: config)
    view.load(URLRequest(url: url))
    for _ in 0..<100 {
        if view.title == "QA cache proof", !view.isLoading { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let title = try #require(view.title)
    #expect(title == "QA cache proof")
    var cachePopulated = false
    for _ in 0..<30 {
        if !(await store.dataRecords(ofTypes: [WKWebsiteDataTypeDiskCache])).isEmpty {
            cachePopulated = true
            break
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    try #require(cachePopulated)
    let repository = try SQLiteClipRepository(databaseURL: AppDirectories(root: root).databaseFile)
    let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(
        items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.url", data: Data(address.utf8))])],
        source: ClipSource()
    )))
    try await repository.save(clip)
    let resource = try await repository.associateLink(clipID: clip.id, resource: LinkResource(
        normalizedURL: address, host: "127.0.0.1", routeSignature: .init(host: "127.0.0.1", pathTemplate: "/"),
        fallbackTitle: "Loopback", fallbackState: .genericURLFallback
    ))
    let resolution = LinkResolutionService(repository: repository)
    await resolution.recordAuthenticatedResult(resource: resource, snapshot: AuthenticatedPageSnapshot(
        finalURL: url, candidates: [
            .init(value: title, source: .documentTitle), .init(value: title, source: .mainHeading)
        ], durationMilliseconds: 10
    ))
    #expect(try await repository.clip(id: clip.id)?.automaticTitle == title)
    await LinkWebKitConfiguration.clearNetworkCache(in: store)
    #expect(await store.dataRecords(ofTypes: [WKWebsiteDataTypeDiskCache]).isEmpty)
    #expect(await store.httpCookieStore.allCookies().contains { $0.name == "qa_login" && $0.value == "kept" })
    #expect(try await view.evaluateJavaScript("localStorage.getItem('proof')") as? String == "kept")
    #expect(try await repository.linkResource(normalizedURL: address)?.resolvedTitle == title)
    #expect(try await repository.clip(id: clip.id)?.automaticTitle == title)
}
