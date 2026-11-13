import Foundation
import Testing
@testable import PasteoryAI

private actor ScriptedTransport: AIChatTransport {
    var requests: [Data] = []
    let reply: @Sendable (Data, Int) throws -> Data
    init(reply: @escaping @Sendable (Data, Int) throws -> Data) { self.reply = reply }
    func completion(body: Data, configuration: AIConfiguration, credential: String) async throws -> Data {
        requests.append(body); return try reply(body, requests.count)
    }
}
private actor UsageCollector {
    var records: [AIUsageRecord] = []
    func append(_ record: AIUsageRecord) { records.append(record) }
}

@Test func analyzerRunsAtomicToolsAndRecordsProviderTokenSubsets() async throws {
    let doc = aiTestDoc(), groupID = UUID()
    let transport = ScriptedTransport { _, index in
        var message = AIChatMessage(role: "assistant", content: "Complete")
        if index == 1 {
            message = AIChatMessage(role: "assistant", toolCalls: [AIToolCall(id: "call_1", name: "groups_add_items", arguments: toolArguments([
                "group_id": .string(groupID.uuidString), "clip_ids": .array([.string(doc.id.uuidString)])
            ]))])
        }
        return try JSONEncoder.sorted.encode(JSONValue.object([
            "model": .string("served-model"), "choices": .array([.object(["message": try .value(message)])]),
            "usage": .object(["prompt_tokens": .number(100), "completion_tokens": .number(20),
                              "prompt_tokens_details": .object(["cached_tokens": .number(40)]),
                              "completion_tokens_details": .object(["reasoning_tokens": .number(10)])])
        ]))
    }
    var config = AIConfiguration(); config.model = "test-model"
    let group = AIGroupProfile(id: groupID, name: "Engineering", definition: "Implementation design")
    let usage = UsageCollector()
    let result = try await AIAnalyzer(transport: transport).analyze(documents: [doc], batchIDs: [doc.id], groups: [group],
                                                                 configuration: config, credential: "not-sent-to-tools", ledger: [], trigger: "manual",
                                                                 onUsage: { await usage.append($0) })
    #expect(result.changeSet.commands.count == 1)
    #expect(result.usage.reduce(0) { $0 + $1.totalTokens } == 240)
    #expect(result.usage.allSatisfy { !$0.estimated && $0.cachedInputTokens == 40 && $0.reasoningTokens == 10 })
    let request = try JSONDecoder().decode(JSONValue.self, from: #require(await transport.requests.first))
    #expect(request["reasoning_effort"] == .null)
    #expect(!(String(data: await transport.requests[0], encoding: .utf8) ?? "").contains("not-sent-to-tools"))
}

@Test func exhaustedBudgetStopsBeforeMakingNetworkRequest() async throws {
    let transport = ScriptedTransport { _, _ in throw AIError.invalid("Must not be called") }
    let doc = aiTestDoc(); var config = AIConfiguration(); config.model = "test"; config.dailyTokenLimit = 1000
    await #expect(throws: AIError.self) {
        try await AIAnalyzer(transport: transport).analyze(documents: [doc], batchIDs: [doc.id], groups: [], configuration: config,
                                                         credential: "", ledger: [], trigger: "manual", onUsage: { _ in })
    }
    #expect(await transport.requests.isEmpty)
}

@Test func failedRequestsKeepConservativeUsageInsteadOfZero() async throws {
    let transport = ScriptedTransport { _, _ in throw AIError.http(503, "Unavailable") }
    let usage = UsageCollector(), doc = aiTestDoc(); var config = AIConfiguration(); config.model = "test"
    await #expect(throws: AIError.self) {
        try await AIAnalyzer(transport: transport).analyze(documents: [doc], batchIDs: [doc.id], groups: [], configuration: config,
                                                         credential: "", ledger: [], trigger: "manual", onUsage: { await usage.append($0) })
    }
    let records = await usage.records
    #expect(records.count == 1)
    #expect(records[0].estimated && !records[0].succeeded && records[0].totalTokens > 0)
}

@Test func aFiveThousandClipLibrarySendsOnlyTheCurrentBoundedBatch() async throws {
    let docs = (0..<5000).map { aiTestDoc("Library item \($0): UNSENT_\($0)") }
    let transport = ScriptedTransport { body, _ in
        let request = try JSONDecoder().decode(JSONValue.self, from: body)
        let messages = try #require(request["messages"].array)
        let last = try #require(messages.last)
        let content = try #require(last["content"].string)
        #expect(!content.contains("UNSENT_4999"))
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
        #expect((payload["current_batch"].array?.count ?? 0) <= 20)
        #expect(body.count < 48_000)
        return Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Complete\"}}],\"usage\":{\"prompt_tokens\":1000,\"completion_tokens\":50}}".utf8)
    }
    var configuration = AIConfiguration(); configuration.model = "test"
    let result = try await AIAnalyzer(transport: transport).analyze(documents: docs, batchIDs: Array(docs.prefix(20).map(\.id)), groups: [], configuration: configuration, credential: "", ledger: [], trigger: "manual", onUsage: { _ in })
    #expect(result.analyzedIDs.count == 20)
    #expect(await transport.requests.count == 1)
}
