import Foundation
import PasteoryAI

public enum AIJobRecovery {
    /// Reconcile only this job's original scope. A moving clipboard must not
    /// restart unrelated work or silently expand the user's authorized scope.
    @discardableResult
    public static func reconcile(_ job: inout AIJobCheckpoint, clips: [UUID: Clip],
                                 groups: [UUID: AIGroupProfile], eligibleIDs: Set<UUID>,
                                 minimumThemeMembers: Int = 3) throws -> Set<UUID> {
        let scope = Set(job.clipIDs)
        let known = scope.union(job.organization?.revisions.keys.map { $0 } ?? [])
        let unavailable = known.filter { !eligibleIDs.contains($0) || clips[$0]?.mayParticipateInAI != true }
        try refreshGroupVersions(&job, groups: groups, removedIDs: unavailable)
        let changed = scope.subtracting(unavailable).filter { id in
            guard let clip = clips[id] else { return true }
            if let revision = job.organization?.revisions[id], revision != clip.aiContentRevision { return true }
            return job.draft.clipRevisions[id].map { $0 != clip.aiRevision } ?? false
        }
        guard !changed.isEmpty || !unavailable.isEmpty else { return [] }

        var retries = job.retryCounts ?? [:]
        let deferred = changed.filter { (retries[$0] ?? 0) >= 2 }
        for id in changed.subtracting(deferred) { retries[id, default: 0] += 1 }
        let excluded = unavailable.union(deferred)
        let invalid = changed.union(unavailable)
        let dependents = prune(&job.draft, invalidIDs: invalid, minimumThemeMembers: minimumThemeMembers)
        let reprocess = changed.union(dependents).subtracting(excluded).intersection(scope)
        let completed = Array(job.clipIDs.prefix(job.cursor)).filter { !invalid.contains($0) && !dependents.contains($0) }
        let remaining = Array(job.clipIDs.dropFirst(job.cursor)).filter { !invalid.contains($0) && !dependents.contains($0) }
        let appended = job.clipIDs.filter { reprocess.contains($0) }
        job.clipIDs = completed + remaining + appended
        job.cursor = completed.count
        job.draft.inputCount = min(job.draft.inputCount, job.cursor)
        job.retryCounts = retries
        job.requeuedIDs = (job.requeuedIDs ?? []).union(reprocess)
        job.skippedIDs = (job.skippedIDs ?? []).union(excluded)
        job.organization?.revisions = Dictionary(uniqueKeysWithValues: job.clipIDs.compactMap { id in clips[id].map { (id, $0.aiContentRevision) } })
        if var cleanup = job.organization?.groupCleanup {
            cleanup.clipRevisions = [:]
            let selected = job.organization?.groupSelection?.groupIDs ?? []
            for clip in clips.values where !clip.collectionIDs.isDisjoint(with: selected) {
                cleanup.clipRevisions[clip.id] = clip.aiRevision
            }
            cleanup.inputCount = cleanup.clipRevisions.count
            job.organization?.groupCleanup = cleanup
        }
        job.failureMessage = nil
        return deferred
    }

    private static func refreshGroupVersions(_ job: inout AIJobCheckpoint, groups: [UUID: AIGroupProfile], removedIDs: Set<UUID>) throws {
        var required = job.draft.groupRevisions
        for (id, version) in job.organization?.groupSelection?.groupRevisions ?? [:] { required[id] = version }
        for (id, version) in required where groups[id]?.revision != version {
            guard var expected = job.organization?.groupSnapshots?[id], let current = groups[id], !removedIDs.isEmpty else {
                throw AIError.conflict("The selected AI groups changed; refresh the selection")
            }
            expected.revision += expected.memberIDs.intersection(removedIDs).count
            expected.memberIDs.subtract(removedIDs); expected.aiMemberIDs.subtract(removedIDs); expected.excludedClipIDs.subtract(removedIDs)
            guard expected == current else { throw AIError.conflict("The selected AI groups changed; refresh the selection") }
            if job.draft.groupRevisions[id] != nil { job.draft.groupRevisions[id] = current.revision }
            if job.organization?.groupSelection?.groupRevisions[id] != nil {
                job.organization?.groupSelection?.groupRevisions[id] = current.revision
                job.organization?.groupCleanup?.groupRevisions[id] = current.revision
            }
        }
        if var selection = job.organization?.groupSelection {
            let members = selection.groupIDs.reduce(into: Set<UUID>()) { $0.formUnion(groups[$1]?.memberIDs ?? []) }
            guard members == selection.memberIDs || members == selection.memberIDs.subtracting(removedIDs) else {
                throw AIError.conflict("Group membership changed; refresh the selection")
            }
            selection.memberIDs = members; job.organization?.groupSelection = selection
        }
        job.organization?.groupSnapshots = groups
    }

    /// Remove stale assignments and every derived result that cites them, while
    /// retaining independent commands and stable theme IDs.
    private static func prune(_ draft: inout AIChangeSet, invalidIDs: Set<UUID>, minimumThemeMembers: Int) -> Set<UUID> {
        var discarded = invalidIDs, dependents = Set<UUID>()
        while true {
            var droppedTargets = Set<UUID>(), retired = Set<UUID>()
            draft.commands = draft.commands.compactMap { original in
                var command = original
                let affected = !Set(command.clipIDs).isDisjoint(with: discarded)
                switch command.kind {
                case .addItems, .removeItems:
                    command.clipIDs.removeAll { discarded.contains($0) }
                    if affected && command.kind == .removeItems { retired.insert(command.targetID) }
                    return command.clipIDs.isEmpty ? nil : command
                case .createAggregation:
                    if affected { droppedTargets.insert(command.targetID); return nil }
                case .updateOverview:
                    if affected { return nil }
                case .setSummary:
                    if command.claims.contains(where: { $0.evidence.contains { discarded.contains($0.clipID) } }) { return nil }
                default: break
                }
                return command
            }
            var affectedMembers = Set<UUID>(), droppedGroups = Set<UUID>()
            for creation in draft.commands where creation.kind == .createGroup {
                var members = Set<UUID>()
                for command in draft.commands where command.targetID == creation.targetID {
                    if command.kind == .addItems { members.formUnion(command.clipIDs) }
                    if command.kind == .removeItems { members.subtract(command.clipIDs) }
                }
                if members.count < minimumThemeMembers {
                    droppedGroups.insert(creation.targetID); affectedMembers.formUnion(members)
                }
            }
            for (id, decision) in draft.decisions ?? [:] where !decision.groupIDs.isDisjoint(with: droppedGroups) { affectedMembers.insert(id) }
            droppedTargets.formUnion(droppedGroups)
            draft.commands.removeAll { droppedTargets.contains($0.targetID) || ($0.kind == .retireGroup && retired.contains($0.targetID)) }
            let additional = affectedMembers.subtracting(discarded)
            guard !additional.isEmpty else { break }
            dependents.formUnion(additional); discarded.formUnion(additional)
        }
        draft.clipRevisions = draft.clipRevisions.filter { !discarded.contains($0.key) }
        draft.decisions = draft.decisions?.filter { !discarded.contains($0.key) }
        draft.planningInputIDs?.subtract(discarded)
        draft.candidates = draft.candidates?.compactMap { original in
            var candidate = original
            candidate.supportRevisions = candidate.supportRevisions.filter { !discarded.contains($0.key) }
            return candidate.supportRevisions.isEmpty ? nil : candidate
        }
        let targets = Set(draft.commands.map(\.targetID))
        draft.groupRevisions = draft.groupRevisions.filter { targets.contains($0.key) }
        return dependents
    }
}
