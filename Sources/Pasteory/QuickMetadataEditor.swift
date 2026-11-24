import AppKit
import PasteoryCore
import SwiftUI

struct QuickMetadataEditor: View {
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
                        Text(L10n.tr("编辑信息")).font(.headline)
                        Spacer()
                        Button(action: onCancel) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("取消编辑"))
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
                        Text(L10n.tr("Tab / Shift-Tab 切换 · ↑↓ 选择 · Space 勾选"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                        HStack {
                            Spacer()
                            Button(L10n.tr("取消"), action: onCancel)
                            Button(L10n.tr("保存")) { save() }.keyboardShortcut(.defaultAction)
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
            HStack { Text(L10n.tr("标题")); Spacer(); Text("\(title.count)/120").foregroundStyle(.tertiary) }
                .font(.caption)
            TextField(L10n.tr("可选标题"), text: Binding(get: { title }, set: { title = String($0.prefix(120)) }))
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
            HStack { Text(L10n.tr("备注")); Spacer(); Text("\(note.count)/4000").foregroundStyle(.tertiary) }
                .font(.caption)
            TextEditor(text: Binding(get: { note }, set: { note = String($0.prefix(64_000)) }))
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
                Text(L10n.tr("抓取的来源信息")).font(.subheadline.weight(.semibold))
                Spacer()
                if captureEvents.count > 1 {
                    Text(L10n.tr("共 \(captureEvents.count) 次复制")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let event = captureEvents.first, let context = event.context {
                VStack(alignment: .leading, spacing: 6) {
                    Text(context.summary).font(.caption.weight(.medium)).textSelection(.enabled)
                    Text(event.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.language.locale)))
                        .font(.caption2).foregroundStyle(.secondary)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if captureEvents.isEmpty {
                Text(L10n.tr("这条剪辑没有单独保存的来源上下文。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.tr("本次复制只记录了来源应用，没有获取到更详细的上下文。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.tr("这里是自动抓取的只读数据，不会写入上面的标题和备注。"))
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
                Text(L10n.tr("分组"))
                Spacer()
                Text(selectedCollectionCountText).foregroundStyle(.tertiary)
            }
            .font(.caption)

            if normalCollections.isEmpty {
                Label(L10n.tr("还没有普通分组"), systemImage: "folder")
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
                GroupIdentityIcon(isAI: state.intelligence.state.groups[collection.id] != nil)
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
        return count == 0 ? L10n.tr("未选择") : L10n.tr("已选择 \(count) 个")
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
