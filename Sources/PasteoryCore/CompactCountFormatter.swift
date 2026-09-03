public enum CompactCountFormatter {
    public static func string(for count: Int) -> String {
        guard count >= 1_000 else { return String(count) }
        let roundedTenths = count / 100 + (count % 100 >= 50 ? 1 : 0)
        return "\(roundedTenths / 10).\(roundedTenths % 10)K"
    }
}
