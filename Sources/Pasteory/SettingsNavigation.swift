import Combine

enum SettingsDestination: String, CaseIterable, Identifiable {
    case library, general, privacy, shortcuts, openBehavior, linkResolution, storage, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "资料库"
        case .general: "通用"
        case .privacy: "采集与隐私"
        case .shortcuts: "快捷键"
        case .openBehavior: "打开方式"
        case .linkResolution: "链接解析"
        case .storage: "存储与清理"
        case .advanced: "高级诊断"
        case .about: "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .library: "浏览、搜索和整理保存的内容"
        case .general: "外观、启动和应用状态"
        case .privacy: "剪贴板检测、来源详情和排除应用"
        case .shortcuts: "快捷面板和内容操作"
        case .openBehavior: "浏览器、编辑器和文件规则"
        case .linkResolution: "网页标题、登录规则和兜底规则"
        case .storage: "统计、占用、归档和备份"
        case .advanced: "权限、插件连接和搜索索引"
        case .about: "版本和产品信息"
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
