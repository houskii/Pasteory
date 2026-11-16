import AppKit
import Foundation
import PasteoryCore
import Testing
@testable import Pasteory

@Test @MainActor func openingThePanelFlushesCopiesBeforeThePollingTickAndDoesNotRecaptureOwnWrites() async throws {
    let suite = "ClipboardFlush." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.enabledSourceCaptureApplications.isEmpty)
    let pasteboard = NSPasteboard(name: .init(suite)); defer { pasteboard.releaseGlobally() }
    var captures = [PasteboardCapture]()
    let monitor = ClipboardMonitor(pasteboard: pasteboard, settings: settings,
                                   sourceContextCapture: SourceContextCaptureCoordinator(settings: settings),
                                   onCapture: { captures.append($0) })
    monitor.start(); defer { monitor.stop() }
    pasteboard.clearContents(); pasteboard.setString("Copied immediately before opening", forType: .string)
    await monitor.flushPendingCapture()
    #expect(captures.count == 1)
    #expect(captures.first?.items.first?.representations.first?.data == Data("Copied immediately before opening".utf8))
    await monitor.flushPendingCapture(); #expect(captures.count == 1)
    pasteboard.clearContents(); pasteboard.setString("Pasteory's own write", forType: .string)
    monitor.markOwnWrite(changeCount: pasteboard.changeCount)
    await monitor.flushPendingCapture(); #expect(captures.count == 1)
    monitor.stop()
    pasteboard.clearContents(); pasteboard.setString("Monitoring is stopped", forType: .string)
    await monitor.flushPendingCapture(); #expect(captures.count == 1)
}

@Test @MainActor func aSlowClipboardCaptureDoesNotHoldThePanelOpenAndStillCompletesOnce() async throws {
    let suite = "ClipboardBoundedFlush." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let pasteboard = NSPasteboard(name: .init(suite)); defer { pasteboard.releaseGlobally() }
    var delivered = 0, settled = false
    let gate = ClipboardTestGate()
    let monitor = ClipboardMonitor(pasteboard: pasteboard, settings: settings,
                                   sourceContextCapture: SourceContextCaptureCoordinator(settings: settings),
                                   onCapture: { _ in await gate.wait(); delivered += 1 })
    monitor.onCaptureSettled = { settled = true }
    monitor.start(); defer { monitor.stop() }
    pasteboard.clearContents(); pasteboard.setString("Slow synthetic capture", forType: .string)
    let ready = await monitor.flushPendingCapture(maximumWait: .milliseconds(15))
    #expect(!ready && !settled && delivered == 0)
    await gate.open()
    #expect(await monitor.flushPendingCapture())
    #expect(delivered == 1 && settled)
}

private actor ClipboardTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true; continuation?.resume(); continuation = nil
    }
}
