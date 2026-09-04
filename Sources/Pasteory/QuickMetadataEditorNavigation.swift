import Foundation

enum QuickMetadataEditorField: Hashable {
    case title
    case note
    case collections
}

enum QuickMetadataEditorKeyCommand: Equatable {
    case moveFocus(id: UUID, backwards: Bool)
    case moveCollection(id: UUID, offset: Int)
    case toggleCollection(id: UUID)
}

enum QuickMetadataEditorKeyboardAction: Equatable {
    case moveFocus(backwards: Bool)
    case moveCollection(offset: Int)
    case toggleCollection
    case commit
    case dismiss
    case passThrough
}

enum QuickMetadataEditorNavigation {
    static func keyboardAction(
        keyCode: UInt16,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        focusedField: QuickMetadataEditorField,
        hasMarkedText: Bool
    ) -> QuickMetadataEditorKeyboardAction {
        if keyCode == 53 || (keyCode == 13 && command) { return .dismiss }
        if keyCode == 36 || keyCode == 76 {
            return hasMarkedText ? .passThrough : .commit
        }
        if keyCode == 48, !command, !option, !control {
            return .moveFocus(backwards: shift)
        }
        guard focusedField == .collections, !command, !option, !control else { return .passThrough }
        switch keyCode {
        case 125: return .moveCollection(offset: 1)
        case 126: return .moveCollection(offset: -1)
        case 49 where !shift: return .toggleCollection
        default: return .passThrough
        }
    }

    static func nextField(
        from field: QuickMetadataEditorField,
        backwards: Bool,
        hasCollections: Bool
    ) -> QuickMetadataEditorField {
        let fields: [QuickMetadataEditorField] = hasCollections
            ? [.title, .note, .collections]
            : [.title, .note]
        guard let index = fields.firstIndex(of: field) else { return fields[0] }
        let offset = backwards ? -1 : 1
        return fields[(index + offset + fields.count) % fields.count]
    }

    static func nextCollection(
        in collectionIDs: [UUID],
        currentID: UUID?,
        offset: Int
    ) -> UUID? {
        guard !collectionIDs.isEmpty else { return nil }
        guard let currentID, let current = collectionIDs.firstIndex(of: currentID) else {
            return offset < 0 ? collectionIDs.last : collectionIDs.first
        }
        return collectionIDs[min(max(current + offset, 0), collectionIDs.count - 1)]
    }

    static func toggled(_ id: UUID, in selection: Set<UUID>) -> Set<UUID> {
        var result = selection
        if result.remove(id) == nil { result.insert(id) }
        return result
    }
}
