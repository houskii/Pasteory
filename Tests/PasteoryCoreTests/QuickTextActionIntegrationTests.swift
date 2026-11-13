import AppKit
import Foundation
import Testing
@testable import Pasteory
@testable import PasteoryCore

private func quickActionDirectories() throws -> AppDirectories {
    try AppDirectories(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("PasteoryQuickAction-\(UUID().uuidString)", isDirectory: true))
}

private func quickActionSource(_ text: String) throws -> Clip {
    try #require(ClipClassifier.makeClip(from: PasteboardCapture(
        items: [CapturedItem(order: 0, representations: [
            CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))
        ])],
        source: ClipSource(appName: "测试编辑器", bundleIdentifier: "test.editor", confidence: .high)
    )))
}

private func quickActionRule(_ value: String) -> SmartRuleSet {
    SmartRuleSet(conditions: [SmartCondition(field: .quickTextAction, operation: .equals, value: value)])
}

@Test func updateCanOpenLibraryWithoutNormalizingExistingData() async throws {
    let directories = try quickActionDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let initial = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let rule = URLFallbackRule(
        name: "存量规则", hostPattern: "example.com", pathTemplate: "/item/{id}",
        requiredQueryKeys: ["unused"], titleTemplate: "{{path.id}}"
    )
    try await initial.saveFallbackRule(rule)
    let before = try #require(try await initial.userFallbackRules().first)
    let skipped = try SQLiteClipRepository(databaseURL: directories.databaseFile, normalizeExistingData: false)
    #expect(try await skipped.userFallbackRules().first == before)
    let normalized = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    #expect(try await normalized.userFallbackRules().first?.requiredQueryKeys == [])
}

@Test @MainActor func quickActionCopiesFullResultAndPersistsOriginalAndSource() async throws {
    let directories = try quickActionDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let attachments = AttachmentStore(directories: directories, threshold: 1)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let coordinator = QuickTextActionCoordinator(repository: repository, attachments: attachments, pasteboard: pasteboard)
    let input = String(repeating: "保留完整原文 🌈\n", count: 500)
    let original = try quickActionSource(input)
    try await repository.save(original)
    let originalBefore = try #require(try await repository.clip(id: original.id))

    let result = try await coordinator.perform(.base64Encode, input: input, sourceClip: original)
    let expected = Data(input.utf8).base64EncodedString()
    #expect(result.output == expected)
    #expect(pasteboard.string(forType: .string) == expected)
    let stored = try #require(try await repository.clip(id: result.clip.id))
    #expect(try await ClipTextReader.read(stored, attachments: attachments) == expected)
    #expect(stored.note == "\(input) (Base64 Encoded)\nSource: 测试编辑器")
    #expect(stored.quickTextTransformations?.first?.originalText == input)
    #expect(stored.quickTextTransformations?.first?.sourceClipID == original.id)
    #expect(stored.quickTextTransformations?.first?.source == original.source)
    #expect(try await repository.clip(id: original.id) == originalBefore)
    #expect(try await repository.captureEvents(for: stored.id, limit: 10).count == 1)
    #expect(try await repository.allClips().count == 2)

    let repeated = try await coordinator.perform(.base64Encode, input: input, sourceClip: original)
    #expect(repeated.clip.id == result.clip.id)
    #expect(repeated.clip.quickTextTransformations?.count == 1)
    #expect(repeated.clip.note == stored.note)
    #expect(try await repository.allClips().count == 2)
}

@Test @MainActor func quickActionFailureDoesNotChangeClipboardOrLibrary() async throws {
    let directories = try quickActionDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("保留当前剪贴板", forType: .string)
    let changeCount = pasteboard.changeCount
    let coordinator = QuickTextActionCoordinator(
        repository: repository, attachments: AttachmentStore(directories: directories), pasteboard: pasteboard
    )
    await #expect(throws: QuickTextActionError.self) {
        try await coordinator.perform(.base64Decode, input: "invalid%", sourceClip: nil)
    }
    #expect(pasteboard.string(forType: .string) == "保留当前剪贴板")
    #expect(pasteboard.changeCount == changeCount)
    #expect(try await repository.allClips().isEmpty)

    let empty = try await coordinator.perform(.base64Encode, input: "", sourceClip: nil)
    #expect(empty.output == "")
    #expect(pasteboard.string(forType: .string) == "")
    #expect(empty.clip.note == " (Base64 Encoded)\nSource: Manual Input")
    #expect(try await repository.allClips().count == 1)
}

