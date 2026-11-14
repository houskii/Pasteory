import Foundation
import Testing
@testable import PasteoryAI

func aiTestDoc(_ body: String = "Use an immutable change set.") -> AIClipDocument {
    AIClipDocument(id: UUID(), revision: UUID().uuidString, title: "Design", body: body, note: "Work project", copiedAt: Date())
}
func toolArguments(_ object: [String: JSONValue]) -> String { JSONValue.object(object).encoded }

@Test func toolsExposeAtomicCommandsRatherThanApplyPlan() {
    let names = Set(AIToolDefinition.all.map { $0.function.name })
    #expect(names.contains("groups_create"))
    #expect(names.contains("groups_add_items"))
    #expect(names.contains("summaries_set"))
    #expect(!names.contains("apply_plan"))
    #expect(!names.contains("shell"))
}

@Test func pagedBodyReadsKeepEvidenceFromEveryActuallyReadPage() throws {
    let a = aiTestDoc(String(repeating: "x", count: 3000) + "A late source quote."), b = aiTestDoc("A second source")
    var workspace = try AtomicWorkspace(documents: [a, b], writableIDs: [a.id, b.id], groups: [])
    _ = try workspace.initialDocuments([a.id, b.id], characterBudget: 2000)
    let page = try workspace.execute(name: "clips_get", arguments: toolArguments(["clip_ids": .array([.string(a.id.uuidString)]), "offset_chars": .number(3000), "max_chars": .number(200)]))
    #expect(page.array?.first?["body"].string == "A late source quote.")
    _ = try workspace.execute(name: "clips_get", arguments: toolArguments(["clip_ids": .array([.string(a.id.uuidString)]), "offset_chars": .number(0)]))
    let bundle = try workspace.execute(name: "aggregations_create", arguments: toolArguments(["title": .string("Sources"), "clip_ids": .array([.string(a.id.uuidString), .string(b.id.uuidString)])]))
    _ = try workspace.execute(name: "summaries_set", arguments: toolArguments([
        "target_id": bundle["aggregation_id"], "claims": .array([.object([
            "kind": .string("fact"), "text": .string("A quoted fact"), "evidence": .array([.object(["clip_id": .string(a.id.uuidString), "quote": .string("A late source quote.")])])
        ])])
    ]))
    #expect(try workspace.finish().commands.last?.kind == .setSummary)
    #expect(throws: AIError.self) { try workspace.execute(name: "clips_search", arguments: "{\"query\":\"x\",\"limit\":1e99}") }
}

@Test func creationReturnsAnIDThatSubsequentCallsCanUse() throws {
    let d = aiTestDoc()
    var w = try AtomicWorkspace(documents: [d], writableIDs: [d.id], groups: [])
    _ = try w.initialDocuments([d.id], characterBudget: 10_000)
    let result = try w.execute(name: "groups_create", arguments: toolArguments(["name": .string("API"), "definition": .string("HTTP integration")]))
    let id = try #require(result["group_id"].string)
    _ = try w.execute(name: "groups_add_items", arguments: toolArguments(["group_id": .string(id), "clip_ids": .array([.string(d.id.uuidString)])]))
    let cs = try w.finish()
    #expect(cs.commands.map(\.kind) == [.createGroup, .addItems])
    #expect(cs.commands[0].targetID == cs.commands[1].targetID)
    #expect(cs.clipRevisions[d.id] == d.revision)
}

@Test func historicalContextCannotBeAssignedAndExcludedMembersStayExcluded() throws {
    let recent = aiTestDoc(), history = aiTestDoc()
    var group = AIGroupProfile(name: "Test", definition: "A project")
    group.excludedClipIDs = [recent.id]
    var w = try AtomicWorkspace(documents: [recent, history], writableIDs: [recent.id], groups: [group])
    _ = try w.initialDocuments([recent.id, history.id], characterBudget: 10_000)
    let historical = toolArguments(["group_id": .string(group.id.uuidString), "clip_ids": .array([.string(history.id.uuidString)])])
    #expect(throws: AIError.self) { try w.execute(name: "groups_add_items", arguments: historical) }
    let excluded = toolArguments(["group_id": .string(group.id.uuidString), "clip_ids": .array([.string(recent.id.uuidString)])])
    #expect(throws: AIError.self) { try w.execute(name: "groups_add_items", arguments: excluded) }
    #expect(w.draft.commands.isEmpty)
}

@Test func manualMembershipCannotBeRemovedByModel() throws {
    let d = aiTestDoc()
    var g = AIGroupProfile(name: "Test", definition: "A project"); g.memberIDs = [d.id]
    var w = try AtomicWorkspace(documents: [d], writableIDs: [d.id], groups: [g])
    _ = try w.initialDocuments([d.id], characterBudget: 5000)
    #expect(throws: AIError.self) {
        try w.execute(name: "groups_remove_items", arguments: toolArguments(["group_id": .string(g.id.uuidString), "clip_ids": .array([.string(d.id.uuidString)])]))
    }
}

@Test func summaryEvidenceMustQuoteAnActuallyReadMember() throws {
    let first = aiTestDoc(), second = aiTestDoc("Use exact evidence.")
    var w = try AtomicWorkspace(documents: [first, second], writableIDs: [first.id, second.id], groups: [])
    _ = try w.initialDocuments([first.id, second.id], characterBudget: 10_000)
    let a = try w.execute(name: "aggregations_create", arguments: toolArguments(["title": .string("Implementation"), "clip_ids": .array([.string(first.id.uuidString), .string(second.id.uuidString)])]))
    let target = try #require(a["aggregation_id"].string)
    func summary(_ quote: String) -> String {
        toolArguments(["target_id": .string(target), "claims": .array([.object([
            "kind": .string("fact"), "text": .string("Changes must be immutable."),
            "evidence": .array([.object(["clip_id": .string(first.id.uuidString), "quote": .string(quote)])])
        ])])])
    }
    #expect(throws: AIError.self) { try w.execute(name: "summaries_set", arguments: summary("Fabricated quotation")) }
    _ = try w.execute(name: "summaries_set", arguments: summary("immutable change set"))
    #expect(try w.finish().commands.last?.kind == .setSummary)
}

@Test func emptyGroupsUnknownToolsAndStaleResumptionAreRejected() throws {
    let d = aiTestDoc()
    var w = try AtomicWorkspace(documents: [d], writableIDs: [d.id], groups: [])
    _ = try w.execute(name: "groups_create", arguments: toolArguments(["name": .string("Empty"), "definition": .string("No members yet")]))
    #expect(throws: AIError.self) { try w.finish() }
    #expect(throws: AIError.self) { try w.execute(name: "apply_plan", arguments: "{}") }
    var draft = AIChangeSet(); draft.clipRevisions[d.id] = "an older content version"
    #expect(throws: AIError.self) { try AtomicWorkspace(documents: [d], writableIDs: [d.id], groups: [], draft: draft) }
}
