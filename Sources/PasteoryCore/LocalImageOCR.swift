import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum LocalOCRMethod: String, Codable, CaseIterable, Sendable {
    case visionAccurate, visionFast
    public var title: String {
        switch self {
        case .visionAccurate: L10n.tr("macOS Vision · 准确（中英文）")
        case .visionFast: L10n.tr("macOS Vision · 快速（英文等西文）")
        }
    }
}

public struct LocalOCRRequest: Codable, Hashable, Sendable {
    public let contentHash: String
    public let method: LocalOCRMethod
    public init(contentHash: String, method: LocalOCRMethod) { self.contentHash = contentHash; self.method = method }
}

public struct LocalOCRResult: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public var version = Self.currentVersion
    public var contentHash: String
    public var text: String
    public let recognizedAt: Date
    public var method: LocalOCRMethod?
    public var appendedNote: String?

    public init(contentHash: String, text: String, recognizedAt: Date = Date(), method: LocalOCRMethod = .visionAccurate) {
        self.contentHash = contentHash; self.text = String(text.prefix(32_000)); self.recognizedAt = recognizedAt
        self.method = method
    }
}

public extension Clip {
    var hasImageContent: Bool { primaryKind == .image || secondaryKinds.contains(.image) || primaryKind == .mixed }
    var hasCurrentOCR: Bool { localOCR?.contentHash == contentHash && localOCR?.version == LocalOCRResult.currentVersion }
    var taggedOCRNote: (range: Range<String.Index>, text: String)? {
        guard let marker = note.range(of: "[OCR:", options: .backwards) else { return nil }
        let closing = note.range(of: "]", options: .backwards, range: marker.upperBound..<note.endIndex)
        let end = closing?.lowerBound ?? note.endIndex
        return (marker.lowerBound..<(closing?.upperBound ?? note.endIndex), String(note[marker.upperBound..<end]))
    }
    var recognizedImageText: String {
        guard hasCurrentOCR else { return "" }
        if localOCR?.appendedNote != nil { return taggedOCRNote?.text ?? "" }
        return localOCR?.text ?? ""
    }
    var noteWithoutAutomaticOCR: String {
        guard localOCR?.appendedNote != nil else { return note }
        if let block = taggedOCRNote {
            var text = note; text.removeSubrange(block.range); return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return note
    }
}

public protocol ImageTextRecognizing: Sendable {
    func recognize(_ data: Data, method: LocalOCRMethod) throws -> String
}

/// Synchronous Vision requests are executed only on the service's background actor.
public struct VisionImageTextRecognizer: ImageTextRecognizing {
    public init() {}
    public func recognize(_ data: Data, method: LocalOCRMethod = .visionAccurate) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = method == .visionFast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.preferBackgroundProcessing = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        // Downsample very large captures before recognition to bound working memory.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw LocalOCRError.unreadableImage }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

public enum LocalOCRError: LocalizedError {
    case unreadableImage
    public var errorDescription: String? { L10n.tr("无法读取图片中的文字") }
}

public actor LocalImageOCRService {
    private let repository: any ClipRepository
    private let attachments: AttachmentStore
    private let recognizer: any ImageTextRecognizing

    public init(repository: any ClipRepository, attachments: AttachmentStore, recognizer: any ImageTextRecognizing = VisionImageTextRecognizer()) {
        self.repository = repository; self.attachments = attachments; self.recognizer = recognizer
    }

    public func recognize(id: UUID, force: Bool = false) async throws -> Clip? {
        guard let clip = try await repository.clip(id: id), clip.deletedAt == nil, clip.hasImageContent,
              force || !clip.hasCurrentOCR else { return nil }
        var texts = [String]()
        let method = clip.localOCRRequest?.method ?? .visionAccurate
        for item in clip.items.sorted(by: { $0.order < $1.order }) {
            // One bitmap representation per pasteboard item; PNG/TIFF alternatives are duplicates.
            let images = item.representations.filter { UTType($0.uti)?.conforms(to: .image) == true }.sorted {
                ($0.uti == "public.png" ? 0 : 1) < ($1.uti == "public.png" ? 0 : 1)
            }
            guard !images.isEmpty else { continue }
            var lastError: (any Error)?
            var text: String?
            for representation in images {
                try Task.checkCancellation()
                do { text = try recognizer.recognize(await attachments.data(for: representation), method: method); break }
                catch { lastError = error }
            }
            if let text { texts.append(text) }
            else if let lastError { throw lastError }
        }
        try Task.checkCancellation()
        let result = LocalOCRResult(contentHash: clip.contentHash, text: texts.joined(separator: "\n"), method: method)
        return try await repository.saveLocalOCR(result, clipID: id)
    }
}
