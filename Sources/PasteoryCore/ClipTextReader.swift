import Foundation

public enum ClipTextReader {
    public static func read(_ clip: Clip, attachments: AttachmentStore) async throws -> String {
        let formats: [(String, String.Encoding)] = [
            ("public.utf8-plain-text", .utf8), ("public.utf16-plain-text", .utf16),
            ("public.text", .utf8), ("NSStringPboardType", .utf8), ("public.url", .utf8)
        ]
        for (uti, encoding) in formats {
            for item in clip.items.sorted(by: { $0.order < $1.order }) {
                guard let representation = item.representations.first(where: { $0.uti == uti }) else { continue }
                let data = try await attachments.data(for: representation)
                guard let text = String(data: data, encoding: encoding) else { throw QuickTextActionError.nonUTF8 }
                return text
            }
        }
        throw QuickTextActionError.noText
    }
}
