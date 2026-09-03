import Testing
@testable import PasteoryCore

@Test func fileSizeFormatterUsesDecimalUnitsWithOneFractionDigit() {
    #expect(FileSizeFormatter.string(forByteCount: 0) == "0.0 B")
    #expect(FileSizeFormatter.string(forByteCount: 8) == "8.0 B")
    #expect(FileSizeFormatter.string(forByteCount: 999) == "999.0 B")
    #expect(FileSizeFormatter.string(forByteCount: 1_000) == "1.0 KB")
    #expect(FileSizeFormatter.string(forByteCount: 1_500) == "1.5 KB")
    #expect(FileSizeFormatter.string(forByteCount: 24_300_000) == "24.3 MB")
    #expect(FileSizeFormatter.string(forByteCount: 2_100_000_000) == "2.1 GB")
}
