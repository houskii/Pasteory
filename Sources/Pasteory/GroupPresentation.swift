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
    var body: some View {
        Picker(L10n.tr("分组视图"), selection: Binding(get: { state.settings.groupPresentation.profile }, set: { state.switchGroupView($0) })) {
            ForEach(GroupViewProfile.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
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
        Button { query = ""; presented = true } label: { Label(L10n.tr("搜索分组"), systemImage: "magnifyingglass") }
            .buttonStyle(.plain).font(.caption)
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(L10n.tr("搜索名称或主题定义"), text: $query).textFieldStyle(.roundedBorder)
                        .onSubmit { if let first = matches.first { select(first) } }
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
