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
