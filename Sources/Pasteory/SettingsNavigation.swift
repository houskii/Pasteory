import PasteoryCore
import Combine
import Foundation

enum SettingsDestination: String, CaseIterable, Identifiable {
    case story, library, general, privacy, shortcuts, openBehavior, linkResolution, aiOrganization, storage, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .story: "Story"
        case .library: L10n.tr("资料库")
        case .general: L10n.tr("通用")
        case .privacy: L10n.tr("采集与隐私")
        case .shortcuts: L10n.tr("快捷键")
        case .openBehavior: L10n.tr("打开方式")
        case .linkResolution: L10n.tr("链接解析")
        case .aiOrganization: L10n.tr("AI 整理")
        case .storage: L10n.tr("存储与清理")
        case .advanced: L10n.tr("高级诊断")
        case .about: L10n.tr("关于")
        }
    }

    var subtitle: String {
        switch self {
        case .story: L10n.tr("回看最近的事情，也看见自己的进展")
        case .library: L10n.tr("浏览、搜索和整理保存的内容")
        case .general: L10n.tr("外观、启动和应用状态")
        case .privacy: L10n.tr("剪贴板检测、图片文字识别、来源详情和排除应用")
        case .shortcuts: L10n.tr("快捷面板和内容操作")
        case .openBehavior: L10n.tr("浏览器、编辑器和文件规则")
        case .linkResolution: L10n.tr("网页标题、登录规则和兜底规则")
        case .aiOrganization: L10n.tr("模型、智能分组、生命周期与无损压缩")
        case .storage: L10n.tr("统计、占用、归档和备份")
        case .advanced: L10n.tr("权限、插件连接和搜索索引")
        case .about: L10n.tr("版本和产品信息")
        }
    }

    var symbol: String {
        switch self {
        case .story: "book.pages"
        case .library: "square.stack"
        case .general: "gearshape"
        case .privacy: "hand.raised"
        case .shortcuts: "command"
        case .openBehavior: "arrow.up.forward.app"
        case .linkResolution: "link"
        case .aiOrganization: "sparkles"
        case .storage: "externaldrive"
        case .advanced: "stethoscope"
        case .about: "info.circle"
        }
    }

    static func primaryDestinations(storyEnabled: Bool) -> [Self] {
        storyEnabled ? [.story, .library] : [.library]
    }
}

/// Owned by the coordinator so routing works even when the window already exists.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var destination: SettingsDestination = .general {
        didSet { if !automaticRouting { defaults.set(destination.rawValue, forKey: "lastSettingsDestination") } }
    }
    private let defaults: UserDefaults
    private var visible = false
    private var countedThisOpening = false
    private var automaticRouting = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func open(requested: SettingsDestination? = nil, storyEnabled: Bool, latestStoryID: UUID?, newOpening: Bool = true) {
        if newOpening { countedThisOpening = false }
        visible = true
        updateLatestStory(latestStoryID)
        guard newOpening || requested != nil else { return }
        let last = defaults.string(forKey: "lastSettingsDestination").flatMap(SettingsDestination.init(rawValue:)) ?? .general
        let preferStory = storyEnabled && (latestStoryID == nil || defaults.integer(forKey: "storyOpeningCount") < 3)
        // A temporary Story landing must not replace the page the user chose.
        automaticRouting = requested == nil
        destination = requested ?? (preferStory ? .story : (last == .story && !storyEnabled ? .library : last))
        automaticRouting = false
        if destination == .story, let latestStoryID { storyViewed(latestStoryID) }
    }

    func close() { visible = false }

    func storyViewed(_ id: UUID) {
        updateLatestStory(id)
        guard visible, destination == .story, !countedThisOpening else { return }
        defaults.set(min(3, defaults.integer(forKey: "storyOpeningCount") + 1), forKey: "storyOpeningCount")
        countedThisOpening = true
    }

    private func updateLatestStory(_ id: UUID?) {
        guard let id, defaults.string(forKey: "lastOpenedStoryID") != id.uuidString else { return }
        defaults.set(id.uuidString, forKey: "lastOpenedStoryID")
        defaults.set(0, forKey: "storyOpeningCount")
        countedThisOpening = false
    }
}
