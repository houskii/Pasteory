import Foundation

public struct AIGroupSelection: Codable, Equatable, Sendable {
    public var groupRevisions: [UUID: Int]
    public var memberIDs: Set<UUID>
    public var groupIDs: Set<UUID> { Set(groupRevisions.keys) }
    public init(groups: [AIGroupProfile]) {
        groupRevisions = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.revision) })
        memberIDs = groups.reduce(into: Set<UUID>()) { $0.formUnion($1.memberIDs) }
    }
    public func validate(in groups: [UUID: AIGroupProfile]) throws {
        guard !groupRevisions.isEmpty else { throw AIError.invalid("Select at least one AI group") }
        for (id, revision) in groupRevisions {
            guard groups[id]?.revision == revision else { throw AIError.conflict("The selected AI groups changed; refresh the selection") }
        }
        let current = groupIDs.reduce(into: Set<UUID>()) { $0.formUnion(groups[$1]!.memberIDs) }
        guard current == memberIDs else { throw AIError.conflict("Group membership changed; refresh the selection") }
    }
}
