import Foundation
import Testing
@testable import PasteoryCore

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

@Test func recognizesExplicitSourceCodePasteboardType() throws {
    let clip = try #require(makeTextClip(
        "let value = service.load()",
        uti: "public.swift-source",
        source: ClipSource(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", confidence: .high)
    ))
    #expect(clip.primaryKind == .code)
    #expect(clip.codeMetadata?.language == .swift)
    #expect(clip.codeMetadata?.confidence == 1)
}

@Test func recognizesCommonEditorCodeWithoutSourceCodeUTI() throws {
    let xcode = ClipSource(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", confidence: .high)
    let vscode = ClipSource(appName: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", confidence: .high)
    let androidStudio = ClipSource(appName: "Android Studio", bundleIdentifier: "com.google.android.studio", confidence: .high)

    let swift = try #require(makeTextClip("let value = service.load()\nprint(value)", source: xcode))
    #expect(swift.primaryKind == .code)
    #expect(swift.codeMetadata?.language == .swift)
    #expect(swift.codeMetadata?.totalLineCount == 2)

    let kotlin = try #require(makeTextClip("val value = repository.load()\nprintln(value)", source: androidStudio))
    #expect(kotlin.primaryKind == .code)
    #expect(kotlin.codeMetadata?.language == .kotlin)

    let python = try #require(makeTextClip("def load_value():\n    return service.load()", source: vscode))
    #expect(python.primaryKind == .code)
    #expect(python.codeMetadata?.language == .python)
}

@Test func separatesDeveloperFormatsAndNaturalLanguage() throws {
    let terminal = ClipSource(appName: "终端", bundleIdentifier: "com.apple.Terminal", confidence: .high)
    let shell = try #require(makeTextClip("git status", source: terminal))
    #expect(shell.primaryKind == .code)
    #expect(shell.codeMetadata?.subtype == .shellCommand)
    #expect(shell.codeMetadata?.language == .shell)

    let json = try #require(makeTextClip(#"{"name":"Pasteory","enabled":true}"#, uti: "public.json"))
    #expect(json.primaryKind == .code)
    #expect(json.codeMetadata?.subtype == .structuredData)
    #expect(json.codeMetadata?.language == .json)

    let prose = try #require(makeTextClip(
        "请检查 foo.bar() 为什么返回空值。",
        source: ClipSource(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", confidence: .high)
    ))
    #expect(prose.primaryKind == .text)
    #expect(prose.codeMetadata == nil)
}

@Test func limitsClassificationSampleForLargeCode() throws {
    let source = ClipSource(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", confidence: .high)
    let text = String(repeating: "func load() { return service.load() }\n", count: 3_000)
    let clip = try #require(makeTextClip(text, source: source))
    #expect(clip.primaryKind == .code)
    #expect(clip.codeMetadata?.language == .swift)
    #expect(clip.codeMetadata?.wasTruncatedForClassification == true)
    #expect((clip.codeMetadata?.analyzedCharacterCount ?? .max) <= 64 * 1_024)
    #expect(clip.codeMetadata?.totalLineCount == 3_000)
    #expect(clip.codeMetadata?.totalCharacterCount == text.trimmingCharacters(in: .whitespacesAndNewlines).count)
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
    let bundleSource = SmartRuleSet(conditions: [
        SmartCondition(field: .sourceApp, operation: .equals, value: "com.apple.Safari")
    ])
    #expect(try engine.matches(sourceClip, ruleSet: bundleSource))
    #expect(try !engine.matches(sourceClip, ruleSet: SmartRuleSet()))
}

private func makeTextClip(
    _ text: String,
    uti: String = "public.utf8-plain-text",
    source: ClipSource = ClipSource(appName: "测试", bundleIdentifier: "app.test", confidence: .high)
) -> Clip? {
    ClipClassifier.makeClip(from: PasteboardCapture(
        items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: uti, data: Data(text.utf8))])],
        source: source
    ))
}
