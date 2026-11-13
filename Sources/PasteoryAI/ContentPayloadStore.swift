import Foundation
import CZlib
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public protocol PayloadCodec: Sendable {
    var identifier: String { get }
    func compress(_ data: Data) throws -> Data
    func decompress(_ data: Data, originalSize: Int) throws -> Data
}

public struct ZlibPayloadCodec: PayloadCodec {
    public let identifier = "zlib-v1"
    public init() {}
    public func compress(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        var size = compressBound(uLong(data.count))
        var result = Data(count: Int(size))
        let status = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compress2(output.bindMemory(to: Bytef.self).baseAddress, &size,
                          input.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_BEST_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw AIError.invalid("Compression failed") }
        result.count = Int(size); return result
    }
    public func decompress(_ data: Data, originalSize: Int) throws -> Data {
        guard (0...536_870_912).contains(originalSize) else { throw AIError.invalid("Payload is too large") }
        if originalSize == 0 {
            guard data.isEmpty else { throw AIError.invalid("Invalid empty payload") }; return Data()
        }
        var size = uLongf(originalSize)
        var result = Data(count: originalSize)
        let status = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                uncompress(output.bindMemory(to: Bytef.self).baseAddress, &size,
                           input.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
            }
        }
        guard status == Z_OK, Int(size) == originalSize else { throw AIError.invalid("Invalid compressed payload") }
        return result
    }
}

public enum PayloadReferenceMode: String, Codable, Sendable { case raw, packed }
public struct PayloadReference: Codable, Equatable, Sendable {
    public var ownerID: String
    public var contentID: String
    public var mode: PayloadReferenceMode
    public var changedAt: Date
    public init(ownerID: String, contentID: String, mode: PayloadReferenceMode = .raw, changedAt: Date = Date()) {
        self.ownerID = ownerID; self.contentID = contentID; self.mode = mode; self.changedAt = changedAt
    }
}
public struct PayloadRecord: Codable, Equatable, Sendable {
    public var contentID: String
    public var originalSize: Int
    public var codec: String
    public var packedSize: Int?
    public var verified: Bool
    public var rawPresent: Bool
    public var rawFilename: String { contentID + ".raw" }
    public var packedFilename: String { contentID + ".packed" }
}
public struct PayloadManifest: Codable, Equatable, Sendable {
    public var version = 1
    public var records: [String: PayloadRecord] = [:]
    public var references: [String: PayloadReference] = [:]
    public init() {}
}

