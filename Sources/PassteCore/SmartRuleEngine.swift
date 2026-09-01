import Foundation

public enum SmartRuleError: LocalizedError {
    case tooManyConditions, invalidRegularExpression, unsafeRegularExpression
    case unsupportedOperator(SmartRuleField, SmartRuleOperator)
    case invalidValue(SmartRuleField)
    public var errorDescription: String? {
        switch self {
        case .tooManyConditions: "智能分组最多包含 10 个条件"
        case .invalidRegularExpression: "正则表达式无效"
        case .unsafeRegularExpression: "正则表达式过长或复杂度过高"
        case .unsupportedOperator: "当前字段不支持这个判断条件"
        case .invalidValue(let field):
            switch field {
            case .createdAt: "时间必须填写大于或等于 0 的天数"
            case .byteSize: "大小必须填写大于或等于 0 的字节数"
            case .copyCount: "使用次数必须填写大于或等于 0 的整数"
            case .priority: "优先级必须是无、P1、P2 或 P3"
            case .favorite: "收藏状态无效"
            case .kind: "内容类型无效"
            case .sourceConfidence: "来源可信度无效"
            case .sourceApp: "请选择来源 App"
            case .title, .body, .note: "请输入匹配内容"
            }
        }
    }
}

public struct SmartRuleEngine: Sendable {
    public init() {}

    public func validate(_ ruleSet: SmartRuleSet) throws {
        guard ruleSet.conditions.count <= 10 else { throw SmartRuleError.tooManyConditions }
        for condition in ruleSet.conditions {
            guard condition.field.supportedOperators.contains(condition.operation) else {
                throw SmartRuleError.unsupportedOperator(condition.field, condition.operation)
            }
            try validateValue(condition)
            if condition.operation == .matchesRegex {
                guard condition.value.count <= 512,
                      !condition.value.contains(".*.*"),
                      !condition.value.contains("++"),
                      !condition.value.contains("**") else { throw SmartRuleError.unsafeRegularExpression }
                do { _ = try NSRegularExpression(pattern: condition.value, options: [.caseInsensitive]) }
                catch { throw SmartRuleError.invalidRegularExpression }
            }
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
            if condition.field == .sourceApp {
                return clip.source.appName.compare(condition.value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ||
                    clip.source.bundleIdentifier?.compare(condition.value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
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

    private func validateValue(_ condition: SmartCondition) throws {
        switch condition.field {
        case .title, .body, .note, .sourceApp:
            guard !condition.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SmartRuleError.invalidValue(condition.field)
            }
        case .sourceConfidence:
            guard SourceConfidence(rawValue: condition.value) != nil else { throw SmartRuleError.invalidValue(condition.field) }
        case .kind:
            guard ClipKind(rawValue: condition.value) != nil else { throw SmartRuleError.invalidValue(condition.field) }
        case .createdAt, .byteSize:
            guard let value = Double(condition.value), value >= 0 else { throw SmartRuleError.invalidValue(condition.field) }
        case .priority:
            guard let value = Int(condition.value), (0...3).contains(value) else { throw SmartRuleError.invalidValue(condition.field) }
        case .favorite:
            guard condition.value == "true" || condition.value == "false" else { throw SmartRuleError.invalidValue(condition.field) }
        case .copyCount:
            guard let value = Int(condition.value), value >= 0 else { throw SmartRuleError.invalidValue(condition.field) }
        }
    }
}
