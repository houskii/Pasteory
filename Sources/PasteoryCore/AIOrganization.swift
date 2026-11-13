import Foundation
import PasteoryAI

public extension Clip {
    var activity: ContentActivity {
        var historical = [ContentActivity.Sample(.copy, at: lastCopiedAt)]
        if let lastPastedAt { historical.append(ContentActivity.Sample(.paste, at: lastPastedAt)) }
        var value = intelligenceActivity ?? ContentActivity(lastUsedAt: lastUsedAt, samples: historical)
        value.lastUsedAt = max(value.lastUsedAt, lastUsedAt)
        return value
    }
    var aiRevision: String {
        AIHash.fingerprint([id.uuidString, contentHash, title, automaticTitle ?? "", note, primaryKind.rawValue,
                            previewText, source.appName, collectionIDs.map(\.uuidString).sorted().joined(separator: ","),
                            aiAnalysisExcluded == true ? "excluded" : "allowed", deletedAt == nil ? "present" : "deleted"])
    }
    var aiContentRevision: String {
        AIHash.fingerprint([id.uuidString, contentHash, title, automaticTitle ?? "", note, primaryKind.rawValue, previewText,
                            deletedAt == nil ? "present" : "deleted"])
    }
    func aiDocument(includeNotes: Bool, includeSource: Bool, body: String? = nil) -> AIClipDocument {
        var text = body ?? previewText
        var metadataOnly = false
        if primaryKind == .link, var url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil {
            url.query = nil; url.fragment = nil; url.user = nil; url.password = nil; text = url.string ?? ""
        }
        if primaryKind == .file { text = effectiveFileMetadata?.fileNames.joined(separator: "\n") ?? "File metadata only"; metadataOnly = true }
        if primaryKind == .image || primaryKind == .mixed { text = "Metadata only; source bytes were not provided."; metadataOnly = true }
        return AIClipDocument(id: id, revision: aiRevision, title: displayTitle, body: text,
                              note: includeNotes ? note : "", source: includeSource ? source.appName : "",
                              kind: primaryKind.rawValue, copiedAt: lastCopiedAt,
                              groupIDs: collectionIDs.sorted { $0.uuidString < $1.uuidString },
                              truncated: metadataOnly || items.flatMap(\.representations).contains {
                                  $0.uti == "public.utf8-plain-text" && $0.storage.byteCount > text.utf8.count
                              })
    }
    var mayParticipateInAI: Bool {
        guard deletedAt == nil, aiAnalysisExcluded != true else { return false }
        return Self.isSafeAIText(previewText + "\n" + note)
    }
    static func isSafeAIText(_ text: String) -> Bool {
        let patterns = [#"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#,
                        #"\bsk-[A-Za-z0-9_-]{20,}"#, #"\bAKIA[A-Z0-9]{16}\b"#]
        return !patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

public struct AIPayloadLZFSECodec: PayloadCodec {
    public let identifier = "lzfse-v1"
    public init() {}
    public func compress(_ data: Data) throws -> Data { try LZFSE.compress(data) }
    public func decompress(_ data: Data, originalSize: Int) throws -> Data { try LZFSE.decompress(data, expectedSize: originalSize) }
}

struct AIUndoRecord: Codable {
    var beforeMemberships: [UUID: Set<UUID>]
    var afterMemberships: [UUID: Set<UUID>]
    var beforeGroups: [UUID: AIGroupProfile]
    var afterGroups: [UUID: AIGroupProfile]
    var createdGroupIDs: Set<UUID>
    var createdAggregations: [ClipAggregation]
    var beforeSummaries: [UUID: AISummary]
    var changedSummaryIDs: Set<UUID>
}
