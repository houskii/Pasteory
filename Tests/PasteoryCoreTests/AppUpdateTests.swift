import Foundation
import Testing
@testable import PasteoryCore
@testable import Pasteory

@Test func updateChecksUseElapsedDaysAndSurviveRelaunch() {
    let lastCheck = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(AppUpdatePolicy.checkIsDue(lastCheck: nil, now: lastCheck))
    #expect(!AppUpdatePolicy.checkIsDue(lastCheck: lastCheck, now: lastCheck.addingTimeInterval(86_399)))
    #expect(AppUpdatePolicy.checkIsDue(lastCheck: lastCheck, now: lastCheck.addingTimeInterval(86_400)))
    #expect(AppUpdatePolicy.checkIsDue(lastCheck: lastCheck, now: lastCheck.addingTimeInterval(172_800)))
    #expect(!AppUpdatePolicy.checkIsDue(lastCheck: lastCheck, now: lastCheck.addingTimeInterval(-60)))
}

@Test func updateDownloadsMustComeFromThisRepositorysGitHubReleaseAssets() {
    #expect(AppUpdatePolicy.isGitHubDownload(URL(string: "https://github.com/houskii/Pasteory/releases/download/v0.1.26/Pasteory-0.1.26-arm64.dmg")))
    for value in [
        "http://github.com/houskii/Pasteory/releases/download/v1/App.dmg",
        "https://github.com.evil.example/houskii/Pasteory/releases/download/v1/App.dmg",
        "https://github.com/another/repo/releases/download/v1/App.dmg",
        "https://github.com/houskii/Pasteory/blob/main/App.dmg",
        "https://github.com/houskii/Pasteory/releases/download/",
        "https://user@github.com/houskii/Pasteory/releases/download/v1/App.dmg"
    ] { #expect(!AppUpdatePolicy.isGitHubDownload(URL(string: value))) }
    #expect(!AppUpdatePolicy.isGitHubDownload(nil))
}

@Test func cachedUpdatesUseNumericBuildOrdering() {
    let update = AppUpdate(version: "0.1.26", build: "100", publishedAt: nil, notes: "", downloadURL: nil, releaseURL: nil)
    #expect(update.isNewer(thanBuild: "99"))
    #expect(!update.isNewer(thanBuild: "100"))
    #expect(!update.isNewer(thanBuild: "101"))
}

@MainActor
@Test func cancellingAnUpdateCheckDoesNotApproveInstallation() throws {
    let name = "app.pasteory.tests.updates.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let service = UpdateService(defaults: defaults)
    #expect(service.responds(to: NSSelectorFromString("updater:didFinishUpdateCycleForUpdateCheck:error:")))
    var cancelled = 0
    service.showUserInitiatedUpdateCheck { cancelled += 1 }
    #expect(service.isShowingDialog)
    #expect(!service.canInstall)
    #expect(service.closeDialog())
    #expect(cancelled == 1)
    #expect(!service.isShowingDialog)
    service.closeDialog()
    #expect(cancelled == 1)
}
