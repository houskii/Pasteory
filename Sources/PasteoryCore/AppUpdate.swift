import Foundation

public struct AppUpdate: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let publishedAt: Date?
    public let notes: String
    public let downloadURL: URL?
    public let releaseURL: URL?

    public init(version: String, build: String, publishedAt: Date?, notes: String, downloadURL: URL?, releaseURL: URL?) {
        self.version = version
        self.build = build
        self.publishedAt = publishedAt
        self.notes = notes
        self.downloadURL = downloadURL
        self.releaseURL = releaseURL
    }

    public func isNewer(thanBuild build: String) -> Bool {
        self.build.compare(build, options: .numeric) == .orderedDescending
    }
}

public enum AppUpdatePolicy {
    public static let checkInterval: TimeInterval = 86_400

    public static func checkIsDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }

    /// Validate the original asset URL; GitHub's signed CDN redirects are handled by Sparkle.
    public static func isGitHubDownload(_ url: URL?) -> Bool {
        guard let url, isRepositoryURL(url) else { return false }
        return url.path.hasPrefix("/houskii/Pasteory/releases/download/")
            && url.path.split(separator: "/").count >= 6
    }

    public static func isGitHubReleasePage(_ url: URL?) -> Bool {
        guard let url, isRepositoryURL(url) else { return false }
        return url.path == "/houskii/Pasteory/releases"
            || url.path.hasPrefix("/houskii/Pasteory/releases/tag/")
    }

    private static func isRepositoryURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
            && url.port == nil && url.user == nil && url.password == nil
    }
}
