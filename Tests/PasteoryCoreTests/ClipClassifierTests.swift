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

@Test func textIdentityIgnoresOuterWhitespaceAndRichTextRepresentations() throws {
    let source = ClipSource(appName: "Chrome", bundleIdentifier: "com.google.Chrome", confidence: .high)
    let plain = PasteboardCapture(items: [CapturedItem(order: 0, representations: [
        CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("4.4.93-alpha.0".utf8)),
        CapturedRepresentation(uti: "public.html", data: Data("<span>4.4.93-alpha.0</span>".utf8))
    ])], source: source)
    let styled = PasteboardCapture(items: [CapturedItem(order: 0, representations: [
        CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(" \n4.4.93-alpha.0\t".utf8)),
        CapturedRepresentation(uti: "public.html", data: Data("<span class='diff-line'>4.4.93-alpha.0</span>".utf8))
    ])], source: source)

    let first = try #require(ClipClassifier.makeClip(from: plain))
    let second = try #require(ClipClassifier.makeClip(from: styled))
    #expect(first.primaryKind == .text)
    #expect(first.identityKey == second.identityKey)
    #expect(first.contentHash != second.contentHash)

    let internalWhitespace = try #require(makeTextClip("4.4.93 - alpha.0"))
    #expect(first.identityKey != internalWhitespace.identityKey)
}

@Test func codeAndColorIdentityUseTheTrimmedTextRule() throws {
    let terminal = ClipSource(appName: "终端", bundleIdentifier: "com.apple.Terminal", confidence: .high)
    let code = try #require(makeTextClip("git status", source: terminal))
    let paddedCode = try #require(makeTextClip("\n git status \t", source: terminal))
    #expect(code.primaryKind == .code)
    #expect(code.identityKey == paddedCode.identityKey)

    let color = try #require(makeTextClip("#7C3AED"))
    let paddedColor = try #require(makeTextClip("  #7C3AED\n"))
    #expect(color.primaryKind == .color)
    #expect(color.identityKey == paddedColor.identityKey)
}

@Test func linkIdentityUsesHostAndWholePathButIgnoresQueryAndFragment() throws {
    let first = try #require(makeTextClip(
        "https://bits.bytedance.net/devops/1486828802/code/detail/8390888?devops_space_type=client"
    ))
    let second = try #require(makeTextClip(
        "https://bits.bytedance.net/devops/1486828802/code/detail/8390888?tab=changes#diff"
    ))
    let otherPath = try #require(makeTextClip(
        "https://bits.bytedance.net/devops/1486828802/code/detail/8296613?tab=changes"
    ))
    #expect(first.primaryKind == .link)
    #expect(first.identityKey == second.identityKey)
    #expect(first.identityKey != otherPath.identityKey)
}

@Test func imageAndFileIdentityUseContentMD5() throws {
    let source = ClipSource(appName: "测试", bundleIdentifier: "app.test", confidence: .high)
    let firstImage = try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [
        CapturedItem(order: 0, representations: [
            CapturedRepresentation(uti: "public.png", data: Data([1, 2, 3])),
            CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("first label".utf8))
        ])
    ], source: source)))
    let secondImage = try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [
        CapturedItem(order: 0, representations: [
            CapturedRepresentation(uti: "public.png", data: Data([1, 2, 3])),
            CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("second label".utf8))
        ])
    ], source: source)))
    #expect(firstImage.primaryKind == .image)
    #expect(firstImage.identityKey == secondImage.identityKey)
    #expect(firstImage.contentHash != secondImage.contentHash)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryIdentity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("first.hap")
    let secondURL = root.appendingPathComponent("second.hap")
    try Data("same file bytes".utf8).write(to: firstURL)
    try Data("same file bytes".utf8).write(to: secondURL)
    let makeFileClip: (URL) -> Clip? = { url in
        ClipClassifier.makeClip(from: PasteboardCapture(items: [
            CapturedItem(order: 0, representations: [
                CapturedRepresentation(uti: "public.file-url", data: Data(url.absoluteString.utf8))
            ])
        ], source: source))
    }
    let firstFile = try #require(makeFileClip(firstURL))
    let secondFile = try #require(makeFileClip(secondURL))
    #expect(firstFile.primaryKind == .file)
    #expect(firstFile.identityKey == secondFile.identityKey)
}

