import Foundation

public struct AppDirectories: Sendable {
    public let root: URL
    public let database: URL
    public let attachments: URL
    public let archives: URL
    public let backups: URL
    public let logs: URL
    public let applicationCache: URL
    public let browserContextInbox: URL

    public init(
        root: URL? = nil,
        identity: PasteoryRuntimeIdentity = .current
    ) throws {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(identity.applicationSupportDirectoryName, isDirectory: true)
        self.root = base
        self.database = base.appendingPathComponent("Database", isDirectory: true)
        self.attachments = base.appendingPathComponent("Attachments", isDirectory: true)
        self.archives = base.appendingPathComponent("Archives", isDirectory: true)
        self.backups = base.appendingPathComponent("Backups", isDirectory: true)
        self.logs = base.appendingPathComponent("Logs", isDirectory: true)
        self.applicationCache = base.appendingPathComponent("ApplicationCache", isDirectory: true)
        self.browserContextInbox = base.appendingPathComponent("BrowserContextInbox", isDirectory: true)
        for directory in [base, database, attachments, archives, backups, logs, applicationCache, browserContextInbox] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public var databaseFile: URL { database.appendingPathComponent("pasteory.sqlite3") }
}
