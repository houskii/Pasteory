import PassteCore
import SwiftUI

struct QuickPanelView: View {
    @ObservedObject var state: AppState
    let onCopy: (Clip, Bool, Bool) -> Void
    let onOpenLibrary: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .tint(.purple)
        .onAppear { searchFocused = true; Task { await state.refreshQuick() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索内容、备注、分组或来源", text: $state.quickQuery)
                .textFieldStyle(.plain).focused($searchFocused)
                .onChange(of: state.quickQuery) { _, _ in Task { await state.refreshQuick(debounce: true) } }
            Button { onOpenLibrary() } label: { Image(systemName: "rectangle.grid.1x2") }
                .buttonStyle(.plain).help("打开资料库（⌘O）")
        }
        .padding(12)
    }

    private var clipList: some View {
        List(state.quickClips, selection: $state.quickSelectionID) { clip in
            ClipRowView(clip: clip, attachments: state.attachments, compact: true)
                .tag(clip.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onCopy(clip, false, true) }
                .contextMenu {
                    Button("直接粘贴") { onCopy(clip, false, true) }
                    Button("只复制") { onCopy(clip, false, false) }
                    Button("纯文本粘贴") { onCopy(clip, true, true) }
                    Divider()
                    Button(clip.isFavorite ? "取消收藏" : "收藏") { state.toggleFavorite(clip) }
                    Button("移到废纸篓", role: .destructive) { state.moveToTrash(clip) }
                }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            state.quickQuery.isEmpty ? "还没有剪贴板内容" : "没有找到匹配内容",
            systemImage: state.quickQuery.isEmpty ? "clipboard" : "magnifyingglass",
            description: Text(state.settings.monitoringEnabled ? "复制一段文字或图片后，它会出现在这里。" : "记录已暂停，可从菜单栏或设置中恢复。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Label(state.settings.monitoringEnabled ? "自动记录中" : "记录已暂停", systemImage: state.settings.monitoringEnabled ? "record.circle" : "pause.circle")
            Spacer()
            Text("↩ 粘贴　⌘↩ 复制　⌥↩ 纯文本")
        }
        .font(.caption2).foregroundStyle(.secondary).padding(10)
    }
}