@Test func multipleFilesKeepEveryNameAcrossFinderPasteboardShapes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryMultiFile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("first.hap")
    let secondURL = root.appendingPathComponent("second.txt")
    try Data("hap bytes".utf8).write(to: firstURL)
    try Data("text bytes".utf8).write(to: secondURL)
    let source = ClipSource(appName: "访达", bundleIdentifier: "com.apple.finder", confidence: .high)

    let filenamesData = try PropertyListSerialization.data(
        fromPropertyList: [firstURL.path, secondURL.path],
        format: .binary,
        options: 0
    )
    let bundled = try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [
        CapturedItem(order: 0, representations: [
            CapturedRepresentation(uti: "NSFilenamesPboardType", data: filenamesData)
        ])
    ], source: source)))
    let separate = try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [
        CapturedItem(order: 0, representations: [
            CapturedRepresentation(uti: "public.file-url", data: Data(firstURL.absoluteString.utf8))
        ]),
        CapturedItem(order: 1, representations: [
            CapturedRepresentation(uti: "public.file-url", data: Data(secondURL.absoluteString.utf8))
        ])
    ], source: source)))

    #expect(bundled.primaryKind == .file)
    #expect(bundled.previewText == "2 files")
    #expect(bundled.fileMetadata?.fileNames == ["first.hap", "second.txt"])
    #expect(bundled.fileMetadata?.filePaths == [firstURL.path, secondURL.path])
    #expect(bundled.identityKey == separate.identityKey)
    #expect(separate.fileMetadata?.namesSummary == "first.hap, second.txt")

    var legacy = bundled
    legacy.fileMetadata = nil
    #expect(legacy.effectiveFileMetadata?.fileCount == 2)
    #expect(legacy.effectiveFileMetadata?.displayName == "2 files")
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

@Test func smartRulesSupportNestedAnyAndAllGroups() throws {
    let engine = SmartRuleEngine()
    let rules = SmartRuleSet(
        mode: .any,
        conditions: [SmartCondition(field: .favorite, operation: .equals, value: "true")],
        groups: [
            SmartRuleGroup(
                mode: .all,
                conditions: [
                    SmartCondition(field: .kind, operation: .equals, value: ClipKind.code.rawValue),
                    SmartCondition(field: .body, operation: .contains, value: "Pasteory")
                ]
            )
        ]
    )

    let favoriteText = smartRuleClip(body: "普通文本", kind: .text, favorite: true)
    let matchingCode = smartRuleClip(body: "struct PasteoryApp {}", kind: .code)
    let unrelatedCode = smartRuleClip(body: "struct OtherApp {}", kind: .code)

    #expect(try engine.matches(favoriteText, ruleSet: rules))
    #expect(try engine.matches(matchingCode, ruleSet: rules))
    #expect(try !engine.matches(unrelatedCode, ruleSet: rules))
}

@Test func smartRuleSetDecodesLegacyFlatConfiguration() throws {
    let conditionID = UUID()
    let data = Data("""
        {
          "mode": "any",
          "conditions": [
            {
              "id": "\(conditionID.uuidString)",
              "field": "body",
              "operation": "contains",
              "value": "Pasteory"
            }
          ]
        }
        """.utf8)

    let decoded = try JSONDecoder().decode(SmartRuleSet.self, from: data)
    #expect(decoded.mode == .any)
    #expect(decoded.conditions.count == 1)
    #expect(decoded.conditions[0].id == conditionID)
    #expect(decoded.groups.isEmpty)
    #expect(try SmartRuleEngine().matches(smartRuleClip(body: "Pasteory"), ruleSet: decoded))
}

@Test func smartRuleSetPreservesNestedGroupsWhenEncoded() throws {
    let original = SmartRuleSet(
        mode: .all,
        conditions: [SmartCondition(field: .favorite, operation: .equals, value: "true")],
        groups: [
            SmartRuleGroup(
                mode: .any,
                conditions: [SmartCondition(field: .body, operation: .contains, value: "Swift")],
                groups: [
                    SmartRuleGroup(
                        mode: .all,
                        conditions: [SmartCondition(field: .note, operation: .equals, value: "保留")]
                    )
                ]
            )
        ]
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SmartRuleSet.self, from: data)
    #expect(decoded == original)
}

@Test func smartRulePreviewReturnsEveryMatchingItem() throws {
    let clips = (0..<25).map { smartRuleClip(body: "Pasteory \($0)") }
    let rules = SmartRuleSet(conditions: [
        SmartCondition(field: .body, operation: .contains, value: "Pasteory")
    ])

    let preview = try SmartRuleEngine().preview(clips, ruleSet: rules)
    #expect(preview.count == 25)
    #expect(preview.items.count == 25)
}

@Test func smartRulesRejectGroupsBeyondMaximumDepth() {
    var group = SmartRuleGroup(conditions: [
        SmartCondition(field: .body, operation: .contains, value: "Pasteory")
    ])
    for _ in 0..<SmartRuleEngine.maximumNestingDepth {
        group = SmartRuleGroup(groups: [group])
    }
    let rules = SmartRuleSet(groups: [group])

    #expect(throws: SmartRuleError.self) {
        try SmartRuleEngine().validate(rules)
    }
}

private func smartRuleClip(
    body: String,
    kind: ClipKind = .text,
    favorite: Bool = false
) -> Clip {
    Clip(
        primaryKind: kind,
        isFavorite: favorite,
        source: ClipSource(appName: "测试", bundleIdentifier: "app.test", confidence: .high),
        previewText: body,
        contentHash: UUID().uuidString,
        byteSize: body.utf8.count,
        items: []
    )
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
