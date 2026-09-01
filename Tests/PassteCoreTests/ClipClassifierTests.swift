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
