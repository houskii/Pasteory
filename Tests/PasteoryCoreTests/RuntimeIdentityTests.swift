import Foundation
import Testing
@testable import PasteoryCore

@Test func productionAndQAUseDifferentSystemDomains() {
    let production = PasteoryRuntimeIdentity.production
    let qa = PasteoryRuntimeIdentity.qa

    #expect(production.bundleIdentifier == "app.pasteory.Pasteory")
    #expect(qa.bundleIdentifier == "app.pasteory.Pasteory.qa")
    #expect(production.bundleIdentifier != qa.bundleIdentifier)
    #expect(production.applicationSupportDirectoryName != qa.applicationSupportDirectoryName)
    #expect(production.nativeMessagingHostName != qa.nativeMessagingHostName)
    #expect(production.chromeIntegrationEnabled)
    #expect(!qa.chromeIntegrationEnabled)
}

@Test func runtimeIdentityRejectsQABuildWithProductionBundleIdentifier() {
    let qaInfo: [String: Any] = [
        "PasteoryBuildVariant": "qa",
        "CFBundleDisplayName": "Pasteory QA",
        "PasteoryApplicationSupportDirectory": "Pasteory QA",
        "PasteoryNativeMessagingHostName": "app.pasteory.qa.web_context",
        "PasteoryChromeIntegrationEnabled": false
    ]

    #expect(throws: PasteoryRuntimeIdentityError.self) {
        try PasteoryRuntimeIdentity.validateCurrentBundleConfiguration(
            bundleIdentifier: PasteoryRuntimeIdentity.production.bundleIdentifier,
            infoDictionary: qaInfo
        )
    }
}

@Test func runtimeIdentityAcceptsMatchingProductionAndQAConfigurations() throws {
    let values: [(PasteoryRuntimeIdentity, [String: Any])] = [
        (
            .production,
            [
                "PasteoryBuildVariant": "production",
                "CFBundleDisplayName": "Pasteory",
                "PasteoryApplicationSupportDirectory": "Pasteory",
                "PasteoryNativeMessagingHostName": "app.pasteory.web_context",
                "PasteoryChromeIntegrationEnabled": true
            ]
        ),
        (
            .qa,
            [
                "PasteoryBuildVariant": "qa",
                "CFBundleDisplayName": "Pasteory QA",
                "PasteoryApplicationSupportDirectory": "Pasteory QA",
                "PasteoryNativeMessagingHostName": "app.pasteory.qa.web_context",
                "PasteoryChromeIntegrationEnabled": false
            ]
        )
    ]

    for (identity, info) in values {
        try PasteoryRuntimeIdentity.validateCurrentBundleConfiguration(
            bundleIdentifier: identity.bundleIdentifier,
            infoDictionary: info
        )
    }
}
