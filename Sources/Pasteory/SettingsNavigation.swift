import PasteoryCore
import Combine

enum SettingsDestination: String, CaseIterable, Identifiable {
    case library, general, privacy, shortcuts, openBehavior, linkResolution, aiOrganization, storage, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
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
        case .library: L10n.tr("浏览、搜索和整理保存的内容")
        case .general: L10n.tr("外观、启动和应用状态")
        case .privacy: L10n.tr("剪贴板检测、来源详情和排除应用")
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
}

/// Owned by the coordinator so routing works even when the window already exists.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var destination: SettingsDestination = .general
}
