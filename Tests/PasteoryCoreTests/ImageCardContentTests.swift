import Foundation
import Testing
@testable import Pasteory
@testable import PasteoryCore

private func imageCardClip() throws -> Clip {
    var clip = try #require(ClipClassifier.makeClip(from: .init(items: [.init(order: 0,
        representations: [.init(uti: "public.utf8-plain-text", data: Data("synthetic image".utf8))])],
        source: .init(appName: "Synthetic"))))
    clip.primaryKind = .image
    return clip
}

@Test func imageCardUsesTheEditableOCRBlockAndKeepsTheOriginalNoteSeparate() throws {
    var clip = try imageCardClip()
    clip.localOCR = LocalOCRResult(contentHash: clip.contentHash, text: "Original recognition")
    clip.localOCR?.appendedNote = "[OCR:Original recognition]"
    clip.note = "My note\n\n[OCR:Corrected first line\nCorrected second [label]]"
    let card = ImageCardContent(clip: clip)
    #expect(card.text == "Corrected first line\nCorrected second [label]")
    #expect(card.note == "My note")
    #expect(card.recognitionState == .recognized)
    #expect(clip.note == "My note\n\n[OCR:Corrected first line\nCorrected second [label]]")
}

@Test func removingTheOCRBlockDoesNotBringBackOldMachineText() throws {
    var clip = try imageCardClip()
    clip.localOCR = LocalOCRResult(contentHash: clip.contentHash, text: "Machine text")
    clip.localOCR?.appendedNote = "[OCR:Machine text]"
    clip.note = "Keep this manual note"
    let card = ImageCardContent(clip: clip)
    #expect(card.text.isEmpty && card.note == clip.note)
    #expect(card.recognitionState == .notRequested)
}

@Test func imageCardDistinguishesWaitingEmptyAndUnrequestedRecognition() throws {
    var clip = try imageCardClip()
    #expect(ImageCardContent(clip: clip).recognitionState == .notRequested)
    clip.localOCRRequest = LocalOCRRequest(contentHash: clip.contentHash, method: .visionAccurate)
    #expect(ImageCardContent(clip: clip).recognitionState == .waiting)
    clip.localOCR = LocalOCRResult(contentHash: clip.contentHash, text: "")
    #expect(ImageCardContent(clip: clip).recognitionState == .noText)
    clip.note = "[OCR:Manually entered image text]"
    #expect(ImageCardContent(clip: clip).text == "Manually entered image text")
}

@Test func imageCardHeightStaysStableWhenBackgroundRecognitionFinishes() throws {
    var clip = try imageCardClip()
    clip.title = "A user title"
    clip.note = "A user note"
    clip.localOCRRequest = LocalOCRRequest(contentHash: clip.contentHash, method: .visionAccurate)
    let compact = ClipRowMetrics.height(for: clip, compact: true)
    let library = ClipRowMetrics.height(for: clip, compact: false)
    clip.localOCR = LocalOCRResult(contentHash: clip.contentHash, text: "First line\nSecond line\nThird line")
    clip.localOCR?.appendedNote = "[OCR:First line\nSecond line\nThird line]"
    clip.note += "\n\n[OCR:First line\nSecond line\nThird line]"
    #expect(ClipRowMetrics.height(for: clip, compact: true) == compact)
    #expect(ClipRowMetrics.height(for: clip, compact: false) == library)
}
