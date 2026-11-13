import CryptoKit
import Foundation
import PasteoryAI

public struct BackupManifest: Codable, Sendable {
    public var formatVersion: Int
    public var appVersion: String
    public var exportedAt: Date
    public var clipCount: Int
    public var captureEventCount: Int?
    public var fallbackRuleCount: Int?
    public var aggregationCount: Int?
    public var collectionCount: Int?
    public var fileChecksums: [String: String]
}

public actor BackupService {
    private let repository: any ClipRepository
    private let directories: AppDirectories
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(repository: any ClipRepository, directories: AppDirectories) {
        self.repository = repository
        self.directories = directories
        self.encoder = JSONEncoder(); self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601; self.decoder.dateDecodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func export(to destination: URL) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let clips = try await repository.allClips()
        let captureEvents = try await repository.allCaptureEvents()
        let fallbackRules = try await repository.userFallbackRules()
        let aggregations = try await repository.aggregations()
        let collections = try await repository.collections()
        let clipsURL = destination.appendingPathComponent("clips.jsonl")
        var lines = Data()
        for clip in clips {
            lines.append(try encoder.encode(clip)); lines.append(Data("\n".utf8))
        }
        try lines.write(to: clipsURL, options: .atomic)
        var checksums = ["clips.jsonl": digest(lines)]
        let eventsURL = destination.appendingPathComponent("capture-events.jsonl")
        var eventLines = Data()
        for event in captureEvents {
            eventLines.append(try encoder.encode(event)); eventLines.append(Data("\n".utf8))
        }
        try eventLines.write(to: eventsURL, options: .atomic)
        checksums["capture-events.jsonl"] = digest(eventLines)
        let rulesURL = destination.appendingPathComponent("url-fallback-rules.jsonl")
        var ruleLines = Data()
        for rule in fallbackRules {
            ruleLines.append(try encoder.encode(rule)); ruleLines.append(Data("\n".utf8))
        }
        try ruleLines.write(to: rulesURL, options: .atomic)
        checksums["url-fallback-rules.jsonl"] = digest(ruleLines)
        let aggregationsURL = destination.appendingPathComponent("aggregations.jsonl")
        var aggregationLines = Data()
        for aggregation in aggregations {
            aggregationLines.append(try encoder.encode(aggregation)); aggregationLines.append(Data("\n".utf8))
        }
        try aggregationLines.write(to: aggregationsURL, options: .atomic)
        checksums["aggregations.jsonl"] = digest(aggregationLines)
        let collectionBytes = try encoder.encode(collections)
        try collectionBytes.write(to: destination.appendingPathComponent("collections.json"), options: .atomic)
        checksums["collections.json"] = digest(collectionBytes)
        var aiState = try await repository.aiState()
        // Undo snapshots are tied to a particular database. Restored organization
        // is retained without offering an undo whose transaction was not backed up.
        aiState.changes = []; aiState.checkpoint = nil
        let aiBytes = try encoder.encode(aiState)
        try aiBytes.write(to: destination.appendingPathComponent("ai-state.json"), options: .atomic)
        checksums["ai-state.json"] = digest(aiBytes)
        let aiFolder = destination.appendingPathComponent("ai-content", isDirectory: true)
        try await repository.exportAIContent(to: aiFolder)
        if let files = fileManager.enumerator(at: aiFolder, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                let relative = String(file.path.dropFirst(destination.path.count + 1))
                checksums[relative] = digest(try Data(contentsOf: file))
            }
        }
        let dataFolder = destination.appendingPathComponent("data", isDirectory: true)
        for clip in clips {
            for item in clip.items {
                for representation in item.representations {
                    let pair: (URL, String)?
                    switch representation.storage {
                    case .inline: pair = nil
                    case .attachment(let relative, _, _): pair = (directories.attachments.appendingPathComponent(relative), "Attachments/\(relative)")
                    case .archived(let relative, _, _): pair = (directories.archives.appendingPathComponent(relative), "Archives/\(relative)")
                    }
                    guard let (source, relative) = pair else { continue }
                    guard safePath(relative, under: dataFolder) != nil else { throw StorageError.invalidArchive }
                    let target = dataFolder.appendingPathComponent(relative)
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fileManager.fileExists(atPath: target.path) {
                        if fileManager.fileExists(atPath: source.path) { try fileManager.copyItem(at: source, to: target) }
                        else if case .attachment = representation.storage {
                            try AttachmentStore.loadData(for: representation, storageRoot: directories.root).write(to: target, options: .atomic)
                        } else { throw StorageError.invalidArchive }
                    }
                    checksums["data/\(relative)"] = digest(try Data(contentsOf: target))
                }
            }
        }
        let manifest = BackupManifest(
            formatVersion: 5,
            appVersion: "0.1.6",
            exportedAt: Date(),
            clipCount: clips.count,
            captureEventCount: captureEvents.count,
            fallbackRuleCount: fallbackRules.count,
            aggregationCount: aggregations.count,
            collectionCount: collections.count,
            fileChecksums: checksums
        )
        try encoder.encode(manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
    }

    @discardableResult
    public func importBackup(from source: URL) async throws -> Int {
        let manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        guard (1...5).contains(manifest.formatVersion) else { throw StorageError.invalidArchive }
        for (relative, expected) in manifest.fileChecksums {
            guard let path = safePath(relative, under: source) else { throw StorageError.invalidArchive }
            let data = try Data(contentsOf: path)
            guard digest(data) == expected else { throw StorageError.checksumMismatch }
        }
        let clipsData = try Data(contentsOf: source.appendingPathComponent("clips.jsonl"))
        guard let content = String(data: clipsData, encoding: .utf8) else { throw StorageError.invalidArchive }
        let clips = try content.split(separator: "\n").map { try decoder.decode(Clip.self, from: Data($0.utf8)) }
        let fileManager = FileManager.default
        let dataFolder = source.appendingPathComponent("data")
        for clip in clips {
            for item in clip.items {
                for representation in item.representations {
                    let pair: (String, URL)?
                    switch representation.storage {
                    case .inline: pair = nil
                    case .attachment(let relative, _, _): pair = ("Attachments/\(relative)", directories.attachments.appendingPathComponent(relative))
                    case .archived(let relative, _, _): pair = ("Archives/\(relative)", directories.archives.appendingPathComponent(relative))
                    }
                    guard let (relative, target) = pair else { continue }
                    guard let origin = safePath(relative, under: dataFolder),
                          safePath(relative, under: directories.root) != nil,
                          manifest.fileChecksums["data/" + relative] != nil else { throw StorageError.invalidArchive }
                    guard fileManager.fileExists(atPath: origin.path) else { throw StorageError.invalidArchive }
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fileManager.fileExists(atPath: target.path) { try fileManager.copyItem(at: origin, to: target) }
                    else if digest(try Data(contentsOf: target)) != digest(try Data(contentsOf: origin)) { throw StorageError.checksumMismatch }
                }
            }
        }
        if manifest.formatVersion >= 5 {
            let collections = try decoder.decode([ClipCollection].self, from: Data(contentsOf: source.appendingPathComponent("collections.json")))
            var existing = try await repository.collections()
            for var collection in collections where !existing.contains(where: { $0.id == collection.id }) {
                let base = String(collection.name.prefix(25)); var suffix = 1
                while existing.contains(where: { $0.name.caseInsensitiveCompare(collection.name) == .orderedSame }) {
                    collection.name = "\(base) (\(suffix))"; suffix += 1
                }
                try await repository.saveCollection(collection); existing.append(collection)
            }
            let aiFolder = source.appendingPathComponent("ai-content")
            if fileManager.fileExists(atPath: aiFolder.appendingPathComponent("manifest.json").path) {
                try await repository.importAIContent(from: aiFolder)
            }
        }
        try await repository.saveBatch(clips)
        if manifest.formatVersion >= 2 {
            let eventsData = try Data(contentsOf: source.appendingPathComponent("capture-events.jsonl"))
            guard let eventContent = String(data: eventsData, encoding: .utf8) else { throw StorageError.invalidArchive }
            let events = try eventContent.split(separator: "\n").map {
                try decoder.decode(ClipCaptureEvent.self, from: Data($0.utf8))
            }
            try await repository.saveCaptureEvents(events)
        }
        if manifest.formatVersion >= 3 {
            let rulesData = try Data(contentsOf: source.appendingPathComponent("url-fallback-rules.jsonl"))
            guard let ruleContent = String(data: rulesData, encoding: .utf8) else { throw StorageError.invalidArchive }
            let rules = try ruleContent.split(separator: "\n").map {
                try decoder.decode(URLFallbackRule.self, from: Data($0.utf8))
            }
            for rule in rules { try await repository.saveFallbackRule(rule) }
        }
        _ = try await repository.consolidateDuplicateClips()
        if manifest.formatVersion >= 4 {
            let aggregationData = try Data(contentsOf: source.appendingPathComponent("aggregations.jsonl"))
            guard let aggregationContent = String(data: aggregationData, encoding: .utf8) else { throw StorageError.invalidArchive }
            let aggregations = try aggregationContent.split(separator: "\n").map {
                try decoder.decode(ClipAggregation.self, from: Data($0.utf8))
            }
            for aggregation in aggregations { _ = try await repository.saveAggregation(aggregation) }
        }
        if manifest.formatVersion >= 5 {
            let imported = try decoder.decode(AIOrganizationState.self, from: Data(contentsOf: source.appendingPathComponent("ai-state.json")))
            let restoredClips = try await repository.allClips()
            let restoredCollections = try await repository.collections()
            let restoredAggregations = Set(try await repository.aggregations().map(\.id))
            let clipIndex = Dictionary(uniqueKeysWithValues: restoredClips.map { ($0.id, $0) })
            try await repository.updateAIState { state in
                for (id, var group) in imported.groups where state.groups[id] == nil {
                    guard let collection = restoredCollections.first(where: { $0.id == id }) else { continue }
                    group.name = collection.name
                    group.memberIDs = Set(restoredClips.filter { $0.collectionIDs.contains(id) }.map(\.id))
                    group.aiMemberIDs.formIntersection(group.memberIDs)
                    state.groups[id] = group
                }
                for (id, summary) in imported.summaries where state.summaries[id] == nil && restoredAggregations.contains(id) {
                    if summary.sourceRevisions.allSatisfy({ clipIndex[$0.key]?.aiContentRevision == $0.value }) { state.summaries[id] = summary }
                }
                let known = Set(state.usage.map(\.id)); state.usage += imported.usage.filter { !known.contains($0.id) }
            }
        }
        return clips.count
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func safePath(_ relative: String, under root: URL) -> URL? {
        let components = relative.components(separatedBy: "/")
        guard !relative.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { return nil }
        let result = root.appendingPathComponent(relative)
        let prefix = root.resolvingSymlinksInPath().path + "/"
        guard result.resolvingSymlinksInPath().path.hasPrefix(prefix) else { return nil }
        return result
    }
}
