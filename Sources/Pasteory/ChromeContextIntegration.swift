import AppKit
import Foundation
import PasteoryCore

struct ChromeWebCapturePayload: Codable, Sendable {
    struct ElementSnapshot: Codable, Sendable {
        var tag: String?
        var selector: String?
        var role: String?
        var ariaLabel: String?
        var href: String?
        var text: String?
        var html: String?
    }

    struct AncestorSnapshot: Codable, Sendable {
        var depth: Int?
        var tag: String?
        var selector: String?
        var text: String?
    }

    struct SurroundingContext: Codable, Sendable {
        var ancestors: [AncestorSnapshot]?
        var before: String?
        var after: String?
    }

    struct SiteAdapter: Codable, Sendable {
        var siteName: String?
        var projectId: String?
        var mergeRequestId: String?
        var repository: String?
        var branch: String?
        var targetBranch: String?
    }

    var schemaVersion: Int
    var capturedAt: Date
    var url: String
    var frameUrl: String?
    var topFrame: Bool?
    var hostname: String
    var siteName: String
    var pageTitle: String
    var selectedText: String
    var selectedHTML: String?
    var element: ElementSnapshot?
    var context: SurroundingContext?
    var adapter: SiteAdapter?
    var captureDurationMs: Double?
    var contextTruncated: Bool?

    func sourceContext() -> CapturedSourceContext {
        let provider = "chrome.extension.web-context.v1"
        let effectiveSiteName = nonEmpty(adapter?.siteName) ?? nonEmpty(siteName) ?? hostname
        let pageName = nonEmpty(pageTitle) ?? url
        var values: [String: String] = [
            "url": limited(url, 8_192),
            "hostname": limited(hostname, 256),
            "siteName": limited(effectiveSiteName, 256),
            "pageTitle": limited(pageName, 1_024),
            "selectedText": limited(selectedText, 8_192)
        ]
        add(selectedHTML, key: "selectedHTML", limit: 16_384, to: &values)
        add(element?.tag, key: "elementTag", limit: 80, to: &values)
        add(element?.selector, key: "elementSelector", limit: 512, to: &values)
        add(element?.role, key: "elementRole", limit: 80, to: &values)
        add(element?.ariaLabel, key: "elementAriaLabel", limit: 256, to: &values)
        add(element?.href, key: "elementLink", limit: 2_048, to: &values)
        add(element?.text, key: "elementText", limit: 2_048, to: &values)
        add(context?.before, key: "previousElementText", limit: 512, to: &values)
        add(context?.after, key: "nextElementText", limit: 512, to: &values)
        if let ancestors = context?.ancestors {
            let text = ancestors.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            add(text, key: "relatedText", limit: 2_048, to: &values)
        }
        add(adapter?.projectId, key: "projectId", limit: 128, to: &values)
        add(adapter?.mergeRequestId, key: "mergeRequestId", limit: 128, to: &values)
        add(adapter?.repository, key: "repository", limit: 256, to: &values)
        add(adapter?.branch, key: "branch", limit: 512, to: &values)
        add(adapter?.targetBranch, key: "targetBranch", limit: 512, to: &values)
        if let captureDurationMs { values["extensionCaptureDurationMs"] = String(format: "%.2f", captureDurationMs) }
        if contextTruncated == true { values["contextTruncated"] = "true" }

        var entities = [
            SourceContextEntity(
                kind: .website,
                provider: provider,
                stableIdentifier: hostname.lowercased(),
                displayName: effectiveSiteName,
                identityQuality: .stableIdentifier,
                metadata: ["hostname": hostname.lowercased()]
            )
        ]
        let pageIdentifier: String
        if let project = nonEmpty(adapter?.projectId), let mergeRequest = nonEmpty(adapter?.mergeRequestId) {
            pageIdentifier = "bits:\(project):merge-request:\(mergeRequest)"
        } else {
            pageIdentifier = url
        }
        entities.append(SourceContextEntity(
            kind: .page,
            provider: provider,
            stableIdentifier: pageIdentifier,
            displayName: pageName,
            identityQuality: .stableIdentifier,
            metadata: ["url": limited(url, 8_192)]
        ))
        if let repository = nonEmpty(adapter?.repository) {
            let repositoryID = [nonEmpty(adapter?.projectId), repository].compactMap { $0 }.joined(separator: "/")
            entities.append(SourceContextEntity(
                kind: .repository,
                provider: provider,
                stableIdentifier: "bits:\(repositoryID)",
                displayName: repository,
                identityQuality: .heuristic
            ))
            if let branch = nonEmpty(adapter?.branch) {
                entities.append(SourceContextEntity(
                    kind: .branch,
                    provider: provider,
                    stableIdentifier: "bits:\(repositoryID):\(branch)",
                    displayName: branch,
                    identityQuality: .heuristic,
                    metadata: ["repository": repository]
                ))
            }
        }
        return CapturedSourceContext(
            kind: .webPage,
            sourceCategory: .browser,
            strategyIdentifier: provider,
            summary: "\(effectiveSiteName) · \(pageName)",
            payload: values,
            entities: entities
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func limited(_ value: String, _ limit: Int) -> String { String(value.prefix(limit)) }

    private func add(_ value: String?, key: String, limit: Int, to values: inout [String: String]) {
        guard let value = nonEmpty(value) else { return }
        values[key] = limited(value, limit)
    }
}

enum ChromeContextInbox {
    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }()
    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()

    static func store(_ payload: ChromeWebCapturePayload) throws {
        let directories = try AppDirectories()
        let file = directories.browserContextInbox.appendingPathComponent("\(UUID().uuidString).json")
        try encoder.encode(payload).write(to: file, options: .atomic)
    }

    static func takeMatching(copiedText: String, now: Date = Date()) -> ChromeWebCapturePayload? {
        guard let directories = try? AppDirectories(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directories.browserContextInbox,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }
        let normalizedCopy = normalize(copiedText)
        var candidates = [(URL, Date)]()
        for file in files where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modifiedAt) > 30 {
                try? FileManager.default.removeItem(at: file)
            } else {
                candidates.append((file, modifiedAt))
            }
        }
        for (file, _) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? decoder.decode(ChromeWebCapturePayload.self, from: data),
                  abs(now.timeIntervalSince(payload.capturedAt)) <= 15,
                  normalize(payload.selectedText) == normalizedCopy else { continue }
            try? FileManager.default.removeItem(at: file)
            return payload
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ChromeNativeMessagingHost {
    static var name: String { PasteoryRuntimeIdentity.current.nativeMessagingHostName }
    static let extensionID = "mhmkadhgbgkioefidlaalkbdpndacikd"

    static var shouldRun: Bool {
        guard PasteoryRuntimeIdentity.current.chromeIntegrationEnabled else { return false }
        return ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("chrome-extension://\(extensionID)") }
            || ProcessInfo.processInfo.arguments.contains("--chrome-native-messaging-host")
    }

