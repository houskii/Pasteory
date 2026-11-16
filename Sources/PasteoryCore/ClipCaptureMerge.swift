import Foundation

public extension Clip {
    /// Keep human metadata and identity when a copy refreshes an existing item.
    func mergingCapture(_ incoming: Clip) -> Clip {
        var result = self
        result.copyCount += max(1, incoming.copyCount)
        var activity = result.activity
        activity.record(.copy, at: incoming.createdAt)
        result.intelligenceActivity = activity
        result.lifecycleEvaluation = nil
        result.lastCopiedAt = max(result.lastCopiedAt, incoming.createdAt)
        result.updatedAt = max(result.updatedAt, incoming.createdAt)
        result.source = incoming.source
        result.isArchived = false; result.archivePath = nil
        result.previewText = incoming.previewText
        let previousHash = result.contentHash
        result.contentHash = incoming.contentHash
        // Deduplication can match the same pixels in a different pasteboard format.
        // Keep the user's OCR edits and sharing marker with that semantic identity.
        if deduplicationKey == incoming.deduplicationKey, result.localOCR?.contentHash == previousHash {
            result.localOCR?.contentHash = incoming.contentHash
        }
        result.identityKey = incoming.identityKey
        result.byteSize = incoming.byteSize
        result.items = incoming.items
        result.secondaryKinds.formUnion(incoming.secondaryKinds)
        if result.automaticTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { result.automaticTitle = incoming.automaticTitle }
        if incoming.codeMetadata != nil { result.codeMetadata = incoming.codeMetadata }
        if incoming.fileMetadata != nil { result.fileMetadata = incoming.fileMetadata }
        for transformation in incoming.quickTextTransformations ?? [] where result.quickTextTransformations?.contains(transformation) != true {
            result.quickTextTransformations = (result.quickTextTransformations ?? []) + [transformation]
            if !result.note.isEmpty { result.note += "\n\n" }
            result.note += transformation.note
        }
        return result
    }
}