@Test func quickActionDeduplicationKeepsUserNotesAndAllConversionTypes() async throws {
    let directories = try quickActionDirectories()
    defer { try? FileManager.default.removeItem(at: directories.root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let source = try quickActionSource("hello")
    var existing = try quickActionSource("aGVsbG8=")
    existing.note = "用户原有备注"
    existing.isFavorite = true
    try await repository.save(existing)
    let base64 = try QuickTextAction.base64Encode.makeResultClip(input: "hello", sourceClip: source, source: source.source)
    let first = try await repository.saveCaptured(base64)
    #expect(first.id == existing.id)
    #expect(first.note == "用户原有备注\n\nhello (Base64 Encoded)\nSource: 测试编辑器")
    #expect(first.isFavorite)

    let url = try QuickTextAction.urlDecode.makeResultClip(input: "aGVsbG8%3D", sourceClip: nil, source: source.source)
    let second = try await repository.saveCaptured(url)
    #expect(second.id == existing.id)
    #expect(second.quickTextTransformations?.map(\.action) == [.base64Encode, .urlDecode])
    #expect(second.note.hasPrefix(first.note))
    #expect(second.note.hasSuffix("aGVsbG8%3D (URL Decoded)\nSource: Manual Input"))

    let copiedAgain = try await repository.saveCaptured(quickActionSource("aGVsbG8="))
    #expect(copiedAgain.quickTextTransformations == second.quickTextTransformations)
    #expect(copiedAgain.note == second.note)
    #expect(try await repository.allClips().count == 1)
    let engine = SmartRuleEngine()
    #expect(try engine.matches(copiedAgain, ruleSet: quickActionRule("any")))
    #expect(try engine.matches(copiedAgain, ruleSet: quickActionRule("base64Encode")))
    #expect(try engine.matches(copiedAgain, ruleSet: quickActionRule("urlDecode")))
    #expect(try !engine.matches(copiedAgain, ruleSet: quickActionRule("md5")))
    #expect(try !engine.matches(copiedAgain, ruleSet: quickActionRule("none")))
}

@Test func quickActionRulesUseMetadataAndSupportLegacyClipsWithoutBackfill() throws {
    var original = try quickActionSource("hello")
    original.note = "hello（Base64 编码后）"
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "quickTextTransformations")
    let legacy = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.quickTextTransformations == nil)
    let engine = SmartRuleEngine()
    #expect(try engine.matches(legacy, ruleSet: quickActionRule("none")))
    #expect(try !engine.matches(legacy, ruleSet: quickActionRule("any")))

    for action in QuickTextAction.allCases {
        var converted = original
        converted.note = "用户改写过备注"
        converted.quickTextTransformations = [QuickTextTransformation(action: action, originalText: "hello")]
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(converted))
        #expect(try engine.matches(decoded, ruleSet: quickActionRule(action.rawValue)))
    }
    #expect(throws: SmartRuleError.self) { try engine.validate(quickActionRule("unknown-tool")) }
    #expect(throws: SmartRuleError.self) {
        try engine.validate(SmartRuleSet(conditions: [SmartCondition(field: .quickTextAction, operation: .contains, value: "any")]))
    }
    let nested = SmartRuleSet(mode: .all, conditions: [
        SmartCondition(field: .sourceApp, operation: .equals, value: "test.editor")
    ], groups: [SmartRuleGroup(mode: .any, conditions: [
        SmartCondition(field: .quickTextAction, operation: .equals, value: "md5"),
        SmartCondition(field: .quickTextAction, operation: .equals, value: "base64Encode")
    ])])
    var converted = original
    converted.quickTextTransformations = [QuickTextTransformation(action: .base64Encode, originalText: "hello")]
    #expect(try engine.preview([legacy, converted], ruleSet: nested).items.map(\.id) == [converted.id])
}
