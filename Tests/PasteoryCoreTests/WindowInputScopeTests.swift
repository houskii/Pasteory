import AppKit
import Testing
@testable import Pasteory

@Test @MainActor func quickPanelInputScopeIncludesItsChildrenAndExcludesSettings() {
    _ = NSApplication.shared
    let panel = NSPanel(contentRect: .zero, styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
    let child = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    let settings = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    #expect(WindowInputScope.contains(panel, root: panel))
    #expect(!WindowInputScope.contains(settings, root: panel))
    #expect(!WindowInputScope.contains(nil, root: panel))
    panel.addChildWindow(child, ordered: .above)
    #expect(WindowInputScope.contains(child, root: panel))
    panel.removeChildWindow(child)
    #expect(!WindowInputScope.contains(child, root: panel))
}

@Test @MainActor func settingsEscapeHandlingLeavesModifierShortcutsAlone() throws {
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    let modified = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    #expect(WindowInputScope.isPlainEscape(escape))
    #expect(!WindowInputScope.isPlainEscape(modified))
}
