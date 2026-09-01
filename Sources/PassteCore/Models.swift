import Foundation

public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, image, link, color, code, file, mixed

    public var displayName: String {
        switch self {
        case .text: "文字"
        case .image: "图像"
        case .link: "链接"
        case .color: "颜色"
        case .code: "代码"
        case .file: "文件"
        case .mixed: "混合内容"
        }
    }

    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .link: "link"
        case .color: "paintpalette"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .file: "doc"
        case .mixed: "square.stack.3d.up"
        }
    }
}

public enum SourceConfidence: String, Codable, CaseIterable, Sendable {
    case high, low, unknown

    public var displayName: String {
        switch self {
        case .high: "高"
        case .low: "低"
        case .unknown: "未知"
        }
    }
}

public struct ClipSource: Codable, Hashable, Sendable {
    public var appName: String
    public var bundleIdentifier: String?
    public var processIdentifier: Int32?
    public var confidence: SourceConfidence

    public init(
        appName: String = "未知来源",
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        confidence: SourceConfidence = .unknown
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.confidence = confidence
    }
}

public enum RepresentationStorage: Codable, Hashable, Sendable {
    case inline(Data)
    case attachment(relativePath: String, checksum: String, size: Int)
    case archived(relativePath: String, checksum: String, size: Int)

    private enum CodingKeys: String, CodingKey { case type, data, relativePath, checksum, size }
    private enum StorageType: String, Codable { case inline, attachment, archived }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(StorageType.self, forKey: .type) {
        case .inline:
            self = .inline(try container.decode(Data.self, forKey: .data))
        case .attachment:
            self = .attachment(
                relativePath: try container.decode(String.self, forKey: .relativePath),
                checksum: try container.decode(String.self, forKey: .checksum),
                size: try container.decode(Int.self, forKey: .size)
            )
        case .archived:
            self = .archived(
                relativePath: try container.decode(String.self, forKey: .relativePath),
                checksum: try container.decode(String.self, forKey: .checksum),
                size: try container.decode(Int.self, forKey: .size)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inline(let data):
            try container.encode(StorageType.inline, forKey: .type)
            try container.encode(data, forKey: .data)
        case .attachment(let path, let checksum, let size):
            try container.encode(StorageType.attachment, forKey: .type)
            try container.encode(path, forKey: .relativePath)
            try container.encode(checksum, forKey: .checksum)
            try container.encode(size, forKey: .size)
        case .archived(let path, let checksum, let size):
            try container.encode(StorageType.archived, forKey: .type)
            try container.encode(path, forKey: .relativePath)
            try container.encode(checksum, forKey: .checksum)
            try container.encode(size, forKey: .size)
        }
    }

    public var byteCount: Int {
        switch self {
        case .inline(let data): data.count
        case .attachment(_, _, let size), .archived(_, _, let size): size
        }
    }
}

public struct ClipRepresentation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var uti: String
    public var storage: RepresentationStorage

    public init(id: UUID = UUID(), uti: String, storage: RepresentationStorage) {
        self.id = id
        self.uti = uti
        self.storage = storage
    }
}

public struct ClipItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var order: Int
    public var representations: [ClipRepresentation]

    public init(id: UUID = UUID(), order: Int, representations: [ClipRepresentation]) {
        self.id = id
        self.order = order
        self.representations = representations
    }
}

public struct Clip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var lastCopiedAt: Date
    public var primaryKind: ClipKind
    public var secondaryKinds: Set<ClipKind>
    public var title: String
    public var note: String
    public var priority: Int
    public var isFavorite: Bool
    public var isPinned: Bool
    public var isArchived: Bool
    public var source: ClipSource
    public var previewText: String
    public var contentHash: String
    public var byteSize: Int
    public var copyCount: Int
    public var deletedAt: Date?
    public var archivePath: String?
    public var items: [ClipItem]
    public var collectionIDs: Set<UUID>

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        primaryKind: ClipKind,
        secondaryKinds: Set<ClipKind> = [],
        title: String = "",
        note: String = "",
        priority: Int = 0,
        isFavorite: Bool = false,
        isPinned: Bool = false,
        isArchived: Bool = false,
        source: ClipSource,
        previewText: String,
        contentHash: String,
        byteSize: Int,
        copyCount: Int = 1,
        deletedAt: Date? = nil,
        archivePath: String? = nil,
        items: [ClipItem],
        collectionIDs: Set<UUID> = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCopiedAt = lastCopiedAt
        self.primaryKind = primaryKind
        self.secondaryKinds = secondaryKinds
        self.title = title
        self.note = note
        self.priority = min(max(priority, 0), 3)
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.source = source
        self.previewText = previewText
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.copyCount = copyCount
        self.deletedAt = deletedAt
        self.archivePath = archivePath
        self.items = items
        self.collectionIDs = collectionIDs
    }
}

