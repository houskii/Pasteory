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
                            .buttonStyle(.plain).id(tab.scope)
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
                LazyVStack(spacing: 8) {
                    ForEach(Array(state.quickClips.enumerated()), id: \.element.id) { index, clip in
                        QuickClipCard(state: state, clip: clip, index: index, onCopy: onCopy).id(clip.id)
                    }
                }.padding(10)
            }
            .id(state.quickPresentationID)
            .onChange(of: state.quickSelectionID) { _, id in
                if let id {
                    let anchor: UnitPoint = id == state.quickClips.first?.id ? .top : .center
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: anchor) }
                }
            }
            .onChange(of: state.quickPresentationID) { _, _ in
                if let id = state.quickClips.first?.id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } }
            }
            .onAppear { if let id = state.quickClips.first?.id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } } }
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
            .contextMenu {
                Button("直接粘贴") { onCopy(clip, false, true) }
                Button("只复制") { onCopy(clip, false, false) }
                Button("纯文本粘贴") { onCopy(clip, true, true) }
                Divider()
                Button(clip.isFavorite ? "取消收藏" : "收藏") { state.toggleFavorite(clip) }
                Button("移到废纸篓", role: .destructive) { state.moveToTrash(clip) }
            }
    }

    private var isSelected: Bool { state.quickSelectionID == clip.id }
}
