import Foundation
import PasteoryAI

public protocol ClipRepository: Sendable {
    func aiState() async throws -> AIOrganizationState
    func aiContext(ids: [UUID], includeNotes: Bool, includeSource: Bool) async throws -> [AIClipDocument]
    func updateAIState(_ mutation: @Sendable (inout AIOrganizationState) throws -> Void) async throws
    func applyAIChangeSet(_ changeSet: AIChangeSet) async throws
    func undoAIChangeSet(_ id: UUID) async throws
    func recordHumanActivity(id: UUID, event: ContentActivity.Event, at: Date) async throws
    func updateAIGroupDefinition(id: UUID, name: String, definition: String, retained: Bool, expectedVersion: Int) async throws
    func compressAIGroup(id: UUID?, policy: LifecyclePolicy, now: Date) async throws -> Int
    func exportAIContent(to: URL) async throws
    func importAIContent(from: URL) async throws
    func saveCaptured(_ clip: Clip, context: CapturedSourceContext?) async throws -> Clip
    func save(_ clip: Clip) async throws
    func updateExisting(_ clip: Clip) async throws
    func saveArchived(_ clip: Clip, replacing original: Clip) async throws -> Bool
    func saveBatch(_ clips: [Clip]) async throws
    func consolidateDuplicateClips() async throws -> Int
    func clip(id: UUID) async throws -> Clip?
    func clips(ids: [UUID]) async throws -> [Clip]
    func recordPaste(id: UUID, at date: Date) async throws -> Clip?
    func list(filter: ClipFilter, query: String, limit: Int) async throws -> [Clip]
    func removePermanently(id: UUID) async throws
    func purgeTrash(olderThan date: Date) async throws -> Int
    func previewHistoryCleanup(olderThan cutoff: Date, largerThan minimumBytes: Int64) async throws -> HistoryCleanupPreview
    func cleanHistory(_ preview: HistoryCleanupPreview) async throws -> HistoryCleanupResult
    func archiveCandidates(olderThan date: Date, hotLimit: Int) async throws -> [Clip]
    func activeClipCount() async throws -> Int
    func recentClipCount(since date: Date) async throws -> Int
    func storedClipKindCounts(since startDate: Date?, before endDate: Date?) async throws -> [ClipKindCount]
    func collections() async throws -> [ClipCollection]
    func saveCollection(_ collection: ClipCollection) async throws
    func removeCollection(id: UUID) async throws
    func allClips() async throws -> [Clip]
    func captureEvents(for clipID: UUID, limit: Int) async throws -> [ClipCaptureEvent]
    func allCaptureEvents() async throws -> [ClipCaptureEvent]
    func saveCaptureEvents(_ events: [ClipCaptureEvent]) async throws
    func aggregations() async throws -> [ClipAggregation]
    func aggregation(id: UUID) async throws -> ClipAggregation?
    @discardableResult func saveAggregation(_ aggregation: ClipAggregation) async throws -> ClipAggregation
    func removeAggregation(id: UUID) async throws
    func contextAggregates(kind: SourceContextEntityKind?, limit: Int) async throws -> [SourceContextAggregate]
    func associateLink(clipID: UUID, resource: LinkResource) async throws -> LinkResource
    func linkResource(normalizedURL: String) async throws -> LinkResource?
    func linkResource(canonicalResourceKey: String) async throws -> LinkResource?
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
    func aiState() async throws -> AIOrganizationState { AIOrganizationState() }
    func aiContext(ids: [UUID], includeNotes: Bool, includeSource: Bool) async throws -> [AIClipDocument] {
        try await clips(ids: ids).filter(\.mayParticipateInAI).map { $0.aiDocument(includeNotes: includeNotes, includeSource: includeSource) }
    }
    func updateAIState(_ mutation: @Sendable (inout AIOrganizationState) throws -> Void) async throws { throw AIError.unavailable }
    func applyAIChangeSet(_ changeSet: AIChangeSet) async throws { throw AIError.unavailable }
    func undoAIChangeSet(_ id: UUID) async throws { throw AIError.unavailable }
    func recordHumanActivity(id: UUID, event: ContentActivity.Event, at: Date) async throws { }
    func updateAIGroupDefinition(id: UUID, name: String, definition: String, retained: Bool, expectedVersion: Int) async throws { throw AIError.unavailable }
    func compressAIGroup(id: UUID?, policy: LifecyclePolicy, now: Date) async throws -> Int { throw AIError.unavailable }
    func exportAIContent(to: URL) async throws { }
    func importAIContent(from: URL) async throws { }
    func saveCaptured(_ clip: Clip) async throws -> Clip {
        try await saveCaptured(clip, context: nil)
    }
}

public enum RepositoryError: LocalizedError {
    case openDatabase(String)
    case sqlite(String)
    case encoding
    case duplicateCollectionName
    case aggregationNeedsMultipleItems

    public var errorDescription: String? {
        switch self {
        case .openDatabase(let message): L10n.tr("无法打开数据库：\(message)")
        case .sqlite(let message): L10n.tr("数据库错误：\(message)")
        case .encoding: L10n.tr("无法解析剪贴板记录")
        case .duplicateCollectionName: L10n.tr("分组名称已经存在")
        case .aggregationNeedsMultipleItems: L10n.tr("至少需要两项不同内容才能创建聚合")
        }
    }
}
