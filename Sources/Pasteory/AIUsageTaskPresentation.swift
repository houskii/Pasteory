import Foundation
import PasteoryAI
import PasteoryCore

struct AIUsageTaskPresentation: Identifiable {
    let id: UUID
    let calls: [AIUsageRecord]
    var latestDate: Date { calls.map(\.date).max() ?? .distantPast }
    var inputTokens: Int { calls.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int { calls.reduce(0) { $0 + $1.outputTokens } }
    var title: String {
        switch calls.first?.trigger ?? "" {
        case "new": L10n.tr("新增内容分析")
        case "idle": L10n.tr("闲时整理")
        case "review", "manual-review": L10n.tr("检查分组状态")
        case "manual-regroup-all": L10n.tr("重新整理全部资料")
        case "manual-regroup-recent": L10n.tr("重新整理最近内容")
        case "definition": L10n.tr("按新定义整理分组")
        case "test": L10n.tr("连接测试")
        case "story": L10n.tr("Story · 最近 7 天总结")
        default: L10n.tr("内容整理")
        }
    }
    static func grouped(_ records: [AIUsageRecord], limit: Int = 30) -> [Self] {
        Dictionary(grouping: records, by: \.runID).map { id, calls in
            Self(id: id, calls: calls.sorted { $0.date < $1.date })
        }.sorted { $0.latestDate > $1.latestDate }.prefix(limit).map { $0 }
    }
}