/// One actor owns all writes, reference switches and garbage collection. Immutable
/// SHA-256 addressed payloads are shared; a reference's mode belongs to its owner.
/// A failed manifest save can leak bytes, but must never destroy reachable data.
public actor ContentPayloadStore {
    public let root: URL
    public let rawDirectory: URL
    public let packedDirectory: URL
    private let codec: any PayloadCodec
    private var manifest: PayloadManifest
    private var leases: [String: Set<UUID>] = [:]
    private var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    public init(root: URL, rawDirectory: URL? = nil, packedDirectory: URL? = nil,
                codec: any PayloadCodec = ZlibPayloadCodec()) throws {
        self.root = root
        self.rawDirectory = rawDirectory ?? root.appendingPathComponent("Raw", isDirectory: true)
        self.packedDirectory = packedDirectory ?? root.appendingPathComponent("Packed", isDirectory: true)
        self.codec = codec
        for folder in [root, self.rawDirectory, self.packedDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        }
        let url = root.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            manifest = try decoder.decode(PayloadManifest.self, from: data)
            guard manifest.version == 1 else { throw AIError.invalid("Unknown payload manifest version") }
        } else { manifest = PayloadManifest() }
        for (key, record) in manifest.records {
            guard Self.validID(key), record.contentID == key, record.codec == codec.identifier,
                  (0...536_870_912).contains(record.originalSize) else { throw AIError.invalid("Invalid payload manifest") }
        }
        for reference in manifest.references.values {
            guard manifest.records[reference.contentID] != nil else { throw AIError.invalid("Dangling payload reference") }
        }
    }

    public func snapshot() -> PayloadManifest { manifest }
    public func referenceCounts(for contentID: String) -> (raw: Int, packed: Int, leases: Int) {
        let refs = manifest.references.values.filter { $0.contentID == contentID }
        return (refs.filter { $0.mode == .raw }.count, refs.filter { $0.mode == .packed }.count,
                leases[contentID]?.count ?? 0)
    }

    @discardableResult
    public func register(_ data: Data, ownerIDs: [String], preferRaw: Bool = false) throws -> PayloadRecord {
        guard data.count <= 536_870_912, !ownerIDs.isEmpty,
              ownerIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw AIError.invalid("Invalid payload owners") }
        let id = AIHash.digest(data)
        let raw = rawDirectory.appendingPathComponent(id + ".raw")
        if FileManager.default.fileExists(atPath: raw.path) {
            guard try Data(contentsOf: raw) == data else { throw AIError.invalid("Raw payload checksum mismatch") }
        } else { try Self.durableWrite(data, to: raw) }
        var next = manifest
        var record = next.records[id] ?? PayloadRecord(contentID: id, originalSize: data.count, codec: codec.identifier,
                                                       packedSize: nil, verified: false, rawPresent: true)
        record.rawPresent = true; next.records[id] = record
        for owner in Set(ownerIDs) {
            if let existing = next.references[owner], existing.contentID == id, !preferRaw { continue }
            next.references[owner] = PayloadReference(ownerID: owner, contentID: id)
        }
        try persist(next); return record
    }

    @discardableResult
    public func pack(ownerIDs: [String]) throws -> [PayloadRecord] {
        guard !ownerIDs.isEmpty else { return [] }
        var next = manifest
        let refs = try ownerIDs.map { owner -> PayloadReference in
            guard let ref = manifest.references[owner] else { throw AIError.invalid("Unknown payload owner") }; return ref
        }
        var packed = [PayloadRecord]()
        for id in Set(refs.map(\.contentID)).sorted() {
            guard var record = next.records[id] else { throw AIError.invalid("Unknown payload") }
            let data = try readVerified(record)
            let url = packedDirectory.appendingPathComponent(record.packedFilename)
            if FileManager.default.fileExists(atPath: url.path) {
                let restored = try codec.decompress(Data(contentsOf: url), originalSize: record.originalSize)
                guard restored == data else { throw AIError.invalid("Packed payload checksum mismatch") }
            } else {
                let compressed = try codec.compress(data)
                guard try codec.decompress(compressed, originalSize: data.count) == data else {
                    throw AIError.invalid("Compression is not lossless")
                }
                try Self.durableWrite(compressed, to: url)
            }
            // Verify the bytes actually published on disk, not just the memory buffer.
            let stored = try Data(contentsOf: url)
            guard AIHash.digest(try codec.decompress(stored, originalSize: record.originalSize)) == id else {
                throw AIError.invalid("Published compressed payload failed verification")
            }
            record.packedSize = stored.count; record.verified = true
            next.records[id] = record; packed.append(record)
        }
        for var ref in refs { ref.mode = .packed; ref.changedAt = Date(); next.references[ref.ownerID] = ref }
        try persist(next); return packed
    }

    public func restoreRaw(ownerID: String) throws {
        guard var ref = manifest.references[ownerID], let record = manifest.records[ref.contentID] else {
            throw AIError.invalid("Unknown payload owner")
        }
        let data = try readVerified(record)
        try Self.durableWrite(data, to: rawDirectory.appendingPathComponent(record.rawFilename))
        var next = manifest; ref.mode = .raw; ref.changedAt = Date(); next.references[ownerID] = ref
        next.records[record.contentID]?.rawPresent = true
        try persist(next)
    }

    public func read(contentID: String) throws -> Data {
        guard let record = manifest.records[contentID] else { throw AIError.invalid("Unknown payload") }
        return try readVerified(record)
    }
    public func acquireRawLease(contentID: String) throws -> UUID {
        guard let record = manifest.records[contentID] else { throw AIError.invalid("Unknown payload") }
        let raw = rawDirectory.appendingPathComponent(record.rawFilename)
        if !FileManager.default.fileExists(atPath: raw.path) { try Self.durableWrite(readVerified(record), to: raw) }
        let lease = UUID(); leases[contentID, default: []].insert(lease); return lease
    }
    public func releaseRawLease(contentID: String, lease: UUID) { leases[contentID]?.remove(lease) }

    /// The caller must first commit all external database references to packed
    /// storage. Callers can conservatively exclude any externally-held content ID.
    @discardableResult
    public func releaseUnreferencedRaw(excluding externalHolders: Set<String> = []) throws -> Int {
        var next = manifest
        var candidates = [PayloadRecord]()
        for record in manifest.records.values {
            let counts = referenceCounts(for: record.contentID)
            guard !externalHolders.contains(record.contentID), counts.raw == 0, counts.packed > 0,
                  counts.leases == 0, record.verified else { continue }
            let packed = try Data(contentsOf: packedDirectory.appendingPathComponent(record.packedFilename))
            guard AIHash.digest(try codec.decompress(packed, originalSize: record.originalSize)) == record.contentID else {
                throw AIError.invalid("Cannot release raw content: packed data is corrupt")
            }
            next.records[record.contentID]?.rawPresent = false; candidates.append(record)
        }
        // Persist reachability first. A crash before unlink leaves a harmless raw
        // cache; the reader always verifies and can fall back to packed bytes.
        try persist(next)
        var released = 0
        for record in candidates {
            let raw = rawDirectory.appendingPathComponent(record.rawFilename)
            if FileManager.default.fileExists(atPath: raw.path) {
                let data = try Data(contentsOf: raw)
                guard AIHash.digest(data) == record.contentID else { throw AIError.invalid("Raw payload was modified") }
                try FileManager.default.removeItem(at: raw); released += data.count
            }
        }
        return released
    }

    public func removeReference(ownerID: String) throws {
        guard let ref = manifest.references[ownerID] else { return }
        let remaining = manifest.references.values.filter { $0.contentID == ref.contentID && $0.ownerID != ownerID }
        // A group dissolution must never destroy a logical Clip's final copy.
        guard !remaining.isEmpty else { throw AIError.invalid("Cannot remove the last recoverable content reference") }
        var next = manifest; next.references.removeValue(forKey: ownerID); try persist(next)
    }

    /// Reconcile against the application's live logical owners. Callers serialize
    /// this with imports/compression. Newly published references are retained if a
    /// stale snapshot would otherwise discard them. Leases protect in-flight reads.
    @discardableResult
    public func reconcile(_ desired: [PayloadReference], snapshotAt: Date, purgeUnreferenced: Bool = false, forceRawOwners: Set<String> = []) throws -> Int {
        var next = manifest
        var owners = [String: PayloadReference]()
        for requested in desired {
            guard var record = next.records[requested.contentID] else { continue }
            var ref = requested
            if let existing = manifest.references[ref.ownerID], existing.contentID == ref.contentID, !forceRawOwners.contains(ref.ownerID) {
                ref = existing
            }
            if ref.mode == .raw {
                let raw = rawDirectory.appendingPathComponent(record.rawFilename)
                if !FileManager.default.fileExists(atPath: raw.path) { try Self.durableWrite(readVerified(record), to: raw) }
                record.rawPresent = true; next.records[record.contentID] = record
            } else if !record.verified { throw AIError.invalid("An unverified payload cannot have compressed owners") }
            owners[ref.ownerID] = ref
        }
        for (id, ref) in manifest.references where ref.changedAt >= snapshotAt && owners[id] == nil { owners[id] = ref }
        next.references = owners
        var removed = [PayloadRecord]()
        if purgeUnreferenced {
            let reachable = Set(owners.values.map(\.contentID))
            for record in next.records.values where !reachable.contains(record.contentID) && (leases[record.contentID]?.isEmpty ?? true) {
                removed.append(record); next.records.removeValue(forKey: record.contentID)
            }
        }
        try persist(next)
        var bytes = 0
        for record in removed {
            for file in [rawDirectory.appendingPathComponent(record.rawFilename), packedDirectory.appendingPathComponent(record.packedFilename)] {
                if FileManager.default.fileExists(atPath: file.path) {
                    let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    try FileManager.default.removeItem(at: file); bytes += size
                }
            }
        }
        return bytes
    }

    public func exportArchive(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for folder in ["Raw", "Packed"] { try fm.createDirectory(at: destination.appendingPathComponent(folder), withIntermediateDirectories: true) }
        var exported = manifest
        for record in manifest.records.values {
            _ = try readVerified(record)
            let raw = rawDirectory.appendingPathComponent(record.rawFilename)
            let pack = packedDirectory.appendingPathComponent(record.packedFilename)
            if fm.fileExists(atPath: raw.path) {
                try Self.durableWrite(Data(contentsOf: raw), to: destination.appendingPathComponent("Raw/" + record.rawFilename))
                exported.records[record.contentID]?.rawPresent = true
            } else { exported.records[record.contentID]?.rawPresent = false }
            if record.verified { try Self.durableWrite(Data(contentsOf: pack), to: destination.appendingPathComponent("Packed/" + record.packedFilename)) }
        }
        try Self.durableWrite(JSONEncoder.sorted.encode(exported), to: destination.appendingPathComponent("manifest.json"))
    }

    public func importArchive(from source: URL) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let imported = try decoder.decode(PayloadManifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        guard imported.version == 1 else { throw AIError.invalid("Unknown payload archive version") }
        var next = manifest
        for (id, record) in imported.records {
            guard Self.validID(id), record.contentID == id, record.codec == codec.identifier,
                  (0...536_870_912).contains(record.originalSize) else { throw AIError.invalid("Invalid payload archive") }
            let raw = source.appendingPathComponent("Raw/" + record.rawFilename)
            let pack = source.appendingPathComponent("Packed/" + record.packedFilename)
            if record.rawPresent {
                let bytes = try Data(contentsOf: raw)
                guard bytes.count == record.originalSize, AIHash.digest(bytes) == id else { throw AIError.invalid("Invalid raw archive checksum") }
                try Self.durableWrite(bytes, to: rawDirectory.appendingPathComponent(record.rawFilename))
            }
            if record.verified {
                let bytes = try Data(contentsOf: pack)
                guard AIHash.digest(try codec.decompress(bytes, originalSize: record.originalSize)) == id else { throw AIError.invalid("Invalid packed archive checksum") }
                try Self.durableWrite(bytes, to: packedDirectory.appendingPathComponent(record.packedFilename))
            }
            guard record.rawPresent || record.verified else { throw AIError.invalid("Unrecoverable archive content") }
            next.records[id] = record
        }
        for (id, ref) in imported.references {
            guard id == ref.ownerID, !id.isEmpty, next.records[ref.contentID] != nil else { throw AIError.invalid("Invalid archive reference") }
            next.references[id] = ref
        }
        try persist(next)
    }

    private func readVerified(_ record: PayloadRecord) throws -> Data {
        let raw = rawDirectory.appendingPathComponent(record.rawFilename)
        let data: Data
        if FileManager.default.fileExists(atPath: raw.path) { data = try Data(contentsOf: raw) }
        else {
            guard record.verified else { throw AIError.invalid("Missing recoverable content") }
            data = try codec.decompress(Data(contentsOf: packedDirectory.appendingPathComponent(record.packedFilename)), originalSize: record.originalSize)
        }
        guard data.count == record.originalSize, AIHash.digest(data) == record.contentID else { throw AIError.invalid("Payload checksum mismatch") }
        return data
    }
    private func persist(_ next: PayloadManifest) throws {
        try Self.durableWrite(JSONEncoder.sorted.encode(next), to: manifestURL); manifest = next
    }
    private static func validID(_ id: String) -> Bool { id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    public static func durableWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AIError.invalid("Cannot create payload file") }
        defer { try? fm.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        let status = temp.path.withCString { source in url.path.withCString { destination in rename(source, destination) } }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directory = url.deletingLastPathComponent().path.withCString { open($0, O_RDONLY) }
        if directory >= 0 { defer { _ = close(directory) }; _ = fsync(directory) }
    }
}
