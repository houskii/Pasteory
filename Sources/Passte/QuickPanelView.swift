import AppKit
import PassteCore
import SwiftUI

struct QuickPanelView: View {
    @ObservedObject var state: AppState
    let onCopy: (Clip, Bool, Bool) -> Void
    let onOpenLibrary: () -> Void
    let onOpenSettings: () -> Void
    let onCreateTextClip: () -> Void
    let onCreateCollection: (Bool) -> Void
    let onEditCollection: (ClipCollection) -> Void
    let onDeleteCollection: (ClipCollection) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            groupTabs
            Divider()
            if state.quickClips.isEmpty { emptyState } else { clipList }
            if let message = state.statusMessage {
                Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(.purple.opacity(0.1))
            }
            footer
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary, lineWidth: 1))
        .frame(minWidth: 340, idealWidth: 380, maxWidth: 520, minHeight: 480, idealHeight: 660, maxHeight: 760)
        .tint(.blue)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { state.quickPanelPinned.toggle() } label: {
                Image(systemName: state.quickPanelPinned ? "pin.fill" : "pin")
                    .foregroundStyle(state.quickPanelPinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).help(state.quickPanelPinned ? "取消固定" : "固定面板")

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("输入开始搜索…", text: $state.quickQuery)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onChange(of: state.quickQuery) { _, _ in Task { await state.refreshQuick(debounce: true) } }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.86), in: Capsule())

            Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("打开设置")
        }
        .padding(12)
    }

    private var groupTabs: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.quickTabs) { tab in
                            Button {
                                state.quickScope = tab.scope
                                state.quickPresentationID = UUID()
                                Task { await state.refreshQuick(resetSelection: true) }
                            } label: {
                                Text(tab.title)
                                    .font(.system(size: 13, weight: state.quickScope == tab.scope ? .semibold : .regular))
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                                    .foregroundStyle(state.quickScope == tab.scope ? Color.accentColor : Color.primary)
                                    .background(state.quickScope == tab.scope ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .id(tab.scope)
                            .contextMenu {
                                if case .collection(let id) = tab.scope,
                                   let collection = state.collections.first(where: { $0.id == id }) {
                                    Button(collection.kind == .smart ? "编辑名称和规则…" : "重命名…") { onEditCollection(collection) }
                                    Divider()
                                    Button("删除分组", role: .destructive) { onDeleteCollection(collection) }
                                }
                            }
                        }
                    }.padding(.leading, 10)
                }
                .onChange(of: state.quickScope) { _, value in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(value, anchor: .center) }
                }
            }
            Menu {
                Button("创建文本剪辑", systemImage: "doc.badge.plus", action: onCreateTextClip)
                Divider()
                Button("创建普通列表", systemImage: "folder.badge.plus") { onCreateCollection(false) }
                Button("创建智能列表", systemImage: "sparkles") { onCreateCollection(true) }
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 8)
        }
        .padding(.bottom, 8)
    }

    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("quick-list-top")
                LazyVStack(spacing: 8) {
                    ForEach(Array(state.quickClips.enumerated()), id: \.element.id) { index, clip in
                        QuickClipCard(state: state, clip: clip, index: index, onCopy: onCopy).id(clip.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .id(state.quickPresentationID)
            .onChange(of: state.quickSelectionID) { _, id in
                if let id {
                    let target: AnyHashable = id == state.quickClips.first?.id ? "quick-list-top" : id
                    let anchor: UnitPoint = id == state.quickClips.first?.id ? .top : .center
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(target, anchor: anchor) }
                }
            }
            .onChange(of: state.quickPresentationID) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo("quick-list-top", anchor: .top) }
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("quick-list-top", anchor: .top) } }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            state.quickQuery.isEmpty ? "还没有剪贴板内容" : "没有找到匹配内容",
            systemImage: state.quickQuery.isEmpty ? "clipboard" : "magnifyingglass",
            description: Text("复制一段文字、链接或图片后，它会出现在这里。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button(action: onOpenLibrary) { Image(systemName: "list.star") }
                .buttonStyle(.plain).help("打开资料库（⌘O）")
            Spacer()
            Text("\(state.quickClips.count) 个项目")
            Spacer()
            Text("↑↓ 选择　↩ 粘贴")
        }
        .font(.caption2).foregroundStyle(.secondary).padding(10)
    }
}

private struct QuickClipCard: View {
    @ObservedObject var state: AppState
    let clip: Clip
    let index: Int
    let onCopy: (Clip, Bool, Bool) -> Void
    @State private var showMetadataEditor = false

    var body: some View {
        ClipRowView(
            clip: clip,
            attachments: state.attachments,
            compact: true,
            shortcutNumber: state.quickCommandKeyDown && index < 9 ? index + 1 : nil
        )
            .padding(.horizontal, 12)
            .frame(height: 72)
            .clipped()
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2) }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { state.quickSelectionID = clip.id }
            .simultaneousGesture(TapGesture(count: 2).onEnded { onCopy(clip, false, true) })
            .popover(isPresented: $showMetadataEditor, arrowEdge: .trailing) {
                QuickMetadataEditor(clip: clip) { title, note in
                    state.updateMetadata(for: clip, title: title, note: note)
                    showMetadataEditor = false
                }
            }
            .contextMenu {
                Button("直接粘贴") { onCopy(clip, false, true) }
                Button("只复制") { onCopy(clip, false, false) }
                Button("纯文本粘贴") { onCopy(clip, true, true) }
                Divider()
                Button(clip.isFavorite ? "取消收藏" : "收藏") { state.toggleFavorite(clip) }
                Button(clip.isPinned ? "取消置顶" : "置顶") { state.togglePinned(clip) }
                Button("编辑标题与备注…") { showMetadataEditor = true }
                Menu("设置分组") {
                    let groups = state.collections.filter { $0.kind == .normal }
                    if groups.isEmpty {
                        Text("还没有普通分组")
                    } else {
                        ForEach(groups) { collection in
                            Button {
                                state.toggleCollection(collection, for: clip)
                            } label: {
                                Label(collection.name, systemImage: clip.collectionIDs.contains(collection.id) ? "checkmark" : "folder")
                            }
                        }
                    }
                }
                Divider()
                Button("移到废纸篓", role: .destructive) { state.moveToTrash(clip) }
            }
    }

    private var isSelected: Bool { state.quickSelectionID == clip.id }
}

private struct QuickMetadataEditor: View {
    let clip: Clip
    let onSave: (String, String) -> Void
    @State private var title: String
    @State private var note: String

    init(clip: Clip, onSave: @escaping (String, String) -> Void) {
        self.clip = clip
        self.onSave = onSave
        _title = State(initialValue: clip.title)
        _note = State(initialValue: clip.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑剪辑信息").font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text("标题"); Spacer(); Text("\(title.count)/120").foregroundStyle(.tertiary) }
                    .font(.caption)
                TextField("可选标题", text: Binding(get: { title }, set: { title = String($0.prefix(120)) }))
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text("备注"); Spacer(); Text("\(note.count)/4000").foregroundStyle(.tertiary) }
                    .font(.caption)
                TextEditor(text: Binding(get: { note }, set: { note = String($0.prefix(4_000)) }))
                    .frame(height: 110)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            }
            HStack {
                Spacer()
                Button("保存") { onSave(title, note) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
