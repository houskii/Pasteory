import AppKit
import Carbon
import PasteoryCore
import SwiftUI

struct QuickPanelView: View {
    private struct ListScrollState: Equatable {
        let selectionID: UUID?
        let aggregationID: UUID?
        let resetID: UUID
        let presentationID: UUID
    }

    @ObservedObject var state: AppState
    let onCopy: (Clip, Bool, Bool) -> Void
    let onOpenLibrary: () -> Void
    let onOpenSettings: () -> Void
    let onCreateTextClip: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var showingCollectionOverview = false
    @State private var editingNormalCollection: ClipCollection?
    @State private var editingSmartCollection: ClipCollection?
    @State private var deletingCollection: ClipCollection?

    var body: some View {
        panelSurface
        .pasteoryTheme(state.settings.themeColor)
        .sheet(isPresented: $state.quickNewNormalCollectionActive) {
            CollectionNameEditor(state: state, existing: nil)
        }
        .sheet(item: $editingNormalCollection) {
            CollectionNameEditor(state: state, existing: $0)
        }
        .sheet(item: $editingSmartCollection) {
            SmartCollectionEditor(state: state, existing: $0)
        }
        .alert(
            deletingCollection.map { "删除“\($0.name)”？" } ?? "删除分组？",
            isPresented: Binding(
                get: { deletingCollection != nil },
                set: { if !$0 { deletingCollection = nil } }
            ),
            presenting: deletingCollection
        ) { collection in
            Button("删除", role: .destructive) {
                Task { await state.deleteCollection(collection) }
            }
            Button("取消", role: .cancel) {}
        } message: { collection in
            Text(collection.kind == .smart
                ? "智能规则会一并删除，剪贴板内容不会被删除。"
                : "内容只会移出这个分组，不会从资料库删除。")
        }
        .onAppear {
            searchFocused = false
            state.quickSearchFocused = false
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--debug-show-collection-overview") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    showingCollectionOverview = true
                }
            }
#endif
        }
        .onChange(of: state.quickSearchFocused) { _, isFocused in
            searchFocused = isFocused
        }
        .onChange(of: searchFocused) { _, isFocused in
            state.quickSearchFocused = isFocused
        }
        .onChange(of: state.quickMetadataEditorActive) { _, isEditing in
            state.quickSearchFocused = false
            searchFocused = false
            if !isEditing {
                DispatchQueue.main.async {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
        }
        .onChange(of: state.quickCollectionPickerActive) { _, isEditing in
            state.quickSearchFocused = false
            searchFocused = false
            if !isEditing {
                DispatchQueue.main.async {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
        }
        .onChange(of: state.quickAggregationEditorActive) { _, isEditing in
            state.quickSearchFocused = false
            searchFocused = false
            if !isEditing {
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onChange(of: showingCollectionOverview) { _, _ in updateCollectionManagerState() }
        .onChange(of: state.quickNewNormalCollectionActive) { _, _ in
            updateCollectionManagerState()
        }
        .onChange(of: editingNormalCollection) { _, _ in updateCollectionManagerState() }
        .onChange(of: editingSmartCollection) { _, _ in updateCollectionManagerState() }
        .onChange(of: deletingCollection) { _, _ in updateCollectionManagerState() }
        .onDisappear { state.quickCollectionManagerActive = false }
    }

    private var metadataEditorClip: Clip? {
        guard let clipID = state.quickMetadataEditorClipID else { return nil }
        if let clip = state.quickClips.first(where: { $0.id == clipID }) { return clip }
        return state.aggregationMembers.values.lazy.flatMap { $0 }.first(where: { $0.id == clipID })
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { state.quickPanelPinned.toggle() } label: {
                Image(systemName: state.quickPanelPinned ? "pin.fill" : "pin")
                    .foregroundStyle(state.quickPanelPinned ? state.settings.themeColor.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).help(state.quickPanelPinned ? "取消固定" : "固定面板")

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("输入开始搜索…", text: $state.quickQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: state.quickQuery) { _, _ in Task { await state.refreshQuick(debounce: true) } }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.86), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                state.quickSearchFocused = true
                searchFocused = true
            }

            QuickActionsToolbarMenu(state: state, clip: state.quickSelectedClip, compact: true)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .buttonStyle(.plain).help("快捷操作")

            Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("打开设置")
        }
        .padding(12)
    }

    private var panelSurface: some View {
        HStack(spacing: 0) {
            if state.settings.quickTabLayout == .sidebar {
                groupSidebar
                Divider()
            }
            panelContent
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary, lineWidth: 1))
        .overlay {
            if let clip = metadataEditorClip {
                QuickMetadataEditor(
                    state: state,
                    clip: clip,
                    initialField: state.quickMetadataEditorInitialField,
                    onSave: { title, note, collectionIDs in
                        state.updateMetadata(
                            for: clip,
                            title: title,
                            note: note,
                            collectionIDs: collectionIDs
                        )
                        state.dismissQuickMetadataEditor()
                    },
                    onCancel: { state.dismissQuickMetadataEditor() }
                )
            } else if let draft = state.quickAggregationDraft {
                QuickAggregationEditor(state: state, draft: draft)
            }
        }
        .frame(minWidth: 340 + state.settings.quickTabLayout.sidebarWidth, idealWidth: 380 + state.settings.quickTabLayout.sidebarWidth, maxWidth: 520 + state.settings.quickTabLayout.sidebarWidth, minHeight: 480, idealHeight: 660, maxHeight: 760)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            header
            if state.settings.quickTabLayout == .horizontal { groupTabs }
            Divider()
            if state.quickMultiSelectActive { multiSelectionBar }
            else if !state.quickQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !state.quickListEntries.isEmpty { aggregationSearchBar }
            if state.quickListEntries.isEmpty { emptyState } else { clipList }
            if let message = state.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbol)
                    Text(message).font(.caption.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 4)
                    if state.undoableAggregation != nil {
                        Button("撤销") { Task { await state.undoLastAggregation() } }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                    }
                    Button { state.clearStatus() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("关闭提示")
                }
                .foregroundStyle(statusColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusColor.opacity(0.13))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            footer
        }
    }

    private var groupSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("分组").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                collectionManagerButton
            }
            HStack(spacing: 3) {
                directionKeycap("arrow.left")
                directionKeycap("arrow.right")
                Text("切换分组").font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.quickTabs) { tab in
                            quickTabButton(tab)
                                .modifier(QuickTabDragModifier(tab: tab, state: state))
                                .id(tab.scope)
                        }
                        Color.clear.frame(height: 20)
                            .dropDestination(for: String.self) { identifiers, _ in
                                guard let raw = identifiers.first, let id = UUID(uuidString: raw) else { return false }
                                Task { await state.moveCollectionToEnd(id: id) }
                                return true
                            }
                    }
                }
                .onAppear { proxy.scrollTo(state.quickScope, anchor: .center) }
                .onChange(of: state.quickScope) { _, value in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(value, anchor: .center) }
                }
            }
        }
        .padding(8)
        .frame(width: 139)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var collectionManagerButton: some View {
        Button {
            showingCollectionOverview.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "square.grid.2x2")
                if !state.collections.isEmpty {
                    Text("\(state.collections.count)").monospacedDigit()
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(showingCollectionOverview ? state.settings.themeColor.accentColor : Color.secondary)
        .help("查看和管理全部分组")
        .popover(isPresented: $showingCollectionOverview, arrowEdge: .bottom) {
            QuickCollectionOverview(
                state: state,
                isPresented: $showingCollectionOverview,
                onCreateText: onCreateTextClip,
                onCreateNormal: {
                    showingCollectionOverview = false
                    DispatchQueue.main.async { state.quickNewNormalCollectionActive = true }
                },
                onCreateSmart: {
                    showingCollectionOverview = false
                    DispatchQueue.main.async {
                        editingSmartCollection = ClipCollection(
                            name: "",
                            kind: .smart,
                            sortOrder: state.collections.count,
                            ruleSet: SmartRuleSet()
                        )
                    }
                },
                onEdit: { collection in
                    showingCollectionOverview = false
                    DispatchQueue.main.async {
                        if collection.kind == .smart { editingSmartCollection = collection }
                        else { editingNormalCollection = collection }
                    }
                },
                onDelete: { collection in
                    showingCollectionOverview = false
                    DispatchQueue.main.async { deletingCollection = collection }
                }
            )
        }
    }

    private var groupTabs: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(state.quickTabs) { tab in
                                quickTabButton(tab)
                                    .modifier(QuickTabDragModifier(tab: tab, state: state))
                                    .id(tab.scope)
                            }
                            Color.clear
                                .frame(width: 14, height: 28)
                                .dropDestination(for: String.self) { identifiers, _ in
                                    guard let raw = identifiers.first, let id = UUID(uuidString: raw) else { return false }
                                    Task { await state.moveCollectionToEnd(id: id) }
                                    return true
                                }
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 4)
                    }
                    .onChange(of: state.quickScope) { _, value in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(value, anchor: .center) }
                    }
                }
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.7))
                    .frame(width: 1, height: 20)
                collectionManagerButton
                .padding(.trailing, 8)
            }

            HStack(spacing: 8) {
                Text("当前：\(currentQuickGroupTitle)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(currentQuickGroupTitle)
                Spacer(minLength: 8)
                Text(currentQuickGroupPosition)
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .accessibilityElement(children: .combine)
        }
        .padding(.bottom, 8)
    }

    private var currentQuickGroupTitle: String {
        guard case .collection(let id) = state.quickScope,
              let collection = state.collections.first(where: { $0.id == id }) else { return "全部内容" }
        return collection.name
    }

    private var currentQuickGroupPosition: String {
        guard case .collection(let id) = state.quickScope,
              let index = state.collections.firstIndex(where: { $0.id == id }) else {
            return "共 \(state.collections.count) 个分组"
        }
        return "第 \(index + 1) / \(state.collections.count) 个分组"
    }

    private func directionKeycap(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 18, height: 16)
            .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private func quickTabButton(_ tab: QuickTab) -> some View {
        Button {
            selectQuickTab(tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(quickTabIconColor(tab))
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: state.settings.quickTabLayout == .sidebar ? .infinity : 68, alignment: .leading)
            }
            .font(.system(size: 12, weight: state.quickScope == tab.scope ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(state.quickScope == tab.scope ? state.settings.themeColor.accentColor : Color.primary)
            .background(
                state.quickScope == tab.scope ? state.settings.themeColor.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(quickTabHelp(tab))
        .contextMenu {
            if case .collection(let id) = tab.scope,
               let collection = state.collections.first(where: { $0.id == id }) {
                Button(collection.kind == .smart ? "编辑名称和规则…" : "重命名…") {
                    if collection.kind == .smart { editingSmartCollection = collection }
                    else { editingNormalCollection = collection }
                }
                Divider()
                Button("删除分组", role: .destructive) { deletingCollection = collection }
            }
        }
    }

    private func selectQuickTab(_ tab: QuickTab) {
        state.dismissQuickMetadataEditor()
        state.quickScope = tab.scope
        state.quickPresentationID = UUID()
        Task { await state.refreshQuick(resetSelection: true) }
    }

    private func updateCollectionManagerState() {
        state.quickCollectionManagerActive = showingCollectionOverview
            || state.quickNewNormalCollectionActive
            || editingNormalCollection != nil
            || editingSmartCollection != nil
            || deletingCollection != nil
    }

    private var clipList: some View {
        let entries = state.quickListEntries
        let topClips = entries.compactMap { entry -> Clip? in
            guard case .clip(let clip, nil) = entry.content else { return nil }
            return clip
        }
        let shortcutNumbers = Dictionary(uniqueKeysWithValues: topClips.prefix(9).enumerated().map { ($0.element.id, $0.offset + 1) })
        return ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("quick-list-top")
                LazyVStack(spacing: 8) {
                    ForEach(entries) { entry in
                        switch entry.content {
                        case .aggregation(let aggregation):
                            QuickAggregationCard(state: state, aggregation: aggregation)
                                .id(entry.id)
                        case .clip(let clip, let parentID):
                            QuickClipCard(
                                state: state,
                                clip: clip,
                                parentAggregationID: parentID,
                                shortcutNumber: parentID == nil ? shortcutNumbers[clip.id] : nil,
                                onCopy: onCopy
                            )
                            .padding(.leading, parentID == nil ? 0 : 16)
                            .overlay(alignment: .leading) {
                                if parentID != nil {
                                    AggregationChildMarker(
                                        accentColor: state.settings.themeColor.accentColor,
                                        gap: 8,
                                        isFirst: entry.isFirstChild,
                                        isLast: entry.isLastChild
                                    )
                                    .frame(width: 16)
                                }
                            }
                            .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .onChange(of: ListScrollState(
                selectionID: state.quickSelectionID,
                aggregationID: state.quickSelectedAggregationID,
                resetID: state.quickListResetID,
                presentationID: state.quickPresentationID
            )) { previous, current in
                if previous.resetID != current.resetID || previous.presentationID != current.presentationID {
                    DispatchQueue.main.async { proxy.scrollTo("quick-list-top", anchor: .top) }
                } else {
                    scrollQuickSelection(proxy)
                }
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("quick-list-top", anchor: .top) } }
        }
    }

    private func scrollQuickSelection(_ proxy: ScrollViewProxy) {
        let target: AggregationListEntryID?
        if let id = state.quickSelectedAggregationID { target = .aggregation(id) }
        else if let id = state.quickSelectionID {
            target = state.quickListEntries.first { entry in
                if case .clip(let clip, _) = entry.content { return clip.id == id }
                return false
            }?.id
        } else { target = nil }
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(target, anchor: .center) }
    }

    private var aggregationSearchBar: some View {
        HStack(spacing: 8) {
            Text("找到 \(state.quickTopLevelResultCount) 个结果")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                Task { await state.prepareQuickAggregation() }
            } label: {
                Label("聚合结果", systemImage: "square.stack.3d.up")
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
            .disabled(!state.quickCanAggregateCurrentResults)
            .help(aggregateResultsHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(state.settings.themeColor.accentColor.opacity(0.06))
    }

    private var multiSelectionBar: some View {
        HStack(spacing: 8) {
            Text("已选 \(state.quickMultiSelectionIDs.count) 项")
                .font(.caption.weight(.semibold))
            Text("Space 勾选 · Esc 退出")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("取消") { state.exitQuickMultiSelect() }
                .buttonStyle(.borderless)
            Button {
                Task { await state.prepareQuickAggregation() }
            } label: {
                Label("聚合", systemImage: "square.stack.3d.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(state.settings.themeColor.accentColor)
            .disabled(state.quickMultiSelectionIDs.count < 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(state.settings.themeColor.accentColor.opacity(0.08))
    }

    private func quickTabHelp(_ tab: QuickTab) -> String {
        guard case .collection(let id) = tab.scope,
              let collection = state.collections.first(where: { $0.id == id }) else {
            return "全部内容"
        }
        return "\(collection.kind == .smart ? "智能分组" : "普通分组")：\(collection.name) · 拖动调整顺序"
    }

    private var aggregateResultsHelp: String {
        guard let shortcut = state.settings.quickShortcut(for: .aggregateContent) else {
            return "聚合当前搜索结果"
        }
        return "聚合当前搜索结果（\(ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))）"
    }

    private func quickTabIconColor(_ tab: QuickTab) -> Color {
        if state.quickScope == tab.scope { return state.settings.themeColor.accentColor }
        guard case .collection(let id) = tab.scope,
              let collection = state.collections.first(where: { $0.id == id }) else {
            return .secondary
        }
        return collection.kind == .smart ? state.settings.themeColor.accentColor : .secondary
    }

    private var emptyState: some View {
        let needsRules = selectedSmartCollection?.ruleSet?.conditions.isEmpty == true
        let activeCollection = selectedCollection
        let title: String
        let description: String
        let symbol: String
        if needsRules {
            title = "智能分组尚未设置规则"
            description = "右键点击上方分组标签，选择“编辑名称和规则”。"
            symbol = "sparkles"
        } else if activeCollection != nil, state.quickQuery.isEmpty {
            title = "分组中还没有内容"
            description = activeCollection?.kind == .smart ? "当前没有内容符合这组规则。" : "右键点击剪辑，可以把内容加入这个分组。"
            symbol = activeCollection?.kind == .smart ? "sparkles" : "folder"
        } else {
            title = state.quickQuery.isEmpty ? "还没有剪贴板内容" : "没有找到匹配内容"
            description = "复制一段文字、链接或图片后，它会出现在这里。"
            symbol = state.quickQuery.isEmpty ? "clipboard" : "magnifyingglass"
        }
        return ContentUnavailableView(
            title,
            systemImage: symbol,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedSmartCollection: ClipCollection? {
        selectedCollection?.kind == .smart ? selectedCollection : nil
    }

    private var selectedCollection: ClipCollection? {
        guard case .collection(let id) = state.quickScope else { return nil }
        return state.collections.first { $0.id == id }
    }

    private var statusColor: Color {
        switch state.statusKind {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    private var statusSymbol: String {
        switch state.statusKind {
        case .info: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onOpenLibrary) { Image(systemName: "list.star") }
                .buttonStyle(.plain).help("打开资料库（⌘L）")
            Text("今日·\(state.quickDayCount)条｜近7日·\(state.quickWeekCount)条")
                .monospacedDigit()
                .help("按本机时区的自然日统计：今日从 0 点开始，近 7 日包含今天；不包含废纸篓")
            Spacer(minLength: 12)
            Text(state.settings.quickTabLayout == .sidebar
                 ? "↑↓ 内容　长按 Command 提示"
                 : "↑↓ 内容　←→ 分组　长按 Command 提示")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

}

private struct QuickTabDragModifier: ViewModifier {
    let tab: QuickTab
    @ObservedObject var state: AppState

    @ViewBuilder
    func body(content: Content) -> some View {
        if case .collection(let targetID) = tab.scope {
            content
                .draggable(targetID.uuidString)
                .dropDestination(for: String.self) { identifiers, _ in
                    guard let raw = identifiers.first,
                          let sourceID = UUID(uuidString: raw),
                          sourceID != targetID else { return false }
                    Task { await state.moveCollection(id: sourceID, before: targetID) }
                    return true
                }
        } else {
            content
        }
    }
}

private struct QuickCollectionOverview: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    let onCreateText: () -> Void
    let onCreateNormal: () -> Void
    let onCreateSmart: () -> Void
    let onEdit: (ClipCollection) -> Void
    let onDelete: (ClipCollection) -> Void
    @State private var highlightedScope: QuickScope?
    @FocusState private var overviewFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("全部分组").font(.headline)
                    Text("拖动分组可调整快捷面板中的顺序")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(state.collections.count) 个")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        overviewRow(
                            title: "全部内容",
                            symbol: "clock",
                            selected: state.quickScope == .all,
                            highlighted: highlightedScope == .all
                        ) {
                            select(scope: .all)
                        }
                        .id(QuickScope.all)

                        ForEach(state.collections) { collection in
                            collectionRow(collection)
                                .id(QuickScope.collection(collection.id))
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.to.line")
                            Text("拖到这里移到末尾")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                        .dropDestination(for: String.self) { identifiers, _ in
                            guard let raw = identifiers.first, let id = UUID(uuidString: raw) else { return false }
                            Task { await state.moveCollectionToEnd(id: id) }
                            return true
                        }
                    }
                    .padding(10)
                }
                .onChange(of: highlightedScope) { _, scope in
                    guard let scope else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(scope, anchor: .center) }
                }
            }
            .frame(height: min(CGFloat(state.collections.count + 2) * 38, 195))

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                actionButton(
                    "新建分组",
                    symbol: "folder.badge.plus",
                    shortcut: state.settings.quickShortcut(for: .createCollection),
                    action: onCreateNormal
                )
                actionButton("新建智能分组", symbol: "sparkles", action: onCreateSmart)
                Divider().padding(.vertical, 3)
                actionButton("新建文本内容", symbol: "doc.badge.plus", action: onCreateText)
            }
            .padding(10)
        }
        .frame(width: 340)
        .pasteoryTheme(state.settings.themeColor)
        .focusable()
        .focusEffectDisabled()
        .focused($overviewFocused)
        .onAppear {
            highlightedScope = state.quickScope
            DispatchQueue.main.async { overviewFocused = true }
        }
        .onKeyPress(.upArrow) {
            moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            select(scope: highlightedScope ?? state.quickScope)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func collectionRow(_ collection: ClipCollection) -> some View {
        let scope = QuickScope.collection(collection.id)
        return overviewRow(
            title: collection.name,
            symbol: collection.kind == .smart ? "sparkles" : "folder",
            selected: state.quickScope == scope,
            highlighted: highlightedScope == scope,
            showsDragHandle: true
        ) {
            select(scope: scope)
        }
        .draggable(collection.id.uuidString)
        .dropDestination(for: String.self) { identifiers, _ in
            guard let raw = identifiers.first,
                  let sourceID = UUID(uuidString: raw),
                  sourceID != collection.id else { return false }
            Task { await state.moveCollection(id: sourceID, before: collection.id) }
            return true
        }
        .contextMenu {
            Button(collection.kind == .smart ? "编辑名称和规则…" : "重命名…") {
                onEdit(collection)
            }
            Divider()
            Button("删除分组", role: .destructive) { onDelete(collection) }
        }
    }

    private func overviewRow(
        title: String,
        symbol: String,
        selected: Bool,
        highlighted: Bool,
        showsDragHandle: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? state.settings.themeColor.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(title)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(state.settings.themeColor.accentColor)
                }
                if showsDragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected
                    ? state.settings.themeColor.accentColor.opacity(0.14)
                    : (highlighted ? Color.secondary.opacity(0.08) : Color.clear),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        shortcut: PasteoryShortcut? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(state.settings.themeColor.accentColor)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(scope: QuickScope) {
        state.quickScope = scope
        state.quickPresentationID = UUID()
        isPresented = false
        Task { await state.refreshQuick(resetSelection: true) }
    }

    private var scopes: [QuickScope] {
        [.all] + state.collections.map { .collection($0.id) }
    }

    private func moveHighlight(by offset: Int) {
        let values = scopes
        guard !values.isEmpty else { return }
        let current = values.firstIndex(of: highlightedScope ?? state.quickScope) ?? 0
        highlightedScope = values[min(max(current + offset, 0), values.count - 1)]
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

struct QuickCommandHelpView: View {
    @ObservedObject var settings: AppSettings
    let scrollEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Command 快捷操作").font(.caption.weight(.semibold))
                Spacer()
                Text("松开 ⌘ 隐藏").font(.caption2).foregroundStyle(.tertiary)
            }

            if scrollEnabled {
                ScrollView(.vertical) {
                    commandHelpSections
                }
                .scrollIndicators(.visible)
            } else {
                commandHelpSections
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.65), lineWidth: 1))
    }

    private var commandHelpSections: some View {
        VStack(alignment: .leading, spacing: 11) {
            commandHelpSection("粘贴与复制", actions: [.directPaste, .copyOnly, .plainTextPaste, .plainTextCopy])
            commandHelpSection("内容打开", actions: [.openSelected])
            commandHelpSection("搜索", actions: [.toggleSearch])
            commandHelpSection("文本工具", actions: [.quickActions])
            commandHelpSection(
                "整理当前项目",
                actions: [
                    .toggleFavorite, .togglePinned, .editMetadata, .setCollection,
                    .createCollection, .aggregateContent, .expandAggregation, .collapseAggregation, .moveToTrash
                ]
            )
            commandHelpSection("窗口与页面", actions: [.openLibrary, .openSettings, .closePanel])
            VStack(alignment: .leading, spacing: 6) {
                commandHelpSectionTitle("固定导航快捷键")
                commandHelpItem(shortcut: "↑↓ / ←→", title: "选择内容 / 切换分组")
                commandHelpItem(shortcut: "⌘1～⌘9", title: "快速粘贴前 9 项")
                commandHelpItem(shortcut: "Esc", title: "关闭当前编辑层")
            }
        }
    }

    private func commandHelpSection(_ title: String, actions: [QuickPanelAction]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            commandHelpSectionTitle(title)
            ForEach(actions) { action in
                if let shortcut = settings.quickShortcut(for: action) {
                    commandHelpItem(
                        shortcut: ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers),
                        title: action.title
                    )
                }
            }
        }
    }

    private func commandHelpSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commandHelpItem(shortcut: String, title: String) -> some View {
        HStack(spacing: 5) {
            Text(shortcut)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(settings.themeColor.accentColor)
                .frame(width: 64, alignment: .trailing)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

private struct QuickClipCard: View {
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
                Button("直接粘贴") { onCopy(clip, false, true) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .directPaste))
                Button("只复制") { onCopy(clip, false, false) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .copyOnly))
                Button("纯文本粘贴") { onCopy(clip, true, true) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .plainTextPaste))
                Button("纯文本复制") { onCopy(clip, true, false) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .plainTextCopy))
                QuickActionsMenu { action in
                    state.runQuickTextAction(action, for: clip)
                }
                Divider()
                Button(clip.isFavorite ? "取消收藏" : "收藏") { state.toggleFavorite(clip) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .toggleFavorite))
                Button(clip.isPinned ? "取消置顶" : "置顶") { state.togglePinned(clip) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .togglePinned))
                Button("编辑信息…") {
                    state.presentQuickMetadataEditor(for: clip.id, initialField: .title)
                }
                    .quickActionShortcut(state.settings.quickShortcut(for: .editMetadata))
                Button("设置分组…") {
                    state.presentQuickMetadataEditor(for: clip.id, initialField: .collections)
                }
                    .quickActionShortcut(state.settings.quickShortcut(for: .setCollection))
                Button("聚合内容…") {
                    state.quickSelectionID = clip.id
                    state.quickSelectedAggregationID = nil
                    Task { await state.prepareQuickAggregation() }
                }
                .quickActionShortcut(state.settings.quickShortcut(for: .aggregateContent))
                Divider()
                if let parentAggregationID,
                   let aggregation = state.aggregations.first(where: { $0.id == parentAggregationID }) {
                    Button("移出当前聚合") {
                        Task { await state.removeClip(clip.id, from: aggregation) }
                    }
                    Divider()
                }
                Button("移到废纸篓", role: .destructive) { state.moveToTrash(clip) }
                    .quickActionShortcut(state.settings.quickShortcut(for: .moveToTrash))
            }
    }

    private var isSelected: Bool { state.quickSelectionID == clip.id }

}

