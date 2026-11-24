import AppKit
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
    @ObservedObject var updateService: UpdateService
    let onCopy: (Clip, Bool, Bool) -> Void
    let onOpenLibrary: () -> Void
    let onOpenSettings: () -> Void
    let onOpenUpdate: () -> Void
    let onCreateTextClip: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var showingCollectionOverview = false
    @State private var editingNormalCollection: ClipCollection?
    @State private var editingSmartCollection: ClipCollection?
    @State private var deletingCollection: ClipCollection?

    var body: some View {
        panelSurface
        .pasteoryTheme(state.settings.themeColor, language: state.settings.appLanguage)
        .sheet(isPresented: $state.quickNewNormalCollectionActive) {
            CollectionNameEditor(state: state, existing: nil)
        }
        .sheet(item: $editingNormalCollection) {
            CollectionNameEditor(state: state, existing: $0)
        }
        .sheet(item: $editingSmartCollection) {
            SmartCollectionEditor(state: state, existing: $0)
        }
        .sheet(isPresented: Binding(get: { state.intelligence.showingReview }, set: { state.intelligence.showingReview = $0 })) {
            AIReviewView(controller: state.intelligence)
        }
        .alert(
            deletingCollection.map { L10n.tr("删除“\($0.name)”？") } ?? L10n.tr("删除分组？"),
            isPresented: Binding(
                get: { deletingCollection != nil },
                set: { if !$0 { deletingCollection = nil } }
            ),
            presenting: deletingCollection
        ) { collection in
            Button(L10n.tr("删除"), role: .destructive) {
                Task { await state.deleteCollection(collection) }
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: { collection in
            Text(collection.kind == .smart
                ? L10n.tr("智能规则会一并删除，剪贴板内容不会被删除。")
                : L10n.tr("内容只会移出这个分组，不会从资料库删除。"))
        }
        .onAppear {
            searchFocused = false
            if state.quickSearchFocused { state.quickSearchFocused = false }
            DispatchQueue.main.async {
                (NSApp.keyWindow as? PasteoryPanel)?.makeFirstResponder(nil)
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
            if state.settings.groupPresentation.profile == .minimal { GroupViewMenu(state: state, quick: true) }
            Button { state.quickPanelPinned.toggle() } label: {
                Image(systemName: state.quickPanelPinned ? "pin.fill" : "pin")
                    .foregroundStyle(state.quickPanelPinned ? state.settings.themeColor.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).help(state.quickPanelPinned ? L10n.tr("取消固定") : L10n.tr("固定面板"))

            HStack(spacing: 7) {
                if state.quickCapturePending { ProgressView().controlSize(.mini) }
                else { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                TextField(state.quickCapturePending ? L10n.tr("正在读取刚复制的内容…") : L10n.tr("输入开始搜索…"), text: $state.quickQuery)
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
                .buttonStyle(.plain).help(L10n.tr("快捷操作"))

            HStack(spacing: 6) {
                UpdateBadge(service: updateService, theme: state.settings.themeColor, onOpen: onOpenUpdate)
                Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help(L10n.tr("打开设置"))
            }
        }
        .padding(12)
    }

    private var panelSurface: some View {
        HStack(spacing: 0) {
            if state.settings.groupSidebarWidth > 0, state.settings.quickTabLayout == .left {
                groupSidebar
                GroupSidebarDivider(settings: state.settings)
            }
            panelContent
            if state.settings.groupSidebarWidth > 0, state.settings.quickTabLayout == .right {
                GroupSidebarDivider(settings: state.settings)
                groupSidebar
            }
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
        .frame(minWidth: 340 + state.settings.groupSidebarWidth, idealWidth: 380 + state.settings.groupSidebarWidth, maxWidth: 520 + state.settings.groupSidebarWidth, minHeight: 480, idealHeight: 660, maxHeight: 760)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            header
            if state.intelligence.needsAttention {
                AIOrganizationStatusView(controller: state.intelligence)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if state.organizationResultsWaiting {
                HStack(spacing: 7) {
                    Spacer(minLength: 0)
                    if state.organizationResultsWaiting { Button(L10n.tr("显示新整理结果")) { Task { await state.showOrganizationResults() } } }
                }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
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
                        Button(L10n.tr("撤销")) { Task { await state.undoLastAggregation() } }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                    }
                    Button { state.clearStatus() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help(L10n.tr("关闭提示"))
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
                Text(L10n.tr("分组")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                collectionManagerButton
            }
            GroupViewPicker(state: state, quick: true)
            HStack(spacing: 3) {
                GroupSearchButton(state: state, quick: true)
                Spacer(minLength: 0)
                directionKeycap("arrow.left")
                directionKeycap("arrow.right")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.quickTabs) { tab in
                            if let title = sectionTitle(for: tab) {
                                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 10)
                            }
                            quickTabButton(tab)
                                .modifier(QuickTabDragModifier(tab: tab, state: state))
                                .id(tab.scope)
                        }
                        if state.settings.groupPresentation.profile == .common, state.intelligence.state.groups.count > state.recommendedAICollections.count {
                            Button(L10n.tr("全部 AI 分组（\(state.intelligence.state.groups.count)）")) { state.switchGroupView(.ai) }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(8)
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
        .frame(width: state.settings.groupSidebarWidth)
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
        .help(L10n.tr("查看和管理全部分组"))
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

    private func directionKeycap(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 18, height: 16)
            .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private func sectionTitle(for tab: QuickTab) -> String? {
        if isAITab(tab), state.quickTabs.first(where: isAITab)?.scope == tab.scope {
            return state.settings.groupPresentation.profile == .ai ? L10n.tr("AI 分组") : L10n.tr("AI 推荐")
        }
        if case .collection(let id) = tab.scope, !isAITab(tab),
           state.collections.first(where: { state.intelligence.state.groups[$0.id] == nil })?.id == id { return L10n.tr("普通与规则分组") }
        return nil
    }

    private func isAITab(_ tab: QuickTab) -> Bool {
        if case .collection(let id) = tab.scope { return state.intelligence.state.groups[id] != nil }
        return false
    }

    private func quickTabButton(_ tab: QuickTab) -> some View {
        Button {
            selectQuickTab(tab)
        } label: {
            HStack(spacing: 5) {
                GroupIdentityIcon(isAI: isAITab(tab), symbol: tab.symbol, size: 11)
                    .foregroundStyle(quickTabIconColor(tab))
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .collection(let id) = tab.scope {
                    GroupNewContentBadge(state: state, id: id)
                }
                GroupShortcutHint(text: tabShortcutHint(tab))
            }
            .font(.system(size: 12, weight: state.quickScope == tab.scope ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, state.settings.groupPresentation.compact ? 4 : 6)
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
            if tab.scope == .all {
                Button(L10n.tr("全部内容")) { state.setUngroupedFilter(false, quick: true) }
                Button(L10n.tr("仅查看未分组内容")) { state.setUngroupedFilter(true, quick: true) }
            }
            if case .collection(let id) = tab.scope,
               let collection = state.collections.first(where: { $0.id == id }) {
                Button(collection.kind == .smart ? L10n.tr("编辑名称和规则…") : L10n.tr("重命名…")) {
                    if collection.kind == .smart { editingSmartCollection = collection }
                    else { editingNormalCollection = collection }
                }
                Divider()
                Button(L10n.tr("删除分组"), role: .destructive) { deletingCollection = collection }
            }
        }
    }

    private func selectQuickTab(_ tab: QuickTab) {
        state.dismissQuickMetadataEditor()
        state.quickScope = tab.scope
        if case .collection(let id) = tab.scope { state.intelligence.groupOpened(id) }
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
                    if state.quickHasMore {
                        Button {
                            Task { await state.loadMoreQuick() }
                        } label: {
                            HStack {
                                if state.quickLoadingMore { ProgressView().controlSize(.mini) }
                                Text(L10n.tr("加载更多"))
                            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .disabled(state.quickLoadingMore)
                        .id(state.quickClips.count)
                        .onAppear { Task { await state.loadMoreQuick() } }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .scrollPosition(id: $state.quickScrollAnchor, anchor: .top)
            .contentMargins(.top, 0, for: .scrollContent)
            .onChange(of: ListScrollState(
                selectionID: state.quickSelectionID,
                aggregationID: state.quickSelectedAggregationID,
                resetID: state.quickListResetID,
                presentationID: state.quickPresentationID
            )) { previous, current in
                guard !state.restoringGroupView else { return }
                if previous.resetID != current.resetID || previous.presentationID != current.presentationID {
                    DispatchQueue.main.async { proxy.scrollTo("quick-list-top", anchor: .top) }
                } else {
                    scrollQuickSelection(proxy)
                }
            }
            .onAppear { if state.quickScrollAnchor == nil { DispatchQueue.main.async { proxy.scrollTo("quick-list-top", anchor: .top) } } }
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
            Text(state.quickHasMore ? L10n.tr("已加载 \(state.quickTopLevelResultCount) 个结果") : L10n.tr("找到 \(state.quickTopLevelResultCount) 个结果"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                Task { await state.prepareQuickAggregation() }
            } label: {
                Label(L10n.tr("聚合结果"), systemImage: "square.stack.3d.up")
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
            Text(L10n.tr("已选 \(state.quickMultiSelectionIDs.count) 项"))
                .font(.caption.weight(.semibold))
            Text(L10n.tr("Space 勾选 · Esc 退出"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(L10n.tr("取消")) { state.exitQuickMultiSelect() }
                .buttonStyle(.borderless)
            Button {
                Task { await state.prepareQuickAggregation() }
            } label: {
                Label(L10n.tr("聚合"), systemImage: "square.stack.3d.up")
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
        let hint = tabShortcutHint(tab).map { "（\($0)）" } ?? ""
        guard case .collection(let id) = tab.scope,
              let collection = state.collections.first(where: { $0.id == id }) else {
            return L10n.tr("全部内容") + hint
        }
        let kind = isAITab(tab) ? L10n.tr("AI 分组") : (collection.kind == .smart ? L10n.tr("智能分组") : L10n.tr("普通分组"))
        return kind + "：" + collection.name + hint + "\n" + (state.intelligence.state.groups[id]?.definition ?? L10n.tr("拖动调整顺序"))
    }

    private func tabShortcutHint(_ tab: QuickTab) -> String? {
        if case .collection(let id) = tab.scope { return state.groupNavigationHint(for: id, quick: true) }
        return state.groupNavigationHint(for: nil, quick: true)
    }

    private var aggregateResultsHelp: String {
        guard let shortcut = state.settings.quickShortcut(for: .aggregateContent) else {
            return L10n.tr("聚合当前搜索结果")
        }
        return L10n.tr("聚合当前搜索结果（\(ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))）")
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
            title = L10n.tr("智能分组尚未设置规则")
            description = L10n.tr("右键点击上方分组标签，选择“编辑名称和规则”。")
            symbol = "sparkles"
        } else if activeCollection != nil, state.quickQuery.isEmpty {
            title = L10n.tr("分组中还没有内容")
            description = activeCollection?.kind == .smart ? L10n.tr("当前没有内容符合这组规则。") : L10n.tr("右键点击剪辑，可以把内容加入这个分组。")
            symbol = activeCollection?.kind == .smart ? "sparkles" : "folder"
        } else {
            title = state.quickQuery.isEmpty ? L10n.tr("还没有剪贴板内容") : L10n.tr("没有找到匹配内容")
            description = L10n.tr("复制一段文字、链接或图片后，它会出现在这里。")
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
                .buttonStyle(.plain).help(L10n.tr("打开资料库（⌘L）"))
            Text(L10n.tr("今日·\(state.quickDayCount)条｜近7日·\(state.quickWeekCount)条"))
                .monospacedDigit()
                .help(L10n.tr("按本机时区的自然日统计：今日从 0 点开始，近 7 日包含今天；不包含废纸篓"))
            Spacer(minLength: 12)
            Text(L10n.tr("↑↓ 内容　长按 Command 提示"))
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
