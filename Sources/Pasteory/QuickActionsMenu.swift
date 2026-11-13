import AppKit
import PasteoryCore
import SwiftUI

struct QuickActionsMenu: View {
    let perform: (QuickTextAction) -> Void

    var body: some View {
        Menu(L10n.tr("快捷操作")) {
            QuickTextActionMenuItems(perform: perform)
        }
    }
}

struct QuickActionsToolbarMenu: View {
    @ObservedObject var state: AppState
    let clip: Clip?
    var compact = false

    var body: some View {
        Menu {
            QuickTextActionMenuItems { state.runQuickTextAction($0, for: clip) }
        } label: {
            if compact { Image(systemName: "wand.and.stars") }
            else { Label(L10n.tr("快捷操作"), systemImage: "wand.and.stars") }
        }
        .disabled(clip == nil || state.quickTextActionRunning)
        .help(L10n.tr("快捷操作"))
    }
}

private struct QuickTextActionMenuItems: View {
    let perform: (QuickTextAction) -> Void

    var body: some View {
        ForEach(QuickTextAction.allCases) { action in
            Button(action.title) { perform(action) }
        }
    }
}

enum QuickActionMenuScope: Hashable {
    case quickPanel, library
}

@MainActor
final class QuickActionMenuController {
    private struct WeakAnchor {
        weak var view: QuickActionMenuAnchorView?
    }

    private var anchors: [ObjectIdentifier: WeakAnchor] = [:]
    private var activeMenu: NSMenu?
    var isPresenting: Bool { activeMenu != nil }

    func register(_ view: QuickActionMenuAnchorView) {
        anchors = anchors.filter { $0.value.view != nil }
        anchors[ObjectIdentifier(view)] = WeakAnchor(view: view)
    }

    func unregister(_ view: QuickActionMenuAnchorView) {
        anchors.removeValue(forKey: ObjectIdentifier(view))
    }

    func present(for clip: Clip, scope: QuickActionMenuScope, in window: NSWindow, perform: (QuickTextAction) -> Void) {
        guard !isPresenting, window.isVisible, let contentView = window.contentView else { return }
        let menu = NSMenu(title: L10n.tr("快捷操作"))
        menu.autoenablesItems = false
        menu.minimumWidth = 200
        let handler = QuickTextActionMenuHandler()
        for action in QuickTextAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(QuickTextActionMenuHandler.select(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.target = handler
            menu.addItem(item)
        }
        let anchor = anchors.values.compactMap(\.view).first {
            $0.clipID == clip.id && $0.scope == scope && $0.window === window && !$0.visibleRect.isEmpty
        }
        let view = anchor ?? contentView
        let location = anchor.map { NSPoint(x: $0.visibleRect.minX + 12, y: $0.visibleRect.minY + 20) }
            ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        activeMenu = menu
        menu.popUp(positioning: menu.items.first, at: location, in: view)
        activeMenu = nil
        if let action = handler.selectedAction { perform(action) }
    }

    func cancel() { activeMenu?.cancelTrackingWithoutAnimation() }
}

@MainActor
private final class QuickTextActionMenuHandler: NSObject {
    var selectedAction: QuickTextAction?

    @objc func select(_ sender: NSMenuItem) {
        selectedAction = (sender.representedObject as? String).flatMap(QuickTextAction.init(rawValue:))
    }
}

struct QuickActionMenuAnchor: NSViewRepresentable {
    let controller: QuickActionMenuController
    let clipID: UUID
    let scope: QuickActionMenuScope

    func makeNSView(context: Context) -> QuickActionMenuAnchorView {
        let view = QuickActionMenuAnchorView()
        view.controller = controller
        view.clipID = clipID
        view.scope = scope
        return view
    }

    func updateNSView(_ view: QuickActionMenuAnchorView, context: Context) {
        view.clipID = clipID
        view.scope = scope
    }

    static func dismantleNSView(_ view: QuickActionMenuAnchorView, coordinator: ()) {
        view.controller?.unregister(view)
    }
}

final class QuickActionMenuAnchorView: NSView {
    weak var controller: QuickActionMenuController?
    var clipID: UUID?
    var scope: QuickActionMenuScope = .quickPanel
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { controller?.register(self) }
        else { controller?.unregister(self) }
    }
}
