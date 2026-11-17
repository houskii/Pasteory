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
