import Foundation

public enum FileSizeFormatter {
    public static func string(forByteCount byteCount: Int) -> String {
        string(forByteCount: Int64(byteCount))
    }

    public static func string(forByteCount byteCount: Int64) -> String {
        let bytes = Double(max(byteCount, 0))
        let value: Double
        let unit: String
        switch bytes {
        case 0..<1_000:
            value = bytes
            unit = "B"
        case 1_000..<1_000_000:
            value = bytes / 1_000
            unit = "KB"
        case 1_000_000..<1_000_000_000:
            value = bytes / 1_000_000
            unit = "MB"
        default:
            value = bytes / 1_000_000_000
            unit = "GB"
        }
        return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, unit)
    }
}