private struct QuickAggregationCard: View {
    @ObservedObject var state: AppState
    let aggregation: ClipAggregation
    @State private var showCollectionPicker = false

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
                    if aggregation.membershipMode == .automatic { Text("· 自动更新") }
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
            Button(state.quickExpandedAggregationIDs.contains(aggregation.id) ? "收起内容" : "展开内容") {
                state.toggleQuickAggregation(aggregation.id)
            }
            .quickActionShortcut(state.settings.quickShortcut(
                for: state.quickExpandedAggregationIDs.contains(aggregation.id) ? .collapseAggregation : .expandAggregation
            ))
            Button("编辑聚合…") {
                state.quickSelectedAggregationID = aggregation.id
                state.quickSelectionID = nil
                Task { await state.prepareQuickAggregation() }
            }
            .quickActionShortcut(state.settings.quickShortcut(for: .editMetadata))
            Divider()
            Button(aggregation.isFavorite ? "取消收藏聚合" : "收藏聚合") {
                Task { await state.toggleAggregationFavorite(aggregation) }
            }
            .quickActionShortcut(state.settings.quickShortcut(for: .toggleFavorite))
            Button(aggregation.isPinned ? "取消置顶聚合" : "置顶聚合") {
                Task { await state.toggleAggregationPinned(aggregation) }
            }
            .quickActionShortcut(state.settings.quickShortcut(for: .togglePinned))
            Menu("设置聚合分组") {
                let groups = state.collections.filter { $0.kind == .normal }
                if groups.isEmpty { Text("还没有普通分组") }
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
            Menu("整理全部成员") {
                let members = state.aggregationMembers[aggregation.id] ?? []
                Button(members.allSatisfy(\.isFavorite) ? "取消收藏全部成员" : "收藏全部成员") {
                    Task { await state.toggleFavoriteForAllMembers(of: aggregation) }
                }
                Button(members.allSatisfy(\.isPinned) ? "取消置顶全部成员" : "置顶全部成员") {
                    Task { await state.togglePinnedForAllMembers(of: aggregation) }
                }
                Menu("设置全部成员的分组") {
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
            Button("删除聚合但保留内容", role: .destructive) {
                Task { await state.removeAggregation(aggregation) }
            }
            .quickActionShortcut(state.settings.quickShortcut(for: .moveToTrash))
        }
    }

    private var memberCountLabel: String {
        let query = state.quickQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "\(aggregation.memberClipIDs.count) 项内容" }
        let visible = Set(state.quickClips.map(\.id)).intersection(aggregation.memberClipIDs).count
        guard visible > 0, visible < aggregation.memberClipIDs.count else {
            return "\(aggregation.memberClipIDs.count) 项内容"
        }
        return "匹配 \(visible) / \(aggregation.memberClipIDs.count)"
    }
}

