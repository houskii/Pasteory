import CryptoKit
import Foundation
import PasteoryAI
import UniformTypeIdentifiers

public actor AttachmentStore {
    private let directories: AppDirectories
    private let threshold: Int

    public init(directories: AppDirectories, threshold: Int = 64 * 1024) {
        self.directories = directories
        self.threshold = threshold
    }

    public func externalize(_ clip: Clip) throws -> Clip {
        try Self.externalize(clip, into: directories.attachments, threshold: threshold)
    }

    static func externalize(_ clip: Clip, into directory: URL, threshold: Int = 64 * 1024) throws -> Clip {
        var result = clip
        for itemIndex in result.items.indices {
            for representationIndex in result.items[itemIndex].representations.indices {
                let representation = result.items[itemIndex].representations[representationIndex]
                guard case .inline(let data) = representation.storage,
                      data.count >= threshold || isBinaryAsset(representation.uti) else { continue }
                let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let relative = "\(checksum.prefix(2))/\(checksum)"
                let destination = directory.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
                result.items[itemIndex].representations[representationIndex].storage = .attachment(relativePath: relative, checksum: checksum, size: data.count)
            }
        }
        return result
    }

    public func data(for representation: ClipRepresentation) throws -> Data {
        try Self.loadData(for: representation, storageRoot: directories.root)
    }

    static func loadData(for representation: ClipRepresentation, storageRoot: URL) throws -> Data {
        switch representation.storage {
        case .inline(let data): return data
        case .attachment(let relativePath, let checksum, let size):
            let raw = storageRoot.appendingPathComponent("Attachments/" + relativePath)
            let data: Data
            if FileManager.default.fileExists(atPath: raw.path) { data = try Data(contentsOf: raw) }
            else {
                // An already-open UI may still hold the old representation after
                // its raw cache was reclaimed. Read the same immutable bytes.
                guard checksum.count == 64, checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      (0...536_870_912).contains(size) else { throw StorageError.invalidArchive }
                let packed = storageRoot.appendingPathComponent("Archives/AIContent/Packed/" + checksum + ".packed")
                data = try LZFSE.decompress(Data(contentsOf: packed), expectedSize: size)
            }
            guard AIHash.digest(data) == checksum else { throw StorageError.checksumMismatch }
            return data
        case .archived(let relativePath, let checksum, let size):
            let compressed = try Data(contentsOf: storageRoot.appendingPathComponent("Archives/" + relativePath))
            let data = try LZFSE.decompress(compressed, expectedSize: size)
            guard AIHash.digest(data) == checksum else { throw StorageError.checksumMismatch }
            return data
        }
    }

    private static func isBinaryAsset(_ uti: String) -> Bool {
        uti == "com.adobe.pdf" || UTType(uti)?.conforms(to: .image) == true
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum StorageError: LocalizedError {
    case checksumMismatch, compressionFailed, invalidArchive
    public var errorDescription: String? {
        switch self {
        case .checksumMismatch: L10n.tr("文件校验失败")
        case .compressionFailed: L10n.tr("压缩或解压失败")
        case .invalidArchive: L10n.tr("归档文件无效")
        }
    }
}
