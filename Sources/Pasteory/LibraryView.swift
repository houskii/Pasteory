import AppKit
import PasteoryCore
import PasteoryAI
import SwiftUI

struct LibraryView: View {
    @ObservedObject var state: AppState
    let onPaste: (Clip, Bool, Bool) -> Void
    var onOpenSettings: () -> Void = {}
    var embedded = false
    @State private var showNewNormalCollection = false
    @State private var editingNormalCollection: ClipCollection?
    @State private var editingSmartCollection: ClipCollection?
    @State private var inspectorCaptureEvents = [ClipCaptureEvent]()
    @State private var inspectorLinkResource: LinkResource?
    @State private var availableWidth: CGFloat = 0
    @State private var showingCompactInspector = false
    @State private var pendingAggregationDraft: AggregationDraft?

    private var accentColor: Color { state.settings.themeColor.accentColor }
    private var brandGradient: LinearGradient { state.settings.themeColor.gradient }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar.frame(width: 232)
                LibraryDivider(axis: .vertical)
                content.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                if geometry.size.width >= 1_050 {
                    LibraryDivider(axis: .vertical)
                    inspector.frame(width: 336).frame(maxHeight: .infinity).clipped()
                }
            }
            .background {
                LinearGradient(
                    colors: [LibraryTheme.canvasTop, accentColor.opacity(0.055)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                availableWidth = width
                if width >= 1_050 { showingCompactInspector = false }
            }
        }
        .frame(minWidth: embedded ? 663 : 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .pasteoryTheme(state.settings.themeColor, language: state.settings.appLanguage)
        .sheet(isPresented: $showingCompactInspector, onDismiss: {
            if let draft = pendingAggregationDraft {
                pendingAggregationDraft = nil
                state.libraryAggregationDraft = draft
            }
        }) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button(L10n.tr("完成")) { showingCompactInspector = false } }
                    .padding(12)
                inspector
            }
            .frame(width: 380, height: 620)
            .pasteoryTheme(state.settings.themeColor, language: state.settings.appLanguage)
        }
        .overlay(alignment: .bottom) {
            if let message = state.statusMessage {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 4, y: 2)
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showNewNormalCollection) { CollectionNameEditor(state: state, existing: nil) }
        .sheet(item: $editingNormalCollection) { CollectionNameEditor(state: state, existing: $0) }
        .sheet(item: $editingSmartCollection) { SmartCollectionEditor(state: state, existing: $0) }
        .sheet(isPresented: Binding(get: { state.intelligence.showingReview }, set: { state.intelligence.showingReview = $0 })) {
            AIReviewView(controller: state.intelligence)
        }
        .sheet(item: $state.libraryAggregationDraft) { draft in
            LibraryAggregationEditor(state: state, draft: draft) { state.libraryAggregationDraft = nil }
        }
        .task {
            await state.refreshCollections()
            await state.refreshLibrary()
            openRequestedCollectionEditor()
        }
        .onChange(of: state.requestedCollectionEditorID) { _, _ in openRequestedCollectionEditor() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !embedded {
            HStack(spacing: 10) {
                Image(nsImage: PasteoryBrand.appIconImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pasteory").font(.system(size: 15, weight: .semibold))
                    Text(L10n.tr("资料库")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    LibrarySectionLabel(title: L10n.tr("资料库"))
                    sidebarRow(L10n.tr("全部内容"), symbol: "square.stack", filter: .all)
                    sidebarRow(L10n.tr("收藏"), symbol: "star", filter: .favorite)
                    sidebarRow(L10n.tr("最近使用"), symbol: "clock", filter: .recent)
                    sidebarRow(L10n.tr("归档"), symbol: "archivebox", filter: .archived)
                    sidebarRow(L10n.tr("废纸篓"), symbol: "trash", filter: .trash)

                    LibrarySectionLabel(title: L10n.tr("内容类型")).padding(.top, 12)
                    ForEach(ClipKind.allCases, id: \.self) { kind in sidebarRow(kind.displayName, symbol: kind.symbolName, filter: .kind(kind)) }

                    LibrarySectionLabel(title: L10n.tr("普通分组")).padding(.top, 12)
                    ForEach(state.collections.filter { $0.kind == .normal && state.intelligence.state.groups[$0.id] == nil }) { collection in
                        collectionRow(collection)
                    }
                    addCollectionButton(L10n.tr("新建分组"), symbol: "folder.badge.plus") { showNewNormalCollection = true }

                    LibrarySectionLabel(title: L10n.tr("规则分组")).padding(.top, 12)
                    ForEach(state.collections.filter { $0.kind == .smart }) { collection in
                        collectionRow(collection)
                    }
                    addCollectionButton(L10n.tr("新建智能分组"), symbol: "sparkles") {
                        editingSmartCollection = ClipCollection(name: "", kind: .smart, sortOrder: state.collections.count, ruleSet: SmartRuleSet())
                    }
                    LibrarySectionLabel(title: L10n.tr("AI 分组")).padding(.top, 12)
                    ForEach(aiCollections(archived: false)) { collection in collectionRow(collection) }
                    if !aiCollections(archived: true).isEmpty {
                        DisclosureGroup(L10n.tr("归档的 AI 分组")) {
                            ForEach(aiCollections(archived: true)) { collection in collectionRow(collection) }
                        }.font(.caption).padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }

            LibraryDivider()
            HStack {
                if !embedded {
                Button(action: onOpenSettings) {
                    Label(L10n.tr("设置"), systemImage: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                }
                Spacer()
                Text(L10n.tr("\(state.clips.count) 条"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func sidebarRow(_ title: String, symbol: String, filter: ClipFilter) -> some View {
        let selected = state.libraryFilter == filter
        return Button {
            state.libraryFilter = filter
            Task { await state.refreshLibrary() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(brandGradient) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func collectionRow(_ collection: ClipCollection) -> some View {
        let filter = ClipFilter.collection(collection.id)
        let selected = state.libraryFilter == filter
        return Button {
            state.libraryFilter = filter
            Task { await state.refreshLibrary() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: state.intelligence.state.groups[collection.id] != nil ? "sparkle" : collection.kind == .smart ? "sparkles" : "folder")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(String(collection.name.prefix(40)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let group = state.intelligence.state.groups[collection.id] {
                    Text(L10n.text(state.intelligence.groupActivity(group).stage.title)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.55))
                    .help(L10n.tr("拖动调整顺序"))
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(brandGradient) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .draggable(collection.id.uuidString)
        .dropDestination(for: String.self) { identifiers, _ in
            guard let raw = identifiers.first,
                  let sourceID = UUID(uuidString: raw),
                  sourceID != collection.id,
                  state.collections.first(where: { $0.id == sourceID })?.kind == collection.kind else { return false }
            Task { await state.moveCollection(id: sourceID, before: collection.id) }
            return true
        }
        .contextMenu {
            if state.intelligence.state.groups[collection.id] != nil {
                Button(L10n.tr("编辑主题与描述…")) { editingNormalCollection = collection }
                Button(L10n.tr("按当前定义重新检查成员")) { state.intelligence.analyze(groupID: collection.id) }
                    .disabled(state.intelligence.running)
                Button(L10n.tr("压缩本组旧资料")) { Task { await state.intelligence.compress(groupID: collection.id) } }
                    .disabled(state.intelligence.running || state.intelligence.storageBusy)
            } else if collection.kind == .smart {
                Button(L10n.tr("编辑名称和规则…")) { editingSmartCollection = collection }
            } else {
                Button(L10n.tr("重命名…")) { editingNormalCollection = collection }
            }
            Divider()
            Button(L10n.tr("删除分组"), role: .destructive) { confirmDeleteCollection(collection) }
        }
    }

    private func aiCollections(archived: Bool) -> [ClipCollection] {
        state.collections.filter { collection in
            guard let group = state.intelligence.state.groups[collection.id] else { return false }
            return (state.intelligence.groupActivity(group).stage == .archived && !group.retained) == archived
        }.sorted { a, b in
            guard let lhs = state.intelligence.state.groups[a.id], let rhs = state.intelligence.state.groups[b.id] else { return a.sortOrder < b.sortOrder }
            if lhs.retained != rhs.retained { return lhs.retained }
            let ls = state.intelligence.groupActivity(lhs).score, rs = state.intelligence.groupActivity(rhs).score
            return ls == rs ? a.sortOrder < b.sortOrder : ls > rs
        }
    }

    private func addCollectionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(accentColor)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var aggregationShortcutHelp: String {
        guard let shortcut = state.settings.quickShortcut(for: .aggregateContent) else {
            return L10n.tr("聚合当前搜索结果")
        }
        return L10n.tr("聚合当前搜索结果（\(ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))）")
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(libraryTitle).font(.system(size: 22, weight: .bold))
                        Text(librarySubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if availableWidth < 1_050 {
                        Button { showingCompactInspector = true } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(L10n.tr("查看详情"))
                        .accessibilityLabel(L10n.tr("查看详情"))
                        .disabled(state.selectedClip == nil && state.selectedAggregation == nil)
                    }
                    QuickActionsToolbarMenu(state: state, clip: state.selectedClip)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .quickActionShortcut(state.settings.quickShortcut(for: .quickActions))
                    Menu {
                        Button(L10n.tr("分析最近内容")) { state.intelligence.analyze() }
                        Button(L10n.tr("检查整理建议")) { state.intelligence.showingReview = true }
                            .disabled(state.intelligence.pending == nil)
                        Button(L10n.tr("分批整理全库")) { state.intelligence.analyze(all: true) }
                        if state.intelligence.latestUndoable != nil {
                            Button(L10n.tr("撤销最近一次整理")) { Task { await state.intelligence.undo() } }
                        }
                    } label: { Label(L10n.tr("AI 整理"), systemImage: "sparkles") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(state.intelligence.running)
                    if !state.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            Task { state.libraryAggregationDraft = await state.makeLibraryAggregationDraft() }
                        } label: {
                            Label(L10n.tr("聚合结果"), systemImage: "square.stack.3d.up")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!state.libraryCanAggregateCurrentResults)
                        .help(aggregationShortcutHelp)
                        .quickActionShortcut(state.settings.quickShortcut(for: .aggregateContent))
                    }
                    Text(L10n.tr("\(state.libraryTopLevelResultCount) 个结果"))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(LibraryTheme.inputBackground, in: Capsule())
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.tr("搜索内容、备注、分组或来源"), text: $state.libraryQuery)
                        .textFieldStyle(.plain)
                        .onChange(of: state.libraryQuery) { _, _ in Task { await state.refreshLibrary(debounce: true) } }
                    if !state.libraryQuery.isEmpty {
                        Button {
                            state.libraryQuery = ""
                            Task { await state.refreshLibrary() }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)

            LibraryDivider()

            if state.libraryListEntries.isEmpty {
                LibraryEmptyState(query: state.libraryQuery)
            } else {
                clipList
            }
        }
    }

    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("library-list-top")
                LazyVStack(spacing: 9) {
                    ForEach(state.libraryListEntries) { entry in
                        switch entry.content {
                        case .aggregation(let aggregation):
                            LibraryAggregationCard(
                                state: state,
                                aggregation: aggregation,
                                selected: state.selectedAggregationID == aggregation.id,
                                onEdit: { state.libraryAggregationDraft = AggregationDraft(
                                    aggregationID: aggregation.id,
                                    memberClipIDs: aggregation.memberClipIDs,
                                    title: aggregation.title,
                                    note: aggregation.note,
                                    origin: aggregation.origin
                                ) }
                            )
                        case .clip(let clip, let parentID):
                            LibraryClipCard(
                                clip: clip,
                                attachments: state.attachments,
                                selected: state.selectedAggregationID == nil && state.selectedClipID == clip.id
                            )
                            .background(QuickActionMenuAnchor(controller: state.quickActionsMenu, clipID: clip.id, scope: .library))
                            .padding(.leading, parentID == nil ? 0 : 16)
                            .overlay(alignment: .leading) {
                                if parentID != nil {
                                    AggregationChildMarker(
                                        accentColor: state.settings.themeColor.accentColor,
                                        gap: 9,
                                        isFirst: entry.isFirstChild,
                                        isLast: entry.isLastChild
                                    )
                                    .frame(width: 16)
                                }
                            }
                            .onTapGesture { state.selectLibraryEntry(entry) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { onPaste(clip, false, true) })
                            .contextMenu { contextMenu(for: clip, parentAggregationID: parentID) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .onChange(of: state.libraryListResetID) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo("library-list-top", anchor: .top) }
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("library-list-top", anchor: .top) } }
        }
    }

    private var libraryTitle: String {
        switch state.libraryFilter {
        case .all: L10n.tr("全部内容")
        case .favorite: L10n.tr("收藏")
        case .recent: L10n.tr("最近使用")
        case .archived: L10n.tr("归档")
        case .trash: L10n.tr("废纸篓")
        case .kind(let kind): kind.displayName
        case .collection(let id): state.collections.first(where: { $0.id == id })?.name ?? L10n.tr("分组")
        }
    }

    private var librarySubtitle: String {
        if !state.libraryQuery.isEmpty { return L10n.tr("正在当前范围内搜索“\(String(state.libraryQuery.prefix(36)))”") }
        return switch state.libraryFilter {
        case .all: L10n.tr("保存过的文字、图片、链接、代码与文件")
        case .favorite: L10n.tr("你标记为收藏的内容")
        case .recent: L10n.tr("最近复制或使用过的内容")
        case .archived: L10n.tr("已从常用列表归档的内容")
        case .trash: L10n.tr("删除的内容会在这里保留 30 天")
        case .kind(let kind): L10n.tr("资料库中的\(kind.displayName)内容")
        case .collection(let id):
            state.collections.first(where: { $0.id == id })?.kind == .smart ? L10n.tr("按规则自动收集的内容") : L10n.tr("整理到这个分组的内容")
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let aggregation = state.selectedAggregation {
            LibraryAggregationInspector(
                state: state,
                aggregation: aggregation,
                onEdit: {
                    let draft = AggregationDraft(
                        aggregationID: aggregation.id,
                        memberClipIDs: aggregation.memberClipIDs,
                        title: aggregation.title,
                        note: aggregation.note,
                        origin: aggregation.origin
                    )
                    if showingCompactInspector {
                        pendingAggregationDraft = draft
                        showingCompactInspector = false
                    } else { state.libraryAggregationDraft = draft }
                }
            )
        } else if let clip = state.selectedClip {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("内容详情")).font(.system(size: 17, weight: .semibold))
                        Text(clip.codeMetadata?.displayName ?? clip.primaryKind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: clip.primaryKind.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 30, height: 30)
                        .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                LibraryDivider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        inspectorSection(L10n.tr("生命周期与 AI")) {
                            HStack {
                                let activity = state.settings.aiConfiguration.lifecycle.evaluate(clip.activity)
                                Text(L10n.text(activity.stage.title)).font(.caption.weight(.semibold))
                                Spacer()
                                Text(activity.score.formatted(.percent.precision(.fractionLength(0)))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Toggle(L10n.tr("禁止此内容参与 AI 分析"), isOn: Binding(get: { clip.aiAnalysisExcluded == true }, set: { value in
                                state.mutate(clip) { $0.aiAnalysisExcluded = value }
                            })).toggleStyle(.switch).font(.caption)
                        }
                        inspectorSection(L10n.tr("预览")) {
                            RepresentationPreview(clip: clip, attachments: state.attachments)
                                .frame(minHeight: 150, maxHeight: 240)
                                .padding(10)
                                .background(LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 10))
                        }

                        inspectorSection(L10n.tr("抓取来源")) {
                            captureSourceDetails(clip)
                        }

                        if clip.primaryKind == .link {
                            inspectorSection(L10n.tr("链接解析")) {
                                linkResolutionDetails
                            }
                        }

                        inspectorSection(L10n.tr("编辑")) {
                            inspectorFieldLabel(L10n.tr("标题"))
                            TextField(L10n.tr("添加一个便于查找的标题"), text: Binding(
                                get: { state.selectedClip?.title ?? "" },
                                set: { value in state.mutateSelected { $0.title = String(value.prefix(120)) } }
                            ))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))

                            if clip.source.bundleIdentifier == PasteoryRuntimeIdentity.current.bundleIdentifier {
                                inspectorFieldLabel(L10n.tr("正文")).padding(.top, 4)
                                TextEditor(text: Binding(
                                    get: { state.selectedClip?.previewText ?? "" },
                                    set: { state.updateManualText($0) }
                                ))
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(7)
                                .frame(minHeight: 100)
                                .background(LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))
                            }

                            inspectorFieldLabel(L10n.tr("备注")).padding(.top, 4)
                            TextEditor(text: Binding(
                                get: { state.selectedClip?.note ?? "" },
                                set: { value in state.mutateSelected { $0.note = String(value.prefix(4_000)) } }
                            ))
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(7)
                            .frame(minHeight: 76)
                            .background(LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))

                            inspectorFieldLabel(L10n.tr("优先级")).padding(.top, 4)
                            Picker(L10n.tr("优先级"), selection: Binding(
                                get: { state.selectedClip?.priority ?? 0 },
                                set: { value in state.mutateSelected { $0.priority = value } }
                            )) {
                                Text(L10n.tr("无")).tag(0)
                                Text("P1").tag(1)
                                Text("P2").tag(2)
                                Text("P3").tag(3)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)

                            HStack(spacing: 8) {
                                inspectorToggle(
                                    title: L10n.tr("收藏"),
                                    symbol: clip.isFavorite ? "star.fill" : "star",
                                    active: clip.isFavorite
                                ) { state.mutateSelected { $0.isFavorite.toggle() } }
                                inspectorToggle(
                                    title: L10n.tr("置顶"),
                                    symbol: clip.isPinned ? "pin.fill" : "pin",
                                    active: clip.isPinned
                                ) { state.mutateSelected { $0.isPinned.toggle() } }
                            }
                            .padding(.top, 4)
                        }

                        if !state.collections.filter({ $0.kind == .normal }).isEmpty {
                            inspectorSection(L10n.tr("分组")) {
                                ForEach(state.collections.filter { $0.kind == .normal }) { collection in
                                    let selected = state.selectedClip?.collectionIDs.contains(collection.id) ?? false
                                    Button {
                                        state.mutateSelected {
                                            if selected { $0.collectionIDs.remove(collection.id) }
                                            else { $0.collectionIDs.insert(collection.id) }
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selected ? accentColor : Color.secondary)
                                            Text(collection.name).lineLimit(1)
                                            Spacer()
                                        }
                                        .font(.system(size: 13))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        inspectorSection(L10n.tr("信息")) { metadata(clip) }

                        HStack(spacing: 8) {
                            Button(L10n.tr("粘贴")) { onPaste(clip, false, true) }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: [])
                            Button(L10n.tr("复制")) { onPaste(clip, false, false) }.buttonStyle(.bordered)
                            Spacer()
                            if clip.deletedAt != nil {
                                Button(L10n.tr("恢复")) { state.restore(clip) }.buttonStyle(.bordered)
                            } else {
                                Button(L10n.tr("删除"), role: .destructive) { state.moveToTrash(clip) }.buttonStyle(.bordered)
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(14)
                }
            }
            .task(id: clip.id) {
                inspectorCaptureEvents = []
                inspectorLinkResource = nil
                async let captureEvents = state.captureEvents(for: clip)
                async let linkResource = state.linkResource(for: clip)
                inspectorCaptureEvents = await captureEvents
                inspectorLinkResource = await linkResource
            }
        } else {
            LibraryEmptyInspector()
        }
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LibraryTheme.cardBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.separator.opacity(0.35), lineWidth: 1))
    }

    private func inspectorFieldLabel(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
    }

    private func inspectorToggle(title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(active ? accentColor.opacity(0.13) : LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func metadata(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataRow(L10n.tr("类型"), value: clip.primaryKind.displayName)
            if let code = clip.codeMetadata {
                metadataRow(L10n.tr("代码类型"), value: code.subtype.displayName)
                if let language = code.language { metadataRow(L10n.tr("语言"), value: language.displayName) }
                if let lineCount = code.totalLineCount { metadataRow(L10n.tr("代码行数"), value: L10n.tr("\(lineCount) 行")) }
                metadataRow(L10n.tr("识别置信度"), value: "\(Int((code.confidence * 100).rounded()))%")
                if code.wasTruncatedForClassification {
                    metadataRow(L10n.tr("分析范围"), value: L10n.tr("前 \(code.analyzedCharacterCount) 个字符"))
                }
            }
            metadataRow(L10n.tr("来源"), value: clip.source.appName)
            metadataRow(L10n.tr("来源可信度"), value: clip.source.confidence.displayName)
            metadataRow(L10n.tr("创建时间"), value: clip.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.language.locale)))
            metadataRow(L10n.tr("复制次数"), value: L10n.tr("\(clip.copyCount) 次"))
            metadataRow(L10n.tr("粘贴次数"), value: L10n.tr("\(clip.recordedPasteCount) 次"))
            metadataRow(L10n.tr("大小"), value: ByteCountFormatter.string(fromByteCount: Int64(clip.byteSize), countStyle: .file))
            metadataRow(L10n.tr("格式"), value: Array(Set(clip.items.flatMap { $0.representations.map(\.uti) })).sorted().joined(separator: "、"))
        }
    }

    @ViewBuilder
    private func captureSourceDetails(_ clip: Clip) -> some View {
        if inspectorCaptureEvents.isEmpty {
            metadataRow(L10n.tr("应用"), value: clip.source.appName)
            metadataRow(L10n.tr("可信度"), value: clip.source.confidence.displayName)
            Text(L10n.tr("这条内容只保存了来源应用，没有单独的复制上下文。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(inspectorCaptureEvents.prefix(5).enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    metadataRow(L10n.tr("应用"), value: event.source.appName)
                    metadataRow(L10n.tr("采集时间"), value: event.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.language.locale)))
                    if let context = event.context {
                        metadataRow(L10n.tr("摘要"), value: context.summary)
                        sourceContextRow(L10n.tr("网页链接"), value: context.payload["url"])
                        sourceContextRow(L10n.tr("页面标题"), value: context.payload["pageTitle"])
                        sourceContextRow(L10n.tr("对话类型"), value: context.payload["conversationTypeName"])
                        sourceContextRow(L10n.tr("对话标题"), value: context.payload["conversationName"])
                        sourceContextRow(L10n.tr("仓库"), value: context.payload["repository"])
                        sourceContextRow(L10n.tr("分支"), value: context.payload["branch"])
                        sourceContextRow(L10n.tr("目标分支"), value: context.payload["targetBranch"])
                        sourceContextRow(L10n.tr("选中内容"), value: context.payload["selectedText"])
                        sourceContextRow(L10n.tr("关联文字"), value: context.payload["relatedText"])
                        sourceContextRow(L10n.tr("元素"), value: context.payload["elementSelector"])
                    } else {
                        Text(L10n.tr("本次复制没有获取到更详细的上下文。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if inspectorCaptureEvents.count > 5 {
                Text(L10n.tr("另有 \(inspectorCaptureEvents.count - 5) 次复制记录"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var linkResolutionDetails: some View {
        if let resource = inspectorLinkResource {
            metadataRow(L10n.tr("状态"), value: resource.requestState.displayName)
            if let title = resource.resolvedTitle {
                metadataRow(L10n.tr("解析标题"), value: title)
            } else if let candidate = resource.candidateTitle {
                metadataRow(L10n.tr("候选标题"), value: candidate)
            }
            metadataRow(L10n.tr("兜底标题"), value: resource.fallbackTitle)
            metadataRow(L10n.tr("标题质量"), value: resource.titleQuality.displayName)
            metadataRow(L10n.tr("解析来源"), value: resource.resolutionSource?.displayName ?? L10n.tr("尚未解析"))
            metadataRow(L10n.tr("链接"), value: URLFallbackEngine.redactedDisplayURL(resource.normalizedURL))
            metadataRow(L10n.tr("尝试次数"), value: L10n.tr("\(resource.attemptCount) 次，失败 \(resource.failedAttemptCount) 次"))
            if let lastAttemptAt = resource.lastAttemptAt {
                metadataRow(L10n.tr("最近解析"), value: lastAttemptAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.language.locale)))
            }
        } else {
            Text(L10n.tr("这条链接尚未建立解析记录。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sourceContextRow(_ label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            metadataRow(label, value: value)
        }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.tertiary).frame(width: 68, alignment: .leading)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func contextMenu(for clip: Clip, parentAggregationID: UUID?) -> some View {
        Button(L10n.tr("粘贴")) { onPaste(clip, false, true) }; Button(L10n.tr("复制")) { onPaste(clip, false, false) }
        QuickActionsMenu { action in
            state.runQuickTextAction(action, for: clip)
        }
        Button(L10n.tr("纯文本粘贴")) { onPaste(clip, true, true) }; Divider()
        Button(clip.isFavorite ? L10n.tr("取消收藏") : L10n.tr("收藏")) { state.toggleFavorite(clip) }
        if let parentAggregationID,
           let aggregation = state.aggregations.first(where: { $0.id == parentAggregationID }) {
            Button(L10n.tr("移出当前聚合")) {
                Task { await state.removeClip(clip.id, from: aggregation) }
            }
            Divider()
        }
        if clip.deletedAt != nil {
            Button(L10n.tr("恢复")) { state.restore(clip) }
            Button(L10n.tr("彻底删除"), role: .destructive) { confirmPermanentDelete(clip) }
        } else { Button(L10n.tr("移到废纸篓"), role: .destructive) { state.moveToTrash(clip) } }
    }

    private func confirmPermanentDelete(_ clip: Clip) {
        let alert = NSAlert(); alert.messageText = L10n.tr("彻底删除这条内容？"); alert.informativeText = L10n.tr("此操作无法撤销。"); alert.addButton(withTitle: L10n.tr("删除")); alert.addButton(withTitle: L10n.tr("取消"))
        if alert.runModal() == .alertFirstButtonReturn { Task { await state.permanentlyDelete(clip) } }
    }

    private func confirmDeleteCollection(_ collection: ClipCollection) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("删除“\(collection.name)”？")
        alert.informativeText = collection.kind == .smart ? L10n.tr("智能规则会一并删除，剪贴板内容不会被删除。") : L10n.tr("内容只会移出这个分组，不会从资料库删除。")
        alert.addButton(withTitle: L10n.tr("删除"))
        alert.addButton(withTitle: L10n.tr("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await state.deleteCollection(collection) }
    }

    private func openRequestedCollectionEditor() {
        guard let id = state.requestedCollectionEditorID,
              let collection = state.collections.first(where: { $0.id == id }) else { return }
        state.requestedCollectionEditorID = nil
        if collection.kind == .smart { editingSmartCollection = collection }
        else { editingNormalCollection = collection }
    }
}

private struct LibraryAggregationCard: View {
    @ObservedObject var state: AppState
    let aggregation: ClipAggregation
    let selected: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(state.settings.themeColor.accentColor)
                .frame(width: 46, height: 46)
                .background(state.settings.themeColor.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(aggregation.displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if !aggregation.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(aggregation.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(aggregation.origin.displayName + (aggregation.membershipMode == .automatic ? L10n.tr(" · 自动更新") : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                state.toggleLibraryAggregation(aggregation.id)
            } label: {
                HStack(spacing: 4) {
                    Text(memberCountLabel)
                    Image(systemName: state.libraryExpandedAggregationIDs.contains(aggregation.id) ? "chevron.up" : "chevron.down")
                }
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.settings.themeColor.accentColor)
        }
        .padding(.horizontal, 12)
        .frame(height: 88)
        .background(
            aggregation.isPinned ? state.settings.themeColor.accentColor.opacity(0.10) : LibraryTheme.cardBackground,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? state.settings.themeColor.accentColor : LibraryTheme.divider, lineWidth: selected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            state.selectedAggregationID = aggregation.id
            state.selectedClipID = nil
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { state.toggleLibraryAggregation(aggregation.id, selectChild: true) })
        .contextMenu {
            Button(state.libraryExpandedAggregationIDs.contains(aggregation.id) ? L10n.tr("收起内容") : L10n.tr("展开内容")) {
                state.toggleLibraryAggregation(aggregation.id)
            }
            .quickActionShortcut(state.settings.quickShortcut(
                for: state.libraryExpandedAggregationIDs.contains(aggregation.id) ? .collapseAggregation : .expandAggregation
            ))
            Button(L10n.tr("编辑聚合…"), action: onEdit)
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
        let query = state.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return L10n.tr("\(aggregation.memberClipIDs.count) 项内容") }
        let visible = Set(state.clips.map(\.id)).intersection(aggregation.memberClipIDs).count
        guard visible > 0, visible < aggregation.memberClipIDs.count else {
            return L10n.tr("\(aggregation.memberClipIDs.count) 项内容")
        }
        return L10n.tr("匹配 \(visible) / \(aggregation.memberClipIDs.count)")
    }
}

private struct LibraryAggregationInspector: View {
    @ObservedObject var state: AppState
    let aggregation: ClipAggregation
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("聚合详情")).font(.system(size: 17, weight: .semibold))
                    Text(L10n.tr("\(aggregation.memberClipIDs.count) 项内容")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(state.settings.themeColor.accentColor)
            }
            .padding(16)
            LibraryDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let summary = state.intelligence.state.summaries[aggregation.id] {
                        AISummaryCard(summary: summary, controller: state.intelligence) { id in
                            Task {
                                state.libraryFilter = state.intelligence.clipIndex[id]?.isArchived == true ? .archived : .all
                                state.libraryQuery = ""; await state.refreshLibrary()
                                state.selectedAggregationID = nil; state.selectedClipID = id
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(aggregation.displayTitle).font(.headline)
                        if !aggregation.note.isEmpty { Text(aggregation.note).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.tr("生成方式")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(aggregation.origin.displayName)
                        Text(aggregation.membershipMode == .automatic ? L10n.tr("成员会按条件自动更新") : L10n.tr("成员保持创建时的内容"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("包含内容")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(state.aggregationMembers[aggregation.id] ?? []) { clip in
                            HStack(spacing: 7) {
                                Image(systemName: clip.primaryKind.symbolName).foregroundStyle(state.settings.themeColor.accentColor)
                                Text(clip.displayTitle.isEmpty ? clip.previewText : clip.displayTitle).lineLimit(1)
                            }
                            .font(.caption)
                        }
                    }
                    Button(L10n.tr("编辑聚合信息和成员…"), action: onEdit)
                        .buttonStyle(.borderedProminent)
                        .tint(state.settings.themeColor.accentColor)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    HStack(spacing: 8) {
                        Button(aggregation.isFavorite ? L10n.tr("取消收藏聚合") : L10n.tr("收藏聚合")) {
                            Task { await state.toggleAggregationFavorite(aggregation) }
                        }
                        Button(aggregation.isPinned ? L10n.tr("取消置顶聚合") : L10n.tr("置顶聚合")) {
                            Task { await state.toggleAggregationPinned(aggregation) }
                        }
                        Spacer()
                        Menu(L10n.tr("整理全部成员")) {
                            let members = state.aggregationMembers[aggregation.id] ?? []
                            Button(members.allSatisfy(\.isFavorite) ? L10n.tr("取消收藏全部成员") : L10n.tr("收藏全部成员")) {
                                Task { await state.toggleFavoriteForAllMembers(of: aggregation) }
                            }
                            Button(members.allSatisfy(\.isPinned) ? L10n.tr("取消置顶全部成员") : L10n.tr("置顶全部成员")) {
                                Task { await state.togglePinnedForAllMembers(of: aggregation) }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
            }
        }
    }
}

private struct LibraryAggregationEditor: View {
    @ObservedObject var state: AppState
    let original: AggregationDraft
    let onDone: () -> Void
    @State private var title: String
    @State private var note: String
    @State private var memberIDs: [UUID]

    init(state: AppState, draft: AggregationDraft, onDone: @escaping () -> Void) {
        self.state = state
        self.original = draft
        self.onDone = onDone
        _title = State(initialValue: draft.title)
        _note = State(initialValue: draft.note)
        _memberIDs = State(initialValue: draft.memberClipIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original.isEditing ? L10n.tr("编辑聚合") : L10n.tr("聚合搜索结果")).font(.title3.bold())
            Text(L10n.tr("包含 \(memberIDs.count) 项不同内容 · \(original.origin.displayName)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(L10n.tr("聚合标题"), text: $title).textFieldStyle(.roundedBorder)
            TextField(L10n.tr("备注（可选）"), text: $note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(memberClips) { clip in
                        HStack(spacing: 8) {
                            Image(systemName: clip.primaryKind.symbolName)
                                .foregroundStyle(state.settings.themeColor.accentColor)
                                .frame(width: 20)
                            Text(clip.displayTitle.isEmpty ? clip.previewText : clip.displayTitle).lineLimit(1)
                            Spacer()
                            Button {
                                memberIDs.removeAll { $0 == clip.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .disabled(memberIDs.count <= 2)
                                .help(L10n.tr("移出聚合，保留原内容"))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 220)
            HStack {
                Spacer()
                Button(L10n.tr("取消"), action: onDone)
                Button(original.isEditing ? L10n.tr("保存") : L10n.tr("创建聚合")) {
                    var draft = original
                    draft.memberClipIDs = memberIDs
                    Task {
                        if await state.saveLibraryAggregation(draft, title: title, note: note) { onDone() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(state.settings.themeColor.accentColor)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberIDs.count < 2)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 470)
    }

    private var memberClips: [Clip] {
        let all = state.clips + state.quickClips + state.aggregationMembers.values.flatMap { $0 }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return memberIDs.compactMap { byID[$0] }
    }
}

private struct LibraryClipCard: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
    let clip: Clip
    let attachments: AttachmentStore
    let selected: Bool

    var body: some View {
        ClipRowView(clip: clip, attachments: attachments)
            .padding(.horizontal, 12)
            .frame(height: ClipRowMetrics.height(for: clip, compact: false))
            .background(
                clip.isPinned ? pasteoryAccentColor.opacity(0.10) : LibraryTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? pasteoryAccentColor : LibraryTheme.divider, lineWidth: selected ? 2 : 1)
            }
            .shadow(color: .black.opacity(selected ? 0.09 : 0.04), radius: selected ? 8 : 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LibrarySectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.bottom, 3)
    }
}

private struct LibraryEmptyState: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
    let query: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(pasteoryAccentColor)
                .frame(width: 58, height: 58)
                .background(pasteoryAccentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 18))
            Text(query.isEmpty ? L10n.tr("这里还没有内容") : L10n.tr("没有找到匹配内容"))
                .font(.system(size: 16, weight: .semibold))
            Text(query.isEmpty ? L10n.tr("复制新的内容后，它会自动出现在资料库。") : L10n.tr("可以换个关键词，或选择其他资料范围。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LibraryEmptyInspector: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.tr("选择一条内容")).font(.system(size: 15, weight: .semibold))
            Text(L10n.tr("预览、备注和分组会显示在这里。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct LibraryDivider: View {
    var axis: Axis = .horizontal

    @ViewBuilder
    var body: some View {
        if axis == .vertical {
            Rectangle().fill(LibraryTheme.divider).frame(width: 1)
        } else {
            Rectangle().fill(LibraryTheme.divider).frame(height: 1)
        }
    }
}

private enum LibraryTheme {
    static let canvasTop = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.90)
    static let inputBackground = Color(nsColor: .textBackgroundColor).opacity(0.82)
    static let divider = Color(nsColor: .separatorColor).opacity(0.55)
}

struct CollectionNameEditor: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let existing: ClipCollection?
    @State private var name: String
    @State private var definition: String
    @State private var retained: Bool
    private let definitionVersion: Int?
    @State private var error: String?

    init(state: AppState, existing: ClipCollection?) {
        self.state = state
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        let profile = existing.flatMap { state.intelligence.state.groups[$0.id] }
        definitionVersion = profile?.definitionVersion
        _definition = State(initialValue: profile?.definition ?? "")
        _retained = State(initialValue: profile?.retained ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? L10n.tr("新建分组") : L10n.tr("重命名分组")).font(.title2.bold())
            VStack(alignment: .leading, spacing: 5) {
                TextField(L10n.tr("分组名称"), text: Binding(get: { name }, set: { name = String($0.prefix(40)) }))
                Text("\(name.count)/40").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let existing, let profile = state.intelligence.state.groups[existing.id] {
                Text(L10n.tr("主题定义")).font(.caption.weight(.semibold))
                TextEditor(text: $definition).frame(height: 110).padding(5)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.2)))
                Text(L10n.tr("用户编辑的定义优先，AI 只维护成员和独立的内容概况。")).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.tr("保留此分组"), isOn: $retained).toggleStyle(.switch)
                if !profile.overview.isEmpty {
                    Text(L10n.tr("当前内容概况")).font(.caption.weight(.semibold))
                    Text(profile.overview).font(.caption).textSelection(.enabled)
                    if profile.overviewIsStale { Text(L10n.tr("概况仅覆盖部分资料或需要更新")).font(.caption2).foregroundStyle(.orange) }
                }
                HStack { Spacer(); Button(L10n.tr("保存并重新检查成员")) { save(recheck: true) } }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }
                Button(existing == nil ? L10n.tr("创建") : L10n.tr("保存")) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onChange(of: name) { _, _ in error = nil }
    }

    private func save(recheck: Bool = false) {
        if let message = state.collectionNameValidationMessage(name, excluding: existing?.id) { error = message; return }
        Task {
            let succeeded: Bool
            if let existing, let expectedVersion = definitionVersion {
                succeeded = await state.intelligence.saveGroup(id: existing.id, name: name, definition: definition,
                                                              retained: retained, expectedVersion: expectedVersion)
                if succeeded && recheck { state.intelligence.analyze(groupID: existing.id) }
            } else if var existing {
                existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                succeeded = await state.saveCollection(existing)
            } else {
                succeeded = await state.addCollection(name: name, smart: false) != nil
            }
            if succeeded { dismiss() }
            else { error = state.intelligence.error ?? state.statusMessage }
        }
    }
}

struct SmartCollectionEditor: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let existing: ClipCollection
    @State private var name: String
    @State private var rootGroup: SmartRuleGroup
    @State private var error: String?
    @State private var candidates: [Clip] = []
    @State private var candidateRevision = 0
    @State private var isLoadingCandidates = true
    @State private var previewItems: [Clip] = []
    @State private var previewCount = 0
    @State private var previewError: String?

    init(state: AppState, existing: ClipCollection) {
        self.state = state; self.existing = existing
        _name = State(initialValue: existing.name)
        var saved = existing.ruleSet?.rootGroup ?? SmartRuleGroup()
        if saved.conditions.isEmpty && saved.groups.isEmpty {
            saved.conditions = [SmartCondition(field: .body, operation: .contains, value: "")]
        }
        _rootGroup = State(initialValue: Self.normalized(saved))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing.name.isEmpty ? L10n.tr("新建智能分组") : L10n.tr("编辑智能分组")).font(.title2.bold())
            VStack(alignment: .leading, spacing: 5) {
                TextField(L10n.tr("分组名称"), text: Binding(get: { name }, set: { name = String($0.prefix(40)) }))
                Text("\(name.count)/40").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            GroupBox {
                ScrollView {
                    SmartRuleGroupEditor(
                        group: $rootGroup,
                        sourceOptions: sourceOptions,
                        depth: 1,
                        isRoot: true,
                        canAddCondition: totalConditionCount < SmartRuleEngine.maximumConditionCount,
                        onRemove: nil
                    )
                    .padding(.vertical, 4)
                }
            } label: {
                Label(L10n.tr("匹配条件"), systemImage: "slider.horizontal.3")
            }
            .frame(minHeight: 220, maxHeight: 320)
            GroupBox {
                if isLoadingCandidates {
                    ProgressView(L10n.tr("正在读取资料库…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let previewError {
                    ContentUnavailableView(
                        L10n.tr("暂时无法预览"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(previewError)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if previewItems.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("没有匹配内容"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(L10n.tr("调整上方条件后，结果会自动更新"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(previewItems) { clip in
                                SmartRulePreviewRow(clip: clip)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } label: {
                HStack {
                    Label(L10n.tr("匹配预览"), systemImage: "eye")
                    Spacer()
                    Text(L10n.tr("\(previewCount) 条"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 250, maxHeight: .infinity)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button(L10n.tr("取消")) { dismiss() }; Button(existing.name.isEmpty ? L10n.tr("创建") : L10n.tr("保存")) { save() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(minWidth: 820, minHeight: 720)
        .task {
            candidates = await state.smartRuleCandidates()
            isLoadingCandidates = false
            candidateRevision += 1
        }
        .task(id: SmartPreviewRequest(group: rootGroup, candidateRevision: candidateRevision)) {
            await refreshPreview()
        }
        .onChange(of: name) { _, _ in error = nil }
        .onChange(of: rootGroup) { _, _ in error = nil }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = state.collectionNameValidationMessage(trimmed, excluding: existing.name.isEmpty ? nil : existing.id) { error = message; return }
        let rules = ruleSet
        do { try SmartRuleEngine().validate(rules) }
        catch { self.error = error.localizedDescription; return }
        var collection = existing
        collection.name = trimmed; collection.kind = .smart; collection.ruleSet = rules
        Task {
            if await state.saveCollection(collection) { dismiss() }
            else { error = state.statusMessage }
        }
    }

    private var ruleSet: SmartRuleSet {
        SmartRuleSet(mode: rootGroup.mode, conditions: rootGroup.conditions, groups: rootGroup.groups)
    }

    private var totalConditionCount: Int {
        conditionCount(in: rootGroup)
    }

    private func conditionCount(in group: SmartRuleGroup) -> Int {
        group.conditions.count + group.groups.reduce(0) { $0 + conditionCount(in: $1) }
    }

    @MainActor
    private func refreshPreview() async {
        guard candidateRevision > 0 else { return }
        do {
            try await Task.sleep(for: .milliseconds(120))
            let candidateSnapshot = candidates
            let ruleSnapshot = ruleSet
            let result = try await Task.detached(priority: .userInitiated) {
                try SmartRuleEngine().preview(candidateSnapshot, ruleSet: ruleSnapshot)
            }.value
            guard !Task.isCancelled else { return }
            previewItems = result.items
            previewCount = result.count
            previewError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            previewItems = []
            previewCount = 0
            previewError = error.localizedDescription
        }
    }

    private var sourceOptions: [ApplicationReference] {
        var values = [String: ApplicationReference]()
        for clip in candidates {
            guard let bundleIdentifier = clip.source.bundleIdentifier, !bundleIdentifier.isEmpty else { continue }
            values[bundleIdentifier] = ApplicationReference(
                bundleIdentifier: bundleIdentifier,
                name: clip.source.appName,
                url: nil
            )
        }
        for condition in allConditions(in: rootGroup) where condition.field == .sourceApp && !condition.value.isEmpty {
            if values[condition.value] == nil {
                values[condition.value] = ApplicationReference(
                    bundleIdentifier: condition.value,
                    name: condition.value,
                    url: nil
                )
            }
        }
        return values.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func allConditions(in group: SmartRuleGroup) -> [SmartCondition] {
        group.conditions + group.groups.flatMap(allConditions)
    }

    private static func normalized(_ group: SmartRuleGroup) -> SmartRuleGroup {
        SmartRuleGroup(
            id: group.id,
            mode: group.mode,
            conditions: group.conditions.map(normalized),
            groups: group.groups.map(normalized)
        )
    }

    private static func normalized(_ condition: SmartCondition) -> SmartCondition {
        guard !condition.field.supportedOperators.contains(condition.operation) else { return condition }
        var value = condition
        value.operation = condition.field.supportedOperators[0]
        value.value = condition.field.defaultValue
        return value
    }
}

private struct SmartPreviewRequest: Hashable {
    let group: SmartRuleGroup
    let candidateRevision: Int
}

private struct SmartRulePreviewRow: View {
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !title.isEmpty, title != content.trimmingCharacters(in: .whitespacesAndNewlines) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            Text(hasContent ? content : L10n.tr("（没有可预览的文本）"))
                .font(.caption)
                .foregroundStyle(hasContent ? .secondary : .tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
    }

    private var title: String {
        clip.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var content: String {
        clip.previewText
    }

    private var hasContent: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct SmartRuleGroupEditor: View {
    @Binding var group: SmartRuleGroup
    let sourceOptions: [ApplicationReference]
    let depth: Int
    let isRoot: Bool
    let canAddCondition: Bool
    let onRemove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(isRoot ? L10n.tr("主规则组") : L10n.tr("子规则组"), systemImage: isRoot ? "point.3.connected.trianglepath.dotted" : "arrow.turn.down.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker(L10n.tr("组内关系"), selection: $group.mode) {
                    Text(L10n.tr("满足全部")).tag(RuleMatchMode.all)
                    Text(L10n.tr("满足任一")).tag(RuleMatchMode.any)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 176)
                if let onRemove {
                    Button(action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L10n.tr("删除这个规则组"))
                }
            }

            Text(group.mode == .all ? L10n.tr("下面每一项都要满足") : L10n.tr("下面任意一项满足即可"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach($group.conditions) { $condition in
                SmartConditionRow(condition: $condition, sourceOptions: sourceOptions) {
                    group.conditions.removeAll { $0.id == condition.id }
                }
            }

            ForEach($group.groups) { $child in
                AnyView(
                    SmartRuleGroupEditor(
                        group: $child,
                        sourceOptions: sourceOptions,
                        depth: depth + 1,
                        isRoot: false,
                        canAddCondition: canAddCondition,
                        onRemove: { group.groups.removeAll { $0.id == child.id } }
                    )
                )
            }

            HStack(spacing: 8) {
                Spacer()
                Button {
                    group.conditions.append(SmartCondition(field: .body, operation: .contains, value: ""))
                } label: {
                    Label(L10n.tr("添加条件"), systemImage: "plus")
                }
                .disabled(!canAddCondition)

                Button {
                    group.groups.append(SmartRuleGroup(
                        mode: .all,
                        conditions: [SmartCondition(field: .body, operation: .contains, value: "")]
                    ))
                } label: {
                    Label(L10n.tr("添加子组"), systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(!canAddCondition || depth >= SmartRuleEngine.maximumNestingDepth)
                .help(depth >= SmartRuleEngine.maximumNestingDepth ? L10n.tr("最多可以嵌套 5 层") : L10n.tr("添加一个可独立设置且／或关系的规则组"))
            }
            .controlSize(.small)
        }
        .padding(isRoot ? 4 : 12)
        .background {
            if !isRoot {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.045))
            }
        }
        .overlay {
            if !isRoot {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
            }
        }
        .padding(.leading, isRoot ? 0 : 12)
    }
}

private struct SmartConditionRow: View {
    @Binding var condition: SmartCondition
    let sourceOptions: [ApplicationReference]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker(L10n.tr("字段"), selection: $condition.field) {
                ForEach(SmartRuleField.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 112)
            .onChange(of: condition.field) { _, field in
                condition.operation = field.supportedOperators[0]
                condition.value = field == .sourceApp ? (sourceOptions.first?.bundleIdentifier ?? "") : field.defaultValue
            }

            Picker(L10n.tr("条件"), selection: $condition.operation) {
                ForEach(condition.field.supportedOperators, id: \.self) { operation in
                    Text(operation.displayName(for: condition.field)).tag(operation)
                }
            }
            .labelsHidden()
            .frame(width: 112)

            valueEditor.frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .help(L10n.tr("删除条件"))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch condition.field {
        case .title, .body, .note:
            TextField(condition.operation == .matchesRegex ? L10n.tr("输入正则表达式") : L10n.tr("输入匹配文字"), text: limitedValue(maxLength: 512))
                .textFieldStyle(.roundedBorder)
        case .sourceApp:
            ApplicationSelectionControl(bundleIdentifier: $condition.value, additionalApplications: sourceOptions)
        case .sourceConfidence:
            Picker(L10n.tr("来源可信度"), selection: $condition.value) {
                Text(L10n.tr("高")).tag(SourceConfidence.high.rawValue)
                Text(L10n.tr("低")).tag(SourceConfidence.low.rawValue)
                Text(L10n.tr("未知")).tag(SourceConfidence.unknown.rawValue)
            }
            .labelsHidden()
        case .kind:
            Picker(L10n.tr("内容类型"), selection: $condition.value) {
                ForEach(ClipKind.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden()
        case .favorite:
            Picker(L10n.tr("收藏状态"), selection: $condition.value) {
                Text(L10n.tr("已收藏")).tag("true")
                Text(L10n.tr("未收藏")).tag("false")
            }
            .labelsHidden()
        case .quickTextAction:
            Picker(L10n.tr("快捷工具转换"), selection: $condition.value) {
                Text(L10n.tr("任意快捷工具")).tag("any")
                ForEach(QuickTextAction.allCases) { action in Text(action.title).tag(action.rawValue) }
                Text(L10n.tr("未使用快捷工具")).tag("none")
            }
            .labelsHidden()
        case .priority:
            Picker(L10n.tr("优先级"), selection: $condition.value) {
                Text(L10n.tr("无")).tag("0")
                Text("P1").tag("1")
                Text("P2").tag("2")
                Text("P3").tag("3")
            }
            .labelsHidden()
        case .createdAt:
            HStack(spacing: 6) {
                TextField(L10n.tr("天数"), text: limitedValue(maxLength: 6)).textFieldStyle(.roundedBorder).frame(width: 90)
                Text(L10n.tr("天")).foregroundStyle(.secondary)
            }
        case .byteSize:
            HStack(spacing: 6) {
                TextField(L10n.tr("字节数"), text: limitedValue(maxLength: 14)).textFieldStyle(.roundedBorder).frame(width: 120)
                Text(L10n.tr("字节")).foregroundStyle(.secondary)
            }
        case .copyCount:
            HStack(spacing: 6) {
                TextField(L10n.tr("次数"), text: limitedValue(maxLength: 9)).textFieldStyle(.roundedBorder).frame(width: 100)
                Text(L10n.tr("次")).foregroundStyle(.secondary)
            }
        }
    }

    private func limitedValue(maxLength: Int) -> Binding<String> {
        Binding(get: { condition.value }, set: { condition.value = String($0.prefix(maxLength)) })
    }
}

private extension SmartRuleField {
    var displayName: String {
        switch self {
        case .sourceApp: L10n.tr("来源")
        case .sourceConfidence: L10n.tr("来源可信度")
        case .createdAt: L10n.tr("时间")
        case .kind: L10n.tr("类型")
        case .title: L10n.tr("标题")
        case .body: L10n.tr("正文")
        case .note: L10n.tr("备注")
        case .byteSize: L10n.tr("大小")
        case .priority: L10n.tr("优先级")
        case .favorite: L10n.tr("收藏")
        case .copyCount: L10n.tr("复制次数")
        case .quickTextAction: L10n.tr("快捷工具转换")
        }
    }
}

private extension SmartRuleOperator {
    func displayName(for field: SmartRuleField) -> String {
        switch self {
        case .contains: L10n.tr("包含")
        case .equals: [.sourceApp, .sourceConfidence, .kind, .priority, .favorite, .quickTextAction].contains(field) ? L10n.tr("是") : L10n.tr("等于")
        case .matchesRegex: L10n.tr("匹配正则")
        case .before: L10n.tr("距今超过")
        case .after: L10n.tr("距今以内")
        case .greaterThan: L10n.tr("大于")
        case .lessThan: L10n.tr("小于")
        }
    }
}
