import Compression
import Foundation

public enum LZFSE {
    public static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        var capacity = max(1024, data.count + data.count / 8 + 256)
        while capacity < data.count * 4 {
            var destination = Data(count: capacity)
            let written = destination.withUnsafeMutableBytes { output in
                data.withUnsafeBytes { input in
                    compression_encode_buffer(
                        output.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                        nil, COMPRESSION_LZFSE
                    )
                }
            }
            if written > 0 { destination.count = written; return destination }
            capacity *= 2
        }
        throw StorageError.compressionFailed
    }

    public static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        guard !data.isEmpty else { return data }
        let capacity = max(1, expectedSize)
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_decode_buffer(
                    output.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard written == expectedSize else { throw StorageError.compressionFailed }
        destination.count = written
        return destination
    }
}
