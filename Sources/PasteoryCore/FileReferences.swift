import Foundation

public enum FileReferenceDecoder {
    private static let unresolvedFileReferencePrefix = "/.__pasteory_unresolved_file_reference__/"

    public static func urls(from data: Data, uti: String) -> [URL] {
        if uti == "NSFilenamesPboardType",
           let paths = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) as? [String] {
            return paths.map { resolvedFileURL(URL(fileURLWithPath: $0)) }
        }
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return [] }
        if value.hasPrefix("/") { return [resolvedFileURL(URL(fileURLWithPath: value))] }
        if let url = URL(string: value), url.isFileURL {
            return [resolvedFileURL(url)]
        }
        if value.hasPrefix("file:///.file/id=") {
            let identifier = value.dropFirst("file:///.file/".count)
            return [URL(fileURLWithPath: unresolvedFileReferencePrefix + identifier)]
        }
        return []
    }

    public static func resolvedFileURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        return (url as NSURL).filePathURL ?? url
    }

    public static func isOpaqueFileReference(_ url: URL) -> Bool {
        url.path.hasPrefix(unresolvedFileReferencePrefix)
    }

    public static func stablePath(for url: URL) -> String? {
        guard !url.path.isEmpty, !isOpaqueFileReference(url) else { return nil }
        return url.path
    }

    public static func urls(in item: CapturedItem) -> [URL] {
        for representation in item.representations.sorted(by: { $0.uti < $1.uti })
        where representation.uti == "public.file-url" || representation.uti == "NSFilenamesPboardType" {
            let values = urls(from: representation.data, uti: representation.uti)
            if !values.isEmpty { return values }
        }
        return []
    }

    public static func urls(in item: ClipItem, loadData: (ClipRepresentation) throws -> Data) throws -> [URL] {
        for representation in item.representations.sorted(by: { $0.uti < $1.uti })
        where representation.uti == "public.file-url" || representation.uti == "NSFilenamesPboardType" {
            let values = urls(from: try loadData(representation), uti: representation.uti)
            if !values.isEmpty { return values }
        }
        return []
    }
}

public struct FileClipMetadata: Codable, Hashable, Sendable {
    public var fileNames: [String]
    public var filePaths: [String]?

    public init(fileNames: [String], filePaths: [String]? = nil) {
        self.fileNames = fileNames
        self.filePaths = filePaths?.count == fileNames.count ? filePaths : nil
    }

    public var fileCount: Int { fileNames.count }
    public var isMultiple: Bool { fileCount > 1 }
    public var displayName: String {
        guard isMultiple else { return fileNames.first ?? "文件" }
        return "\(fileCount) 个文件"
    }
    public var namesSummary: String {
        let visible = fileNames.prefix(3).joined(separator: "、")
        guard fileCount > 3 else { return visible }
        return "\(visible) 等"
    }
}
