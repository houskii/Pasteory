import Foundation

public protocol ClipRepository: Sendable {
    func saveCaptured(_ clip: Clip) async throws -> Clip
    func save(_ clip: Clip) async throws
    func saveBatch(_ clips: [Clip]) async throws
    func clip(id: UUID) async throws -> Clip?
    func list(filter: ClipFilter, query: String, limit: Int) async throws -> [Clip]
    func removePermanently(id: UUID) async throws
    func purgeTrash(olderThan date: Date) async throws -> Int
    func archiveCandidates(olderThan date: Date, hotLimit: Int) async throws -> [Clip]
    func activeClipCount() async throws -> Int
    func recentClipCount(since date: Date) async throws -> Int
    func collections() async throws -> [ClipCollection]
    func saveCollection(_ collection: ClipCollection) async throws
    func removeCollection(id: UUID) async throws
    func allClips() async throws -> [Clip]
    func rebuildSearchIndex() async throws
}

public enum RepositoryError: LocalizedError {
    case openDatabase(String)
    case sqlite(String)
    case encoding
    case duplicateCollectionName

    public var errorDescription: String? {
        switch self {
        case .openDatabase(let message): "无法打开数据库：\(message)"
        case .sqlite(let message): "数据库错误：\(message)"
        case .encoding: "无法解析剪贴板记录"
        case .duplicateCollectionName: "分组名称已经存在"
        }
    }
}
