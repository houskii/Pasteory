import Darwin
import Foundation

public struct HistoryCleanupEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let lastUsedAt: Date
    public let byteCount: Int64
    let updatedAt: Date
}

public struct HistoryCleanupPreview: Equatable, Sendable {
    public let cutoff: Date
    public let minimumBytes: Int64
    public let entries: [HistoryCleanupEntry]
    public let reclaimableBytes: Int64
    let files: [HistoryStoredFile: HistoryFileSize]
}

public struct HistoryCleanupResult: Equatable, Sendable {
    public let deletedCount: Int
    public let freedBytes: Int64
    public let failedFileCount: Int
}

public enum HistoryCleanupError: LocalizedError {
    case previewChanged

    public var errorDescription: String? {
        L10n.tr("符合条件的内容已变化，请重新预览后再清理。")
    }
}

struct HistoryFileSize: Equatable, Sendable {
    let logical: Int64
    let allocated: Int64
}

struct HistoryStoredFile: Hashable, Sendable {
    let directory: String
    let relativePath: String

    init?(storage: RepresentationStorage) {
        switch storage {
        case .inline: return nil
        case .attachment(let path, _, _): (directory, relativePath) = ("Attachments", path)
        case .archived(let path, _, _): (directory, relativePath) = ("Archives", path)
        }
    }

    func url(in root: URL) -> URL? {
        let components = relativePath.components(separatedBy: "/")
        guard components.count == (directory == "Attachments" ? 2 : 3),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        var url = root.resolvingSymlinksInPath()
        for component in [directory] + components {
            url.appendPathComponent(component)
            // A path from imported data must never redirect cleanup outside the managed folders.
            guard !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) else { return nil }
        }
        return url
    }

    func size(in root: URL) -> HistoryFileSize? {
        guard let url = url(in: root) else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        // Unlinking one name does not reclaim blocks if another hard link exists.
        return HistoryFileSize(logical: info.st_size, allocated: info.st_nlink == 1 ? info.st_blocks * 512 : 0)
    }

    func remove(in root: URL, expectedSize: HistoryFileSize) -> Bool {
        guard let url = url(in: root), size(in: root) == expectedSize else { return false }
        return unlink(url.path) == 0
    }
}

extension Clip {
    var historyStoredFiles: Set<HistoryStoredFile> {
        Set(items.flatMap(\.representations).compactMap { HistoryStoredFile(storage: $0.storage) })
    }
}