public enum CollectionKind: String, Codable, Sendable { case normal, smart }

public struct ClipCollection: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: CollectionKind
    public var sortOrder: Int
    public var ruleSet: SmartRuleSet?

    public init(id: UUID = UUID(), name: String, kind: CollectionKind, sortOrder: Int = 0, ruleSet: SmartRuleSet? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sortOrder = sortOrder
        self.ruleSet = ruleSet
    }
}

public enum RuleMatchMode: String, Codable, Sendable { case all, any }
public enum SmartRuleField: String, Codable, CaseIterable, Sendable {
    case sourceApp, sourceConfidence, createdAt, kind, title, body, note, byteSize, priority, favorite, copyCount
}
public enum SmartRuleOperator: String, Codable, CaseIterable, Sendable {
    case contains, equals, matchesRegex, before, after, greaterThan, lessThan
}

public extension SmartRuleField {
    var supportedOperators: [SmartRuleOperator] {
        switch self {
        case .title, .body, .note:
            [.contains, .equals, .matchesRegex]
        case .sourceApp, .sourceConfidence, .kind, .priority, .favorite:
            [.equals]
        case .createdAt:
            [.before, .after]
        case .byteSize, .copyCount:
            [.greaterThan, .lessThan, .equals]
        }
    }

    var defaultValue: String {
        switch self {
        case .sourceConfidence: SourceConfidence.high.rawValue
        case .kind: ClipKind.text.rawValue
        case .priority: "0"
        case .favorite: "true"
        case .createdAt: "7"
        case .byteSize, .copyCount: "1"
        case .sourceApp, .title, .body, .note: ""
        }
    }
}

public struct SmartCondition: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var field: SmartRuleField
    public var operation: SmartRuleOperator
    public var value: String

    public init(id: UUID = UUID(), field: SmartRuleField, operation: SmartRuleOperator, value: String) {
        self.id = id
        self.field = field
        self.operation = operation
        self.value = value
    }
}

public struct SmartRuleSet: Codable, Hashable, Sendable {
    public var mode: RuleMatchMode
    public var conditions: [SmartCondition]

    public init(mode: RuleMatchMode = .all, conditions: [SmartCondition] = []) {
        self.mode = mode
        self.conditions = Array(conditions.prefix(10))
    }
}

public struct CapturePolicy: Codable, Sendable {
    public var maximumItemBytes: Int
    public var excludedBundleIdentifiers: Set<String>
    public var excludedPasteboardTypes: Set<String>

    public static let `default` = CapturePolicy(
        maximumItemBytes: 10 * 1024 * 1024,
        excludedBundleIdentifiers: ["com.apple.keychainaccess", "com.apple.Passwords"],
        excludedPasteboardTypes: [
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
            "org.nspasteboard.ConcealedType"
        ]
    )
}

public struct RetentionPolicy: Codable, Sendable {
    public var archiveAfterDays: Int
    public var maximumHotClips: Int
    public var trashRetentionDays: Int

    public static let `default` = RetentionPolicy(archiveAfterDays: 30, maximumHotClips: 10_000, trashRetentionDays: 30)
}

public enum ClipFilter: Hashable, Sendable {
    case all, favorite, recent, archived, trash
    case kind(ClipKind)
    case collection(UUID)
}

public struct CapturedRepresentation: Sendable {
    public var uti: String
    public var data: Data
    public init(uti: String, data: Data) { self.uti = uti; self.data = data }
}

public struct CapturedItem: Sendable {
    public var order: Int
    public var representations: [CapturedRepresentation]
    public init(order: Int, representations: [CapturedRepresentation]) { self.order = order; self.representations = representations }
}

public struct PasteboardCapture: Sendable {
    public var items: [CapturedItem]
    public var source: ClipSource
    public var capturedAt: Date
    public init(items: [CapturedItem], source: ClipSource, capturedAt: Date = Date()) {
        self.items = items; self.source = source; self.capturedAt = capturedAt
    }
}
