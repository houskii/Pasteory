import Foundation
import Testing
@testable import Pasteory

@MainActor
private final class CacheFixture {
    let suite = "Pasteory.WebCacheTests.\(UUID())"
    let defaults: UserDefaults
    let settings: AppSettings
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var bytes: Int64 = 0
    var clears = 0
    var holdClearance: CheckedContinuation<Void, Never>?

    init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = AppSettings(defaults: defaults)
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite) }

    func makeMaintenance() -> WebCacheMaintenance {
        WebCacheMaintenance(settings: settings, measure: { self.bytes }, clear: {
            self.clears += 1
            self.bytes = 0
        }, now: { self.now }, idleDelay: .zero)
    }
}

@Test @MainActor func cacheMaintenanceClearsOnFirstUseAgeAndCapacity() async {
    let fixture = CacheFixture()
    defer { fixture.cleanup() }
    let cache = fixture.makeMaintenance()
    #expect(fixture.settings.automaticWebCacheCleanup)
    await cache.check()
    #expect(fixture.settings.lastWebCacheCleanup == nil)
    fixture.bytes = 1
    await cache.check()
    #expect(fixture.clears == 1)
    #expect(AppSettings(defaults: fixture.defaults).lastWebCacheCleanup == fixture.now)

    fixture.bytes = 100_000_000
    fixture.now += 86_399
    await cache.check()
    #expect(fixture.clears == 1)
    fixture.now += 1
    await cache.check()
    #expect(fixture.clears == 2)

    fixture.bytes = 100_000_001
    await cache.check()
    #expect(fixture.clears == 3)
}

@Test @MainActor func cacheMaintenanceDefersAndCoalescesManualRequestsWithAutomaticOff() async {
    let fixture = CacheFixture()
    defer { fixture.cleanup() }
    let other = CacheFixture()
    defer { other.cleanup() }
    fixture.settings.automaticWebCacheCleanup = false
    #expect(other.settings.automaticWebCacheCleanup)
    let cache = fixture.makeMaintenance()
    fixture.bytes = 200_000_000
    await cache.check()
    #expect(fixture.clears == 0)

    let login = cache.beginActivity()
    let batch = cache.beginActivity()
    await cache.check(manual: true)
    await cache.check(manual: true)
    #expect(cache.manualPending)
    cache.endActivity(login)
    await cache.check()
    #expect(fixture.clears == 0)
    cache.endActivity(batch)
    await cache.check()
    #expect(fixture.clears == 1)
    #expect(!cache.manualPending)
    #expect(other.settings.lastWebCacheCleanup == nil)
}

@Test @MainActor func cacheMaintenanceDoesNotOverlapClearanceWithNewNavigation() async {
    let fixture = CacheFixture()
    defer { fixture.cleanup() }
    var started = false
    let cache = WebCacheMaintenance(settings: fixture.settings, measure: { 200_000_000 }, clear: {
        fixture.clears += 1
        await withCheckedContinuation { fixture.holdClearance = $0 }
    }, idleDelay: .seconds(60))
    let first = Task { await cache.check() }
    while fixture.holdClearance == nil { await Task.yield() }
    let login = cache.beginActivity()
    let navigation = Task {
        await cache.waitForClearance()
        started = true
    }
    await cache.check(manual: true)
    #expect(!started)
    #expect(fixture.clears == 1)
    fixture.holdClearance?.resume()
    fixture.holdClearance = nil
    await first.value
    await navigation.value
    #expect(started)
    #expect(!cache.manualPending)
    cache.endActivity(login)
}
