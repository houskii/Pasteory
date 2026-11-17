import Foundation
import Testing
@testable import PasteoryAI

private let lifecycleNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func activityPercentilesIncludeTiesAndDoNotOverstateEqualScores() {
    let ids = (0..<100).map { _ in UUID() }
    let ranks = ActivityPercentile.ranks(Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, Double(100 - $0.offset)) }))
    #expect(ranks[ids[0]] == 1 && ranks[ids[49]] == 50 && ranks[ids[99]] == 100)
    let tied = ActivityPercentile.ranks([ids[0]: 1, ids[1]: 1, ids[2]: 0.5, ids[3]: 0.5])
    #expect(tied[ids[0]] == 50 && tied[ids[1]] == 50 && tied[ids[2]] == 100)
    #expect(ActivityPercentile.ranks([ids[0]: 0.5, ids[1]: 0.5]).values.allSatisfy { $0 == 100 })
    #expect(ActivityPercentile.ranks([ids[0]: .nan]).isEmpty)
}

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

@Test func presetsAndScoringParametersAreValidated() throws {
    #expect(LifecyclePolicy.preset(.aggressive).archiveDays == 30)
    #expect(LifecyclePolicy.preset(.conservative).archiveDays == 120)
    var p = LifecyclePolicy()
    p.compressionDays = 2
    #expect(throws: AIError.self) { try p.validate() }
    p = LifecyclePolicy(); p.scoringParameters.halfLifeHours = .nan
    #expect(throws: AIError.self) { try p.validate() }
    p = LifecyclePolicy(); p.scoringParameters.halfLifeHours = 0
    #expect(throws: AIError.self) { try p.validate() }
    p = LifecyclePolicy(); p.scoringParameters.copyIncrement = -0.4
    #expect(throws: AIError.self) { try p.validate() }
    p = LifecyclePolicy(); p.scoringParameters.pasteIncrement = .infinity
    #expect(throws: AIError.self) { try p.validate() }
}

@Test func onlyRetainedHumanEventsContributeReuseBonus() {
    let p = LifecyclePolicy()
    let last = lifecycleNow.addingTimeInterval(-2 * 86_400)
    let plain = ContentActivity(lastUsedAt: last)
    let recent = ContentActivity(lastUsedAt: last, samples: [.init(.paste, at: last)])
    let stale = ContentActivity(lastUsedAt: last, samples: [.init(.paste, at: lifecycleNow.addingTimeInterval(-400 * 86_400))])
    #expect(p.evaluate(recent, now: lifecycleNow).score > p.evaluate(plain, now: lifecycleNow).score)
    #expect(p.evaluate(stale, now: lifecycleNow).score == p.evaluate(plain, now: lifecycleNow).score)
}

@Test func ordinaryActivityStartsAtOneHundredAndHalvesEveryFortyEightHours() {
    let p = LifecyclePolicy()
    let activity = ContentActivity(lastUsedAt: lifecycleNow, samples: [.init(.copy, at: lifecycleNow)], capturedAt: lifecycleNow)
    for (hours, expected) in [(0.0, 1.0), (6, 0.9170040432), (12, 0.8408964153), (24, 0.7071067812),
                              (48, 0.5), (72, 0.3535533906), (168, 0.0883883476), (336, 0.0078125), (720, 0.000030517578125)] {
        let result = p.evaluate(activity, now: lifecycleNow.addingTimeInterval(hours * 3600))
        #expect(abs(result.score - expected) < 0.000000001)
    }
    #expect(p.evaluate(activity, now: lifecycleNow.addingTimeInterval(-3600)).score == 1)
}

@Test func copiesAndPastesRefreshToOneHundredAndAddTheirOwnDecayingCoefficient() {
    let p = LifecyclePolicy(), acquired = lifecycleNow.addingTimeInterval(-86_400)
    for (event, increment) in [(ContentActivity.Event.copy, 0.4), (.paste, 0.8)] {
        var activity = ContentActivity(lastUsedAt: acquired, samples: [.init(.copy, at: acquired)], capturedAt: acquired)
        activity.record(event, at: lifecycleNow)
        #expect(p.evaluate(activity, now: lifecycleNow).score == 1)
        let bonus = increment * pow(0.5, 2.0 / 7)
        let expected = pow(0.5, 1 / (1 + bonus))
        #expect(abs(p.evaluate(activity, now: lifecycleNow.addingTimeInterval(48 * 3600)).score - expected) < 1e-12)
    }
}

