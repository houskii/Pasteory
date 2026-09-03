import AppKit
import Foundation
import PasteoryCore
import UniformTypeIdentifiers

enum ClipOpenError: LocalizedError {
    case unsupportedKind(ClipKind)
    case browserNotConfigured
    case codeEditorNotConfigured
    case fileRuleNotConfigured(String)
    case fileHasNoExtension
    case applicationUnavailable(String)
    case contentUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedKind(let kind): "暂不支持打开“\(kind.displayName)”内容"
        case .browserNotConfigured: "尚未配置网页浏览器，请先前往“设置 → 打开方式”"
        case .codeEditorNotConfigured: "尚未配置代码编辑器，请先前往“设置 → 打开方式”"
        case .fileRuleNotConfigured(let fileExtension): "尚未为 .\(fileExtension) 文件配置打开应用"
        case .fileHasNoExtension: "这个文件没有后缀，无法匹配打开规则"
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

    init(settings: AppSettings, attachments: AttachmentStore, workspace: NSWorkspace = .shared) {
        self.settings = settings
        self.attachments = attachments
        self.workspace = workspace
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
            let fileExtension = resolvedURL.pathExtension.lowercased()
            guard !fileExtension.isEmpty else { throw ClipOpenError.fileHasNoExtension }
            guard let bundleIdentifier = settings.applicationBundleIdentifier(forFileExtension: fileExtension) else {
                throw ClipOpenError.fileRuleNotConfigured(fileExtension)
            }
            try await open(resolvedURL, withBundleIdentifier: bundleIdentifier)

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
