import PasteoryAI
import PasteoryCore
import SwiftUI

struct AIReviewView: View {
    @ObservedObject var controller: AIOrganizationController
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("检查整理建议")).font(.title2.bold())
                    Text(L10n.tr("原子操作将统一提交，原文和用户备注保持不变。" )).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Button(L10n.tr("关闭")) { dismiss() }
            }
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let pending = controller.pending {
                HStack {
                    Text(L10n.tr("分析 \(pending.inputCount) 条，选择 \(selected.count) 项操作")).font(.caption)
                    Spacer(); Button(selected.isEmpty ? L10n.tr("全选") : L10n.tr("取消全选")) {
                        selected = selected.isEmpty ? Set(pending.commands.map(\.id)) : []
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(pending.commands) { command in commandRow(command, in: pending) }
                    }
                }
                HStack {
                    Text(L10n.tr("版本变化或引用失效时，整批停止并保留现有数据。")).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("忽略本次")) { Task { await controller.reject(pending); dismiss() } }
                    Button(L10n.tr("应用所选变更")) { Task { await controller.apply(pending, selectedIDs: selected); if controller.pending == nil { dismiss() } } }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty || controller.running)
                }
            } else {
                ContentUnavailableView(L10n.tr("没有待检查的建议"), systemImage: "checkmark.circle")
            }
        }
        .padding(22).frame(width: 800, height: 650)
        .task(id: controller.pending?.id) { selected = Set(controller.pending?.commands.map(\.id) ?? []) }
    }
    private func commandRow(_ command: AICommand, in pending: AIChangeSet) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { selected.contains(command.id) }, set: { enabled in toggle(command, enabled: enabled, in: pending) }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(commandTitle(command)).font(.callout.weight(.semibold)); Spacer(); Text(command.kind.rawValue).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                if ![.createGroup, .createAggregation].contains(command.kind) {
                    Text(targetName(command, in: pending)).font(.caption.weight(.medium))
                }
                if !command.reason.isEmpty { Text(command.reason).font(.caption).foregroundStyle(.secondary) }
                if !command.definition.isEmpty { Text(command.definition).font(.caption) }
                if !command.overview.isEmpty { Text(command.overview).font(.caption).textSelection(.enabled) }
                if !command.clipIDs.isEmpty {
                    DisclosureGroup(L10n.tr("\(command.clipIDs.count) 条内容")) {
                        ForEach(command.clipIDs, id: \.self) { id in
                            Text(controller.clipIndex[id].map { $0.displayTitle.isEmpty ? $0.previewText : $0.displayTitle } ?? id.uuidString)
                                .font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.font(.caption)
                }
                ForEach(Array(command.claims.enumerated()), id: \.offset) { _, claim in
                    Text(claim.text).font(.caption)
                    ForEach(Array(claim.evidence.enumerated()), id: \.offset) { _, evidence in Text("“" + evidence.quote + "”").font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                }
            }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
    private func targetName(_ command: AICommand, in draft: AIChangeSet) -> String {
        if let creation = draft.commands.first(where: { $0.targetID == command.targetID && [.createGroup, .createAggregation].contains($0.kind) }) { return creation.name }
        return controller.state.groups[command.targetID]?.name ?? command.targetID.uuidString
    }
    private func commandTitle(_ command: AICommand) -> String {
        switch command.kind {
        case .createGroup: L10n.tr("新建 AI 分组") + " · " + command.name
        case .addItems: L10n.tr("补充分组成员")
        case .removeItems: L10n.tr("移出 AI 分组成员")
        case .updateOverview: L10n.tr("更新内容概况")
        case .createAggregation: L10n.tr("创建资料聚合") + " · " + command.name
        case .setSummary: L10n.tr("保存带依据的归纳")
        }
    }
    private func toggle(_ command: AICommand, enabled: Bool, in draft: AIChangeSet) {
        if enabled {
            selected.insert(command.id)
            for parent in draft.commands where parent.targetID == command.targetID && [.createGroup, .createAggregation].contains(parent.kind) {
                selected.insert(parent.id)
            }
            if command.kind == .createGroup, let add = draft.commands.first(where: { $0.targetID == command.targetID && $0.kind == .addItems }) { selected.insert(add.id) }
        } else {
            selected.remove(command.id)
            if [.createGroup, .createAggregation].contains(command.kind) {
                for dependent in draft.commands where dependent.targetID == command.targetID { selected.remove(dependent.id) }
            }
        }
    }
}

struct AISummaryCard: View {
    let summary: AISummary
    @ObservedObject var controller: AIOrganizationController
    let onSource: (UUID) -> Void
    private var stale: Bool { summary.sourceRevisions.contains { id, version in controller.clipIndex[id]?.aiContentRevision != version } }
    var body: some View {
        AISettingsCard(title: L10n.tr("AI 归纳")) {
            if stale { Text(L10n.tr("原文已有变化，本归纳需要重新检查")).font(.caption).foregroundStyle(.orange) }
            ForEach(Array(summary.claims.enumerated()), id: \.offset) { _, claim in
                VStack(alignment: .leading, spacing: 6) {
                    Text(label(claim.kind)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(claim.text).font(.callout).textSelection(.enabled)
                    ForEach(Array(claim.evidence.enumerated()), id: \.offset) { _, evidence in
                        Button { onSource(evidence.clipID) } label: { Text("“" + evidence.quote + "” ↗").font(.caption).lineLimit(3) }.buttonStyle(.link)
                    }
                }
            }
        }
    }
    private func label(_ kind: AIClaim.Kind) -> String {
        switch kind { case .fact: L10n.tr("事实摘录"); case .inference: L10n.tr("推断"); case .action: L10n.tr("建议待办") }
    }
}
