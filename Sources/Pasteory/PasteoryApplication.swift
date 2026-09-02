import AppKit
import PasteoryCore

@main
enum PasteoryApplication {
    @MainActor
    static func main() {
        do {
            try PasteoryRuntimeIdentity.validateCurrentBundleConfiguration()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Pasteory 构建身份无效"
            alert.runModal()
            return
        }
#if DEBUG
        if DebugSourceContextProbe.runIfRequested() { return }
#endif
        if ProcessInfo.processInfo.arguments.contains("--install-chrome-native-host") {
            do {
                try ChromeExtensionIntegration.installNativeHostManifest()
                print("chrome-native-host-installed")
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
            }
            return
        }
        if ChromeNativeMessagingHost.shouldRun {
            ChromeNativeMessagingHost.run()
            return
        }
        let application = NSApplication.shared
        TextEditingCommands.installMainMenu(on: application)
        let delegate = AppDelegate()
        application.delegate = delegate
#if DEBUG
        application.setActivationPolicy(
            ProcessInfo.processInfo.arguments.contains("--debug-ui-qa") ? .regular : .accessory
        )
#else
        application.setActivationPolicy(.accessory)
#endif
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
            let linkResolutionService = LinkResolutionService(repository: repository)
            ApplicationCatalog.configure(cacheDirectory: directories.applicationCache)
            if PasteoryRuntimeIdentity.current.chromeIntegrationEnabled {
                try? ChromeExtensionIntegration.installNativeHostManifest()
            }
            let state = AppState(
                repository: repository,
                attachments: attachments,
                archive: archive,
                backup: backup,
                settings: settings,
                linkResolutionService: linkResolutionService
            )
            let coordinator = AppCoordinator(state: state, settings: settings, attachments: attachments)
            self.coordinator = coordinator
            coordinator.start()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Pasteory 无法启动"
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showSettings()
        return true
    }
}
