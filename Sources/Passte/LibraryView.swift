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
                sidebar.frame(width: 220)
                Divider()
                content.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                if geometry.size.width >= 1_000 {
                    Divider()
                    inspector.frame(width: 340).frame(maxHeight: .infinity).clipped()
                }
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .tint(.purple)
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
            List {
                Section("资料库") {
                    sidebarRow("全部内容", symbol: "square.stack", filter: .all)
                    sidebarRow("收藏", symbol: "star", filter: .favorite)
                    sidebarRow("最近使用", symbol: "clock", filter: .recent)
                    sidebarRow("归档", symbol: "archivebox", filter: .archived)
                    sidebarRow("废纸篓", symbol: "trash", filter: .trash)
                }
                Section("内容类型") {
                    ForEach(ClipKind.allCases, id: \.self) { kind in sidebarRow(kind.displayName, symbol: kind.symbolName, filter: .kind(kind)) }
                }
                Section("普通分组") {
                    ForEach(state.collections.filter { $0.kind == .normal }) { collection in
                        collectionRow(collection)
                    }
                    .onMove { offsets, destination in
                        Task { await state.reorderCollections(kind: .normal, fromOffsets: offsets, toOffset: destination) }
                    }
                    Button { showNewNormalCollection = true } label: { Label("新建分组", systemImage: "plus") }
                }
                Section("智能分组") {
                    ForEach(state.collections.filter { $0.kind == .smart }) { collection in
                        collectionRow(collection)
                    }
                    .onMove { offsets, destination in
                        Task { await state.reorderCollections(kind: .smart, fromOffsets: offsets, toOffset: destination) }
                    }
                    Button { editingSmartCollection = ClipCollection(name: "", kind: .smart, sortOrder: state.collections.count, ruleSet: SmartRuleSet()) } label: { Label("新建智能分组", systemImage: "plus") }
                }
            }
            Divider()
            HStack {
                Button(action: onOpenSettings) { Label("设置", systemImage: "gearshape") }.buttonStyle(.plain)
                Spacer()
                Text("\(state.clips.count) 条").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func sidebarRow(_ title: String, symbol: String, filter: ClipFilter) -> some View {
        Button {
            state.libraryFilter = filter
            Task { await state.refreshLibrary() }
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if state.libraryFilter == filter { Image(systemName: "checkmark").font(.caption) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func collectionRow(_ collection: ClipCollection) -> some View {
        Button {
            state.libraryFilter = .collection(collection.id)
            Task { await state.refreshLibrary() }
        } label: {
            HStack(spacing: 7) {
                Label(String(collection.name.prefix(40)), systemImage: collection.kind == .smart ? "sparkles" : "folder")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if state.libraryFilter == .collection(collection.id) { Image(systemName: "checkmark").font(.caption) }
                Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.tertiary).help("拖动调整顺序")
            }
            .contentShape(Rectangle())
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

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索内容、备注、分组或来源", text: $state.libraryQuery)
                    .textFieldStyle(.plain)
                    .onChange(of: state.libraryQuery) { _, _ in Task { await state.refreshLibrary(debounce: true) } }
                if !state.libraryQuery.isEmpty { Button { state.libraryQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(12)
            Divider()
            if state.clips.isEmpty {
                ContentUnavailableView("没有内容", systemImage: "tray", description: Text("更换筛选条件，或复制新的内容。"))
            } else {
                List(state.clips, selection: $state.selectedClipID) { clip in
                    ClipRowView(clip: clip, attachments: state.attachments).tag(clip.id).contentShape(Rectangle())
                        .onTapGesture { state.selectedClipID = clip.id }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onPaste(clip, false, true) })
                        .contextMenu { contextMenu(for: clip) }
                }.listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let clip = state.selectedClip {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RepresentationPreview(clip: clip, attachments: state.attachments).frame(minHeight: 180, maxHeight: 320)
                    Divider()
                    Group {
                        Text("标题").font(.caption).foregroundStyle(.secondary)
                        TextField("可选标题", text: Binding(
                            get: { state.selectedClip?.title ?? "" },
                            set: { value in state.mutateSelected { $0.title = String(value.prefix(120)) } }
                        ))
                        if clip.source.bundleIdentifier == "app.passte.Passte" {
                            Text("正文").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: Binding(get: { state.selectedClip?.previewText ?? "" }, set: { state.updateManualText($0) }))
                                .font(.body).frame(minHeight: 110).border(.quaternary)
                        }
                        Text("备注").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(
                            get: { state.selectedClip?.note ?? "" },
                            set: { value in state.mutateSelected { $0.note = String(value.prefix(4_000)) } }
                        )).frame(minHeight: 80).border(.quaternary)
                        Picker("优先级", selection: Binding(get: { state.selectedClip?.priority ?? 0 }, set: { value in state.mutateSelected { $0.priority = value } })) {
                            Text("无").tag(0); Text("P1").tag(1); Text("P2").tag(2); Text("P3").tag(3)
                        }
                        Toggle("收藏", isOn: Binding(get: { state.selectedClip?.isFavorite ?? false }, set: { value in state.mutateSelected { $0.isFavorite = value } }))
                        Toggle("置顶", isOn: Binding(get: { state.selectedClip?.isPinned ?? false }, set: { value in state.mutateSelected { $0.isPinned = value } }))
                    }
                    if !state.collections.filter({ $0.kind == .normal }).isEmpty {
                        Divider(); Text("分组").font(.headline)
                        ForEach(state.collections.filter { $0.kind == .normal }) { collection in
                            Toggle(collection.name, isOn: Binding(
                                get: { state.selectedClip?.collectionIDs.contains(collection.id) ?? false },
                                set: { value in state.mutateSelected { if value { $0.collectionIDs.insert(collection.id) } else { $0.collectionIDs.remove(collection.id) } } }
                            ))
                        }
                    }
                    Divider(); metadata(clip)
                    HStack {
                        Button("粘贴") { onPaste(clip, false, true) }.keyboardShortcut(.return, modifiers: [])
                        Button("复制") { onPaste(clip, false, false) }
                        Spacer()
                        if clip.deletedAt != nil { Button("恢复") { state.restore(clip) } }
                        else { Button("删除", role: .destructive) { state.moveToTrash(clip) } }
                    }
                }.padding(16)
            }
        } else {
            ContentUnavailableView("选择一条内容", systemImage: "sidebar.right")
        }
    }

    private func metadata(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("信息").font(.headline)
            LabeledContent("类型", value: clip.primaryKind.displayName)
            LabeledContent("来源", value: clip.source.appName)
            LabeledContent("来源可信度", value: clip.source.confidence.displayName)
            LabeledContent("创建时间", value: clip.createdAt.formatted(date: .abbreviated, time: .standard))
            LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(clip.byteSize), countStyle: .file))
            LabeledContent("格式", value: Array(Set(clip.items.flatMap { $0.representations.map(\.uti) })).sorted().joined(separator: "、"))
        }.font(.caption)
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

    private var sourceOptions: [String] {
        var values = Set(candidates.map(\.source.appName).filter { !$0.isEmpty })
        for condition in conditions where condition.field == .sourceApp && !condition.value.isEmpty { values.insert(condition.value) }
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
    let sourceOptions: [String]
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
                condition.value = field == .sourceApp ? (sourceOptions.first ?? "") : field.defaultValue
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
            Picker("来源 App", selection: $condition.value) {
                if sourceOptions.isEmpty { Text("没有可选来源").tag("") }
                ForEach(sourceOptions, id: \.self) { Text(String($0.prefix(50))).tag($0) }
            }
            .labelsHidden()
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