@Test func reuseBonusDecaysBeforeEachIncrementAndIsCappedAtThree() {
    let p = LifecyclePolicy(), acquired = lifecycleNow.addingTimeInterval(-20 * 86_400)
    var activity = ContentActivity(lastUsedAt: acquired, capturedAt: acquired)
    activity.record(.copy, at: lifecycleNow.addingTimeInterval(-7 * 86_400))
    activity.record(.paste, at: lifecycleNow)
    // The old 0.4 is now 0.2; the paste adds exactly 0.8.
    let expected = pow(0.5, 1 / (1 + 1.0 * pow(0.5, 2.0 / 7)))
    #expect(abs(p.evaluate(activity, now: lifecycleNow.addingTimeInterval(48 * 3600)).score - expected) < 1e-12)
    for _ in 0..<100 { activity.record(.paste, at: lifecycleNow) }
    #expect(p.evaluate(activity, now: lifecycleNow).score == 1)
    let capped = pow(0.5, 1 / (1 + 3.0 * pow(0.5, 2.0 / 7)))
    #expect(abs(p.evaluate(activity, now: lifecycleNow.addingTimeInterval(48 * 3600)).score - capped) < 1e-12)
    #expect(p.evaluate(activity, now: lifecycleNow.addingTimeInterval(366 * 86_400)).score < 1e-40)
}

@Test func manualOpensRefreshTimeWithoutAddingOrPreservingReuseBonus() {
    let p = LifecyclePolicy(), copied = lifecycleNow.addingTimeInterval(-7 * 86_400)
    var activity = ContentActivity(lastUsedAt: copied, samples: [.init(.copy, at: copied)])
    activity.record(.open, at: lifecycleNow)
    activity.record(.edit, at: lifecycleNow)
    activity.samples.append(.init(.paste, at: lifecycleNow.addingTimeInterval(10 * 86_400)))
    #expect(p.evaluate(activity, now: lifecycleNow).score == 1)
    let expected = pow(0.5, 1 / (1 + 0.4 * pow(0.5, 9.0 / 7)))
    #expect(abs(p.evaluate(activity, now: lifecycleNow.addingTimeInterval(48 * 3600)).score - expected) < 1e-12)
}

@Test func oldLifecycleSettingsAndActivityAdoptTheNewDefaultsWithoutLosingRetentionRules() throws {
    let legacy = Data(#"{"preset":"custom","version":1,"deprioritizeDays":9,"compressionDays":18,"archiveDays":90,"frequencyWindowDays":30,"recencyWeight":0.6,"frequencyWeight":0.25,"activeDaysWeight":0.15,"copyWeight":1,"pasteWeight":2,"openWeight":1,"editWeight":1.5,"topK":5,"topKWeight":0.6,"activeThreshold":0.65,"archiveThreshold":0.1}"#.utf8)
    var policy = try JSONDecoder().decode(LifecyclePolicy.self, from: legacy)
    try policy.validate()
    #expect(policy.scoringParameters.halfLifeHours == 48)
    #expect(policy.scoringParameters.copyIncrement == 0.4 && policy.scoringParameters.pasteIncrement == 0.8)
    #expect(policy.deprioritizeDays == 9 && policy.compressionDays == 18 && policy.archiveDays == 90)
    let oldActivity = try JSONDecoder().decode(ContentActivity.self, from: Data(#"{"lastUsedAt":100,"samples":[{"event":"paste","at":100}]}"#.utf8))
    #expect(oldActivity.capturedAt == nil && oldActivity.samples.count == 1)
    policy.scoringParameters.halfLifeHours = 96
    let restored = try JSONDecoder().decode(LifecyclePolicy.self, from: JSONEncoder().encode(policy))
    #expect(restored == policy && restored.scoringParameters.halfLifeHours == 96)
    #expect(abs(restored.evaluate(ContentActivity(lastUsedAt: lifecycleNow), now: lifecycleNow.addingTimeInterval(48 * 3600)).score - sqrt(0.5)) < 1e-12)
    #expect(restored.fingerprint != LifecyclePolicy().fingerprint)
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
