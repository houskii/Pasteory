import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum ClipClassifier {
    private static let colorPattern = try! NSRegularExpression(
        pattern: #"(?i)^(?:#[0-9a-f]{3,8}|rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}(?:\s*,\s*(?:0|1|0?\.\d+))?\s*\)|hsla?\(\s*[-+]?\d+(?:\.\d+)?(?:deg)?\s*,\s*\d+(?:\.\d+)?%\s*,\s*\d+(?:\.\d+)?%(?:\s*,\s*(?:0|1|0?\.\d+))?\s*\))$"#
    )

    public static func makeClip(from capture: PasteboardCapture) -> Clip? {
        guard !capture.items.isEmpty else { return nil }
        var kinds = Set<ClipKind>()
        var convertedItems: [ClipItem] = []
        var previewCandidates: [String] = []
        var totalBytes = 0
        var hasher = SHA256()

        for capturedItem in capture.items.sorted(by: { $0.order < $1.order }) {
            var representations: [ClipRepresentation] = []
            let itemKind = classify(capturedItem, previewCandidates: &previewCandidates)
            kinds.insert(itemKind)
            for representation in capturedItem.representations.sorted(by: { $0.uti < $1.uti }) {
                totalBytes += representation.data.count
                hasher.update(data: Data(representation.uti.utf8))
                hasher.update(data: representation.data)
                representations.append(ClipRepresentation(uti: representation.uti, storage: .inline(representation.data)))
            }
            convertedItems.append(ClipItem(order: capturedItem.order, representations: representations))
        }

        guard totalBytes > 0 else { return nil }
        let primary = primaryKind(from: kinds)
        let secondary = kinds.subtracting([primary])
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let preview = previewCandidates.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? defaultPreview(for: primary, itemCount: capture.items.count)

        return Clip(
            createdAt: capture.capturedAt,
            updatedAt: capture.capturedAt,
            lastCopiedAt: capture.capturedAt,
            primaryKind: kinds.count > 1 ? .mixed : primary,
            secondaryKinds: secondary,
            source: capture.source,
            previewText: String(preview.prefix(2_000)),
            contentHash: digest,
            byteSize: totalBytes,
            items: convertedItems
        )
    }

    public static func isColor(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return colorPattern.firstMatch(in: trimmed, range: range) != nil
    }

    public static func isLikelyCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return false }
        let signals = ["func ", "class ", "struct ", "import ", "SELECT ", "#!/", "git ", "npm ", "swift ", "{", "=>", "&&", "||", "sudo ", "curl "]
        return signals.filter { trimmed.localizedCaseInsensitiveContains($0) }.count >= (trimmed.contains("\n") ? 1 : 2)
    }

    private static func classify(_ item: CapturedItem, previewCandidates: inout [String]) -> ClipKind {
        let types = Set(item.representations.map(\.uti))
        if types.contains(where: { $0 == "public.file-url" || $0 == "NSFilenamesPboardType" }) {
            previewCandidates.append(filePreview(item))
            return .file
        }
        if types.contains(where: { $0 == "com.adobe.pdf" || UTType($0)?.conforms(to: .image) == true }) {
            previewCandidates.append("图像")
            return .image
        }
        let text = bestText(item)
        if types.contains("public.url") || types.contains("public.url-name") || text.flatMap(URL.init(string:))?.scheme != nil {
            previewCandidates.append(text ?? "链接")
            return .link
        }
        if types.contains("com.apple.cocoa.pasteboard.color") || types.contains("NSColorPboardType") || text.map(isColor) == true {
            previewCandidates.append(text ?? "颜色")
            return .color
        }
        if let text {
            previewCandidates.append(text)
            return isLikelyCode(text) ? .code : .text
        }
        return .text
    }

    private static func bestText(_ item: CapturedItem) -> String? {
        let preferred = ["public.utf8-plain-text", "public.utf16-plain-text", "public.text", "NSStringPboardType", "public.url"]
        for uti in preferred {
            guard let data = item.representations.first(where: { $0.uti == uti })?.data else { continue }
            if let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) { return value }
        }
        return nil
    }

    private static func filePreview(_ item: CapturedItem) -> String {
        guard let data = item.representations.first(where: { $0.uti == "public.file-url" || $0.uti == "NSFilenamesPboardType" })?.data,
              let value = String(data: data, encoding: .utf8), let url = URL(string: value) else { return "文件" }
        return url.lastPathComponent.isEmpty ? value : url.lastPathComponent
    }

    private static func primaryKind(from kinds: Set<ClipKind>) -> ClipKind {
        for kind in [ClipKind.file, .image, .link, .color, .code, .text] where kinds.contains(kind) { return kind }
        return .text
    }

    private static func defaultPreview(for kind: ClipKind, itemCount: Int) -> String {
        itemCount > 1 ? "\(itemCount) 项\(kind.displayName)" : kind.displayName
    }
}
