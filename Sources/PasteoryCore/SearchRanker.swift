import Foundation

public enum SearchRanker {
    public static func rank(_ clips: [Clip], query: String) -> [Clip] {
        let needle = normalize(query)
        // Calculate expensive text scores once per result, rather than twice
        // on every sorting comparison.
        let scored = clips.map { (clip: $0, score: needle.isEmpty ? 0 : score($0, needle: needle)) }
        return scored.sorted { left, right in
            let lhs = left.clip, rhs = right.clip
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if left.score != right.score { return left.score > right.score }
            if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.map(\.clip)
    }

    private static func score(_ clip: Clip, needle: String) -> Double {
        let fields = [clip.displayTitle, clip.previewText + "\n" + clip.recognizedImageText, clip.note, clip.source.appName].map(normalize)
        var score = 0.0
        for (index, field) in fields.enumerated() {
            let weight = [8.0, 5.0, 4.0, 2.0][index]
            if field == needle { score += 20 * weight }
            else if field.hasPrefix(needle) { score += 10 * weight }
            else if field.contains(needle) { score += 5 * weight }
            else { score += max(0, 1 - normalizedDistance(field, needle)) * weight }
        }
        score += clip.isFavorite ? 5 : 0
        score += Double(clip.priority) * 2
        score += min(log2(Double(max(1, clip.copyCount))), 5)
        return score
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedDistance(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs.prefix(256)), b = Array(rhs.prefix(256))
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(max(a.count, b.count, 1))
    }
}
