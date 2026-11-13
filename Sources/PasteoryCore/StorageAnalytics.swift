import Foundation

public enum StorageAnalyticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case oneDay
    case sevenDays
    case thirtyDays
    case all

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .oneDay: L10n.tr("1 天")
        case .sevenDays: L10n.tr("7 天")
        case .thirtyDays: L10n.tr("30 天")
        case .all: L10n.tr("总共")
        }
    }

    public func startDate(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let todayStart = calendar.startOfDay(for: date)
        switch self {
        case .oneDay:
            return todayStart
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        case .all:
            return nil
        }
    }
}

public struct ClipKindCount: Identifiable, Equatable, Sendable {
    public let kind: ClipKind
    public let count: Int

    public init(kind: ClipKind, count: Int) {
        self.kind = kind
        self.count = count
    }

    public var id: ClipKind { kind }
}

public enum PasteoryStorageCategory: String, CaseIterable, Identifiable, Sendable {
    case database
    case attachments
    case archives
    case backups
    case logs
    case webKitNetworkCache
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .database: L10n.tr("数据库")
        case .attachments: L10n.tr("图片与附件")
        case .archives: L10n.tr("归档")
        case .backups: L10n.tr("备份")
        case .logs: L10n.tr("日志")
        case .webKitNetworkCache: L10n.tr("WebKit 网页缓存")
        case .other: L10n.tr("其他")
        }
    }
}

public struct PasteoryStorageUsage: Identifiable, Equatable, Sendable {
    public let category: PasteoryStorageCategory
    public let byteCount: Int64

    public init(category: PasteoryStorageCategory, byteCount: Int64) {
        self.category = category
        self.byteCount = byteCount
    }

    public var id: PasteoryStorageCategory { category }
}

public struct StorageAnalyticsSnapshot: Equatable, Sendable {
    public let period: StorageAnalyticsPeriod
    public let clipBuckets: [StorageClipBucket]
    public let storageUsage: [PasteoryStorageUsage]
    public let volumeTotalBytes: Int64?

    public init(
        period: StorageAnalyticsPeriod,
        clipBuckets: [StorageClipBucket],
        storageUsage: [PasteoryStorageUsage],
        volumeTotalBytes: Int64?
    ) {
        self.period = period
        self.clipBuckets = clipBuckets
        self.storageUsage = storageUsage
        self.volumeTotalBytes = volumeTotalBytes
    }

    public var clipCounts: [ClipKindCount] {
        var totals = [ClipKind: Int]()
        for bucket in clipBuckets {
            for item in bucket.counts { totals[item.kind, default: 0] += item.count }
        }
        return ClipKind.allCases.compactMap { kind in
            let count = totals[kind, default: 0]
            return count > 0 ? ClipKindCount(kind: kind, count: count) : nil
        }
    }

    public var clipCount: Int { clipBuckets.reduce(0) { $0 + $1.totalCount } }
    public var totalStorageBytes: Int64 { storageUsage.reduce(0) { $0 + $1.byteCount } }
}

public struct StorageClipBucket: Identifiable, Equatable, Sendable {
    public let startDate: Date?
    public let endDate: Date?
    public let counts: [ClipKindCount]

    public init(startDate: Date?, endDate: Date?, counts: [ClipKindCount]) {
        self.startDate = startDate
        self.endDate = endDate
        self.counts = counts
    }

    public var id: Date { startDate ?? .distantPast }
    public var totalCount: Int { counts.reduce(0) { $0 + $1.count } }
}

public actor StorageAnalyticsService {
    private let repository: any ClipRepository
    private let directories: AppDirectories

    public init(repository: any ClipRepository, directories: AppDirectories) {
        self.repository = repository
        self.directories = directories
    }

    public func snapshot(
        period: StorageAnalyticsPeriod,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) async throws -> StorageAnalyticsSnapshot {
        let buckets = try await clipBuckets(period: period, now: now, calendar: calendar)
        let usage = storageUsage()
        let volumeTotal = try? directories.root.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity
        return StorageAnalyticsSnapshot(
            period: period,
            clipBuckets: buckets,
            storageUsage: usage,
            volumeTotalBytes: volumeTotal.map(Int64.init)
        )
    }

    private func clipBuckets(
        period: StorageAnalyticsPeriod,
        now: Date,
        calendar: Calendar
    ) async throws -> [StorageClipBucket] {
        guard let rangeStart = period.startDate(containing: now, calendar: calendar) else {
            let counts = try await repository.storedClipKindCounts(since: nil, before: nil)
            return [StorageClipBucket(startDate: nil, endDate: nil, counts: counts)]
        }

        let todayStart = calendar.startOfDay(for: now)
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        var buckets = [StorageClipBucket]()
        var dayStart = rangeStart
        while dayStart < rangeEnd {
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? rangeEnd
            let counts = try await repository.storedClipKindCounts(since: dayStart, before: dayEnd)
            buckets.append(StorageClipBucket(startDate: dayStart, endDate: dayEnd, counts: counts))
            dayStart = dayEnd
        }
        return buckets
    }

    private func storageUsage() -> [PasteoryStorageUsage] {
        let database = allocatedByteCount(at: directories.database)
        let attachments = allocatedByteCount(at: directories.attachments)
        let archives = allocatedByteCount(at: directories.archives)
        let backups = allocatedByteCount(at: directories.backups)
        let logs = allocatedByteCount(at: directories.logs)
        let webKitNetworkCache = webKitNetworkCacheBytes()
        let total = allocatedByteCount(at: directories.root)
        let known = database + attachments + archives + backups + logs
        let other = max(0, total - known)
        return [
            PasteoryStorageUsage(category: .database, byteCount: database),
            PasteoryStorageUsage(category: .attachments, byteCount: attachments),
            PasteoryStorageUsage(category: .archives, byteCount: archives),
            PasteoryStorageUsage(category: .backups, byteCount: backups),
            PasteoryStorageUsage(category: .logs, byteCount: logs),
            PasteoryStorageUsage(category: .webKitNetworkCache, byteCount: webKitNetworkCache),
            PasteoryStorageUsage(category: .other, byteCount: other)
        ]
    }

    public func webKitNetworkCacheBytes() -> Int64 {
        directories.webKitNetworkCache.map { allocatedByteCount(at: $0) } ?? 0
    }

    private func allocatedByteCount(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileResourceIdentifierKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var seenFileIDs = Set<AnyHashable>()
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            if let identifier = values.fileResourceIdentifier as? AnyHashable,
               !seenFileIDs.insert(identifier).inserted { continue }
            let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(max(bytes, 0))
        }
        return total
    }
}
