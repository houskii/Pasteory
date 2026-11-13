import Foundation

public enum SmartRuleError: LocalizedError {
    case tooManyConditions, tooManyNestedLevels, emptyRuleGroup
    case invalidRegularExpression, unsafeRegularExpression
    case unsupportedOperator(SmartRuleField, SmartRuleOperator)
    case invalidValue(SmartRuleField)
    public var errorDescription: String? {
        switch self {
        case .tooManyConditions: "一个智能分组最多包含 50 个条件"
        case .tooManyNestedLevels: "规则组最多可以嵌套 5 层"
        case .emptyRuleGroup: "子规则组至少需要一个条件或规则组"
        case .invalidRegularExpression: "正则表达式无效"
        case .unsafeRegularExpression: "正则表达式过长或复杂度过高"
        case .unsupportedOperator: "当前字段不支持这个判断条件"
        case .invalidValue(let field):
            switch field {
            case .createdAt: "时间必须填写大于或等于 0 的天数"
            case .byteSize: "大小必须填写大于或等于 0 的字节数"
            case .copyCount: "复制次数必须填写大于或等于 0 的整数"
            case .priority: "优先级必须是无、P1、P2 或 P3"
            case .favorite: "收藏状态无效"
            case .kind: "内容类型无效"
            case .sourceConfidence: "来源可信度无效"
            case .sourceApp: "请选择来源 App"
            case .quickTextAction: "请选择快捷工具转换类型"
            case .title, .body, .note: "请输入匹配内容"
            }
        }
    }
}

public struct SmartRuleEngine: Sendable {
    public static let maximumConditionCount = 50
    public static let maximumNestingDepth = 5

    public init() {}

    public func validate(_ ruleSet: SmartRuleSet) throws {
        guard conditionCount(in: ruleSet) <= Self.maximumConditionCount else {
            throw SmartRuleError.tooManyConditions
        }
        try validate(
            conditions: ruleSet.conditions,
            groups: ruleSet.groups,
            depth: 1
        )
    }

    private func validate(
        conditions: [SmartCondition],
        groups: [SmartRuleGroup],
        depth: Int
    ) throws {
        guard depth <= Self.maximumNestingDepth else { throw SmartRuleError.tooManyNestedLevels }
        for condition in conditions {
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
        for group in groups {
            guard !group.conditions.isEmpty || !group.groups.isEmpty else {
                throw SmartRuleError.emptyRuleGroup
            }
            try validate(conditions: group.conditions, groups: group.groups, depth: depth + 1)
        }
    }

    public func matches(_ clip: Clip, ruleSet: SmartRuleSet, now: Date = Date()) throws -> Bool {
        try validate(ruleSet)
        return try matches(
            clip,
            mode: ruleSet.mode,
            conditions: ruleSet.conditions,
            groups: ruleSet.groups,
            now: now
        )
    }

    public func preview(_ clips: [Clip], ruleSet: SmartRuleSet, now: Date = Date()) throws -> (items: [Clip], count: Int) {
        let matchingItems = try matchingItems(in: clips, ruleSet: ruleSet, now: now)
        return (matchingItems, matchingItems.count)
    }

    public func matchingItems(in clips: [Clip], ruleSet: SmartRuleSet, now: Date = Date()) throws -> [Clip] {
        try validate(ruleSet)
        return try clips.filter {
            try matches(
                $0,
                mode: ruleSet.mode,
                conditions: ruleSet.conditions,
                groups: ruleSet.groups,
                now: now
            )
        }
    }

    private func matches(
        _ clip: Clip,
        mode: RuleMatchMode,
        conditions: [SmartCondition],
        groups: [SmartRuleGroup],
        now: Date
    ) throws -> Bool {
        guard !conditions.isEmpty || !groups.isEmpty else { return false }
        var results = try conditions.map { try matches(clip, condition: $0, now: now) }
        results += try groups.map { group in
            try matches(
                clip,
                mode: group.mode,
                conditions: group.conditions,
                groups: group.groups,
                now: now
            )
        }
        return mode == .all ? results.allSatisfy { $0 } : results.contains(true)
    }

    private func conditionCount(in ruleSet: SmartRuleSet) -> Int {
        ruleSet.conditions.count + ruleSet.groups.reduce(0) { $0 + conditionCount(in: $1) }
    }

    private func conditionCount(in group: SmartRuleGroup) -> Int {
        group.conditions.count + group.groups.reduce(0) { $0 + conditionCount(in: $1) }
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
        case .quickTextAction:
            let actions = clip.quickTextTransformations?.map(\.action) ?? []
            switch condition.value {
            case "any": return !actions.isEmpty
            case "none": return actions.isEmpty
            default: return actions.contains { $0.rawValue == condition.value }
            }
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
        case .quickTextAction:
            guard ["any", "none"].contains(condition.value) || QuickTextAction(rawValue: condition.value) != nil else {
                throw SmartRuleError.invalidValue(condition.field)
            }
        }
    }
}
