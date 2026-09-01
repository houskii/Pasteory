import CryptoKit
import Foundation

public actor AttachmentStore {
    private let directories: AppDirectories
    private let threshold: Int

    public init(directories: AppDirectories, threshold: Int = 64 * 1024) {
        self.directories = directories
        self.threshold = threshold
    }

    public func externalize(_ clip: Clip) throws -> Clip {
        var result = clip
        for itemIndex in result.items.indices {
            for representationIndex in result.items[itemIndex].representations.indices {
                let representation = result.items[itemIndex].representations[representationIndex]
                guard case .inline(let data) = representation.storage,
                      data.count >= threshold || isBinaryAsset(representation.uti) else { continue }
                let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let relative = "\(checksum.prefix(2))/\(checksum)"
                let destination = directories.attachments.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
                result.items[itemIndex].representations[representationIndex].storage = .attachment(relativePath: relative, checksum: checksum, size: data.count)
            }
        }
        return result
    }

    public func data(for representation: ClipRepresentation) throws -> Data {
        switch representation.storage {
        case .inline(let data): return data
        case .attachment(let relativePath, let checksum, _):
            let data = try Data(contentsOf: directories.attachments.appendingPathComponent(relativePath))
            guard digest(data) == checksum else { throw StorageError.checksumMismatch }
            return data
        case .archived(let relativePath, let checksum, let size):
            let compressed = try Data(contentsOf: directories.archives.appendingPathComponent(relativePath))
            let data = try LZFSE.decompress(compressed, expectedSize: size)
            guard digest(data) == checksum else { throw StorageError.checksumMismatch }
            return data
        }
    }

    private func isBinaryAsset(_ uti: String) -> Bool {
        uti == "public.png" || uti == "public.tiff" || uti == "com.adobe.pdf" || uti.hasPrefix("public.image")
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum StorageError: LocalizedError {
    case checksumMismatch, compressionFailed, invalidArchive
    public var errorDescription: String? {
        switch self {
        case .checksumMismatch: "文件校验失败"
        case .compressionFailed: "压缩或解压失败"
        case .invalidArchive: "归档文件无效"
        }
    }
}
