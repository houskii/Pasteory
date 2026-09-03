import Foundation
import Testing
@testable import PasteoryCore

@Test func authenticatedLinkPatternMatchesWithoutScheme() throws {
    let mergeRequest = try #require(URL(string: "https://code.byted.org/ugc-android/ByteX/merge_requests/912"))
    let issue = try #require(URL(string: "https://code.byted.org/ugc-android/ByteX/issues/912"))
    let pattern = #"^code\.byted\.org/ugc-android/ByteX/merge_requests/\d+$"#

    #expect(AuthenticatedLinkPattern.matches(pattern, url: mergeRequest))
    #expect(!AuthenticatedLinkPattern.matches(pattern, url: issue))
    #expect(AuthenticatedLinkPattern.normalized("https://\(pattern)") == pattern)
}

@Test func authenticatedLinkPatternSuggestsRouteAndInfersLoginOrigin() throws {
    let signature = URLRouteSignature(
        host: "code.byted.org",
        pathTemplate: "/ugc-android/ByteX/merge_requests/{segment4}"
    )
    let pattern = AuthenticatedLinkPattern.suggestedPattern(for: signature)
    let sample = "https://code.byted.org/ugc-android/ByteX/merge_requests/912"
    let url = try #require(URL(string: sample))

    #expect(pattern == #"^code\.byted\.org/ugc-android/ByteX/merge_requests/[^/]+$"#)
    #expect(AuthenticatedLinkPattern.matches(pattern, url: url))
    #expect(AuthenticatedLinkPattern.inferredStartURL(pattern: pattern, sampleURLs: [sample])?.absoluteString == "https://code.byted.org/")
}

@Test func authenticatedLinkRuleRejectsInvalidRegularExpression() {
    #expect(AuthenticatedLinkPattern.validationError(#"code\.byted\.org/("#) != nil)
    #expect(AuthenticatedLinkPattern.validationError(#"code\.byted\.org/.*"#) == nil)
}
