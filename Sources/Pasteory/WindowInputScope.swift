import AppKit

@MainActor
enum WindowInputScope {
    static func contains(_ window: NSWindow?, root: NSWindow) -> Bool {
        var candidate = window
        while let current = candidate {
            if current === root { return true }
            candidate = current.sheetParent ?? current.parent
        }
        return false
    }

    static func isPlainEscape(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 53
            && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
    }
}