    static func run() {
        while let message = readMessage() {
            handle(message)
        }
    }

    private static func handle(_ message: [String: Any]) {
        let type = message["type"] as? String
        let requestID = message["requestId"] as? String
        switch type {
        case "getConfig":
            recordContact()
            sendConfig(requestID: requestID)
        case "capture":
            recordContact()
            guard let object = message["payload"], JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 128 * 1024 else {
                send(["type": "ack", "requestId": requestID ?? "", "ok": false, "error": "invalid_payload"])
                return
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let payload = try? decoder.decode(ChromeWebCapturePayload.self, from: data),
                  chromeCaptureEnabled() else {
                send(["type": "ack", "requestId": requestID ?? "", "ok": false, "error": "capture_disabled"])
                return
            }
            do {
                try ChromeContextInbox.store(payload)
                send(["type": "ack", "requestId": requestID ?? "", "ok": true])
            } catch {
                send(["type": "ack", "requestId": requestID ?? "", "ok": false, "error": "write_failed"])
            }
        default:
            send(["type": "error", "requestId": requestID ?? "", "error": "unsupported_message"])
        }
    }

    private static func chromeCaptureEnabled() -> Bool {
        let defaults = preferences()
        let applications = Set(defaults.stringArray(forKey: SourceCapturePreferenceKey.enabledApplications) ?? [])
        return applications.contains(SourceCaptureApplication.chrome.rawValue)
    }

    private static func sendConfig(requestID: String?) {
        send([
            "type": "config",
            "requestId": requestID ?? "",
            "ok": true,
            "chromeEnabled": chromeCaptureEnabled(),
            "language": preferences().string(forKey: AppLanguage.preferenceKey) ?? AppLanguage.english.rawValue
        ])
    }

    private static func preferences() -> UserDefaults {
        .standard
    }

    private static func recordContact() {
        guard let directories = try? AppDirectories() else { return }
        try? Data(String(Date().timeIntervalSince1970).utf8)
            .write(to: directories.browserContextInbox.appendingPathComponent("native-host-last-contact"), options: .atomic)
    }

    private static func readMessage() -> [String: Any]? {
        let input = FileHandle.standardInput
        let header = input.readData(ofLength: 4)
        guard header.count == 4 else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard length > 0, length <= 1_048_576 else { return nil }
        var data = Data()
        while data.count < Int(length) {
            let next = input.readData(ofLength: Int(length) - data.count)
            guard !next.isEmpty else { return nil }
            data.append(next)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        var length = UInt32(data.count).littleEndian
        let output = FileHandle.standardOutput
        output.write(Data(bytes: &length, count: 4))
        output.write(data)
    }
}

@MainActor
enum ChromeExtensionIntegration {
    struct Status {
        var extensionAvailable: Bool
        var nativeHostRegistered: Bool
        var lastContactAt: Date?
    }

    static func installNativeHostManifest() throws {
        guard PasteoryRuntimeIdentity.current.chromeIntegrationEnabled else {
            throw ChromeExtensionError.unavailableInQA
        }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let manifest: [String: Any] = [
            "name": ChromeNativeMessagingHost.name,
            "description": "Pasteory Web Context native bridge",
            "path": executable.standardizedFileURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(ChromeNativeMessagingHost.extensionID)/"]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        for directory in nativeHostDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(ChromeNativeMessagingHost.name).json"), options: .atomic)
        }
    }

