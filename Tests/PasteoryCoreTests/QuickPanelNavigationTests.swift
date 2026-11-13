import Testing
@testable import Pasteory

@Test func quickScopeNavigationWrapsAtBothEnds() {
    #expect(QuickPanelNavigation.wrappedIndex(current: 0, offset: -1, count: 4) == 3)
    #expect(QuickPanelNavigation.wrappedIndex(current: 3, offset: 1, count: 4) == 0)
    #expect(QuickPanelNavigation.wrappedIndex(current: 1, offset: 1, count: 4) == 2)
    #expect(QuickPanelNavigation.wrappedIndex(current: 2, offset: -1, count: 4) == 1)
    #expect(QuickPanelNavigation.wrappedIndex(current: 0, offset: 1, count: 0) == nil)
}

@Test func unmodifiedHorizontalArrowsAreReservedForScopeNavigation() {
    #expect(QuickPanelNavigation.scopeOffset(
        forKeyCode: 123,
        command: false,
        shift: false,
        option: false,
        control: false
    ) == -1)
    #expect(QuickPanelNavigation.scopeOffset(
        forKeyCode: 124,
        command: false,
        shift: false,
        option: false,
        control: false
    ) == 1)
    #expect(QuickPanelNavigation.scopeOffset(
        forKeyCode: 123,
        command: true,
        shift: false,
        option: false,
        control: false
    ) == nil)
    #expect(QuickPanelNavigation.scopeOffset(
        forKeyCode: 5,
        command: false,
        shift: false,
        option: false,
        control: false
    ) == nil)
}

@Test func verticalArrowsNeverSwitchGroups() {
    for keyCode: UInt16 in [125, 126] {
        #expect(QuickPanelNavigation.scopeOffset(
            forKeyCode: keyCode,
            command: false, shift: false, option: false, control: false
        ) == nil)
    }
}
