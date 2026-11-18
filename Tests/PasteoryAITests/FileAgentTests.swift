import Foundation
import Testing
@testable import PasteoryAI

private actor ExpiredImageWorkspace: AIFileAgentWorkspace {
    var saved = [JSONValue]()
    func loadConversation() -> [JSONValue] {
        [.object(["role": .string("system"), "content": .string("Previous task prompt")]),
         .object(["role": .string("user"), "content": .array([.object(["type": .string("image_url"), "image_url": .object(["url": .string("file:///no-longer-present.png")])])])])]
    }
    func saveConversation(_ messages: [JSONValue]) { saved = messages }
    func perform(_ call: AIToolCall) -> AIFileToolOutput { AIFileToolOutput("not used") }
    func imageDataURL(for path: String) throws -> String { throw AIError.invalid("Removed image") }
    func validatePlan() -> String? { nil }
    func record(event: String, details: JSONValue) {}
}
private actor ExpiredImageTransport: AIChatTransport {
    var called = false
    func completion(body: Data, configuration: AIConfiguration, credential: String) throws -> Data {
        called = true
        let request = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(request["reasoning_effort"].string == "medium")
        let messages = try #require(request["messages"].array)
        #expect(messages.first?["content"].string == "Current task prompt")
        #expect(messages[1]["content"].array?.first?["type"].string == "text")
        #expect(messages[1]["content"].array?.first?["text"].string?.contains("no longer available") == true)
        return Data(#"{"choices":[{"message":{"role":"assistant","content":"Complete"}}],"usage":{"prompt_tokens":100,"completion_tokens":10}}"#.utf8)
    }
}

@Test func fileAgentContinuesWhenAnImageFromItsSavedConversationWasRemoved() async throws {
    var configuration = AIConfiguration(); configuration.model = "synthetic"; configuration.reasoning = "medium"; configuration.supportedReasoningLevels = ["medium"]
    let workspace = ExpiredImageWorkspace(), transport = ExpiredImageTransport()
    try await AIFileAgent(transport: transport).run(taskID: UUID(), prompt: "Current task prompt", directory: "/synthetic-task", configuration: configuration,
        credential: "", ledger: [], trigger: "manual", workspace: workspace, onUsage: { _ in })
    #expect(await transport.called)
}

private actor SavedContextWorkspace: AIFileAgentWorkspace {
    var history: [JSONValue]
    init(history: [JSONValue]) { self.history = history }

    func loadConversation() -> [JSONValue] { history }
    func saveConversation(_ messages: [JSONValue]) { history = messages }
    func perform(_ call: AIToolCall) throws -> AIFileToolOutput { throw AIError.invalid("The tool already ran") }
    func imageDataURL(for path: String) throws -> String { throw AIError.invalid("Unexpected image") }
    func validatePlan() -> String? { nil }
    func record(event: String, details: JSONValue) {}
}

private actor ContextBudgetTransport: AIChatTransport {
    var requests = [[JSONValue]]()

    func completion(body: Data, configuration: AIConfiguration, credential: String) throws -> Data {
        #expect(body.count <= configuration.maxInputTokens * 2)
        let request = try JSONDecoder().decode(JSONValue.self, from: body)
        requests.append(try #require(request["messages"].array))
        return Data(#"{"choices":[{"message":{"role":"assistant","content":"Complete"}}],"usage":{"prompt_tokens":100,"completion_tokens":10}}"#.utf8)
    }
}

@Test(arguments: [false, true])
func fileAgentFitsTheWholeRequestAndPreservesSavedToolResults(latestResultIsOversized: Bool) async throws {
    var configuration = AIConfiguration()
    configuration.model = "synthetic"
    configuration.maxInputTokens = 12_000
    func exchange(id: String, result: String) throws -> [JSONValue] {
        let assistant = AIChatMessage(role: "assistant", toolCalls: [
            .init(id: id, name: "task_read", arguments: #"{"path":"items.json"}"#)
        ])
        return [try .value(assistant), .object([
            "role": .string("tool"), "tool_call_id": .string(id), "content": .string(result)
        ])]
    }
    let prefix: [JSONValue] = [
        .object(["role": .string("system"), "content": .string("Prior instructions")]),
        .object(["role": .string("user"), "content": .string("Read the task files")])
    ]
    let old = try exchange(id: "older-read", result: String(repeating: "x", count: 22_400))
    let recent = try exchange(id: "recent-read",
        result: latestResultIsOversized ? String(repeating: "新", count: 10_000) : "Recent result")
    let workspace = SavedContextWorkspace(history: prefix + old + recent)
    let transport = ContextBudgetTransport()
    try await AIFileAgent(transport: transport).run(taskID: UUID(), prompt: "Updated instructions",
        directory: "/synthetic-task", configuration: configuration, credential: "", ledger: [],
        trigger: "story", workspace: workspace, onUsage: { _ in })

    let requests = await transport.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.first?["content"].string == "Updated instructions")
    #expect(request.contains { $0["content"].string?.contains("Earlier exchanges were shortened") == true })
    let calls = request.flatMap { $0["tool_calls"].array ?? [] }.compactMap { $0["id"].string }
    let results = request.compactMap { $0["tool_call_id"].string }
    #expect(calls == (latestResultIsOversized ? [] : ["recent-read"]))
    #expect(results == calls)
    #expect(Array((await workspace.history).dropFirst(2).prefix(4)) == old + recent)
}
