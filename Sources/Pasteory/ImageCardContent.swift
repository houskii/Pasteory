import Foundation
import PasteoryCore

/// The editable note remains the source of truth for an OCR block shown on a card.
struct ImageCardContent {
    enum RecognitionState { case recognized, waiting, noText, notRequested }

    let text: String
    let note: String
    let recognitionState: RecognitionState

    init(clip: Clip) {
        if let block = clip.taggedOCRNote {
            text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var remaining = clip.note
            remaining.removeSubrange(block.range)
            note = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = clip.recognizedImageText.trimmingCharacters(in: .whitespacesAndNewlines)
            note = clip.note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !text.isEmpty { recognitionState = .recognized }
        else if clip.hasCurrentOCR, clip.localOCR?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            recognitionState = .noText
        }
        else if clip.localOCRRequest?.contentHash == clip.contentHash { recognitionState = .waiting }
        else { recognitionState = .notRequested }
    }
}
