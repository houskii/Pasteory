import AppKit
import Foundation
import PasteoryCore
import UniformTypeIdentifiers

private final class FileCommandLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let maximumOutputBytes = 1_024 * 1_024
    private var outputBytes = 0
    private var wroteTruncationNotice = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, maximumOutputBytes - outputBytes)
        if remaining > 0 {
            let accepted = data.prefix(remaining)
            try? handle.write(contentsOf: accepted)
            outputBytes += accepted.count
        }
        if data.count > remaining, !wroteTruncationNotice {
            try? handle.write(contentsOf: Data("\n\n…日志输出超过 1 MB，后续内容已省略…\n".utf8))
            wroteTruncationNotice = true
        }
    }

    func finish(exitCode: Int32) {
        lock.lock()
        defer { lock.unlock() }
        let footer = "\n\n结束：\(Date().formatted(.iso8601))\n退出码：\(exitCode)\n"
        try? handle.write(contentsOf: Data(footer.utf8))
        try? handle.close()
    }

    func failToLaunch(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        let footer = "\n\n启动失败：\(error.localizedDescription)\n"
        try? handle.write(contentsOf: Data(footer.utf8))
        try? handle.close()
    }
}

enum ClipOpenError: LocalizedError {
    case unsupportedKind(ClipKind)
    case browserNotConfigured
    case codeEditorNotConfigured
    case fileRuleNotConfigured(String)
    case fileApplicationNotConfigured(String)
    case fileCommandNotConfigured(String)
    case fileUnavailable
    case applicationUnavailable(String)
    case contentUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedKind(let kind): "暂不支持打开“\(kind.displayName)”内容"
        case .browserNotConfigured: "尚未配置链接浏览器，请先前往“设置 → 打开方式”"
        case .codeEditorNotConfigured: "尚未配置代码编辑器，请先前往“设置 → 打开方式”"
        case .fileRuleNotConfigured(let fileType): "尚未为“\(fileType)”配置打开方式"
        case .fileApplicationNotConfigured(let fileType): "尚未为“\(fileType)”选择打开应用"
        case .fileCommandNotConfigured(let fileType): "尚未为“\(fileType)”填写命令"
        case .fileUnavailable: "原文件已经删除，无法打开"
        case .applicationUnavailable(let bundleIdentifier): "找不到已配置的应用（\(bundleIdentifier)）"
        case .contentUnavailable: "当前项目没有可打开的原始内容"
        }
    }
}

@MainActor
final class ClipOpenCoordinator {
    private let settings: AppSettings
    private let attachments: AttachmentStore
    private let workspace: NSWorkspace
    private let onCommandCompletion: (@MainActor @Sendable (FileCommandExecution) -> Void)?
    private var runningFileCommands: [UUID: Process] = [:]

    init(
        settings: AppSettings,
        attachments: AttachmentStore,
        workspace: NSWorkspace = .shared,
        onCommandCompletion: (@MainActor @Sendable (FileCommandExecution) -> Void)? = nil
    ) {
        self.settings = settings
        self.attachments = attachments
        self.workspace = workspace
        self.onCommandCompletion = onCommandCompletion
    }