private struct QuickAggregationEditor: View {
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
                Text(draft.isEditing ? "编辑聚合" : "聚合内容")
                    .font(.headline)
                Text(draft.isEditing ? "当前包含 \(memberIDs.count) 项内容" : "将 \(memberIDs.count) 项不同内容保存为一个聚合")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("聚合标题", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                TextField("备注（可选）", text: $note, axis: .vertical)
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
                    Button("取消") { state.dismissQuickAggregationDraft() }
                    Button(draft.isEditing ? "保存" : "创建聚合") {
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

extension View {
    @ViewBuilder
    func quickActionShortcut(_ shortcut: PasteoryShortcut?) -> some View {
        if let shortcut, let key = shortcut.keyEquivalent {
            keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}

extension PasteoryShortcut {
    var eventModifiers: SwiftUI.EventModifiers {
        var value: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { value.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { value.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { value.insert(.shift) }
        if modifiers & UInt32(controlKey) != 0 { value.insert(.control) }
        return value
    }

    var keyEquivalent: KeyEquivalent? {
        let characters: [UInt32: Character] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'",
            40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`"
        ]
        if let character = characters[keyCode] { return KeyEquivalent(character) }
        switch keyCode {
        case 36, 76: return .return
        case 125: return .downArrow
        case 126: return .upArrow
        case 48: return .tab
        case 49: return .space
        case 51: return .delete
        case 53: return .escape
        default: return nil
        }
    }
}

private struct QuickAggregationCollectionPicker: View {
    @ObservedObject var state: AppState
    let aggregation: ClipAggregation
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置聚合分组").font(.headline)
            let groups = state.collections.filter { $0.kind == .normal }
            if groups.isEmpty {
                ContentUnavailableView("还没有普通分组", systemImage: "folder")
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
            HStack { Spacer(); Button("完成", action: onDone).keyboardShortcut(.defaultAction) }
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

private struct QuickMetadataEditor: View {
    @ObservedObject var state: AppState
    let clip: Clip
    let initialField: QuickMetadataEditorField
    let onSave: (String, String, Set<UUID>) -> Void
    let onCancel: () -> Void
    @State private var title: String
    @State private var note: String
    @State private var selectedCollectionIDs: Set<UUID>
    @State private var highlightedCollectionID: UUID?
    @State private var captureEvents = [ClipCaptureEvent]()
    @FocusState private var focusedField: QuickMetadataEditorField?

    init(
        state: AppState,
        clip: Clip,
        initialField: QuickMetadataEditorField,
        onSave: @escaping (String, String, Set<UUID>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.clip = clip
        self.initialField = initialField
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: clip.title)
        _note = State(initialValue: clip.note)
        _selectedCollectionIDs = State(initialValue: clip.collectionIDs)
    }

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = max(300, min(430, geometry.size.width - 24))
            let cardHeight = max(420, min(620, geometry.size.height - 24))
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Text("编辑信息").font(.headline)
                        Spacer()
                        Button(action: onCancel) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("取消编辑")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            titleEditor
                            noteEditor
                            Divider()
                            collectionEditor
                            Divider()
                            sourceContextEditor
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tab / Shift-Tab 切换 · ↑↓ 选择 · Space 勾选")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                        HStack {
                            Spacer()
                            Button("取消", action: onCancel)
                            Button("保存") { save() }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(width: cardWidth, height: cardHeight)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
                }
                .shadow(radius: 18, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: clip.id) { captureEvents = await state.captureEvents(for: clip) }
        .onAppear {
            state.quickMetadataEditorActive = true
            if highlightedCollectionID == nil {
                highlightedCollectionID = normalCollections.first(where: { selectedCollectionIDs.contains($0.id) })?.id
                    ?? normalCollections.first?.id
            }
            DispatchQueue.main.async {
                let target = initialField == .collections && normalCollections.isEmpty ? .title : initialField
                state.quickMetadataEditorFocusedField = target
                focusedField = target
            }
        }
        .onDisappear { state.quickMetadataEditorActive = false }
        .onChange(of: focusedField) { _, field in
            if let field { state.quickMetadataEditorFocusedField = field }
        }
        .onChange(of: state.quickMetadataEditorKeyCommand) { _, command in
            guard let command else { return }
            switch command {
            case .moveFocus(_, let backwards):
                moveFocus(from: focusedField ?? state.quickMetadataEditorFocusedField, backwards: backwards)
            case .moveCollection(_, let offset):
                focusedField = .collections
                state.quickMetadataEditorFocusedField = .collections
                moveCollectionHighlight(by: offset)
            case .toggleCollection:
                focusedField = .collections
                state.quickMetadataEditorFocusedField = .collections
                toggleHighlightedCollection()
            }
        }
        .onChange(of: state.quickMetadataEditorCommitRequestID) { _, request in
            guard request != nil else { return }
            save()
        }
        .onChange(of: state.quickMetadataEditorDismissRequestID) { _, request in
            guard request != nil else { return }
            onCancel()
        }
    }

    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("标题"); Spacer(); Text("\(title.count)/120").foregroundStyle(.tertiary) }
                .font(.caption)
            TextField("可选标题", text: Binding(get: { title }, set: { title = String($0.prefix(120)) }))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .title)
                .onKeyPress(keys: [.tab]) { press in
                    moveFocus(from: .title, backwards: press.modifiers.contains(.shift))
                    return .handled
                }
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("备注"); Spacer(); Text("\(note.count)/4000").foregroundStyle(.tertiary) }
                .font(.caption)
            TextEditor(text: Binding(get: { note }, set: { note = String($0.prefix(4_000)) }))
                .frame(height: 90)
                .padding(6)
                .focused($focusedField, equals: .note)
                .onKeyPress(keys: [.tab]) { press in
                    moveFocus(from: .note, backwards: press.modifiers.contains(.shift))
                    return .handled
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            focusedField == .note ? state.settings.themeColor.accentColor : Color(nsColor: .quaternaryLabelColor),
                            lineWidth: focusedField == .note ? 2 : 1
                        )
                }
        }
    }

    private var sourceContextEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("抓取的来源信息").font(.subheadline.weight(.semibold))
                Spacer()
                if captureEvents.count > 1 {
                    Text("共 \(captureEvents.count) 次复制").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let event = captureEvents.first, let context = event.context {
                VStack(alignment: .leading, spacing: 6) {
                    Text(context.summary).font(.caption.weight(.medium)).textSelection(.enabled)
                    Text(event.capturedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2).foregroundStyle(.secondary)
                    sourceContextRow("网页链接", value: context.payload["url"])
                    sourceContextRow("页面标题", value: context.payload["pageTitle"])
                    sourceContextRow("对话类型", value: context.payload["conversationTypeName"])
                    sourceContextRow("对话标题", value: context.payload["conversationName"])
                    sourceContextRow("仓库", value: context.payload["repository"])
                    sourceContextRow("分支", value: context.payload["branch"])
                    sourceContextRow("目标分支", value: context.payload["targetBranch"])
                    sourceContextRow("选中内容", value: context.payload["selectedText"])
                    sourceContextRow("关联文字", value: context.payload["relatedText"])
                    sourceContextRow("元素", value: context.payload["elementSelector"])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if captureEvents.isEmpty {
                Text("这条剪辑没有单独保存的来源上下文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("本次复制只记录了来源应用，没有获取到更详细的上下文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("这里是自动抓取的只读数据，不会写入上面的标题和备注。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var normalCollections: [ClipCollection] {
        state.collections.filter { $0.kind == .normal }
    }

    @ViewBuilder
    private var collectionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("分组")
                Spacer()
                Text(selectedCollectionCountText).foregroundStyle(.tertiary)
            }
            .font(.caption)

            if normalCollections.isEmpty {
                Label("还没有普通分组", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(normalCollections) { collection in
                                collectionRow(collection)
                                    .id(collection.id)
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: highlightedCollectionID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .frame(maxHeight: 142)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .quaternaryLabelColor), lineWidth: 1)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focusedField, equals: .collections)
                .onKeyPress(keys: [.tab]) { press in
                    moveFocus(from: .collections, backwards: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveCollectionHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveCollectionHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.space) {
                    toggleHighlightedCollection()
                    return .handled
                }
            }
        }
    }

    private func collectionRow(_ collection: ClipCollection) -> some View {
        let selected = selectedCollectionIDs.contains(collection.id)
        let highlighted = focusedField == .collections && highlightedCollectionID == collection.id
        return Button {
            highlightedCollectionID = collection.id
            selectedCollectionIDs = QuickMetadataEditorNavigation.toggled(collection.id, in: selectedCollectionIDs)
            focusedField = .collections
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected || highlighted ? state.settings.themeColor.accentColor : Color.secondary)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(collection.name).lineLimit(1)
                Spacer(minLength: 8)
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                highlighted
                    ? state.settings.themeColor.accentColor.opacity(0.14)
                    : (selected ? state.settings.themeColor.accentColor.opacity(0.07) : Color.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var selectedCollectionCountText: String {
        let count = normalCollections.lazy.filter { selectedCollectionIDs.contains($0.id) }.count
        return count == 0 ? "未选择" : "已选择 \(count) 个"
    }

    private func moveFocus(from field: QuickMetadataEditorField, backwards: Bool) {
        focusedField = QuickMetadataEditorNavigation.nextField(
            from: field,
            backwards: backwards,
            hasCollections: !normalCollections.isEmpty
        )
    }

    private func moveCollectionHighlight(by offset: Int) {
        highlightedCollectionID = QuickMetadataEditorNavigation.nextCollection(
            in: normalCollections.map(\.id),
            currentID: highlightedCollectionID,
            offset: offset
        )
    }

    private func toggleHighlightedCollection() {
        guard let highlightedCollectionID else { return }
        selectedCollectionIDs = QuickMetadataEditorNavigation.toggled(
            highlightedCollectionID,
            in: selectedCollectionIDs
        )
    }

    private func save() {
        onSave(title, note, selectedCollectionIDs)
    }

    @ViewBuilder
    private func sourceContextRow(_ label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                Text(value).textSelection(.enabled).lineLimit(4)
            }
            .font(.caption)
        }
    }
}
