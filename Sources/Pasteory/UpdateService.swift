import AppKit
import Combine
import PasteoryCore
import Sparkle

/// One updater for the entire app. Scheduled checks publish a badge; only a user action opens UI.
@MainActor
final class UpdateService: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    enum Stage { case idle, checking, available, current, downloading, extracting, installing, failed }

    @Published private(set) var availableUpdate: AppUpdate?
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var automaticChecksEnabled: Bool
    @Published private(set) var releaseNotes = ""
    @Published private(set) var isShowingDialog = false
    @Published private(set) var configurationMessage: String?

    let currentVersion: String
    let currentBuild: String
    var onPresent: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let defaults: UserDefaults
    private let bundle: Bundle
    private var updater: SPUUpdater?
    private var choiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var acknowledgement: (() -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var installationApproved = false
    private var observers = [NSObjectProtocol]()
    private let cacheKey = "PasteoryAvailableUpdate"
    private let checkDateKey = "PasteoryLastSuccessfulUpdateCheck"

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        automaticChecksEnabled = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: checkDateKey) as? Date
        if let data = defaults.data(forKey: cacheKey),
           let update = try? JSONDecoder().decode(AppUpdate.self, from: data),
           update.isNewer(thanBuild: currentBuild),
           AppUpdatePolicy.isGitHubDownload(update.downloadURL) {
            availableUpdate = update
        }
        super.init()
    }

    var canInstall: Bool { choiceReply != nil && AppUpdatePolicy.isGitHubDownload(availableUpdate?.downloadURL) }
    var canCloseDialog: Bool {
        stage != .extracting && stage != .installing && !(stage == .downloading && cancellation == nil)
    }
    var isBusy: Bool { stage == .checking || stage == .downloading || stage == .extracting || stage == .installing }

    func start() {
        guard updater == nil else { return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-update-available") {
            availableUpdate = AppUpdate(
                version: "0.1.27", build: "32", publishedAt: Date(),
                notes: "资料库已整合到设置。\n新增每日更新检查和 GitHub 自动下载安装。",
                downloadURL: URL(string: "https://github.com/houskii/Pasteory/releases/download/v0.1.27/Pasteory-0.1.27-arm64.dmg"),
                releaseURL: nil
            )
            releaseNotes = availableUpdate?.notes ?? ""
            configurationMessage = "更新预览使用演示数据，不执行下载安装。"
            return
        }
#endif
        guard PasteoryRuntimeIdentity.identity(for: bundle.bundleIdentifier).variant == .production else {
            configurationMessage = "QA 版本使用隔离环境，不接收正式应用更新。"
            automaticChecksEnabled = false
            availableUpdate = nil
            return
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-ui-qa")
            || ProcessInfo.processInfo.arguments.contains("--debug-data-root") {
            configurationMessage = "隔离调试环境不检查正式更新。"
            return
        }
#endif
        guard bundle.bundleURL.pathExtension == "app",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            configurationMessage = "此构建尚未配置更新签名，请安装正式发布的 Pasteory。"
            availableUpdate = nil
            return
        }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.updater = updater
        do {
            try updater.start()
            automaticChecksEnabled = updater.automaticallyChecksForUpdates
            lastCheckedAt = lastCheckedAt ?? updater.lastUpdateCheckDate
        } catch {
            self.updater = nil
            configurationMessage = error.localizedDescription
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.resumeScheduledChecks() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.resumeScheduledChecks() } })
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        automaticChecksEnabled = enabled
        if let updater { updater.automaticallyChecksForUpdates = enabled }
        else { defaults.set(enabled, forKey: "SUEnableAutomaticChecks") }
    }

    private func resumeScheduledChecks() {
        guard automaticChecksEnabled, !isBusy, !isShowingDialog,
              AppUpdatePolicy.checkIsDue(lastCheck: lastCheckedAt) else { return }
        updater?.resetUpdateCycle()
    }

    func checkForUpdates() {
        if isShowingDialog { onPresent?(); return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-update-available") {
            stage = .available
            presentDialog()
            return
        }
#endif
        guard let updater else {
            lastError = configurationMessage ?? "更新服务尚未就绪。"
            stage = .failed
            presentDialog()
            return
        }
        guard updater.canCheckForUpdates else { return }
        lastError = nil
        updater.checkForUpdates()
    }

    func installUpdate() {
        guard canInstall, let reply = choiceReply else { return }
        installationApproved = true
        choiceReply = nil
        progress = 0
        stage = .downloading
        reply(.install)
    }

    /// Called by both the cancel button and the titlebar close button.
    @discardableResult
    func closeDialog() -> Bool {
        guard canCloseDialog else { return false }
        let reply = choiceReply
        let cancel = cancellation
        let acknowledge = acknowledgement
        choiceReply = nil; cancellation = nil; acknowledgement = nil
        installationApproved = false
        isShowingDialog = false
        onDismiss?()
        if let reply { reply(.dismiss) }
        else if let cancel { cancel() }
        else { acknowledge?() }
        return true
    }

    private func presentDialog() {
        isShowingDialog = true
        onPresent?()
    }

    private func cache(_ update: AppUpdate?) {
        availableUpdate = update
        if let update, let data = try? JSONEncoder().encode(update) { defaults.set(data, forKey: cacheKey) }
        else { defaults.removeObject(forKey: cacheKey) }
    }

    // MARK: Sparkle lifecycle

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        lastCheckedAt = Date()
        defaults.set(lastCheckedAt, forKey: checkDateKey)
        lastError = nil
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard AppUpdatePolicy.isGitHubDownload(item.fileURL) else { return }
        cache(descriptor(for: item))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        cache(nil)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        lastError = error.localizedDescription
    }

    private func descriptor(for item: SUAppcastItem) -> AppUpdate {
        AppUpdate(
            version: item.displayVersionString, build: item.versionString, publishedAt: item.date,
            notes: item.itemDescriptionFormat == "plain-text"
                ? (item.itemDescription ?? "暂无更新说明。")
                : Self.plainTextNotes(item.itemDescription ?? "暂无更新说明。"),
            downloadURL: item.fileURL,
            releaseURL: AppUpdatePolicy.isGitHubReleasePage(item.infoURL) ? item.infoURL : nil
        )
    }

    // MARK: Custom user driver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticChecksEnabled, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        stage = .checking
        installationApproved = false
        presentDialog()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        guard AppUpdatePolicy.isGitHubDownload(appcastItem.fileURL) else {
            cache(nil)
            lastError = "此更新未提供可安装的 GitHub 发布包，请到发布页面查看说明。"
            stage = .failed
            reply(.dismiss)
            if state.userInitiated { presentDialog() }
            return
        }
        let update = descriptor(for: appcastItem)
        cache(update)
        releaseNotes = update.notes
        stage = .available
        if state.userInitiated {
            choiceReply = reply
            presentDialog()
        } else {
            // Finish the scheduled session without stealing focus or downloading anything.
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if let text = String(data: downloadData.data, encoding: .utf8) {
            releaseNotes = Self.plainTextNotes(text)
        }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        if releaseNotes.isEmpty { releaseNotes = "暂时无法加载更新说明，可稍后重试。" }
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        self.acknowledgement = acknowledgement
        stage = .current
        lastError = error.localizedDescription
        presentDialog()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        choiceReply = nil; cancellation = nil
        installationApproved = false
        self.acknowledgement = acknowledgement
        stage = .failed
        lastError = error.localizedDescription
        presentDialog()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        receivedBytes = 0; expectedBytes = 0; progress = 0
        stage = .downloading
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        if expectedBytes > 0 { progress = min(1, Double(receivedBytes) / Double(expectedBytes)) }
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        progress = 0
        stage = .extracting
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        self.progress = min(1, max(0, progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The user already approved installation and restart in the confirmation dialog.
        if installationApproved { reply(.install) }
        else {
            choiceReply = reply
            stage = .available
            presentDialog()
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        stage = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        choiceReply = nil; cancellation = nil; acknowledgement = nil
        installationApproved = false
        isShowingDialog = false
        onDismiss?()
    }

    func showUpdateInFocus() { presentDialog() }

    /// Release notes are displayed as text, never as a web page with scripts or remote assets.
    private static func plainTextNotes(_ value: String) -> String {
        value.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</li>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
