import Foundation
import Testing
@testable import PassteCore

@Test func recognizesColorOnlyOnWholeString() {
    #expect(ClipClassifier.isColor("#7C3AED"))
    #expect(ClipClassifier.isColor("rgb(124, 58, 237)"))
    #expect(!ClipClassifier.isColor("颜色是 #7C3AED"))
}

@Test func capturesMultipleItemsAndUsesStableHash() {
    let source = ClipSource(appName: "测试", bundleIdentifier: "app.test", processIdentifier: 1, confidence: .high)
    let capture = PasteboardCapture(items: [
        CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("hello".utf8))]),
        CapturedItem(order: 1, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("world".utf8))])
    ], source: source)
    let first = ClipClassifier.makeClip(from: capture)
    let second = ClipClassifier.makeClip(from: capture)
    #expect(first?.items.count == 2)
    #expect(first?.contentHash == second?.contentHash)
}

@Test func validatesSmartRuleRegex() throws {
    let engine = SmartRuleEngine()
    let valid = SmartRuleSet(conditions: [SmartCondition(field: .body, operation: .matchesRegex, value: "git\\s+(pull|push)")])
    try engine.validate(valid)
    let invalid = SmartRuleSet(conditions: [SmartCondition(field: .body, operation: .matchesRegex, value: "[")])
    #expect(throws: SmartRuleError.self) { try engine.validate(invalid) }
}

@Test func smartRulesRejectOperatorsThatDoNotMatchFieldType() throws {
    let engine = SmartRuleEngine()
    let invalidSource = SmartRuleSet(conditions: [SmartCondition(field: .sourceApp, operation: .before, value: "7")])
    #expect(throws: SmartRuleError.self) { try engine.validate(invalidSource) }

    let validSource = SmartRuleSet(conditions: [SmartCondition(field: .sourceApp, operation: .equals, value: "Safari")])
    try engine.validate(validSource)

    let validTime = SmartRuleSet(conditions: [SmartCondition(field: .createdAt, operation: .after, value: "7")])
    try engine.validate(validTime)

    let sourceClip = Clip(
        primaryKind: .text,
        source: ClipSource(appName: "Safari", bundleIdentifier: "com.apple.Safari", confidence: .high),
        previewText: "example",
        contentHash: "source-rule-test",
        byteSize: 7,
        items: []
    )
    #expect(try engine.matches(sourceClip, ruleSet: validSource))
}
