import Testing
@testable import PasteoryCore

@Test func compactCountUsesKAtOneThousandAndKeepsOneDecimalPlace() {
    #expect(CompactCountFormatter.string(for: 0) == "0")
    #expect(CompactCountFormatter.string(for: 999) == "999")
    #expect(CompactCountFormatter.string(for: 1_000) == "1.0K")
    #expect(CompactCountFormatter.string(for: 1_250) == "1.3K")
    #expect(CompactCountFormatter.string(for: 9_999) == "10.0K")
}
