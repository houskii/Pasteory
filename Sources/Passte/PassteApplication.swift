import AppKit
import PassteCore

@main
enum PassteApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        _ = delegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directories: AppDirectories
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--debug-data-root"), arguments.indices.contains(index + 1) {
                directories = try AppDirectories(root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            } else {
                directories = try AppDirectories()
            }
#else
            directories = try AppDirectories()
#endif
            let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
            let attachments = AttachmentStore(directories: directories)
            let archive = ArchiveService(repository: repository, directories: directories)
            let backup = BackupService(repository: repository, directories: directories)
            let settings = AppSettings()
            let state = AppState(repository: repository, attachments: attachments, archive: archive, backup: backup, settings: settings)
            let coordinator = AppCoordinator(state: state, settings: settings, attachments: attachments)
            self.coordinator = coordinator
            coordinator.start()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Passte 无法启动"
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
