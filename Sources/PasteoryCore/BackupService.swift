import CryptoKit
import Foundation

public struct BackupManifest: Codable, Sendable {
    public var formatVersion: Int
    public var appVersion: String
    public var exportedAt: Date
    public var clipCount: Int
    public var captureEventCount: Int?
    public var fallbackRuleCount: Int?
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
                    guard let (source, relative) = pair, fileManager.fileExists(atPath: source.path) else { continue }
                    let target = dataFolder.appendingPathComponent(relative)
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fileManager.fileExists(atPath: target.path) { try fileManager.copyItem(at: source, to: target) }
                    checksums["data/\(relative)"] = digest(try Data(contentsOf: source))
                }
            }
        }
        let manifest = BackupManifest(
            formatVersion: 3,
            appVersion: "0.1.6",
            exportedAt: Date(),
            clipCount: clips.count,
            captureEventCount: captureEvents.count,
            fallbackRuleCount: fallbackRules.count,
            fileChecksums: checksums
        )
        try encoder.encode(manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
    }

    @discardableResult
    public func importBackup(from source: URL) async throws -> Int {
        let manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        guard (1...3).contains(manifest.formatVersion) else { throw StorageError.invalidArchive }
        for (relative, expected) in manifest.fileChecksums {
            let data = try Data(contentsOf: source.appendingPathComponent(relative))
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
                    let origin = dataFolder.appendingPathComponent(relative)
                    guard fileManager.fileExists(atPath: origin.path) else { throw StorageError.invalidArchive }
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fileManager.fileExists(atPath: target.path) { try fileManager.copyItem(at: origin, to: target) }
                }
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
        return clips.count
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
