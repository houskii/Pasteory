import AppKit
import PassteCore
import SwiftUI

struct LibraryView: View {
    @ObservedObject var state: AppState
    let onPaste: (Clip, Bool, Bool) -> Void
    let onOpenSettings: () -> Void
    @State private var showNewNormalCollection = false
    @State private var editingNormalCollection: ClipCollection?
    @State private var editingSmartCollection: ClipCollection?

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
                    colors: [LibraryTheme.canvasTop, LibraryTheme.canvasBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .tint(LibraryTheme.accent)
        .sheet(isPresented: $showNewNormalCollection) { CollectionNameEditor(state: state, existing: nil) }
        .sheet(item: $editingNormalCollection) { CollectionNameEditor(state: state, existing: $0) }
        .sheet(item: $editingSmartCollection) { SmartCollectionEditor(state: state, existing: $0) }
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
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LibraryTheme.brandGradient)
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Passte").font(.system(size: 15, weight: .semibold))
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
            .background(selected ? AnyShapeStyle(LibraryTheme.brandGradient) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
            .background(selected ? AnyShapeStyle(LibraryTheme.brandGradient) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
            .foregroundStyle(LibraryTheme.accent)
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
                    Text("\(state.clips.count) 条内容")
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

            if state.clips.isEmpty {
                LibraryEmptyState(query: state.libraryQuery)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(state.clips) { clip in
                            LibraryClipCard(
                                clip: clip,
                                attachments: state.attachments,
                                selected: state.selectedClipID == clip.id
                            )
                            .onTapGesture { state.selectedClipID = clip.id }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { onPaste(clip, false, true) })
                            .contextMenu { contextMenu(for: clip) }
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
        if let clip = state.selectedClip {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("内容详情").font(.system(size: 17, weight: .semibold))
                        Text(clip.primaryKind.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: clip.primaryKind.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LibraryTheme.accent)
                        .frame(width: 30, height: 30)
                        .background(LibraryTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
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

                            if clip.source.bundleIdentifier == "app.passte.Passte" {
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
                                                .foregroundStyle(selected ? LibraryTheme.accent : Color.secondary)
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
            .foregroundStyle(active ? LibraryTheme.accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(active ? LibraryTheme.accent.opacity(0.13) : LibraryTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func metadata(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataRow("类型", value: clip.primaryKind.displayName)
            metadataRow("来源", value: clip.source.appName)
            metadataRow("来源可信度", value: clip.source.confidence.displayName)
            metadataRow("创建时间", value: clip.createdAt.formatted(date: .abbreviated, time: .standard))
            metadataRow("大小", value: ByteCountFormatter.string(fromByteCount: Int64(clip.byteSize), countStyle: .file))
            metadataRow("格式", value: Array(Set(clip.items.flatMap { $0.representations.map(\.uti) })).sorted().joined(separator: "、"))
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
    private func contextMenu(for clip: Clip) -> some View {
        Button("粘贴") { onPaste(clip, false, true) }; Button("复制") { onPaste(clip, false, false) }
        Button("纯文本粘贴") { onPaste(clip, true, true) }; Divider()
        Button(clip.isFavorite ? "取消收藏" : "收藏") { state.toggleFavorite(clip) }
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

private struct LibraryClipCard: View {
    let clip: Clip
    let attachments: AttachmentStore
    let selected: Bool

    var body: some View {
        ClipRowView(clip: clip, attachments: attachments)
            .padding(.horizontal, 12)
            .frame(height: 82)
            .background(
                clip.isPinned ? LibraryTheme.pinnedBackground : LibraryTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? LibraryTheme.accent : LibraryTheme.divider, lineWidth: selected ? 2 : 1)
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
    let query: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LibraryTheme.accent)
                .frame(width: 58, height: 58)
                .background(LibraryTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 18))
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
    static let accent = Color(red: 0.28, green: 0.43, blue: 0.95)
    static let brandGradient = LinearGradient(
        colors: [accent, Color(red: 0.50, green: 0.25, blue: 0.92)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let canvasTop = Color(nsColor: .windowBackgroundColor)
    static let canvasBottom = Color(red: 0.97, green: 0.95, blue: 0.98).opacity(0.72)
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.90)
    static let inputBackground = Color(nsColor: .textBackgroundColor).opacity(0.82)
    static let pinnedBackground = Color(red: 0.48, green: 0.23, blue: 0.93).opacity(0.10)
    static let divider = Color(nsColor: .separatorColor).opacity(0.55)
}

private struct CollectionNameEditor: View {
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
                        ForEach(preview.items.prefix(5)) { clip in Text(clip.title.isEmpty ? clip.previewText : clip.title).lineLimit(1).font(.caption) }
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
        case .copyCount: "使用次数"
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
