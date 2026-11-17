import Foundation
import PasteoryAI
import PasteoryCore
import Testing
@testable import Pasteory

@Test(arguments: [Optional<Int>.none, .some(1)]) @MainActor func analysisDefaultsMigrateOnceAndPreserveLaterUserChoices(version: Int?) throws {
    let suite = "AnalysisDefaults." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var old = AIConfiguration(); old.model = "existing-model"; old.topN = 1000
    old.includeNotes = false; old.includeSource = false; old.includeImageText = false
    old.allowOriginalResourceRead = false; old.analyzeNew = false; old.timerEnabled = false
    old.organizationPolicy.idleEnabled = false; old.organizationPolicy.weeklyReviewEnabled = false
    old.storyEnabled = false
    var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    if let version { value["analysisDefaultsVersion"] = version } else { value.removeValue(forKey: "analysisDefaultsVersion") }
    defaults.set(try JSONSerialization.data(withJSONObject: value), forKey: "aiOrganizationConfiguration.v1")
    let settings = AppSettings(defaults: defaults), migrated = settings.aiConfiguration
    #expect(migrated.model == old.model && migrated.topN == 1000)
    #expect(migrated.includeNotes && migrated.includeSource && migrated.includeImageText == true && migrated.allowOriginalResourceRead == true)
    #expect(migrated.analyzeNew && migrated.organizationPolicy.idleEnabled && migrated.organizationPolicy.weeklyReviewEnabled)
    #expect(migrated.storyEnabled == true && migrated.analysisDefaultsVersion == 2)
    settings.aiConfiguration.analyzeNew = false; settings.aiConfiguration.includeImageText = false
    settings.aiConfiguration.organizationPolicy.idleEnabled = false
    settings.aiConfiguration.storyEnabled = false
    let reloaded = AppSettings(defaults: defaults).aiConfiguration
    #expect(!reloaded.analyzeNew && reloaded.includeImageText == false && !reloaded.organizationPolicy.idleEnabled && reloaded.storyEnabled == false)
}

@Test func linkHistoryKeepsIndividualURLsSourcesAndTheLatestAttemptEvenWhenAnOldTitleSurvives() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let oldDate = Date(timeIntervalSince1970: 1_790_000_000), recent = oldDate.addingTimeInterval(86_400)
    for index in 0..<3 {
        let raw = "https://example.com/articles/\(1000 + index)"
        let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data(raw.utf8))])], source: .init(appName: index == 0 ? "Chrome" : "Orca", bundleIdentifier: "test.history.\(index)", confidence: .high), capturedAt: oldDate)))
        try await repo.save(clip)
        let fallback = URLFallbackEngine.fallback(for: URL(string: raw)!, rules: [])
        var resource = try await repo.associateLink(clipID: clip.id, resource: LinkResource(normalizedURL: raw, host: "example.com", routeSignature: fallback.routeSignature, fallbackTitle: fallback.title, fallbackState: fallback.state, createdAt: oldDate))
        if index < 2 {
            resource.requestState = index == 0 ? .notFound : .needsAuthentication
            resource.lastAttemptAt = recent; resource.lastResolvedAt = index == 0 ? oldDate : nil
            resource.resolvedTitle = index == 0 ? "Previously saved title" : nil
            let latest = LinkResolutionAttempt(linkResourceID: resource.id, startedAt: recent, finishedAt: recent.addingTimeInterval(2), resolver: .webKit, requestState: resource.requestState, httpStatus: index == 0 ? 404 : 401, quality: .loginOrError, durationMilliseconds: 2000)
            try await repo.saveLinkResolution(resource, attempt: latest)
            // Save an older attempt afterwards: display must still select the latest timestamp.
            try await repo.saveLinkResolution(resource, attempt: LinkResolutionAttempt(linkResourceID: resource.id, startedAt: oldDate, finishedAt: oldDate.addingTimeInterval(1), resolver: .anonymousHTTP, requestState: .resolved, httpStatus: 200, quality: .distinctive, durationMilliseconds: 1000))
        }
    }
    let entries = try await repo.linkResolutionEntries(limit: 100)
    #expect(entries.count == 3)
    let unavailable = try #require(entries.first { $0.resource.requestState == .notFound })
    #expect(unavailable.latestAttempt?.httpStatus == 404 && unavailable.latestAttempt?.resolver == .webKit)
    #expect(unavailable.sourceApplications == ["Chrome"] && unavailable.retainedTitleAfterFailure)
    #expect(unavailable.cannotAccess && !unavailable.needsLogin && unavailable.activityDate == recent.addingTimeInterval(2))
    #expect(entries.filter(\.needsLogin).count == 1)
    let pending = try #require(entries.first { $0.resource.requestState == .pending })
    #expect(pending.latestAttempt == nil && pending.activityDate == oldDate)
    #expect(LinkResolutionDay.grouped(entries).count == 2)
    #expect(LinkResolutionDateScope.selectedDay.contains(oldDate, selectedDay: oldDate))
    #expect(!LinkResolutionDateScope.selectedDay.contains(recent, selectedDay: oldDate))
}

@Test @MainActor func activityRanksAndGroupScoresRefreshAfterHumanCopyWithoutModelRequests() async throws {
    let dirs = try AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: dirs.root) }
    let suite = "ActivityRanks." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults), repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile)
    let clips = try [90.0, 20.0, 1.0].enumerated().map { index, days in
        try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data("Rank source \(index)".utf8))])], source: .init(appName: "Tests", confidence: .high), capturedAt: Date().addingTimeInterval(-days * 86_400))))
    }
    try await repo.saveBatch(clips)
    var first = AIGroupProfile(name: "Older", definition: "Older source"), second = AIGroupProfile(name: "Recent", definition: "Recent source")
    first.memberIDs = [clips[0].id]; second.memberIDs = [clips[2].id]
    let catalog = [first.id: first, second.id: second]
    try await repo.updateAIState { $0.groups = catalog }
    let controller = AIOrganizationController(repository: repo, settings: settings, directories: dirs)
    try await controller.reload(); await controller.waitUntilIdle()
    #expect(controller.clipActivityPercentiles[clips[0].id] == 100)
    #expect(controller.groupActivityPercentiles[first.id] == 100)
    let before = controller.groupActivity(first).score
    try await repo.recordHumanActivity(id: clips[0].id, event: .copy, at: Date())
    controller.synchronize(try #require(await repo.clip(id: clips[0].id)))
    await controller.waitUntilIdle()
    #expect(controller.clipActivityPercentiles[clips[0].id] == 34)
    #expect(controller.groupActivityPercentiles[first.id] == 50)
    #expect(controller.groupActivity(first).score > before)
    #expect(controller.state.usage.isEmpty)
}
