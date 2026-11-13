import Foundation

public enum AggregationMembershipMode: String, Codable, Hashable, Sendable {
    case fixed
    case automatic
}

public enum AggregationOrigin: Codable, Hashable, Sendable {
    case manual
    case search(query: String)
    case condition(summary: String)

    public var displayName: String {
        switch self {
        case .manual: L10n.tr("手动创建")
        case .search(let query): L10n.tr("来自搜索：\(query)")
        case .condition(let summary): summary == "AI" ? L10n.tr("AI 整理生成") : L10n.tr("自动条件：\(summary)")
        }
    }
}

public struct ClipAggregation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isFavorite: Bool
    public var isPinned: Bool
    public var collectionIDs: Set<UUID>
    public var memberClipIDs: [UUID]
    public var membershipMode: AggregationMembershipMode
    public var origin: AggregationOrigin
    public var excludedClipIDs: Set<UUID>

    public init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isFavorite: Bool = false,
        isPinned: Bool = false,
        collectionIDs: Set<UUID> = [],
        memberClipIDs: [UUID],
        membershipMode: AggregationMembershipMode = .fixed,
        origin: AggregationOrigin = .manual,
        excludedClipIDs: Set<UUID> = []
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.collectionIDs = collectionIDs
        self.memberClipIDs = Self.unique(memberClipIDs)
        self.membershipMode = membershipMode
        self.origin = origin
        self.excludedClipIDs = excludedClipIDs
    }

    public var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? L10n.tr("未命名聚合") : value
    }

    public mutating func normalizeMembers() {
        memberClipIDs = Self.unique(memberClipIDs).filter { !excludedClipIDs.contains($0) }
    }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
