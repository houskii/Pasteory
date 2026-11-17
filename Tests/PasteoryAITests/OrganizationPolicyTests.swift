import Foundation
import Testing
@testable import PasteoryAI

@Test func organizationDefaultsAndLegacyStorageRemainCompatible() throws {
    var configuration = AIConfiguration(); configuration.model = "original-model"
    let old = try JSONEncoder().encode(configuration)
    let restored = try JSONDecoder().decode(AIConfiguration.self, from: old)
    #expect(restored.organizationPolicy.recommendedCount == 3)
    #expect(restored.organizationPolicy.targetGroupCount == 7)
    #expect(restored.model == configuration.model)
    #expect(restored.organizationPolicy.idleEnabled)
    configuration.timerEnabled = false
    #expect(try JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(configuration)).organizationPolicy.idleEnabled == false)
    #expect(try JSONDecoder().decode(AIOrganizationState.self, from: JSONEncoder().encode(AIOrganizationState())).automation.dirty.isEmpty)
}

@Test func nightlyWindowAndSevenDayReviewUseLocalCalendar() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))! }
    let policy = AIOrganizationPolicy()
    #expect(!policy.isIdleWindow(at: date(16, 0, 59), calendar: calendar))
    #expect(policy.isIdleWindow(at: date(16, 1), calendar: calendar))
    #expect(policy.isIdleWindow(at: date(16, 1, 59), calendar: calendar))
    #expect(!policy.isIdleWindow(at: date(16, 2), calendar: calendar))
    #expect(!policy.reviewIsDue(lastReview: date(9, 1, 30), now: date(16, 1, 29), calendar: calendar))
    #expect(policy.reviewIsDue(lastReview: date(9, 1, 30), now: date(16, 1, 30), calendar: calendar))
}

@Test func dirtyQueuePersistsOnlyChangedIDsAndKeepsItsOriginalWait() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000), ids = (0..<5).map { _ in UUID() }
    var state = AIAutomationState()
    for id in ids { state.enqueue(id: id, revision: "v1", at: start) }
    state.enqueue(id: ids[0], revision: "v1", at: start.addingTimeInterval(25))
    #expect(state.incrementalIDs(at: start.addingTimeInterval(29)).isEmpty)
    #expect(Set(state.incrementalIDs(at: start.addingTimeInterval(30))) == Set(ids))
    state = try JSONDecoder().decode(AIAutomationState.self, from: JSONEncoder().encode(state))
    #expect(state.dirty.count == 5)
    state.decisions[ids[0]] = AIClassificationDecision(revision: "v1", outcome: .unmatched, reason: "Unrelated")
    state.dirty.removeValue(forKey: ids[0]); state.enqueue(id: ids[0], revision: "v1", at: start)
    #expect(state.dirty[ids[0]] == nil)
    state.enqueue(id: ids[0], revision: "v2", at: start)
    #expect(state.dirty[ids[0]]?.revision == "v2")
}

@Test func smallQueueBecomesDueAfterTwoMinutes() {
    let start = Date(), id = UUID(); var state = AIAutomationState()
    state.enqueue(id: id, revision: "v1", at: start)
    #expect(state.incrementalIDs(at: start.addingTimeInterval(119)).isEmpty)
    #expect(state.incrementalIDs(at: start.addingTimeInterval(120)) == [id])
}

@Test func classificationRecordsUnmatchedAndRejectsPartialUnauthorizedBatchAtomically() throws {
    let current = aiTestDoc(), history = aiTestDoc()
    let group = AIGroupProfile(name: "Existing", definition: "An existing topic")
    let rules = AIAnalysisRules()
    var workspace = try AtomicWorkspace(documents: [current, history], writableIDs: [current.id], groups: [group], rules: rules)
    _ = try workspace.initialDocuments([current.id], characterBudget: 5000)
    let invalid = toolArguments(["decisions": .array([
        .object(["clip_id": .string(current.id.uuidString), "group_ids": .array([.string(group.id.uuidString)]), "reason": .string("Matches")]),
        .object(["clip_id": .string(history.id.uuidString), "group_ids": .array([]), "reason": .string("Outside batch")])
    ])])
    #expect(throws: AIError.self) { try workspace.execute(name: "clips_classify", arguments: invalid) }
    #expect(workspace.draft.commands.isEmpty)
    #expect(workspace.draft.decisions?.isEmpty ?? true)
    _ = try workspace.execute(name: "clips_classify", arguments: toolArguments(["decisions": .array([
        .object(["clip_id": .string(current.id.uuidString), "group_ids": .array([]), "reason": .string("No suitable theme")])
    ])]))
    let draft = try workspace.finish()
    #expect(draft.commands.isEmpty)
    #expect(draft.decisions?[current.id]?.outcome == .unmatched)
}