    func open(_ clip: Clip) async throws {
        switch clip.primaryKind {
        case .link:
            guard !settings.browserBundleIdentifier.isEmpty else { throw ClipOpenError.browserNotConfigured }
            guard let url = await firstURL(in: clip, acceptedUTIs: ["public.url"]) ?? URL(string: clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw ClipOpenError.contentUnavailable
            }
            try await open(url, withBundleIdentifier: settings.browserBundleIdentifier)

        case .image:
            let url: URL
            if let fileURL = await firstURL(in: clip, acceptedUTIs: ["public.file-url", "NSFilenamesPboardType"]),
               fileURL.isFileURL {
                url = fileURL
            } else {
                guard let representation = imageRepresentation(in: clip),
                      let data = try? await attachments.data(for: representation) else {
                    throw ClipOpenError.contentUnavailable
                }
                let fileExtension = UTType(representation.uti)?.preferredFilenameExtension ?? "png"
                url = try writeTemporary(data, fileExtension: fileExtension)
            }
            try await open(url, withBundleIdentifier: "com.apple.Preview")

        case .code:
            guard !settings.codeEditorBundleIdentifier.isEmpty else { throw ClipOpenError.codeEditorNotConfigured }
            let text = try await textContent(in: clip)
            let url = try writeTemporary(Data(text.utf8), fileExtension: fileExtension(for: clip.codeMetadata?.language))
            try await open(url, withBundleIdentifier: settings.codeEditorBundleIdentifier)

        case .file:
            guard let url = await firstURL(in: clip, acceptedUTIs: ["public.file-url", "NSFilenamesPboardType"]), url.isFileURL else {
                throw ClipOpenError.contentUnavailable
            }
            let resolvedURL = PasteboardFileURLDecoder.resolvedPathURL(url)
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                throw ClipOpenError.fileUnavailable
            }
            let uti = try? resolvedURL.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
            let descriptor = FileIconResolver.descriptor(fileName: resolvedURL.lastPathComponent, uti: uti)
            let fileTypeName = FileIconResolver.fileType(assetName: descriptor.assetName)?.displayName ?? descriptor.label
            guard let rule = settings.fileOpenRule(fileName: resolvedURL.lastPathComponent, uti: uti) else {
                throw ClipOpenError.fileRuleNotConfigured(fileTypeName)
            }
            switch rule.action {
            case .application:
                guard !rule.bundleIdentifier.isEmpty else {
                    throw ClipOpenError.fileApplicationNotConfigured(fileTypeName)
                }
                try await open(resolvedURL, withBundleIdentifier: rule.bundleIdentifier)
            case .command:
                let command = rule.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { throw ClipOpenError.fileCommandNotConfigured(fileTypeName) }
                try runFileCommand(command, fileURL: resolvedURL, fileType: rule.matchIdentifier)
            }

        case .text, .color, .mixed:
            throw ClipOpenError.unsupportedKind(clip.primaryKind)
        }
    }

    private func open(_ url: URL, withBundleIdentifier bundleIdentifier: String) async throws {
        guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw ClipOpenError.applicationUnavailable(bundleIdentifier)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func runFileCommand(_ command: String, fileURL: URL, fileType: String) throws {
        let invocation = FileCommandInvocation.make(
            shell: settings.fileCommandShell,
            command: command,
            fileURL: fileURL
        )
        switch settings.fileCommandPresentation {
        case .silent:
            let logSession = settings.beginFileCommandLog(fileType: fileType, shell: settings.fileCommandShell)
            let process = Process()
            process.executableURL = invocation.executableURL
            process.arguments = invocation.arguments
            process.environment = invocation.environment
            process.currentDirectoryURL = invocation.currentDirectoryURL
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var outputPipe: Pipe?
            var logCapture: FileCommandLogCapture?
            if let (_, logHandle) = logSession {
                let pipe = Pipe()
                let capture = FileCommandLogCapture(handle: logHandle)
                outputPipe = pipe
                logCapture = capture
                process.standardOutput = pipe.fileHandleForWriting
                process.standardError = pipe.fileHandleForWriting
                pipe.fileHandleForReading.readabilityHandler = { readable in
                    let data = readable.availableData
                    if data.isEmpty { readable.readabilityHandler = nil }
                    else { capture.append(data) }
                }
            }
            let commandID = logSession?.0.id ?? UUID()
            let execution = logSession?.0
            let settings = settings
            let onCommandCompletion = onCommandCompletion
            let completionPipe = outputPipe
            let completionCapture = logCapture
            process.terminationHandler = { [weak self] completedProcess in
                let exitCode = completedProcess.terminationStatus
                completionPipe?.fileHandleForReading.readabilityHandler = nil
                if let remaining = try? completionPipe?.fileHandleForReading.readToEnd() {
                    completionCapture?.append(remaining)
                }
                try? completionPipe?.fileHandleForReading.close()
                completionCapture?.finish(exitCode: exitCode)
                Task { @MainActor [weak self] in
                    self?.runningFileCommands.removeValue(forKey: commandID)
                    guard let execution else { return }
                    let finished = settings.finishFileCommandLog(execution: execution, exitCode: exitCode)
                    onCommandCompletion?(finished)
                }
            }
            runningFileCommands[commandID] = process
            do {
                try process.run()
                try? outputPipe?.fileHandleForWriting.close()
            } catch {
                runningFileCommands.removeValue(forKey: commandID)
                if let (execution, _) = logSession {
                    outputPipe?.fileHandleForReading.readabilityHandler = nil
                    try? outputPipe?.fileHandleForReading.close()
                    try? outputPipe?.fileHandleForWriting.close()
                    logCapture?.failToLaunch(error)
                    let finished = settings.finishFileCommandLog(execution: execution, exitCode: -1)
                    onCommandCompletion?(finished)
                }
                throw error
            }
        case .terminalWindow:
            try runFileCommandInTerminal(invocation)
        }
    }

    private func runFileCommandInTerminal(_ invocation: FileCommandInvocation) throws {
        let process = Process()
        let completionMarkerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pasteory-FileCommand-\(UUID().uuidString).done")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", Self.terminalAppleScript,
            invocation.executableURL.path,
            invocation.environment["file"] ?? "",
            invocation.currentDirectoryURL.path,
            invocation.arguments.last ?? "",
            invocation.environment["PATH"] ?? "",
            completionMarkerURL.path
        ]
        let commandID = UUID()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runningFileCommands.removeValue(forKey: commandID)
            }
        }
        runningFileCommands[commandID] = process
        do {
            try process.run()
        } catch {
            runningFileCommands.removeValue(forKey: commandID)
            throw error
        }
    }

    private static let terminalAppleScript = """
    on run argv
        set shellPath to item 1 of argv
        set filePath to item 2 of argv
        set directoryPath to item 3 of argv
        set commandText to item 4 of argv
        set executablePath to item 5 of argv
        set completionMarker to item 6 of argv
        set launchCommand to "cd " & quoted form of directoryPath & " && env file=" & quoted form of filePath & " PATH=" & quoted form of executablePath & " " & quoted form of shellPath & " -c " & quoted form of commandText & "; commandStatus=$?; sleep 3; /usr/bin/touch " & quoted form of completionMarker & "; (exit $commandStatus)"
        tell application "Terminal"
            activate
            set targetTab to do script launchCommand
            set targetWindow to first window whose selected tab is targetTab
            repeat
                if not (exists targetWindow) then return
                try
                    POSIX file completionMarker as alias
                    exit repeat
                end try
                delay 0.2
            end repeat
            if exists targetWindow then close targetWindow
        end tell
        do shell script "/bin/rm " & quoted form of completionMarker
    end run
    """

    private func firstURL(in clip: Clip, acceptedUTIs: Set<String>) async -> URL? {
        for representation in clip.items.flatMap(\.representations) where acceptedUTIs.contains(representation.uti) {
            guard let data = try? await attachments.data(for: representation) else { continue }
            if let url = decodeURL(data, uti: representation.uti) { return url }
        }
        return nil
    }

    private func decodeURL(_ data: Data, uti: String) -> URL? {
        if uti == "NSFilenamesPboardType",
           let paths = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String],
           let path = paths.first {
            return URL(fileURLWithPath: path)
        }
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if uti == "public.file-url", value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        return URL(string: value)
    }

    private func imageRepresentation(in clip: Clip) -> ClipRepresentation? {
        clip.items.flatMap(\.representations).first {
            UTType($0.uti)?.conforms(to: .image) == true
        }
    }

    private func textContent(in clip: Clip) async throws -> String {
        let textUTIs = ["public.utf8-plain-text", "public.utf16-plain-text", "NSStringPboardType", "public.text"]
        for uti in textUTIs {
            for representation in clip.items.flatMap(\.representations) where representation.uti == uti {
                guard let data = try? await attachments.data(for: representation) else { continue }
                if uti.contains("utf16"), let text = String(data: data, encoding: .utf16) { return text }
                if let text = String(data: data, encoding: .utf8) { return text }
            }
        }
        guard !clip.previewText.isEmpty else { throw ClipOpenError.contentUnavailable }
        return clip.previewText
    }

    private func writeTemporary(_ data: Data, fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pasteory", isDirectory: true)
            .appendingPathComponent("Open", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func fileExtension(for language: CodeLanguage?) -> String {
        switch language {
        case .swift: "swift"
        case .kotlin: "kt"
        case .java: "java"
        case .python: "py"
        case .javascript: "js"
        case .typescript: "ts"
        case .shell: "sh"
        case .sql: "sql"
        case .json: "json"
        case .yaml: "yaml"
        case .xml: "xml"
        case .html: "html"
        case .css: "css"
        case nil: "txt"
        }
    }
}
