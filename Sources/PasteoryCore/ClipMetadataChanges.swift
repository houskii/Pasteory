import Foundation

/// A process-lifetime metadata cache. Revisions follow committed database writes,
/// including maintenance, imports and changes made through another connection.
public struct ClipMetadataChanges: Sendable {
    public let revision: Int64
    public let resetsIndex: Bool
    public let upserts: [Clip]
    public let removedIDs: Set<UUID>
}
