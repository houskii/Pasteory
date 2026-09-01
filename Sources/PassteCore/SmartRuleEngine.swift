import Foundation

public enum SmartRuleError: LocalizedError {
    case tooManyConditions, invalidRegularExpression, unsafeRegularExpression
    public var errorDescription: String? {
        switch self {
        case .tooManyConditions: "智能分组最多包含 10 个条件"
        case .invalidRegularExpression: "正则表达式无效"
        case .unsafeRegularExpression: "正则表达式过长或复杂度过高"
        }
    }
}

public struct SmartRuleEngine: Sendable {
    public init() {}

    public func validate(_ ruleSet: SmartRuleSet) throws {
        guard ruleSet.conditions.count <= 10 else { throw SmartRuleError.tooManyConditions }
        for condition in ruleSet.conditions where condition.operation == .matchesRegex {
            guard condition.value.count <= 512,
                  !condition.value.contains(".*.*"),
                  !condition.value.contains("++"),
                  !condition.value.contains("**") else { throw SmartRuleError.unsafeRegularExpression }
            do { _ = try NSRegularExpression(pattern: condition.value, options: [.caseInsensitive]) }
            catch { throw SmartRuleError.invalidRegularExpression }
        }
    }

    public func matches(_ clip: Clip, ruleSet: SmartRuleSet, now: Date = Date()) throws -> Bool {
        try validate(ruleSet)
        guard !ruleSet.conditions.isEmpty else { return true }
        let results = try ruleSet.conditions.map { try matches(clip, condition: $0, now: now) }
        return ruleSet.mode == .all ? results.allSatisfy { $0 } : results.contains(true)
    }

    public func preview(_ clips: [Clip], ruleSet: SmartRuleSet, now: Date = Date()) throws -> (items: [Clip], count: Int) {
        let matches = try clips.filter { try self.matches($0, ruleSet: ruleSet, now: now) }
        return (Array(matches.prefix(20)), matches.count)
    }

    private func matches(_ clip: Clip, condition: SmartCondition, now: Date) throws -> Bool {
        let string: String
        let number: Double?
        switch condition.field {
        case .sourceApp: string = [clip.source.appName, clip.source.bundleIdentifier ?? ""].joined(separator: " "); number = nil
        case .sourceConfidence: string = clip.source.confidence.rawValue; number = nil
        case .createdAt: string = ISO8601DateFormatter().string(from: clip.createdAt); number = clip.createdAt.timeIntervalSince1970
        case .kind: string = clip.primaryKind.rawValue; number = nil
        case .title: string = clip.title; number = nil
        case .body: string = clip.previewText; number = nil
        case .note: string = clip.note; number = nil
        case .byteSize: string = String(clip.byteSize); number = Double(clip.byteSize)
        case .priority: string = String(clip.priority); number = Double(clip.priority)
        case .favorite: string = clip.isFavorite ? "true" : "false"; number = clip.isFavorite ? 1 : 0
        case .copyCount: string = String(clip.copyCount); number = Double(clip.copyCount)
        }
        switch condition.operation {
        case .contains:
            return string.localizedCaseInsensitiveContains(condition.value)
        case .equals:
            return string.compare(condition.value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        case .matchesRegex:
            let regex = try NSRegularExpression(pattern: condition.value, options: [.caseInsensitive])
            return regex.firstMatch(in: string, range: NSRange(string.startIndex..<string.endIndex, in: string)) != nil
        case .greaterThan:
            guard let number, let target = Double(condition.value) else { return false }
            return number > target
        case .lessThan:
            guard let number, let target = Double(condition.value) else { return false }
            return number < target
        case .before, .after:
            let target = dateValue(condition.value, now: now)
            guard let target else { return false }
            return condition.operation == .before ? clip.createdAt < target : clip.createdAt > target
        }
    }

    private func dateValue(_ value: String, now: Date) -> Date? {
        if let days = Double(value) { return Calendar.current.date(byAdding: .second, value: -Int(days * 86_400), to: now) }
        return ISO8601DateFormatter().date(from: value)
    }
}
