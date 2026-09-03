import AppKit
import PasteoryCore
import SwiftUI

struct LibraryView: View {
    @ObservedObject var state: AppState
    let onPaste: (Clip, Bool, Bool) -> Void
    let onOpenSettings: () -> Void
    @State private var showNewNormalCollection = false
    @State private var editingNormalCollection: ClipCollection?
    @State private var editingSmartCollection: ClipCollection?
    @State private var inspectorCaptureEvents = [ClipCaptureEvent]()
    @State private var inspectorLinkResource: LinkResource?

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
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .pasteoryTheme(state.settings.themeColor)
        .sheet(isPresented: $showNewNormalCollection) { CollectionNameEditor(state: state, existing: nil) }
        .sheet(item: $editingNormalCollection) { CollectionNameEditor(state: state, existing: $0) }
        .sheet(item: $editingSmartCollection) { SmartCollectionEditor(state: state, existing: $0) }
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
            HStack(spacing: 10) {
                Image(nsImage: PasteoryBrand.appIconImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pasteory").font(.system(size: 15, weight: .semibold))
                    Text("资料库").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    LibrarySectionLabel(title: "资料库")
                    sidebarRow("全部内容", symbol: "square.stack", filter: .all)
                    sidebarRow("收藏", symbol: "star", filter: .favorite)
                    sidebarRow("最近使用", symbol: "clock", filter: .recent)
                    sidebarRow("归档", symbol: "archivebox", filter: .archived)
                    sidebarRow("废纸篓", symbol: "trash", filter: .trash)

                    LibrarySectionLabel(title: "内容类型").padding(.top, 12)
                    ForEach(ClipKind.allCases, id: \.self) { kind in sidebarRow(kind.displayName, symbol: kind.symbolName, filter: .kind(kind)) }

                    LibrarySectionLabel(title: "普通分组").padding(.top, 12)
                    ForEach(state.collections.filter { $0.kind == .normal }) { collection in
                        collectionRow(collection)
                    }
                    addCollectionButton("新建分组", symbol: "folder.badge.plus") { showNewNormalCollection = true }

                    LibrarySectionLabel(title: "智能分组").padding(.top, 12)
                    ForEach(state.collections.filter { $0.kind == .smart }) { collection in
                        collectionRow(collection)
                    }
                    addCollectionButton("新建智能分组", symbol: "sparkles") {
                        editingSmartCollection = ClipCollection(name: "", kind: .smart, sortOrder: state.collections.count, ruleSet: SmartRuleSet())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }

            LibraryDivider()
            HStack {
                Button(action: onOpenSettings) {
                    Label("设置", systemImage: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(state.clips.count) 条")
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
                Image(systemName: collection.kind == .smart ? "sparkles" : "folder")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(String(collection.name.prefix(40)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.55))
                    .help("拖动调整顺序")
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
            if collection.kind == .smart {
                Button("编辑名称和规则…") { editingSmartCollection = collection }
            } else {
                Button("重命名…") { editingNormalCollection = collection }
            }
            Divider()
            Button("删除分组", role: .destructive) { confirmDeleteCollection(collection) }
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

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(libraryTitle).font(.system(size: 22, weight: .bold))
                        Text(librarySubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !state.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            Task { state.libraryAggregationDraft = await state.makeLibraryAggregationDraft() }
                        } label: {
                            Label("聚合结果", systemImage: "square.stack.3d.up")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!state.libraryCanAggregateCurrentResults)
                        .help("聚合当前搜索结果（⌘⇧M）")
                        .quickActionShortcut(state.settings.quickShortcut(for: .aggregateContent))
                    }
                    Text("\(state.libraryTopLevelResultCount) 个结果")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(LibraryTheme.inputBackground, in: Capsule())
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索内容、备注、分组或来源", text: $state.libraryQuery)
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
                ScrollView {
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
            }
        }
    }

    private var libraryTitle: String {
        switch state.libraryFilter {
        case .all: "全部内容"
        case .favorite: "收藏"
        case .recent: "最近使用"
        case .archived: "归档"
        case .trash: "废纸篓"
        case .kind(let kind): kind.displayName
        case .collection(let id): state.collections.first(where: { $0.id == id })?.name ?? "分组"
        }
    }

    private var librarySubtitle: String {
        if !state.libraryQuery.isEmpty { return "正在当前范围内搜索“\(String(state.libraryQuery.prefix(36)))”" }
        return switch state.libraryFilter {
        case .all: "保存过的文字、图片、链接、代码与文件"
        case .favorite: "你标记为收藏的内容"
        case .recent: "最近复制或使用过的内容"
        case .archived: "已从常用列表归档的内容"
        case .trash: "删除的内容会在这里保留 30 天"
        case .kind(let kind): "资料库中的\(kind.displayName)内容"
        case .collection(let id):
            state.collections.first(where: { $0.id == id })?.kind == .smart ? "按规则自动收集的内容" : "整理到这个分组的内容"
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let aggregation = state.selectedAggregation {
            LibraryAggregationInspector(
                state: state,
                aggregation: aggregation,
                onEdit: { state.libraryAggregationDraft = AggregationDraft(
                    aggregationID: aggregation.id,
                    memberClipIDs: aggregation.memberClipIDs,
                    title: aggregation.title,
                    note: aggregation.note,
                    origin: aggregation.origin
                ) }
            )
        } else if let clip = state.selectedClip {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("内容详情").font(.system(size: 17, weight: .semibold))
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
                        inspectorSection("预览") {
                            RepresentationPreview(clip: clip, attachments: state.attachments)
                                .frame(minHeight: 150, maxHeight: 240)
                                .padding(10)
                                .background(LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 10))
                        }

                        inspectorSection("抓取来源") {
                            captureSourceDetails(clip)
                        }

                        if clip.primaryKind == .link {
                            inspectorSection("链接解析") {
                                linkResolutionDetails
                            }
                        }

                        inspectorSection("编辑") {
                            inspectorFieldLabel("标题")
                            TextField("添加一个便于查找的标题", text: Binding(
                                get: { state.selectedClip?.title ?? "" },
                                set: { value in state.mutateSelected { $0.title = String(value.prefix(120)) } }
                            ))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))

                            if clip.source.bundleIdentifier == PasteoryRuntimeIdentity.current.bundleIdentifier {
                                inspectorFieldLabel("正文").padding(.top, 4)
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

                            inspectorFieldLabel("备注").padding(.top, 4)
                            TextEditor(text: Binding(
                                get: { state.selectedClip?.note ?? "" },
                                set: { value in state.mutateSelected { $0.note = String(value.prefix(4_000)) } }
                            ))
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(7)
                            .frame(minHeight: 76)
                            .background(LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))

                            inspectorFieldLabel("优先级").padding(.top, 4)
                            Picker("优先级", selection: Binding(
                                get: { state.selectedClip?.priority ?? 0 },
                                set: { value in state.mutateSelected { $0.priority = value } }
                            )) {
                                Text("无").tag(0)
                                Text("P1").tag(1)
                                Text("P2").tag(2)
                                Text("P3").tag(3)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)

                            HStack(spacing: 8) {
                                inspectorToggle(
                                    title: "收藏",
                                    symbol: clip.isFavorite ? "star.fill" : "star",
                                    active: clip.isFavorite
                                ) { state.mutateSelected { $0.isFavorite.toggle() } }
                                inspectorToggle(
                                    title: "置顶",
                                    symbol: clip.isPinned ? "pin.fill" : "pin",
                                    active: clip.isPinned
                                ) { state.mutateSelected { $0.isPinned.toggle() } }
                            }
                            .padding(.top, 4)
                        }

                        if !state.collections.filter({ $0.kind == .normal }).isEmpty {
                            inspectorSection("分组") {
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

                        inspectorSection("信息") { metadata(clip) }

                        HStack(spacing: 8) {
                            Button("粘贴") { onPaste(clip, false, true) }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: [])
                            Button("复制") { onPaste(clip, false, false) }.buttonStyle(.bordered)
                            Spacer()
                            if clip.deletedAt != nil {
                                Button("恢复") { state.restore(clip) }.buttonStyle(.bordered)
                            } else {
                                Button("删除", role: .destructive) { state.moveToTrash(clip) }.buttonStyle(.bordered)
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
            metadataRow("类型", value: clip.primaryKind.displayName)
            if let code = clip.codeMetadata {
                metadataRow("代码类型", value: code.subtype.displayName)
                if let language = code.language { metadataRow("语言", value: language.displayName) }
                if let lineCount = code.totalLineCount { metadataRow("代码行数", value: "\(lineCount) 行") }
                metadataRow("识别置信度", value: "\(Int((code.confidence * 100).rounded()))%")
                if code.wasTruncatedForClassification {
                    metadataRow("分析范围", value: "前 \(code.analyzedCharacterCount) 个字符")
                }
            }
            metadataRow("来源", value: clip.source.appName)
            metadataRow("来源可信度", value: clip.source.confidence.displayName)
            metadataRow("创建时间", value: clip.createdAt.formatted(date: .abbreviated, time: .standard))
            metadataRow("复制次数", value: "\(clip.copyCount) 次")
            metadataRow("粘贴次数", value: "\(clip.recordedPasteCount) 次")
            metadataRow("大小", value: ByteCountFormatter.string(fromByteCount: Int64(clip.byteSize), countStyle: .file))
            metadataRow("格式", value: Array(Set(clip.items.flatMap { $0.representations.map(\.uti) })).sorted().joined(separator: "、"))
        }
    }

    @ViewBuilder
    private func captureSourceDetails(_ clip: Clip) -> some View {
        if inspectorCaptureEvents.isEmpty {
            metadataRow("应用", value: clip.source.appName)
            metadataRow("可信度", value: clip.source.confidence.displayName)
            Text("这条内容只保存了来源应用，没有单独的复制上下文。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(inspectorCaptureEvents.prefix(5).enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    metadataRow("应用", value: event.source.appName)
                    metadataRow("采集时间", value: event.capturedAt.formatted(date: .abbreviated, time: .standard))
                    if let context = event.context {
                        metadataRow("摘要", value: context.summary)
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
                    } else {
                        Text("本次复制没有获取到更详细的上下文。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if inspectorCaptureEvents.count > 5 {
                Text("另有 \(inspectorCaptureEvents.count - 5) 次复制记录")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var linkResolutionDetails: some View {
        if let resource = inspectorLinkResource {
            metadataRow("状态", value: resource.requestState.displayName)
            if let title = resource.resolvedTitle {
                metadataRow("解析标题", value: title)
            } else if let candidate = resource.candidateTitle {
                metadataRow("候选标题", value: candidate)
            }
            metadataRow("兜底标题", value: resource.fallbackTitle)
            metadataRow("标题质量", value: resource.titleQuality.displayName)
            metadataRow("解析来源", value: resource.resolutionSource?.displayName ?? "尚未解析")
            metadataRow("链接", value: URLFallbackEngine.redactedDisplayURL(resource.normalizedURL))
            metadataRow("尝试次数", value: "\(resource.attemptCount) 次，失败 \(resource.failedAttemptCount) 次")
            if let lastAttemptAt = resource.lastAttemptAt {
                metadataRow("最近解析", value: lastAttemptAt.formatted(date: .abbreviated, time: .standard))
            }
        } else {
            Text("这条链接尚未建立解析记录。")
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
        Button("粘贴") { onPaste(clip, false, true) }; Button("复制") { onPaste(clip, false, false) }
        Button("纯文本粘贴") { onPaste(clip, true, true) }; Divider()
        Button(clip.isFavorite ? "取消收藏" : "收藏") { state.toggleFavorite(clip) }
        if let parentAggregationID,
           let aggregation = state.aggregations.first(where: { $0.id == parentAggregationID }) {
            Button("移出当前聚合") {
                Task { await state.removeClip(clip.id, from: aggregation) }
            }
            Divider()
        }
        if clip.deletedAt != nil {
            Button("恢复") { state.restore(clip) }
            Button("彻底删除", role: .destructive) { confirmPermanentDelete(clip) }
        } else { Button("移到废纸篓", role: .destructive) { state.moveToTrash(clip) } }
    }

    private func confirmPermanentDelete(_ clip: Clip) {
        let alert = NSAlert(); alert.messageText = "彻底删除这条内容？"; alert.informativeText = "此操作无法撤销。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { Task { await state.permanentlyDelete(clip) } }
    }

    private func confirmDeleteCollection(_ collection: ClipCollection) {
        let alert = NSAlert()
        alert.messageText = "删除“\(collection.name)”？"
        alert.informativeText = collection.kind == .smart ? "智能规则会一并删除，剪贴板内容不会被删除。" : "内容只会移出这个分组，不会从资料库删除。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
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
                Text(aggregation.origin.displayName + (aggregation.membershipMode == .automatic ? " · 自动更新" : ""))
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
            Button(state.libraryExpandedAggregationIDs.contains(aggregation.id) ? "收起内容" : "展开内容") {
                state.toggleLibraryAggregation(aggregation.id)
            }
            .quickActionShortcut(state.settings.quickShortcut(
                for: state.libraryExpandedAggregationIDs.contains(aggregation.id) ? .collapseAggregation : .expandAggregation
            ))
            Button("编辑聚合…", action: onEdit)
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
        let query = state.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "\(aggregation.memberClipIDs.count) 项内容" }
        let visible = Set(state.clips.map(\.id)).intersection(aggregation.memberClipIDs).count
        guard visible > 0, visible < aggregation.memberClipIDs.count else {
            return "\(aggregation.memberClipIDs.count) 项内容"
        }
        return "匹配 \(visible) / \(aggregation.memberClipIDs.count)"
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
                    Text("聚合详情").font(.system(size: 17, weight: .semibold))
                    Text("\(aggregation.memberClipIDs.count) 项内容").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(state.settings.themeColor.accentColor)
            }
            .padding(16)
            LibraryDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(aggregation.displayTitle).font(.headline)
                        if !aggregation.note.isEmpty { Text(aggregation.note).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("生成方式").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(aggregation.origin.displayName)
                        Text(aggregation.membershipMode == .automatic ? "成员会按条件自动更新" : "成员保持创建时的内容")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("包含内容").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(state.aggregationMembers[aggregation.id] ?? []) { clip in
                            HStack(spacing: 7) {
                                Image(systemName: clip.primaryKind.symbolName).foregroundStyle(state.settings.themeColor.accentColor)
                                Text(clip.displayTitle.isEmpty ? clip.previewText : clip.displayTitle).lineLimit(1)
                            }
                            .font(.caption)
                        }
                    }
                    Button("编辑聚合信息和成员…", action: onEdit)
                        .buttonStyle(.borderedProminent)
                        .tint(state.settings.themeColor.accentColor)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    HStack(spacing: 8) {
                        Button(aggregation.isFavorite ? "取消收藏聚合" : "收藏聚合") {
                            Task { await state.toggleAggregationFavorite(aggregation) }
                        }
                        Button(aggregation.isPinned ? "取消置顶聚合" : "置顶聚合") {
                            Task { await state.toggleAggregationPinned(aggregation) }
                        }
                        Spacer()
                        Menu("整理全部成员") {
                            let members = state.aggregationMembers[aggregation.id] ?? []
                            Button(members.allSatisfy(\.isFavorite) ? "取消收藏全部成员" : "收藏全部成员") {
                                Task { await state.toggleFavoriteForAllMembers(of: aggregation) }
                            }
                            Button(members.allSatisfy(\.isPinned) ? "取消置顶全部成员" : "置顶全部成员") {
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
            Text(original.isEditing ? "编辑聚合" : "聚合搜索结果").font(.title3.bold())
            Text("包含 \(memberIDs.count) 项不同内容 · \(original.origin.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("聚合标题", text: $title).textFieldStyle(.roundedBorder)
            TextField("备注（可选）", text: $note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
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
                                .help("移出聚合，保留原内容")
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
                Button("取消", action: onDone)
                Button(original.isEditing ? "保存" : "创建聚合") {
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
            Text(query.isEmpty ? "这里还没有内容" : "没有找到匹配内容")
                .font(.system(size: 16, weight: .semibold))
            Text(query.isEmpty ? "复制新的内容后，它会自动出现在资料库。" : "可以换个关键词，或选择其他资料范围。")
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
            Text("选择一条内容").font(.system(size: 15, weight: .semibold))
            Text("预览、备注和分组会显示在这里。")
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
    @State private var error: String?

    init(state: AppState, existing: ClipCollection?) {
        self.state = state
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "新建分组" : "重命名分组").font(.title2.bold())
            VStack(alignment: .leading, spacing: 5) {
                TextField("分组名称", text: Binding(get: { name }, set: { name = String($0.prefix(40)) }))
                Text("\(name.count)/40").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(existing == nil ? "创建" : "保存") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onChange(of: name) { _, _ in error = nil }
    }

    private func save() {
        if let message = state.collectionNameValidationMessage(name, excluding: existing?.id) { error = message; return }
        Task {
            let succeeded: Bool
            if var existing {
                existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                succeeded = await state.saveCollection(existing)
            } else {
                succeeded = await state.addCollection(name: name, smart: false) != nil
            }
            if succeeded { dismiss() }
            else { error = state.statusMessage }
        }
    }
}

struct SmartCollectionEditor: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let existing: ClipCollection
    @State private var name: String
    @State private var mode: RuleMatchMode
    @State private var conditions: [SmartCondition]
    @State private var error: String?
    @State private var candidates: [Clip] = []

    init(state: AppState, existing: ClipCollection) {
        self.state = state; self.existing = existing
        _name = State(initialValue: existing.name)
        _mode = State(initialValue: existing.ruleSet?.mode ?? .all)
        let saved = existing.ruleSet?.conditions.isEmpty == false ? existing.ruleSet!.conditions : [SmartCondition(field: .body, operation: .contains, value: "")]
        _conditions = State(initialValue: saved.map(Self.normalized))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing.name.isEmpty ? "新建智能分组" : "编辑智能分组").font(.title2.bold())
            VStack(alignment: .leading, spacing: 5) {
                TextField("分组名称", text: Binding(get: { name }, set: { name = String($0.prefix(40)) }))
                Text("\(name.count)/40").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            Picker("匹配方式", selection: $mode) { Text("满足全部条件").tag(RuleMatchMode.all); Text("满足任一条件").tag(RuleMatchMode.any) }.pickerStyle(.segmented)
            ForEach($conditions) { $condition in
                SmartConditionRow(condition: $condition, sourceOptions: sourceOptions) {
                    conditions.removeAll { $0.id == condition.id }
                }
            }
            if conditions.count < 10 { Button("添加条件") { conditions.append(SmartCondition(field: .body, operation: .contains, value: "")) } }
            let preview = previewResult
            GroupBox("匹配预览：\(preview.count) 条") {
                if preview.items.isEmpty { Text("当前资料库没有匹配内容").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preview.items.prefix(5)) { clip in Text(clip.displayTitle.isEmpty ? clip.previewText : clip.displayTitle).lineLimit(1).font(.caption) }
                        if preview.count > 5 { Text("另有 \(preview.count - 5) 条").font(.caption2).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button(existing.name.isEmpty ? "创建" : "保存") { save() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(minWidth: 680)
        .task { candidates = await state.smartRuleCandidates() }
        .onChange(of: name) { _, _ in error = nil }
        .onChange(of: mode) { _, _ in error = nil }
        .onChange(of: conditions) { _, _ in error = nil }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = state.collectionNameValidationMessage(trimmed, excluding: existing.name.isEmpty ? nil : existing.id) { error = message; return }
        let rules = SmartRuleSet(mode: mode, conditions: conditions)
        do { try SmartRuleEngine().validate(rules) }
        catch { self.error = error.localizedDescription; return }
        var collection = existing
        collection.name = trimmed; collection.kind = .smart; collection.ruleSet = rules
        Task {
            if await state.saveCollection(collection) { dismiss() }
            else { error = state.statusMessage }
        }
    }

    private var previewResult: (items: [Clip], count: Int) {
        (try? SmartRuleEngine().preview(candidates, ruleSet: SmartRuleSet(mode: mode, conditions: conditions))) ?? ([], 0)
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
        for condition in conditions where condition.field == .sourceApp && !condition.value.isEmpty {
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

    private static func normalized(_ condition: SmartCondition) -> SmartCondition {
        guard !condition.field.supportedOperators.contains(condition.operation) else { return condition }
        var value = condition
        value.operation = condition.field.supportedOperators[0]
        value.value = condition.field.defaultValue
        return value
    }
}

private struct SmartConditionRow: View {
    @Binding var condition: SmartCondition
    let sourceOptions: [ApplicationReference]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("字段", selection: $condition.field) {
                ForEach(SmartRuleField.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 112)
            .onChange(of: condition.field) { _, field in
                condition.operation = field.supportedOperators[0]
                condition.value = field == .sourceApp ? (sourceOptions.first?.bundleIdentifier ?? "") : field.defaultValue
            }

            Picker("条件", selection: $condition.operation) {
                ForEach(condition.field.supportedOperators, id: \.self) { operation in
                    Text(operation.displayName(for: condition.field)).tag(operation)
                }
            }
            .labelsHidden()
            .frame(width: 112)

            valueEditor.frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .help("删除条件")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch condition.field {
        case .title, .body, .note:
            TextField(condition.operation == .matchesRegex ? "输入正则表达式" : "输入匹配文字", text: limitedValue(maxLength: 512))
                .textFieldStyle(.roundedBorder)
        case .sourceApp:
            ApplicationSelectionControl(bundleIdentifier: $condition.value, additionalApplications: sourceOptions)
        case .sourceConfidence:
            Picker("来源可信度", selection: $condition.value) {
                Text("高").tag(SourceConfidence.high.rawValue)
                Text("低").tag(SourceConfidence.low.rawValue)
                Text("未知").tag(SourceConfidence.unknown.rawValue)
            }
            .labelsHidden()
        case .kind:
            Picker("内容类型", selection: $condition.value) {
                ForEach(ClipKind.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden()
        case .favorite:
            Picker("收藏状态", selection: $condition.value) {
                Text("已收藏").tag("true")
                Text("未收藏").tag("false")
            }
            .labelsHidden()
        case .priority:
            Picker("优先级", selection: $condition.value) {
                Text("无").tag("0")
                Text("P1").tag("1")
                Text("P2").tag("2")
                Text("P3").tag("3")
            }
            .labelsHidden()
        case .createdAt:
            HStack(spacing: 6) {
                TextField("天数", text: limitedValue(maxLength: 6)).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("天").foregroundStyle(.secondary)
            }
        case .byteSize:
            HStack(spacing: 6) {
                TextField("字节数", text: limitedValue(maxLength: 14)).textFieldStyle(.roundedBorder).frame(width: 120)
                Text("字节").foregroundStyle(.secondary)
            }
        case .copyCount:
            HStack(spacing: 6) {
                TextField("次数", text: limitedValue(maxLength: 9)).textFieldStyle(.roundedBorder).frame(width: 100)
                Text("次").foregroundStyle(.secondary)
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
        case .sourceApp: "来源"
        case .sourceConfidence: "来源可信度"
        case .createdAt: "时间"
        case .kind: "类型"
        case .title: "标题"
        case .body: "正文"
        case .note: "备注"
        case .byteSize: "大小"
        case .priority: "优先级"
        case .favorite: "收藏"
        case .copyCount: "复制次数"
        }
    }
}

private extension SmartRuleOperator {
    func displayName(for field: SmartRuleField) -> String {
        switch self {
        case .contains: "包含"
        case .equals: [.sourceApp, .sourceConfidence, .kind, .priority, .favorite].contains(field) ? "是" : "等于"
        case .matchesRegex: "匹配正则"
        case .before: "距今超过"
        case .after: "距今以内"
        case .greaterThan: "大于"
        case .lessThan: "小于"
        }
    }
}
