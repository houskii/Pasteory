import PasteoryAI
import PasteoryCore
import SwiftUI

struct AIGroupPromptCard: View {
    let group: AIGroupProfile
    let edit: () -> Void
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView { Text(group.definition).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 100)
            Text(L10n.tr("此分组的收录范围与排除项，会和全局整理偏好一起交给 AI。")).font(.caption2).foregroundStyle(.secondary)
        } label: {
            HStack {
                Text(L10n.tr("分组 Prompt（主题定义）")).font(.caption.weight(.semibold))
                Spacer()
                Button(L10n.tr("编辑 Prompt"), action: edit).buttonStyle(.plain).font(.caption)
            }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AIGroupManagementView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var controller: AIOrganizationController
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>
    @State private var editing: ClipCollection?
    @State private var promptExpanded = false
    @State private var cleanupSelection: AIGroupSelection?
    @State private var confirmingCleanup = false

    init(state: AppState, preselected: Set<UUID> = []) {
        self.state = state; controller = state.intelligence
        _selected = State(initialValue: preselected)
    }
    private var groups: [ClipCollection] { state.orderedAICollections }
    private var groupIDs: Set<UUID> { Set(groups.map(\.id)) }
    private var selection: AIGroupSelection { AIGroupSelection(groups: selected.intersection(groupIDs).compactMap { controller.state.groups[$0] }) }
    private var eligibleCount: Int { selection.memberIDs.filter { controller.clipIndex[$0]?.mayParticipateInAI == true }.count }
    private var busy: Bool { controller.running || controller.storageBusy }
    private var canOperate: Bool { !busy && controller.pending == nil && controller.state.checkpoint == nil && !selection.groupIDs.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("管理 AI 分组")).font(.title2.bold())
                    Text(L10n.tr("查看分组 Prompt，选择需要清理或重新分组的范围。")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Button(L10n.tr("关闭")) { dismiss() }
            }
            HStack {
                Text(L10n.tr("已选 \(selection.groupIDs.count) / \(groups.count) 个组，包含 \(selection.memberIDs.count) 条不同内容")).font(.caption)
                Spacer()
                Button(selected == groupIDs && !groupIDs.isEmpty ? L10n.tr("取消全选") : L10n.tr("全选")) {
                    selected = selected == groupIDs ? [] : groupIDs
                }.disabled(groups.isEmpty || busy)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(groups) { collection in groupRow(collection) }
                    if groups.isEmpty { ContentUnavailableView(L10n.tr("还没有 AI 分组"), systemImage: "folder") }
                }
            }.frame(maxHeight: .infinity)
            promptPreview
            if controller.pending != nil {
                HStack {
                    Text(L10n.tr("有待检查的整理建议，请先应用或忽略。")).font(.caption)
                    Spacer(); Button(L10n.tr("检查整理建议")) { controller.showingReview = true; dismiss() }
                }
            } else if controller.state.checkpoint != nil {
                HStack {
                    Text(L10n.tr("有已保存的整理任务。")).font(.caption)
                    Spacer()
                    Button(L10n.tr("继续已保存任务")) { controller.analyze(resume: true); if controller.running { dismiss() } }
                    Button(L10n.tr("放弃已保存任务")) { Task { await controller.discardCheckpoint() } }
                }
            }
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
            if !controller.status.isEmpty { Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Text(L10n.tr("清理仅移除所选 AI 分组及其归属，可撤销；原文、备注和手动文件夹保留。重新分组先生成方案，检查后统一应用。")).font(.caption2).foregroundStyle(.secondary)
            HStack {
                if controller.latestUndoable != nil { Button(L10n.tr("撤销最近一次整理")) { Task { await controller.undo() } }.disabled(busy) }
                Spacer()
                Button(L10n.tr("清理所选分组…"), role: .destructive) {
                    cleanupSelection = selection; confirmingCleanup = true
                }.disabled(!canOperate)
                Button(L10n.tr("生成重新分组方案")) {
                    if controller.regroupGroups(selection) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(!canOperate || eligibleCount == 0)
            }
        }
        .padding(22).frame(width: 800, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { CollectionNameEditor(state: state, existing: $0) }
        .alert(L10n.tr("清理所选 AI 分组？"), isPresented: $confirmingCleanup, presenting: cleanupSelection) { scope in
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("清理分组"), role: .destructive) {
                Task { if await controller.cleanupGroups(scope) { selected = [] } }
            }
        } message: { scope in
            Text(L10n.tr("将移除 \(scope.groupIDs.count) 个 AI 分组，涉及 \(scope.memberIDs.count) 条不同内容。所选组的手动定义和保留设置也会移除，操作可以撤销。原始内容和手动文件夹继续保留，不调用模型。"))
        }
        .task {
            try? await controller.reload(); await state.refreshCollections()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--debug-ai-group-manager-select-all") { selected = groupIDs; promptExpanded = true }
#endif
        }
        .onChange(of: groupIDs) { _, ids in selected.formIntersection(ids) }
    }

    @ViewBuilder private func groupRow(_ collection: ClipCollection) -> some View {
        if let group = controller.state.groups[collection.id] {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Toggle("", isOn: Binding(get: { selected.contains(collection.id) }, set: { value in
                    if value { selected.insert(collection.id) } else { selected.remove(collection.id) }
                })).toggleStyle(.checkbox).labelsHidden().disabled(busy)
                GroupIdentityIcon(isAI: true)
                Text(group.name).font(.callout.weight(.semibold))
                if group.retained || group.definitionIsManual || group.nameIsManual { Text(L10n.tr("含手动设置")).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text(L10n.tr("\(group.memberIDs.count) 条")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(L10n.tr("编辑 Prompt")) { editing = collection }.font(.caption).disabled(busy)
            }
            Text(group.definition).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled).padding(.leading, 26)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var promptPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
        DisclosureGroup(isExpanded: $promptExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("全局整理偏好 Prompt")).font(.caption.weight(.semibold))
                    Text(state.settings.aiConfiguration.prompt).font(.caption).textSelection(.enabled)
                    Text(L10n.tr("固定分类规则")).font(.caption.weight(.semibold))
                    Text(AIAnalyzer.classificationInstructions).font(.caption2).textSelection(.enabled)
                    if controller.state.groups.count - selection.groupIDs.count < state.settings.aiConfiguration.organizationPolicy.maximumGroupCount,
                       eligibleCount >= state.settings.aiConfiguration.organizationPolicy.minimumThemeMembers {
                        Text(L10n.tr("主题规划规则")).font(.caption.weight(.semibold))
                        Text(AIThemePlanner.planningInstructions).font(.caption2).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 160)
        } label: { Text(L10n.tr("查看本次 AI Prompt 与发送范围")).font(.caption.weight(.semibold)) }
            .padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("当前模型：\(state.settings.aiConfiguration.model.isEmpty ? L10n.tr("未设置") : state.settings.aiConfiguration.model)")).font(.caption2).foregroundStyle(.secondary)
                    Text(L10n.tr("重新分组范围：\(eligibleCount) 条可分析内容，\(selection.memberIDs.count - eligibleCount) 条不发送给模型。")).font(.caption2)
                    Text(L10n.tr("所选旧主题及定义在应用方案时替换，其他主题定义保留；内容可以匹配到已有主题。原有分组在应用前保持可用。")).font(.caption2).foregroundStyle(.secondary)
                    if controller.state.groups.count - selection.groupIDs.count >= state.settings.aiConfiguration.organizationPolicy.maximumGroupCount {
                        Text(L10n.tr("未选组已用完主题名额，本次复用已有主题；无匹配内容保留未分组或候选。")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(L10n.tr("正文、显示标题和复制时间；备注：\(state.settings.aiConfiguration.includeNotes ? L10n.tr("包含") : L10n.tr("不包含"))；来源应用名：\(state.settings.aiConfiguration.includeSource ? L10n.tr("包含") : L10n.tr("不包含"))。仅做分类，不生成摘要或聚合。")).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
    }
}
