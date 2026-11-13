import AppKit
import PasteoryCore

@MainActor
final class QuickTextActionCoordinator {
    struct Result {
        var clip: Clip
        var output: String
    }

    private let repository: any ClipRepository
    private let attachments: AttachmentStore
    private let pasteboard: NSPasteboard
    weak var monitor: ClipboardMonitor?

    init(repository: any ClipRepository, attachments: AttachmentStore, pasteboard: NSPasteboard? = nil) {
        self.repository = repository
        self.attachments = attachments
        if let pasteboard {
            self.pasteboard = pasteboard
        } else {
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--debug-quick-action-pasteboard"), arguments.indices.contains(index + 1) {
                self.pasteboard = NSPasteboard(name: NSPasteboard.Name(arguments[index + 1]))
            } else {
                self.pasteboard = .general
            }
#else
            self.pasteboard = .general
#endif
        }
    }

    func perform(_ action: QuickTextAction, input: String, sourceClip: Clip?) async throws -> Result {
        let source = ClipSource(
            appName: PasteoryRuntimeIdentity.current.displayName,
            bundleIdentifier: PasteoryRuntimeIdentity.current.bundleIdentifier,
            confidence: .high
        )
        let clip = try await Task.detached(priority: .userInitiated) {
            try action.makeResultClip(input: input, sourceClip: sourceClip, source: source)
        }.value
        let output = try await ClipTextReader.read(clip, attachments: attachments)
        let stored = try await repository.saveCaptured(clip, context: nil)
        try copy(output)
        return Result(clip: stored, output: output)
    }

    func copy(_ text: String) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw PasteError.writeFailed }
        monitor?.markOwnWrite(changeCount: pasteboard.changeCount)
    }
}
