import Testing
@testable import PasteoryCore

@Test func quickSearchReturnConfirmsInputMethodBeforeRunningShortcut() {
    #expect(QuickSearchInputPolicy.returnDisposition(
        hasMarkedText: true,
        hasConfiguredShortcut: true
    ) == .confirmMarkedText)
    #expect(QuickSearchInputPolicy.returnDisposition(
        hasMarkedText: false,
        hasConfiguredShortcut: true
    ) == .performShortcut)
    #expect(QuickSearchInputPolicy.returnDisposition(
        hasMarkedText: false,
        hasConfiguredShortcut: false
    ) == .consume)
}
