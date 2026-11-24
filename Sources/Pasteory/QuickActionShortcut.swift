import Carbon
import SwiftUI

extension View {
    @ViewBuilder
    func quickActionShortcut(_ shortcut: PasteoryShortcut?) -> some View {
        if let shortcut, let key = shortcut.keyEquivalent {
            keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}

extension PasteoryShortcut {
    var eventModifiers: SwiftUI.EventModifiers {
        var value: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { value.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { value.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { value.insert(.shift) }
        if modifiers & UInt32(controlKey) != 0 { value.insert(.control) }
        return value
    }

    var keyEquivalent: KeyEquivalent? {
        let characters: [UInt32: Character] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'",
            40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`"
        ]
        if let character = characters[keyCode] { return KeyEquivalent(character) }
        switch keyCode {
        case 36, 76: return .return
        case 125: return .downArrow
        case 126: return .upArrow
        case 48: return .tab
        case 49: return .space
        case 51: return .delete
        case 53: return .escape
        default: return nil
        }
    }
}
