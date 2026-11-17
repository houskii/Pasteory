import Foundation
import Testing
@testable import Pasteory

@Test @MainActor func eachNewStoryGetsThreeSettingsOpeningsThenRestoresTheLastPageAcrossLaunches() throws {
    let suite = "StoryNavigation.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let story = UUID(), navigation = SettingsNavigation(defaults: defaults)
    for opening in 1...3 {
        navigation.open(storyEnabled: true, latestStoryID: story)
        #expect(navigation.destination == .story)
        navigation.storyViewed(story); navigation.storyViewed(story)
        navigation.open(storyEnabled: true, latestStoryID: story, newOpening: false)
        #expect(defaults.integer(forKey: "storyOpeningCount") == opening)
        navigation.destination = .aiOrganization; navigation.close()
    }
    let relaunched = SettingsNavigation(defaults: defaults)
    relaunched.open(storyEnabled: true, latestStoryID: story)
    #expect(relaunched.destination == .aiOrganization && defaults.integer(forKey: "storyOpeningCount") == 3)
    relaunched.close()
    relaunched.open(storyEnabled: true, latestStoryID: UUID())
    #expect(relaunched.destination == .story && defaults.integer(forKey: "storyOpeningCount") == 1)
}

@Test @MainActor func temporaryStoryLandingsDoNotOverwriteTheRememberedSettingsPage() throws {
    let suite = "StoryTemporaryLanding.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let navigation = SettingsNavigation(defaults: defaults), story = UUID()
    navigation.destination = .shortcuts
    for _ in 0..<3 {
        navigation.open(storyEnabled: true, latestStoryID: story)
        #expect(navigation.destination == .story)
        navigation.close()
    }
    navigation.open(storyEnabled: true, latestStoryID: story)
    #expect(navigation.destination == .shortcuts)
}

@Test @MainActor func explicitLibraryRoutesAndEmptyOrHiddenStoriesDoNotConsumeStoryOpenings() throws {
    let suite = "StoryNavigationRoutes.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let navigation = SettingsNavigation(defaults: defaults), story = UUID()
    navigation.open(requested: .library, storyEnabled: true, latestStoryID: story)
    #expect(navigation.destination == .library && defaults.integer(forKey: "storyOpeningCount") == 0)
    navigation.close(); navigation.open(storyEnabled: true, latestStoryID: nil)
    #expect(navigation.destination == .story && defaults.integer(forKey: "storyOpeningCount") == 0)
    navigation.storyViewed(story)
    #expect(defaults.integer(forKey: "storyOpeningCount") == 1)
    navigation.close(); let replacement = UUID(); navigation.storyViewed(replacement)
    #expect(defaults.integer(forKey: "storyOpeningCount") == 0)
    navigation.open(storyEnabled: false, latestStoryID: replacement)
    #expect(navigation.destination == .library && defaults.integer(forKey: "storyOpeningCount") == 0)
}
