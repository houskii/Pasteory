import Foundation
import Testing
@testable import Pasteory

#if DEBUG
private func withUpdateFixture(_ body: (URL, [String: Any]) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pasteory-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = UUID().uuidString
    let marker = ["identifier": identifier, "bundle_identifier": "app.pasteory.Pasteory.qa"]
    try JSONSerialization.data(withJSONObject: marker).write(to: root.appendingPathComponent("update-fixture.json"))
    try body(root, ["PasteoryUpdateIntegrationID": identifier,
                    "PasteoryUpdateIntegrationDataRoot": root.path,
                    "SUFeedURL": "http://127.0.0.1:45678/appcast.xml"])
}

@Test func actualUpdateFixtureRequiresQAIdentityAndMatchingNonce() throws {
    try withUpdateFixture { root, info in
        #expect(DebugUpdateIntegration(bundleIdentifier: "app.pasteory.Pasteory.qa", info: info) != nil)
        #expect(DebugUpdateIntegration(bundleIdentifier: "app.pasteory.Pasteory", info: info) == nil)
        var changed = info
        changed["PasteoryUpdateIntegrationID"] = UUID().uuidString
        #expect(DebugUpdateIntegration(bundleIdentifier: "app.pasteory.Pasteory.qa", info: changed) == nil)
        changed = info
        changed["PasteoryUpdateIntegrationDataRoot"] = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pasteory").path
        #expect(DebugUpdateIntegration(bundleIdentifier: "app.pasteory.Pasteory.qa", info: changed) == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("update-fixture.json"))
        #expect(DebugUpdateIntegration(bundleIdentifier: "app.pasteory.Pasteory.qa", info: info) == nil)
    }
}

@Test func actualUpdateFixtureOnlyAcceptsItsOwnLoopbackServer() throws {
    try withUpdateFixture { _, info in
        let fixture = try #require(DebugUpdateIntegration(bundleIdentifier: "app.pasteory.Pasteory.qa", info: info))
        #expect(fixture.allows(URL(string: "http://127.0.0.1:45678/updates/candidate.zip")))
        for value in ["http://127.0.0.1:45679/updates/candidate.zip", "http://localhost:45678/updates/candidate.zip",
                      "http://user@127.0.0.1:45678/updates/candidate.zip", "http://127.0.0.1:45678/updates/../other.zip",
                      "http://127.0.0.1:45678/updates/candidate.zip?redirect=1",
                      "https://github.com/houskii/Pasteory/releases/download/v1/candidate.zip"] {
            #expect(!fixture.allows(URL(string: value)))
        }
        var changed = info
        changed["SUFeedURL"] = "https://example.com/appcast.xml"
        #expect(DebugUpdateIntegration(bundleIdentifier: "app.pasteory.Pasteory.qa", info: changed) == nil)
    }
}
#endif
