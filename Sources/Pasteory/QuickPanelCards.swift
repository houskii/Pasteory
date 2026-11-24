import AppKit
import PasteoryCore
import SwiftUI

struct QuickClipCard: View {
    @ObservedObject var state: AppState
    let clip: Clip
    let parentAggregationID: UUID?
    let shortcutNumber: Int?
    let onCopy: (Clip, Bool, Bool) -> Void

    var body: some View {
        ClipRowView(
            clip: clip,
            attachments: state.attachments,
            compact: true,
            shortcutNumber: state.quickCommandKeyDown ? shortcutNumber : nil,
            filePresentationRefreshID: state.quickPresentationID
        )
            .padding(.horizontal, 12)
            .frame(height: ClipRowMetrics.height(for: clip, compact: true))
            .background(QuickActionMenuAnchor(controller: state.quickActionsMenu, clipID: clip.id, scope: .quickPanel))
            .clipped()
            .background(
                clip.isPinned ? state.settings.themeColor.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.82),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(isSelected ? state.settings.themeColor.accentColor : Color.clear, lineWidth: 2) }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                if state.quickMultiSelectActive {
                    Image(systemName: state.quickMultiSelectionIDs.contains(clip.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(state.quickMultiSelectionIDs.contains(clip.id) ? state.settings.themeColor.accentColor : Color.secondary)
                        .padding(8)
                }
            }
            .onTapGesture {
                state.handleQuickClipTap(clip, parentAggregationID: parentAggregationID, modifiers: NSEvent.modifierFlags)
            }
            .onHover { hovering in
                if hovering { state.quickHoveredClipID = clip.id }
                else if state.quickHoveredClipID == clip.id { state.quickHoveredClipID = nil }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard !state.quickMultiSelectActive else { return }
                onCopy(clip, false, true)
            })
            .contextMenu {
                Button(L10n.tr("直接粘贴")) { onCopy(clip, false, true) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .directPaste))
                Button(L10n.tr("只复制")) { onCopy(clip, false, false) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .copyOnly))
                Button(L10n.tr("纯文本粘贴")) { onCopy(clip, true, true) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .plainTextPaste))
                Button(L10n.tr("纯文本复制")) { onCopy(clip, true, false) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .plainTextCopy))
                QuickActionsMenu { action in
                    state.runQuickTextAction(action, for: clip)
                }
                Divider()
                Button(clip.isFavorite ? L10n.tr("取消收藏") : L10n.tr("收藏")) { state.toggleFavorite(clip) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .toggleFavorite))
                Button(clip.isPinned ? L10n.tr("取消置顶") : L10n.tr("置顶")) { state.togglePinned(clip) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .togglePinned))
                Button(L10n.tr("编辑信息…")) {
                    state.presentQuickMetadataEditor(for: clip.id, initialField: .title)
                }
                    .quickActionShortcut(state.settings.quickShortcut(for: .editMetadata))
                Button(L10n.tr("设置分组…")) {
                    state.presentQuickMetadataEditor(for: clip.id, initialField: .collections)
                }
                    .quickActionShortcut(state.settings.quickShortcut(for: .setCollection))
                Button(L10n.tr("聚合内容…")) {
                    state.quickSelectionID = clip.id
                    state.quickSelectedAggregationID = nil
                    Task { await state.prepareQuickAggregation() }
                }
                .quickActionShortcut(state.settings.quickShortcut(for: .aggregateContent))
                Divider()
                if let parentAggregationID,
                   let aggregation = state.aggregations.first(where: { $0.id == parentAggregationID }) {
                    Button(L10n.tr("移出当前聚合")) {
                        Task { await state.removeClip(clip.id, from: aggregation) }
                    }
                    Divider()
                }
                Button(L10n.tr("移到废纸篓"), role: .destructive) { state.moveToTrash(clip) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .moveToTrash))
            }
    }

    private var isSelected: Bool { state.quickSelectionID == clip.id }

}

struct QuickAggregationCard: View {
    @ObservedObject var state: AppState
    let aggregation: ClipAggregation
    @State private var showCollectionPicker = false

