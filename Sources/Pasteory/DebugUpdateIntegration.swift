#if DEBUG
import Foundation
import PasteoryCore

/// A nonce-matched QA fixture can exercise Sparkle's real installation path.
/// The loopback exception is absent from production builds.
struct DebugUpdateIntegration {
    let feed: URL
    let dataRoot: URL
    let identifier: String

    init?(bundleIdentifier: String?, info: [String: Any]) {
        guard PasteoryRuntimeIdentity.identity(for: bundleIdentifier).variant == .qa,
              let identifier = info["PasteoryUpdateIntegrationID"] as? String, UUID(uuidString: identifier) != nil,
              let rawRoot = info["PasteoryUpdateIntegrationDataRoot"] as? String, rawRoot.hasPrefix("/"),
              let rawFeed = info["SUFeedURL"] as? String, let feed = URL(string: rawFeed),
              feed.scheme == "http", feed.host == "127.0.0.1", let port = feed.port, (1024...65535).contains(port),
              feed.user == nil, feed.password == nil, feed.query == nil, feed.fragment == nil,
              feed.path == "/appcast.xml" else { return nil }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let production = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pasteory").path
        guard root.path != production, !root.path.hasPrefix(production + "/"),
              let marker = try? Data(contentsOf: root.appendingPathComponent("update-fixture.json")),
              let value = try? JSONSerialization.jsonObject(with: marker) as? [String: String],
              value["identifier"] == identifier, value["bundle_identifier"] == bundleIdentifier else { return nil }
        self.feed = feed; self.dataRoot = root; self.identifier = identifier
    }

    func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == feed.scheme, url.host == feed.host, url.port == feed.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/updates/"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return true
    }

    func recordLaunch(bundle: Bundle, actualRoot: URL) {
        let report: [String: Any] = ["identifier": identifier,
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "bundle_path": bundle.bundleURL.path, "data_root": actualRoot.path,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "launched_at": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dataRoot.appendingPathComponent("update-launch.json"), options: .atomic)
        }
    }
}
#endif