    static func prepareInteractiveInstall() throws -> Int {
        guard PasteoryRuntimeIdentity.current.chromeIntegrationEnabled else {
            throw ChromeExtensionError.unavailableInQA
        }
        try installNativeHostManifest()
        guard let extensionDirectory else { throw ChromeExtensionError.extensionResourcesMissing }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(extensionDirectory.path, forType: .string)
        let changeCount = NSPasteboard.general.changeCount
        guard let url = URL(string: "chrome://extensions") else { return changeCount }
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: chrome,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
        return changeCount
    }

    static func status() -> Status {
        guard PasteoryRuntimeIdentity.current.chromeIntegrationEnabled else {
            return Status(extensionAvailable: false, nativeHostRegistered: false, lastContactAt: nil)
        }
        let manifests = nativeHostDirectories.map { $0.appendingPathComponent("\(ChromeNativeMessagingHost.name).json") }
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.path
        let registered = manifests.contains { manifest in
            guard let data = try? Data(contentsOf: manifest),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return (object["path"] as? String) == executable
        }
        let contact = (try? AppDirectories())?.browserContextInbox.appendingPathComponent("native-host-last-contact")
        let timestamp = contact.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
        return Status(
            extensionAvailable: extensionDirectory != nil,
            nativeHostRegistered: registered,
            lastContactAt: timestamp
        )
    }

    static var extensionDirectory: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension", isDirectory: true)
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) { return bundled }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let development = repository.appendingPathComponent("ChromeExtension", isDirectory: true)
        return FileManager.default.fileExists(atPath: development.appendingPathComponent("manifest.json").path) ? development : nil
    }

    private static var nativeHostDirectories: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google", isDirectory: true)
        return ["Chrome", "Chrome Beta", "Chrome Canary"].map {
            support.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        }
    }
}

enum ChromeExtensionError: LocalizedError {
    case extensionResourcesMissing
    case unavailableInQA

    var errorDescription: String? {
        switch self {
        case .extensionResourcesMissing:
            L10n.tr("找不到 Chrome 插件目录，请先重新构建 Pasteory。")
        case .unavailableInQA:
            L10n.tr("Pasteory QA 已隔离 Chrome 原生消息桥，请使用正式包验证 Chrome 插件。")
        }
    }
}
