import AppKit
import PasteoryCore
import SwiftUI

struct QuickCollectionOverview: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    let onCreateText: () -> Void
    let onCreateNormal: () -> Void
    let onCreateSmart: () -> Void
    let onEdit: (ClipCollection) -> Void
    let onDelete: (ClipCollection) -> Void
    @State private var highlightedScope: QuickScope?
    @FocusState private var overviewFocused: Bool

    init(
        state: AppState,
        isPresented: Binding<Bool>,
        onCreateText: @escaping () -> Void,
        onCreateNormal: @escaping () -> Void,
        onCreateSmart: @escaping () -> Void,
        onEdit: @escaping (ClipCollection) -> Void,
        onDelete: @escaping (ClipCollection) -> Void
    ) {
        self.state = state
        self._isPresented = isPresented
        self.onCreateText = onCreateText
        self.onCreateNormal = onCreateNormal
        self.onCreateSmart = onCreateSmart
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("全部分组")).font(.headline)
                    Text(L10n.tr("拖动分组可调整快捷面板中的顺序"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.tr("\(state.collections.count) 个"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("关闭"))
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        overviewRow(
                            title: L10n.tr("全部内容"),
                            symbol: "clock",
                            selected: state.quickScope == .all,
                            highlighted: highlightedScope == .all
                        ) {
                            select(scope: .all)
                        }
                        .id(QuickScope.all)

                        ForEach(state.collections) { collection in
                            collectionRow(collection)
                                .id(QuickScope.collection(collection.id))
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.to.line")
                            Text(L10n.tr("拖到这里移到末尾"))
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                        .dropDestination(for: String.self) { identifiers, _ in
                            guard let raw = identifiers.first, let id = UUID(uuidString: raw) else { return false }
                            Task { await state.moveCollectionToEnd(id: id) }
                            return true
                        }
                    }
                    .padding(10)
                }
                .onChange(of: highlightedScope) { _, scope in
                    guard let scope else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(scope, anchor: .center) }
                }
            }
            .frame(height: min(CGFloat(state.collections.count + 2) * 38, 195))

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                actionButton(
                    L10n.tr("新建分组"),
                    symbol: "folder.badge.plus",
                    shortcut: state.settings.quickShortcut(for: .createCollection),
                    action: onCreateNormal
                )
                actionButton(L10n.tr("新建智能分组"), symbol: "sparkles", action: onCreateSmart)
                Divider().padding(.vertical, 3)
                actionButton(L10n.tr("新建文本内容"), symbol: "doc.badge.plus", action: onCreateText)
            }
            .padding(10)
        }
        .frame(width: 340)
        .pasteoryTheme(state.settings.themeColor, language: state.settings.appLanguage)
        .focusable()
        .focusEffectDisabled()
        .focused($overviewFocused)
        .onAppear {
            highlightedScope = state.quickScope
            DispatchQueue.main.async { overviewFocused = true }
        }
        .onKeyPress(.upArrow) {
            moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            select(scope: highlightedScope ?? state.quickScope)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func collectionRow(_ collection: ClipCollection) -> some View {
        let scope = QuickScope.collection(collection.id)
        return overviewRow(
            title: collection.name,
            symbol: state.intelligence.state.groups[collection.id] != nil ? "AI" : collection.kind == .smart ? "sparkles" : "folder",
            selected: state.quickScope == scope,
            highlighted: highlightedScope == scope,
            showsDragHandle: true
        ) {
            select(scope: scope)
        }
        .draggable(collection.id.uuidString)
        .dropDestination(for: String.self) { identifiers, _ in
            guard let raw = identifiers.first,
                  let sourceID = UUID(uuidString: raw),
                  sourceID != collection.id else { return false }
            Task { await state.moveCollection(id: sourceID, before: collection.id) }
            return true
        }
        .contextMenu {
            Button(collection.kind == .smart ? L10n.tr("编辑名称和规则…") : L10n.tr("重命名…")) {
                onEdit(collection)
            }
            Divider()
            Button(L10n.tr("删除分组"), role: .destructive) { onDelete(collection) }
        }
    }

    private func overviewRow(
        title: String,
        symbol: String,
        selected: Bool,
        highlighted: Bool,
        showsDragHandle: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                GroupIdentityIcon(isAI: symbol == "AI", symbol: symbol)
                    .foregroundStyle(selected ? state.settings.themeColor.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(title)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(state.settings.themeColor.accentColor)
                }
                if showsDragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected
                    ? state.settings.themeColor.accentColor.opacity(0.14)
                    : (highlighted ? Color.secondary.opacity(0.08) : Color.clear),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        shortcut: PasteoryShortcut? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(state.settings.themeColor.accentColor)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(scope: QuickScope) {
        state.quickScope = scope
        state.markVisibleGroupOpened(quick: true)
        state.quickPresentationID = UUID()
        isPresented = false
        Task { await state.refreshQuick(resetSelection: true) }
    }

    private var scopes: [QuickScope] {
        [.all] + state.collections.map { .collection($0.id) }
    }

    private func moveHighlight(by offset: Int) {
        let values = scopes
        guard !values.isEmpty else { return }
        let current = values.firstIndex(of: highlightedScope ?? state.quickScope) ?? 0
        highlightedScope = values[min(max(current + offset, 0), values.count - 1)]
    }
}
