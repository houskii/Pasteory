import Foundation
import PasteoryAI

public enum AIGroupManagement {
    public static func cleanup(_ selection: AIGroupSelection, state: AIOrganizationState, clips: [Clip]) throws -> AIChangeSet {
        try selection.validate(in: state.groups)
        let members = clips.filter { !$0.collectionIDs.isDisjoint(with: selection.groupIDs) }
        guard Set(members.map(\.id)) == selection.memberIDs else { throw AIError.conflict("Group membership changed; refresh the selection") }
        var result = AIChangeSet()
        result.isThemeReview = true
        result.userSelectedGroupIDs = selection.groupIDs
        result.groupRevisions = selection.groupRevisions
        result.clipRevisions = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.aiRevision) })
        result.inputCount = members.count
        result.commands = selection.groupIDs.sorted { $0.uuidString < $1.uuidString }.map {
            AICommand(kind: .clearGroup, targetID: $0, reason: "用户选择清理 AI 分组；原始内容与手动文件夹保留")
        }
        return result
    }

    public static func combining(cleanup: AIChangeSet, analysis: AIChangeSet) throws -> AIChangeSet {
        var result = analysis
        for (id, revision) in cleanup.clipRevisions {
            if let other = result.clipRevisions[id], other != revision { throw AIError.conflict("Content changed while regrouping") }
            result.clipRevisions[id] = revision
        }
        for (id, revision) in cleanup.groupRevisions {
            if let other = result.groupRevisions[id], other != revision { throw AIError.conflict("A selected group changed while regrouping") }
            result.groupRevisions[id] = revision
        }
        result.commands = cleanup.commands + analysis.commands
        result.userSelectedGroupIDs = cleanup.userSelectedGroupIDs
        result.isThemeReview = true
        return result
    }
}
