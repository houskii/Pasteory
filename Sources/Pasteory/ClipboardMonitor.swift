import AppKit
import Foundation
import PasteoryCore

@MainActor
final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private let settings: AppSettings
    private let sourceContextCapture: SourceContextCaptureCoordinator
    private let onCapture: (PasteboardCapture) async -> Void
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ownChangeCounts = Set<Int>()
    private var observers = [NSObjectProtocol]()
    private(set) var isRunning = false

    init(
        pasteboard: NSPasteboard = .general,
        settings: AppSettings,
        sourceContextCapture: SourceContextCaptureCoordinator,
        onCapture: @escaping (PasteboardCapture) async -> Void
    ) {
        self.pasteboard = pasteboard
        self.settings = settings
        self.sourceContextCapture = sourceContextCapture
        self.onCapture = onCapture
        self.lastChangeCount = pasteboard.changeCount
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspendTimer() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspendTimer() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        })
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastChangeCount = pasteboard.changeCount
        schedule(after: settings.clipboardPollingInterval.rawValue)
    }

    func stop() {
        isRunning = false
        timer?.invalidate(); timer = nil
    }

    func markOwnWrite(changeCount: Int) {
        ownChangeCounts.insert(changeCount)
        if ownChangeCounts.count > 20 { ownChangeCounts = Set(ownChangeCounts.sorted().suffix(10)) }
    }

    private func suspendTimer() { timer?.invalidate(); timer = nil }

    private func resumeAfterWake() {
        guard isRunning else { return }
        lastChangeCount = pasteboard.changeCount
        schedule(after: settings.clipboardPollingInterval.rawValue)
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        guard isRunning else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = min(0.1, interval * 0.1)
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func tick() {
        defer { schedule(after: settings.clipboardPollingInterval.rawValue) }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if ownChangeCounts.remove(count) != nil { return }
        guard settings.monitoringEnabled else { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication
        let bundle = sourceApp?.bundleIdentifier
        let policy = settings.capturePolicy
        guard bundle.map({ !policy.excludedBundleIdentifiers.contains($0) }) ?? true else { return }
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else { return }
        let allTypes = Set(pasteboardItems.flatMap { $0.types.map(\.rawValue) })
        guard policy.excludedPasteboardTypes.isDisjoint(with: allTypes) else { return }

        var capturedItems = [CapturedItem]()
        for (index, item) in pasteboardItems.enumerated() {
            var representations = [CapturedRepresentation]()
            var oversized = false
            for type in item.types where !policy.excludedPasteboardTypes.contains(type.rawValue) {
                guard let data = item.data(forType: type) else { continue }
                if data.count > policy.maximumItemBytes { oversized = true; break }
                representations.append(CapturedRepresentation(uti: type.rawValue, data: data))
            }
            if oversized { return }
            if !representations.isEmpty { capturedItems.append(CapturedItem(order: index, representations: representations)) }
        }
        guard !capturedItems.isEmpty else { return }
        let source = ClipSource(
            appName: sourceApp?.localizedName ?? "未知来源",
            bundleIdentifier: bundle,
            processIdentifier: sourceApp?.processIdentifier,
            confidence: bundle == nil ? .unknown : .high
        )
        let capturedAt = Date()
        let copiedText = capturedItems.lazy.flatMap(\.representations).first(where: {
            ["public.utf8-plain-text", "public.text", "NSStringPboardType", "public.url"].contains($0.uti)
        }).flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        Task {
            let context = await sourceContextCapture.captureContext(for: source, copiedText: copiedText, capturedAt: capturedAt)
            let effectiveSource: ClipSource
            if context?.strategyIdentifier == "chrome.extension.web-context.v1",
               SourceCaptureApplication.application(for: source.bundleIdentifier) != .chrome {
                effectiveSource = ClipSource(appName: "Google Chrome", bundleIdentifier: "com.google.Chrome", confidence: .high)
            } else {
                effectiveSource = source
            }
            await onCapture(PasteboardCapture(
                items: capturedItems,
                source: effectiveSource,
                capturedAt: capturedAt,
                sourceContext: context
            ))
        }
    }
}
