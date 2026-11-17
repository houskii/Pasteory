import Foundation
import PasteoryAI

struct AIReviewGroupPlan: Identifiable {
    let id: UUID
    let name: String
    let definition: String
    let overview: String
    let isNew: Bool
    let memberIDs: [UUID]
}

/// Product-level review of one plan, independent of its database command count.
struct AIReviewPresentation {
    let groups: [AIReviewGroupPlan]
    let assignedCount: Int
    let unassignedCount: Int
    let replacedGroupIDs: [UUID]

    func requiresRevision(policy: AIOrganizationPolicy, existingGroupCount: Int) -> Bool {
        let created = groups.filter(\.isNew)
        let total = max(0, existingGroupCount - Set(replacedGroupIDs).count) + created.count
        return groups.count > policy.maximumGroupCount || (!created.isEmpty && total > policy.maximumGroupCount) ||
            (assignedCount >= 6 * policy.minimumThemeMembers && total < 6) || created.contains { $0.memberIDs.count < policy.minimumThemeMembers }
    }

    init(draft: AIChangeSet, catalog: [UUID: AIGroupProfile]) {
        var ordered = [UUID](), seen = Set<UUID>()
        for command in draft.commands where [.createGroup, .addItems, .updateOverview].contains(command.kind) {
            if seen.insert(command.targetID).inserted { ordered.append(command.targetID) }
        }
        groups = ordered.map { id in
            let commands = draft.commands.filter { $0.targetID == id }
            let creation = commands.first { $0.kind == .createGroup }
            let members = Set(commands.filter { $0.kind == .addItems }.flatMap(\.clipIDs))
            return AIReviewGroupPlan(id: id, name: creation?.name ?? catalog[id]?.name ?? "",
                definition: creation?.definition ?? catalog[id]?.definition ?? "",
                overview: commands.last { $0.kind == .updateOverview }?.overview ?? "", isNew: creation != nil,
                memberIDs: members.sorted { $0.uuidString < $1.uuidString })
        }
        assignedCount = draft.decisions?.values.filter { !$0.groupIDs.isEmpty }.count ?? Set(draft.commands.filter { $0.kind == .addItems }.flatMap(\.clipIDs)).count
        unassignedCount = max(0, draft.inputCount - assignedCount)
        replacedGroupIDs = draft.commands.filter { $0.kind == .clearGroup }.map(\.targetID)
    }
}