    init(state: AppState, aggregation: ClipAggregation) {
        self.state = state
        self.aggregation = aggregation
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(state.settings.themeColor.accentColor)
                .frame(width: 42, height: 42)
                .background(state.settings.themeColor.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(aggregation.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !aggregation.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(aggregation.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(aggregation.origin.displayName)
                    if aggregation.membershipMode == .automatic { Text(L10n.tr("· 自动更新")) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                state.toggleQuickAggregation(aggregation.id)
            } label: {
                HStack(spacing: 4) {
                    Text(memberCountLabel)
                    Image(systemName: state.quickExpandedAggregationIDs.contains(aggregation.id) ? "chevron.up" : "chevron.down")
                }
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.settings.themeColor.accentColor)
        }
        .padding(.horizontal, 12)
        .frame(height: 82)
        .background(
            aggregation.isPinned ? state.settings.themeColor.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.82),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(state.quickSelectedAggregationID == aggregation.id ? state.settings.themeColor.accentColor : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            state.quickSelectedAggregationID = aggregation.id
            state.quickSelectionID = nil
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            state.toggleQuickAggregation(aggregation.id, selectChild: true)
        })
        .popover(isPresented: $showCollectionPicker, arrowEdge: .trailing) {
            QuickAggregationCollectionPicker(
                state: state,
                aggregation: aggregation,
                onDone: { showCollectionPicker = false }
            )
        }
        .onChange(of: state.quickCollectionPickerOpenRequestID) { _, request in
            guard request != nil, state.quickSelectedAggregationID == aggregation.id else { return }
            showCollectionPicker = true
        }
        .contextMenu {
            Button(state.quickExpandedAggregationIDs.contains(aggregation.id) ? L10n.tr("收起内容") : L10n.tr("展开内容")) {
                state.toggleQuickAggregation(aggregation.id)
            }
            .quickActionShortcut(state.settings.quickShortcut(
                for: state.quickExpandedAggregationIDs.contains(aggregation.id) ? .collapseAggregation : .expandAggregation
            ))
            Button(L10n.tr("编辑聚合…")) {
                state.quickSelectedAggregationID = aggregation.id
                state.quickSelectionID = nil
                Task { await state.prepareQuickAggregation() }
            }
            .quickActionShortcut(state.settings.quickShortcut(for: .editMetadata))
            Divider()
            Button(aggregation.isFavorite ? L10n.tr("取消收藏聚合") : L10n.tr("收藏聚合")) {
                Task { await state.toggleAggregationFavorite(aggregation) }
            }
            .quickActionShortcut(state.settings.quickShortcut(for: .toggleFavorite))
            Button(aggregation.isPinned ? L10n.tr("取消置顶聚合") : L10n.tr("置顶聚合")) {
                Task { await state.toggleAggregationPinned(aggregation) }
            }
            .quickActionShortcut(state.settings.quickShortcut(for: .togglePinned))
            Menu(L10n.tr("设置聚合分组")) {
                let groups = state.collections.filter { $0.kind == .normal }
                if groups.isEmpty { Text(L10n.tr("还没有普通分组")) }
                else {
                    ForEach(groups) { collection in
                        Button {
                            Task { await state.toggleAggregationCollection(collection, aggregation: aggregation) }
                        } label: {
                            Label(collection.name, systemImage: aggregation.collectionIDs.contains(collection.id) ? "checkmark" : "folder")
                        }
                    }
                }
            }
            .quickActionShortcut(state.settings.quickShortcut(for: .setCollection))
            Divider()
            Menu(L10n.tr("整理全部成员")) {
                let members = state.aggregationMembers[aggregation.id] ?? []
                Button(members.allSatisfy(\.isFavorite) ? L10n.tr("取消收藏全部成员") : L10n.tr("收藏全部成员")) {
                    Task { await state.toggleFavoriteForAllMembers(of: aggregation) }
                }
                Button(members.allSatisfy(\.isPinned) ? L10n.tr("取消置顶全部成员") : L10n.tr("置顶全部成员")) {
                    Task { await state.togglePinnedForAllMembers(of: aggregation) }
                }
                Menu(L10n.tr("设置全部成员的分组")) {
                    ForEach(state.collections.filter { $0.kind == .normal }) { collection in
                        let allIncluded = members.allSatisfy { $0.collectionIDs.contains(collection.id) }
                        Button {
                            Task { await state.toggleCollectionForAllMembers(collection, aggregation: aggregation) }
                        } label: {
                            Label(collection.name, systemImage: allIncluded ? "checkmark" : "folder")
                        }
                    }
                }
            }
            Divider()
            Button(L10n.tr("删除聚合但保留内容"), role: .destructive) {
                Task { await state.removeAggregation(aggregation) }
            }
            .quickActionShortcut(state.settings.quickShortcut(for: .moveToTrash))
        }
    }

    private var memberCountLabel: String {
        let query = state.quickQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return L10n.tr("\(aggregation.memberClipIDs.count) 项内容") }
        let visible = Set(state.quickClips.map(\.id)).intersection(aggregation.memberClipIDs).count
        guard visible > 0, visible < aggregation.memberClipIDs.count else {
            return L10n.tr("\(aggregation.memberClipIDs.count) 项内容")
        }
        return L10n.tr("匹配 \(visible) / \(aggregation.memberClipIDs.count)")
    }
}

