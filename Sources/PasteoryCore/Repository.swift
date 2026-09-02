import Foundation

public protocol ClipRepository: Sendable {
    func saveCaptured(_ clip: Clip, context: CapturedSourceContext?) async throws -> Clip
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
    func captureEvents(for clipID: UUID, limit: Int) async throws -> [ClipCaptureEvent]
    func allCaptureEvents() async throws -> [ClipCaptureEvent]
    func saveCaptureEvents(_ events: [ClipCaptureEvent]) async throws
    func contextAggregates(kind: SourceContextEntityKind?, limit: Int) async throws -> [SourceContextAggregate]
    func associateLink(clipID: UUID, resource: LinkResource) async throws -> LinkResource
    func linkResource(normalizedURL: String) async throws -> LinkResource?
    func saveLinkResolution(_ resource: LinkResource, attempt: LinkResolutionAttempt) async throws
    func unresolvedLinkGroups(limit: Int) async throws -> [LinkFailureGroup]
    func unresolvedLinkResources(routeKey: String) async throws -> [LinkResource]
    func resolvedLinkResources(limit: Int) async throws -> [ResolvedLinkSummary]
    func userFallbackRules() async throws -> [URLFallbackRule]
    func saveFallbackRule(_ rule: URLFallbackRule) async throws
    func removeFallbackRule(id: UUID) async throws
    func reapplyFallbackRules() async throws -> Int
    func linkTitleRepetitionStats(host: String, routeKey: String, fingerprint: String) async throws -> LinkTitleRepetitionStats
    func rebuildSearchIndex() async throws
}

public extension ClipRepository {
    func saveCaptured(_ clip: Clip) async throws -> Clip {
        try await saveCaptured(clip, context: nil)
    }
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
