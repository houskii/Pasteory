import AppKit
import Carbon
import PasteoryCore
import SwiftUI

enum GroupNavigationAction: Hashable, CaseIterable, Identifiable {
    case profile(GroupViewProfile)
    case allContent
    case group1, group2, group3, group4, group5, group6, group7, group8, group9

    var id: Self { self }
    static var profiles: [Self] { GroupViewProfile.allCases.map(Self.profile) }
    static let groups: [Self] = [.group1, .group2, .group3, .group4, .group5, .group6, .group7, .group8, .group9]
    static var allCases: [Self] { profiles + [.allContent] + groups }
    var rawValue: String {
        if case .profile(let profile) = self { return "profile.\(profile.rawValue)" }
        if self == .allContent { return "allContent" }
        return "group\(Self.groups.firstIndex(of: self)! + 1)"
    }
    var title: String {
        if case .profile(let profile) = self { return L10n.tr("切换到“\(profile.title)”视图") }
        if self == .allContent { return L10n.tr("全部内容") }
        return L10n.tr("第 \(Self.groups.firstIndex(of: self)! + 1) 个分组")
    }
    var defaultShortcut: PasteoryShortcut? {
        if case .profile(let profile) = self {
            guard let index = GroupViewProfile.allCases.firstIndex(of: profile), Self.numberKeys.indices.contains(index) else { return nil }
            return PasteoryShortcut(keyCode: Self.numberKeys[index], modifiers: UInt32(controlKey | optionKey))
        }
        if self == .allContent { return PasteoryShortcut(keyCode: 29, modifiers: UInt32(optionKey)) }
        return PasteoryShortcut(keyCode: Self.numberKeys[Self.groups.firstIndex(of: self)!], modifiers: UInt32(optionKey))
    }
    private static let numberKeys: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
}

struct GroupNavigationShortcuts: Codable, Equatable {
    var overrides: [String: PasteoryShortcut] = [:]
    var disabled: Set<String> = []
    func shortcut(for action: GroupNavigationAction) -> PasteoryShortcut? {
        disabled.contains(action.rawValue) ? nil : overrides[action.rawValue] ?? action.defaultShortcut
    }
}

extension AppState {
    func groupNavigationCollections(quick: Bool) -> [ClipCollection] {
        if quick {
            return quickTabs.compactMap { tab in
                guard case .collection(let id) = tab.scope else { return nil }
                return collections.first { $0.id == id }
            }
        }
        switch settings.groupPresentation.profile {
        case .minimal: return []
        case .ai: return orderedAICollections
        case .common:
            return (settings.groupPresentation.recommendationsEnabled ? recommendedAICollections : [])
                + collections.filter { $0.kind == .normal && intelligence.state.groups[$0.id] == nil }
                + collections.filter { $0.kind == .smart }
        }
    }

    func groupNavigationHint(for id: UUID?, quick: Bool) -> String? {
        let action: GroupNavigationAction
        if let id {
            guard let index = groupNavigationCollections(quick: quick).firstIndex(where: { $0.id == id }),
                  GroupNavigationAction.groups.indices.contains(index) else { return nil }
            action = GroupNavigationAction.groups[index]
        } else { action = .allContent }
        return settings.groupNavigationHint(for: action)
    }

    @discardableResult
    func navigateGroup(_ action: GroupNavigationAction, quick: Bool) async -> Bool {
        if case .profile(let profile) = action {
            switchGroupView(profile); await waitForGroupView()
            markVisibleGroupOpened(quick: quick)
            return true
        }
        let id: UUID?
        if action == .allContent { id = nil }
        else {
            guard let index = GroupNavigationAction.groups.firstIndex(of: action) else { return false }
            let groups = groupNavigationCollections(quick: quick)
            guard groups.indices.contains(index) else { return false }
            id = groups[index].id
        }
        if let id { intelligence.groupOpened(id) }
        if quick {
            quickScope = id.map(QuickScope.collection) ?? .all
            quickPresentationID = UUID()
            await refreshQuick(resetSelection: true)
        } else {
            libraryFilter = id.map(ClipFilter.collection) ?? .all
            await refreshLibrary()
        }
        return true
    }

    func setUngroupedFilter(_ enabled: Bool, quick: Bool) {
        if quick {
            quickScope = enabled ? .ungrouped : .all
            Task { await refreshQuick(resetSelection: true) }
        } else {
            libraryFilter = enabled ? .ungrouped : .all
            Task { await refreshLibrary() }
        }
    }

    func markVisibleGroupOpened(quick: Bool) {
        if quick, case .collection(let id) = quickScope { intelligence.groupOpened(id) }
        if !quick, case .collection(let id) = libraryFilter { intelligence.groupOpened(id) }
    }
}

struct GroupShortcutHint: View {
    var text: String?
    var body: some View {
        if let text {
            Text(text).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                .fixedSize().padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
                .accessibilityLabel(text)
        }
    }
}

struct GroupNewContentBadge: View {
    @ObservedObject var state: AppState
    var id: UUID
    var body: some View {
        let count = state.intelligence.newGroupContentCount(id)
        if count > 0 {
            Text(L10n.tr("新内容")).font(.system(size: 9, weight: .medium)).fixedSize()
                .foregroundStyle(state.settings.themeColor.accentColor)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(state.settings.themeColor.accentColor.opacity(0.1), in: Capsule())
                .help(L10n.tr("自上次打开后新增 \(count) 条内容"))
                .accessibilityLabel(L10n.tr("自上次打开后新增 \(count) 条内容"))
        }
    }
}

// The quick panel handles these events in its existing monitor. Library events
// stay scoped to this view's window, excluding sheets, popovers and recording.
struct LibraryGroupKeyMonitor: NSViewRepresentable {
    let state: AppState
    func makeNSView(context: Context) -> MonitorView { MonitorView(state: state) }
    func updateNSView(_ nsView: MonitorView, context: Context) {}
    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) { nsView.stopMonitoring() }
    final class MonitorView: NSView {
        let state: AppState
        var monitor: Any?
        init(state: AppState) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow, window.attachedSheet == nil,
                      event.window === window, !(window.firstResponder is ShortcutRecorderNSView),
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true,
                      let action = self.state.settings.groupNavigationAction(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags.carbonGroupModifiers) else { return event }
                Task { await self.state.navigateGroup(action, quick: false) }
                return nil
            }
        }
        func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}

extension NSEvent.ModifierFlags {
    var carbonGroupModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