@Test func themeCapIncludesGroupsCreatedInEarlierBatches() throws {
    let docs = (0..<3).map { _ in aiTestDoc() }
    let groups = (0..<7).map { AIGroupProfile(name: "Existing \($0)", definition: "Stable topic \($0)") }
    var rules = AIAnalysisRules(); rules.allowNewGroups = true
    var first = try AtomicWorkspace(documents: docs, writableIDs: Set(docs.map(\.id)), groups: groups, rules: rules)
    _ = try first.initialDocuments(docs.map(\.id), characterBudget: 10_000)
    let created = try first.execute(name: "groups_create", arguments: toolArguments(["name": .string("New topic"), "definition": .string("New meaningful topic")]))
    let id = try #require(created["group_id"].string)
    _ = try first.execute(name: "clips_classify", arguments: toolArguments(["decisions": .array(docs.map {
        .object(["clip_id": .string($0.id.uuidString), "group_ids": .array([.string(id)]), "reason": .string("Strong match")])
    })]))
    let draft = try first.finish()
    var resumed = try AtomicWorkspace(documents: docs, writableIDs: Set(docs.map(\.id)), groups: groups, draft: draft, rules: rules)
    #expect(throws: AIError.self) { try resumed.execute(name: "groups_create", arguments: toolArguments(["name": .string("Ninth topic"), "definition": .string("Would exceed cap")])) }
}

@Test func candidateThemesCombineEvidenceWithoutCreatingGroups() {
    var state = AIAutomationState()
    let a = UUID(), b = UUID(), c = UUID()
    state.mergeCandidates([AIThemeCandidate(name: "Project", definition: "A project", supportRevisions: [a: "1", b: "2"])])
    state.mergeCandidates([AIThemeCandidate(name: "project", definition: "Same project", supportRevisions: [c: "3"])])
    #expect(state.candidates.count == 1)
    #expect(state.candidates[0].supportRevisions.count == 3)
}

@Test func activityProtectionIncludesReadingAndRecentlyDemotedThemes() {
    let now = Date(), member = UUID()
    var cold = AIGroupProfile(name: "Cold", definition: "An old topic"); cold.createdAt = now.addingTimeInterval(-30 * 86_400)
    cold.memberIDs = [member]; cold.aiMemberIDs = [member]
    let active = AIGroupProfile(name: "Reading", definition: "Currently open")
    var automation = AIAutomationState(); automation.protectedUntil[cold.id] = now.addingTimeInterval(7 * 86_400)
    #expect(AIGroupProtection.ids(groups: [cold, active], automation: automation, activities: [:], reading: [active.id], now: now) == [cold.id, active.id])
    automation.protectedUntil = [:]
    #expect(AIGroupProtection.ids(groups: [cold], automation: automation, activities: [:], now: now).isEmpty)
    let human = ContentActivity(lastUsedAt: now, samples: [.init(.paste, at: now.addingTimeInterval(-60))])
    #expect(AIGroupProtection.ids(groups: [cold], automation: automation, activities: [member: human], now: now) == [cold.id])
}

@Test func themeReviewKeepsStableIDsAndRejectsProtectedRenames() throws {
    let documents = (0..<8).map { _ in aiTestDoc() }
    var groups = (0..<8).map { AIGroupProfile(name: "Topic \($0)", definition: "Definition \($0)") }
    for index in groups.indices { groups[index].memberIDs = [documents[index].id]; groups[index].aiMemberIDs = groups[index].memberIDs }
    let themes = groups.prefix(6).map { AIThemePlan.Theme(groupID: $0.id, name: $0.name, definition: $0.definition) }
    let protected = Set(groups.prefix(3).map(\.id))
    let draft = try AIThemePlan(themes: themes).changeSet(groups: groups, documents: documents, protectedIDs: protected, policy: AIOrganizationPolicy())
    #expect(draft.commands.filter { $0.kind == .retireGroup }.count == 2)
    #expect(draft.commands.allSatisfy { !protected.contains($0.targetID) })
    var changed = themes; changed[0].name = "Renamed"
    #expect(throws: AIError.self) { try AIThemePlan(themes: changed).changeSet(groups: groups, documents: documents, protectedIDs: protected, policy: AIOrganizationPolicy()) }
}

@Test func unmatchedCacheIgnoresMembershipButNotThemeBoundaryOrPromptChanges() {
    var group = AIGroupProfile(name: "Project", definition: "Topic")
    let before = AIThemeCatalog.fingerprint([group]); group.memberIDs.insert(UUID()); group.overview = "A refreshed overview"
    #expect(AIThemeCatalog.fingerprint([group]) == before)
    group.definition = "A different boundary"
    #expect(AIThemeCatalog.fingerprint([group]) != before)
    var config = AIConfiguration(); let semantic = AIThemeCatalog.configurationFingerprint(config)
    config.batchSize = 20; config.dailyTokenLimit *= 2
    #expect(AIThemeCatalog.configurationFingerprint(config) == semantic)
    config.prompt += " Only classify"
    #expect(AIThemeCatalog.configurationFingerprint(config) != semantic)
}

@Test func nightlyBudgetSurvivesPauseAndCountsUniqueContent() throws {
    let now = Date(), policy = AIOrganizationPolicy()
    var budget = AINightlyBudget(now: now); budget.processedIDs = Set((0..<99).map { _ in UUID() })
    budget = try JSONDecoder().decode(AINightlyBudget.self, from: JSONEncoder().encode(budget))
    #expect(!budget.exhausted(policy: policy, now: now, tokens: 299_999))
    budget.processedIDs.insert(UUID())
    #expect(budget.exhausted(policy: policy, now: now, tokens: 1))
    #expect(AINightlyBudget(now: now).exhausted(policy: policy, now: now.addingTimeInterval(600), tokens: 1))
    #expect(AINightlyBudget(now: now).exhausted(policy: policy, now: now, tokens: 300_000))
}
