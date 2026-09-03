public enum QuickSearchReturnDisposition: Equatable, Sendable {
    case confirmMarkedText
    case performShortcut
    case consume
}

public enum QuickSearchInputPolicy {
    public static func returnDisposition(
        hasMarkedText: Bool,
        hasConfiguredShortcut: Bool
    ) -> QuickSearchReturnDisposition {
        if hasMarkedText { return .confirmMarkedText }
        if hasConfiguredShortcut { return .performShortcut }
        return .consume
    }
}
