import CryptoKit
import Foundation

public actor ArchiveService {
    private let repository: any ClipRepository
    private let directories: AppDirectories
    private let policy: RetentionPolicy

    public init(repository: any ClipRepository, directories: AppDirectories, policy: RetentionPolicy = .default) {
        self.repository = repository
        self.directories = directories
        self.policy = policy
    }

    @discardableResult
    public func run(now: Date = Date()) async throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -policy.archiveAfterDays, to: now) ?? now
        let clips = try await repository.archiveCandidates(olderThan: cutoff, hotLimit: policy.maximumHotClips)
        for clip in clips { try await archive(clip) }
        let trashCutoff = Calendar.current.date(byAdding: .day, value: -policy.trashRetentionDays, to: now) ?? now
        _ = try await repository.purgeTrash(olderThan: trashCutoff)
        return clips.count
    }

    public func archive(_ clip: Clip) async throws {
        guard try await repository.clip(id: clip.id) != nil else { return }
        guard !clip.isFavorite, !clip.isPinned, !clip.isArchived else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"
        let month = formatter.string(from: clip.createdAt)
        let clipFolder = "\(month)/\(clip.id.uuidString)"
        let folderURL = directories.archives.appendingPathComponent(clipFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var archived = clip
        var newFiles = [URL]()
        var committed = false
        defer {
            if !committed {
                for file in newFiles { try? FileManager.default.removeItem(at: file) }
            }
        }
        for itemIndex in archived.items.indices {
            for representationIndex in archived.items[itemIndex].representations.indices {
                let representation = archived.items[itemIndex].representations[representationIndex]
                guard case .inline(let data) = representation.storage else { continue }
                let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let relative = "\(clipFolder)/\(UUID().uuidString).lzfse"
                let compressed = try LZFSE.compress(data)
                let file = directories.archives.appendingPathComponent(relative)
                try compressed.write(to: file, options: .atomic)
                newFiles.append(file)
                archived.items[itemIndex].representations[representationIndex].storage = .archived(relativePath: relative, checksum: checksum, size: data.count)
            }
        }
        archived.isArchived = true
        archived.archivePath = clipFolder
        archived.updatedAt = Date()
        committed = try await repository.saveArchived(archived, replacing: clip)
    }
}