struct QuickAggregationEditor: View {
    @ObservedObject var state: AppState
    let draft: AggregationDraft
    @State private var title: String
    @State private var note: String
    @State private var memberIDs: [UUID]
    @FocusState private var titleFocused: Bool

    init(state: AppState, draft: AggregationDraft) {
        self.state = state
        self.draft = draft
        _title = State(initialValue: draft.title)
        _note = State(initialValue: draft.note)
        _memberIDs = State(initialValue: draft.memberClipIDs)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.isEditing ? L10n.tr("编辑聚合") : L10n.tr("聚合内容"))
                    .font(.headline)
                Text(draft.isEditing ? L10n.tr("当前包含 \(memberIDs.count) 项内容") : L10n.tr("将 \(memberIDs.count) 项不同内容保存为一个聚合"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("聚合标题"), text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                TextField(L10n.tr("备注（可选）"), text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                if draft.isEditing {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(memberClips) { clip in
                                HStack(spacing: 7) {
                                    Image(systemName: clip.primaryKind.symbolName)
                                        .foregroundStyle(state.settings.themeColor.accentColor)
                                    Text(clip.displayTitle.isEmpty ? clip.previewText : clip.displayTitle)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        memberIDs.removeAll { $0 == clip.id }
                                    } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.plain)
                                        .disabled(memberIDs.count <= 2)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
                HStack {
                    Text(draft.origin.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(L10n.tr("取消")) { state.dismissQuickAggregationDraft() }
                    Button(draft.isEditing ? L10n.tr("保存") : L10n.tr("创建聚合")) {
                        Task { await state.saveQuickAggregation(title: title, note: note, memberIDs: memberIDs) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.settings.themeColor.accentColor)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberIDs.count < 2)
                }
            }
            .padding(16)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.65), lineWidth: 1))
            .shadow(radius: 18, y: 8)
        }
        .onAppear { titleFocused = true }
        .onChange(of: state.quickAggregationCommitRequestID) { _, request in
            guard request != nil,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await state.saveQuickAggregation(title: title, note: note, memberIDs: memberIDs) }
        }
        .onChange(of: state.quickAggregationDismissRequestID) { _, request in
            guard request != nil else { return }
            state.dismissQuickAggregationDraft()
        }
    }

    private var memberClips: [Clip] {
        let all = state.quickClips + state.clips + state.aggregationMembers.values.flatMap { $0 }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return memberIDs.compactMap { byID[$0] }
    }
}

private struct QuickAggregationCollectionPicker: View {
    @ObservedObject var state: AppState
    let aggregation: ClipAggregation
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("设置聚合分组")).font(.headline)
            let groups = state.collections.filter { $0.kind == .normal }
            if groups.isEmpty {
                ContentUnavailableView(L10n.tr("还没有普通分组"), systemImage: "folder")
                    .frame(height: 120)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(groups) { collection in
                            Button {
                                Task { await state.toggleAggregationCollection(collection, aggregation: currentAggregation) }
                            } label: {
                                HStack {
                                    Image(systemName: currentAggregation.collectionIDs.contains(collection.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(currentAggregation.collectionIDs.contains(collection.id) ? state.settings.themeColor.accentColor : Color.secondary)
                                    Text(collection.name).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack { Spacer(); Button(L10n.tr("完成"), action: onDone).keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { state.quickCollectionPickerActive = true }
        .onDisappear { state.quickCollectionPickerActive = false }
        .onChange(of: state.quickCollectionPickerDismissRequestID) { _, request in
            guard request != nil else { return }
            onDone()
        }
    }

    private var currentAggregation: ClipAggregation {
        state.aggregations.first(where: { $0.id == aggregation.id }) ?? aggregation
    }
}

struct AggregationChildMarker: View {
    let accentColor: Color
    let gap: CGFloat
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        GeometryReader { geometry in
            let x: CGFloat = 7
            let middle = geometry.size.height / 2
            Path { path in
                path.move(to: CGPoint(x: x, y: isFirst ? -gap : 0))
                path.addLine(to: CGPoint(x: x, y: isLast ? geometry.size.height : geometry.size.height + gap))
            }
            .stroke(
                accentColor.opacity(0.30),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .butt)
            )
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(accentColor.opacity(0.68))
                .frame(width: 2, height: 15)
                .position(x: x, y: middle)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
