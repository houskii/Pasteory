import SwiftUI
import PasteoryCore

enum GroupViewProfile: String, Codable, CaseIterable, Identifiable {
    case common, ai, minimal
    var id: Self { self }
    var title: String {
        switch self { case .common: L10n.tr("常用"); case .ai: "AI"; case .minimal: L10n.tr("极简") }
    }
}
struct GroupPresentationSettings: Codable, Equatable {
    var profile: GroupViewProfile = .common
    var recommendationsEnabled = true
    var sidebarWidth = 224.0
    var compact = false
    var rowHeight: CGFloat { compact ? 28 : 34 }
}

struct GroupIdentityIcon: View {
    var isAI: Bool
    var symbol = "folder"
    var size: CGFloat = 13
    var body: some View {
        Group {
            if isAI { Text("AI").font(.system(size: max(10, size - 2), weight: .bold, design: .rounded)) }
            else { Image(systemName: symbol).font(.system(size: size, weight: .medium)) }
        }.frame(width: 18).accessibilityLabel(isAI ? L10n.tr("AI 分组") : "")
    }
}

struct GroupViewPicker: View {
    @ObservedObject var state: AppState
    var quick = false
#if DEBUG
    @State private var previewProfileID: String?
#endif
    var body: some View {
        ProfileTabStrip(items: items, selectedID: selectedID, accent: state.settings.themeColor.accentColor) { id in
            if let profile = GroupViewProfile(rawValue: id) {
                state.switchGroupView(profile); state.markVisibleGroupOpened(quick: quick)
                return
            }
#if DEBUG
            previewProfileID = id
#endif
        }
    }
    private var items: [ProfileTabItem] {
        var result = GroupViewProfile.allCases.map { ProfileTabItem(id: $0.rawValue, title: $0.title) }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-profile-overflow") {
            result += [.init(id: "demoPersonal", title: L10n.tr("个人")), .init(id: "demoWork", title: L10n.tr("工作"))]
        }
#endif
        return result
    }
    private var selectedID: String {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-profile-overflow") { return previewProfileID ?? "demoWork" }
#endif
        return state.settings.groupPresentation.profile.rawValue
    }
}

struct ProfileTabItem: Identifiable, Equatable {
    var id: String
    var title: String
}

struct ProfileTabStrip: View {
    var items: [ProfileTabItem]
    var selectedID: String
    var accent: Color
    var onSelect: (String) -> Void
    var body: some View {
        HStack(spacing: 3) {
            if items.count <= 3 {
                ForEach(items) { tab($0, fills: true) }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) { ForEach(items) { tab($0, fills: false).id($0.id) } }
                    }
                    .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
                    .onChange(of: selectedID) { _, id in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
                }
                Menu {
                    ForEach(items) { item in
                        Button { onSelect(item.id) } label: {
                            if item.id == selectedID { Label(item.title, systemImage: "checkmark") }
                            else { Text(item.title) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help(L10n.tr("全部视图"))
            }
        }.padding(3).frame(height: 32).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 260)
    }
    private func tab(_ item: ProfileTabItem, fills: Bool) -> some View {
        let selected = item.id == selectedID
        return Button { onSelect(item.id) } label: {
            Text(item.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false).padding(.horizontal, fills ? 0 : 10)
                .frame(maxWidth: fills ? .infinity : nil).padding(.vertical, 5)
                .background(selected ? accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct GroupViewMenu: View {
    @ObservedObject var state: AppState
    var quick = false
    var body: some View {
        Menu {
            ForEach(GroupViewProfile.allCases) { profile in
                Button(profile.title) { state.switchGroupView(profile); state.markVisibleGroupOpened(quick: quick) }
            }
            Divider()
            Button(L10n.tr("全部内容")) { state.setUngroupedFilter(false, quick: quick) }
            Button(L10n.tr("仅查看未分组内容")) { state.setUngroupedFilter(true, quick: quick) }
        } label: { Image(systemName: "sidebar.left") }
            .menuStyle(.borderlessButton).fixedSize().help(L10n.tr("分组视图与筛选"))
    }
}

struct GroupSidebarDivider: View {
    @ObservedObject var settings: AppSettings
    @State private var start: Double?
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            .overlay { Color.clear.frame(width: 7).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if start == nil { start = settings.groupPresentation.sidebarWidth }
                    settings.groupPresentation.sidebarWidth = min(320, max(180, (start ?? 224) + value.translation.width))
                }.onEnded { _ in start = nil }) }
            .help(L10n.tr("拖动调整分组栏宽度"))
            .accessibilityLabel(L10n.tr("分组栏宽度"))
    }
}

struct GroupSearchButton: View {
    @ObservedObject var state: AppState
    var quick = false
    @State private var presented = false
    @State private var query = ""
    var body: some View {
        Button { query = ""; presented = true } label: {
            Label((quick ? state.quickScope == .ungrouped : state.libraryFilter == .ungrouped) ? L10n.tr("未分组筛选") : L10n.tr("搜索分组"), systemImage: "magnifyingglass")
        }
            .buttonStyle(.plain).font(.caption)
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(L10n.tr("搜索名称或主题定义"), text: $query).textFieldStyle(.roundedBorder)
                        .onSubmit { if let first = matches.first { select(first) } }
                    Toggle(L10n.tr("仅查看未分组内容"), isOn: Binding(
                        get: { quick ? state.quickScope == .ungrouped : state.libraryFilter == .ungrouped },
                        set: { state.setUngroupedFilter($0, quick: quick); presented = false }
                    )).toggleStyle(.checkbox)
                    Text(L10n.tr("未分组表示没有 AI 主题归属，不占用分组切换位置。"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(matches) { collection in
                                Button { select(collection) } label: {
                                    HStack(spacing: 8) {
                                        GroupIdentityIcon(isAI: state.intelligence.state.groups[collection.id] != nil, symbol: collection.kind == .smart ? "sparkles" : "folder")
                                        Text(collection.name).lineLimit(1); Spacer()
                                        if let group = state.intelligence.state.groups[collection.id] { Text("\(group.memberIDs.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                    }.padding(7).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(state.intelligence.state.groups[collection.id]?.definition ?? collection.name)
                            }
                            if matches.isEmpty { Text(L10n.tr("没有匹配的分组")).foregroundStyle(.secondary).padding(10) }
                        }
                    }.frame(maxHeight: 320)
                }.padding(14).frame(width: 320)
            }
    }
    private var matches: [ClipCollection] {
        state.collections.filter { collection in
            let text = collection.name + " " + (state.intelligence.state.groups[collection.id]?.definition ?? "")
            return query.isEmpty || text.localizedCaseInsensitiveContains(query)
        }
    }
    private func select(_ collection: ClipCollection) {
        presented = false; state.intelligence.groupOpened(collection.id)
        if quick { state.quickScope = .collection(collection.id); Task { await state.refreshQuick(resetSelection: true) } }
        else { state.libraryFilter = .collection(collection.id); Task { await state.refreshLibrary() } }
    }
}
