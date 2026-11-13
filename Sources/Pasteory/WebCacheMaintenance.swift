import Combine
import Foundation

@MainActor
final class WebCacheMaintenance: ObservableObject {
    static let maximumBytes: Int64 = 100_000_000
    static let cleanupInterval: TimeInterval = 86_400

    private let settings: AppSettings
    private let measure: () async -> Int64
    private let clear: () async -> Void
    private let now: () -> Date
    private let idleDelay: Duration
    private var active = Set<UUID>()
    private var idleCheck: Task<Void, Never>?
    private var work: Task<Void, Never>?
    @Published private(set) var manualPending = false
    @Published private(set) var isClearing = false
    var onCleared: (() -> Void)?

    init(
        settings: AppSettings,
        measure: @escaping () async -> Int64,
        clear: @escaping () async -> Void,
        now: @escaping () -> Date = Date.init,
        idleDelay: Duration = .seconds(2)
    ) {
        self.settings = settings
        self.measure = measure
        self.clear = clear
        self.now = now
        self.idleDelay = idleDelay
    }

    func beginActivity() -> UUID {
        idleCheck?.cancel()
        let id = UUID()
        active.insert(id)
        return id
    }

    func endActivity(_ id: UUID) {
        guard active.remove(id) != nil, active.isEmpty else { return }
        idleCheck?.cancel()
        idleCheck = Task { [weak self, idleDelay] in
            do { try await Task.sleep(for: idleDelay) } catch { return }
            await self?.check()
        }
    }

    func waitForClearance() async {
        if isClearing { await work?.value }
    }

    func check(manual: Bool = false) async {
        if manual, !isClearing { manualPending = true }
        guard active.isEmpty else { return }
        if let work {
            await work.value
            return
        }
        guard manualPending || settings.automaticWebCacheCleanup else { return }
        let task = Task { [self] in
            defer { work = nil }
            let bytes = await measure()
            // The scan suspends; a page may have opened or the setting changed.
            guard active.isEmpty else { return }
            let age = settings.lastWebCacheCleanup.map { now().timeIntervalSince($0) } ?? .infinity
            let due = settings.automaticWebCacheCleanup && bytes > 0 &&
                (bytes > Self.maximumBytes || age >= Self.cleanupInterval)
            guard manualPending || due else { return }
            manualPending = false
            isClearing = true
            await clear()
            settings.lastWebCacheCleanup = now()
            isClearing = false
            onCleared?()
        }
        work = task
        await task.value
    }
}
