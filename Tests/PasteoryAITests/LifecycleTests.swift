import Foundation
import Testing
@testable import PasteoryAI

private let lifecycleNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func standardPolicyUsesSevenFourteenSixtyDays() throws {
    let policy = LifecyclePolicy.preset(.standard)
    try policy.validate()
    func result(_ days: Double) -> ActivityEvaluation {
        policy.evaluate(ContentActivity(lastUsedAt: lifecycleNow.addingTimeInterval(-days * 86_400)), now: lifecycleNow)
    }
    #expect(result(6.99).stage == .active)
    #expect(result(7).stage == .retained)
    #expect(!result(13.99).compressionEligible)
    #expect(result(14).compressionEligible)
    #expect(result(59.99).stage == .retained)
    #expect(result(60).stage == .archived)
    #expect(result(60).score < result(14).score)
}

@Test func presetsAndMetricOverridesAreValidated() throws {
    #expect(LifecyclePolicy.preset(.aggressive).archiveDays == 30)
    #expect(LifecyclePolicy.preset(.conservative).archiveDays == 120)
    var p = LifecyclePolicy()
    p.compressionDays = 2
    #expect(throws: AIError.self) { try p.validate() }
    p = LifecyclePolicy(); p.recencyWeight = .nan
    #expect(throws: AIError.self) { try p.validate() }
    p = LifecyclePolicy(); p.recencyWeight = 0; p.frequencyWeight = 0; p.activeDaysWeight = 0
    #expect(throws: AIError.self) { try p.validate() }
}

@Test func onlyWindowedHumanEventsAffectFrequency() {
    let p = LifecyclePolicy()
    let last = lifecycleNow.addingTimeInterval(-2 * 86_400)
    let plain = ContentActivity(lastUsedAt: last)
    let recent = ContentActivity(lastUsedAt: last, samples: [.init(.paste, at: last)])
    let stale = ContentActivity(lastUsedAt: last, samples: [.init(.paste, at: lifecycleNow.addingTimeInterval(-400 * 86_400))])
    #expect(p.evaluate(recent, now: lifecycleNow).score > p.evaluate(plain, now: lifecycleNow).score)
    #expect(p.evaluate(stale, now: lifecycleNow).score == p.evaluate(plain, now: lifecycleNow).score)
}

@Test func groupStatusComesFromMembersAndEmptyGroupIsArchived() {
    let p = LifecyclePolicy()
    let active = p.evaluate(ContentActivity(lastUsedAt: lifecycleNow), now: lifecycleNow)
    let old = p.evaluate(ContentActivity(lastUsedAt: lifecycleNow.addingTimeInterval(-100 * 86_400)), now: lifecycleNow)
    let first = p.group([active, old, old])
    #expect(first.counts[.active] == 1)
    #expect(first.counts[.archived] == 2)
    #expect(first.score < p.group([active]).score)
    #expect(p.group([]).stage == .archived)
}

@Test func tokenSubsetsAreNotCountedTwiceAndUnknownPriceStaysUnknown() {
    var c = AIConfiguration()
    #expect(AIUsageRecord.estimateCost(input: 91_240, output: 18_360, cached: 21_400, configuration: c) == nil)
    c.inputPricePerMillion = 1; c.cachedPricePerMillion = 0.25; c.outputPricePerMillion = 3
    let cost = AIUsageRecord.estimateCost(input: 91_240, output: 18_360, cached: 21_400, configuration: c)!
    #expect(abs(cost - 0.13027) < 0.000001)
    let record = AIUsageRecord(runID: UUID(), requestedModel: "test", inputTokens: 91_240, outputTokens: 18_360,
                               estimated: false, succeeded: true, trigger: "test", cachedInputTokens: 21_400, reasoningTokens: 4_120)
    #expect(record.totalTokens == 109_600)
}

@Test func endpointsAndReasoningCapabilitiesAreExplicit() throws {
    var c = AIConfiguration(); c.model = "test"
    try c.validate()
    c.endpoint = "http://cloud.example/v1"
    #expect(throws: AIError.self) { try c.validate() }
    c.endpoint = "https://user:secret@cloud.example/v1"
    #expect(throws: AIError.self) { try c.validate() }
    c.endpoint = "https://cloud.example/v1?key=secret"
    #expect(throws: AIError.self) { try c.validate() }
    c.endpoint = "https://cloud.example/v1"; c.reasoning = "high"
    #expect(throws: AIError.self) { try c.validate() }
    c.supportedReasoningLevels = ["low", "high"]
    try c.validate()
}
