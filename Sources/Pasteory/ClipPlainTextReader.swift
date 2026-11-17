import Foundation
import PasteoryCore

enum ClipPlainTextReader {
    static func read(_ clip: Clip, attachments: AttachmentStore) async throws -> String? {
        if [.image, .file, .mixed].contains(clip.primaryKind) {
            let note = unwrapOCR(in: clip.note)
            if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return note }
            let recognized = clip.recognizedImageText
            if !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return recognized }
        }
        do {
            return try await ClipTextReader.read(clip, attachments: attachments)
        } catch QuickTextActionError.noText {
            // Image previews contain format/size metadata, never the image text.
            guard clip.primaryKind != .image, clip.primaryKind != .mixed else { return nil }
            return clip.previewText.isEmpty ? nil : clip.previewText
        }
    }

    /// Remove only OCR wrappers; keep nested brackets, other annotations and
    /// the user's exact whitespace. An unfinished OCR block retains its text.
    static func unwrapOCR(in note: String) -> String {
        var output = ""
        var brackets = [Bool]()
        var index = note.startIndex
        while index < note.endIndex {
            if note[index...].hasPrefix("[OCR:") {
                brackets.append(true)
                index = note.index(index, offsetBy: 5)
                continue
            }
            let character = note[index]
            if character == "[" { brackets.append(false) }
            if character == "]", let ocr = brackets.popLast() {
                if !ocr { output.append(character) }
            } else {
                output.append(character)
            }
            index = note.index(after: index)
        }
        return output
    }
}
