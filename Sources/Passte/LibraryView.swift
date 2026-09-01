import AppKit
import PassteCore
import SwiftUI

struct LibraryView: View {
    @ObservedObject var state: AppState
    let onPaste: (Clip, Bool, Bool) -> Void
    let onOpenSettings: () -> Void
    @State private var showNewCollection = false
    @State private var editingSmartCollection: ClipCollection?
    @State private var newCollectionName = ""

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
            content.frame(minWidth: 360, idealWidth: 440)
            inspector.frame(minWidth: 280, idealWidth: 340)
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(.purple)
        .sheet(isPresented: $showNewCollection) { newCollectionSheet }
        .sheet(item: $editingSmartCollection) { SmartCollectionEditor(state: state, existing: $0) }
        .task { await state.refreshCollections(); await state.refreshLibrary() }
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
                        sidebarRow(collection.name, symbol: "folder", filter: .collection(collection.id))
                    }
                    Button { newCollectionName = ""; showNewCollection = true } label: { Label("新建分组", systemImage: "plus") }
                }
                Section("智能分组") {
                    ForEach(state.collections.filter { $0.kind == .smart }) { collection in
                        sidebarRow(collection.name, symbol: "sparkles", filter: .collection(collection.id))
                            .contextMenu { Button("编辑规则") { editingSmartCollection = collection } }
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
                        .onTapGesture(count: 2) { onPaste(clip, false, true) }
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
                        TextField("可选标题", text: Binding(get: { state.selectedClip?.title ?? "" }, set: { value in state.mutateSelected { $0.title = value } }))
                        Text("备注").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { state.selectedClip?.note ?? "" }, set: { value in state.mutateSelected { $0.note = value } })).frame(minHeight: 80).border(.quaternary)
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

    private var newCollectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建分组").font(.title2.bold())
            TextField("分组名称", text: $newCollectionName)
            HStack { Spacer(); Button("取消") { showNewCollection = false }; Button("创建") { let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }; Task { await state.addCollection(name: name, smart: false); showNewCollection = false } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 360)
    }

    private func confirmPermanentDelete(_ clip: Clip) {
        let alert = NSAlert(); alert.messageText = "彻底删除这条内容？"; alert.informativeText = "此操作无法撤销。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { Task { await state.permanentlyDelete(clip) } }
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

    init(state: AppState, existing: ClipCollection) {
        self.state = state; self.existing = existing
        _name = State(initialValue: existing.name)
        _mode = State(initialValue: existing.ruleSet?.mode ?? .all)
        _conditions = State(initialValue: existing.ruleSet?.conditions.isEmpty == false ? existing.ruleSet!.conditions : [SmartCondition(field: .body, operation: .contains, value: "")])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建智能分组").font(.title2.bold())
            TextField("分组名称", text: $name)
            Picker("匹配方式", selection: $mode) { Text("满足全部条件").tag(RuleMatchMode.all); Text("满足任一条件").tag(RuleMatchMode.any) }.pickerStyle(.segmented)
            ForEach($conditions) { $condition in
                HStack {
                    Picker("字段", selection: $condition.field) { ForEach(SmartRuleField.allCases, id: \.self) { Text(ruleFieldName($0)).tag($0) } }.labelsHidden()
                    Picker("条件", selection: $condition.operation) { ForEach(SmartRuleOperator.allCases, id: \.self) { Text(ruleOperatorName($0)).tag($0) } }.labelsHidden()
                    TextField("值", text: $condition.value)
                    Button { conditions.removeAll { $0.id == condition.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
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
            HStack { Spacer(); Button("取消") { dismiss() }; Button("创建") { save() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(minWidth: 620)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { error = "请输入分组名称"; return }
        let rules = SmartRuleSet(mode: mode, conditions: conditions)
        do { try SmartRuleEngine().validate(rules) }
        catch { self.error = error.localizedDescription; return }
        var collection = existing
        collection.name = trimmed; collection.kind = .smart; collection.ruleSet = rules
        Task { await state.saveCollection(collection); dismiss() }
    }

    private var previewResult: (items: [Clip], count: Int) {
        (try? SmartRuleEngine().preview(state.clips, ruleSet: SmartRuleSet(mode: mode, conditions: conditions))) ?? ([], 0)
    }

    private func ruleFieldName(_ field: SmartRuleField) -> String {
        switch field { case .sourceApp: "来源"; case .sourceConfidence: "来源可信度"; case .createdAt: "时间"; case .kind: "类型"; case .title: "标题"; case .body: "正文"; case .note: "备注"; case .byteSize: "大小"; case .priority: "优先级"; case .favorite: "收藏"; case .copyCount: "使用次数" }
    }
    private func ruleOperatorName(_ operation: SmartRuleOperator) -> String {
        switch operation { case .contains: "包含"; case .equals: "等于"; case .matchesRegex: "匹配正则"; case .before: "早于／距今超过天数"; case .after: "晚于／距今以内天数"; case .greaterThan: "大于"; case .lessThan: "小于" }
    }
}
