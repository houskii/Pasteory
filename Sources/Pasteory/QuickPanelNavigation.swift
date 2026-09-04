enum QuickPanelNavigation {
    static func scopeOffset(
        forKeyCode keyCode: UInt16,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> Int? {
        guard !command, !shift, !option, !control else { return nil }
        switch keyCode {
        case 123: return -1
        case 124: return 1
        default: return nil
        }
    }

    static func wrappedIndex(current: Int, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let normalizedCurrent = min(max(current, 0), count - 1)
        return (normalizedCurrent + (offset % count) + count) % count
    }
}
