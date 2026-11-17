import Foundation
import PasteoryCore
import SwiftUI

enum LinkResolutionDateScope: String, CaseIterable {
    case all, today, lastSevenDays, selectedDay
    var title: String {
        switch self {
        case .all: L10n.tr("全部日期")
        case .today: L10n.tr("今天")
        case .lastSevenDays: L10n.tr("最近 7 天")
        case .selectedDay: L10n.tr("指定日期")
        }
    }
    func contains(_ date: Date, selectedDay: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: true
        case .today: calendar.isDate(date, inSameDayAs: now)
        case .selectedDay: calendar.isDate(date, inSameDayAs: selectedDay)
        case .lastSevenDays:
            date >= calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
                && date < calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        }
    }
}

enum LinkResolutionIssueFilter: String, CaseIterable {
    case all, needsLogin, cannotAccess
    var title: String {
        switch self {
        case .all: L10n.tr("全部状态")
        case .needsLogin: L10n.tr("登录或验证")
        case .cannotAccess: L10n.tr("无法访问")
        }
    }
    func includes(_ entry: LinkResolutionEntry) -> Bool {
        switch self { case .all: true; case .needsLogin: entry.needsLogin; case .cannotAccess: entry.cannotAccess }
    }
}

struct LinkResolutionDay: Identifiable {
    let id: Date
    let entries: [LinkResolutionEntry]
    static func grouped(_ entries: [LinkResolutionEntry], calendar: Calendar = .current) -> [Self] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.activityDate) }.map { day, entries in
            Self(id: day, entries: entries.sorted { $0.activityDate == $1.activityDate ? $0.id.uuidString < $1.id.uuidString : $0.activityDate > $1.activityDate })
        }.sorted { $0.id > $1.id }
    }
}

struct LinkResolutionEntryRow: View {
    @Environment(\.pasteoryAccentColor) private var accentColor
    let entry: LinkResolutionEntry
    let isRetrying: Bool
    let onRetry: () -> Void
    let onAuthenticate: (() -> Void)?
    let onConfigureAuthentication: () -> Void
    let onConfigureFallback: () -> Void
    private var resource: LinkResource { entry.resource }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(resource.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                Text(resource.requestState.displayName).font(.caption.weight(.medium)).foregroundStyle(statusColor)
                    .fixedSize().padding(.horizontal, 7).padding(.vertical, 3)
                    .background(statusColor.opacity(0.09), in: Capsule())
            }
            Text(URLFallbackEngine.redactedDisplayURL(resource.normalizedURL))
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            HStack(spacing: 14) {
                Label(entry.sourceApplications.isEmpty ? L10n.tr("采集应用未知") : entry.sourceApplications.joined(separator: "、"), systemImage: "app")
                Text(resource.host)
            }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("收录时间：\(formatted(resource.createdAt))"))
                if let date = entry.latestAttempt?.finishedAt ?? resource.lastAttemptAt {
                    Text(L10n.tr("最近尝试：\(formatted(date))") + " · " + resolverName)
                } else {
                    Text(L10n.tr("最近尝试：尚无请求记录") + " · " + resolverName)
                }
                if let date = resource.lastResolvedAt { Text(L10n.tr("上次成功：\(formatted(date))")) }
            }.font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            if entry.retainedTitleAfterFailure {
                Label(L10n.tr("最近请求失败，当前保留上次保存的标题。"), systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if let attempt = entry.latestAttempt {
                    Text(attempt.httpStatus.map { "HTTP \($0)" } ?? resource.requestState.displayName)
                    Text(L10n.tr("耗时 \(Double(attempt.durationMilliseconds).formatted(.number.scale(0.001).precision(.fractionLength(2)))) 秒"))
                }
                Spacer(minLength: 4)
                Button(isRetrying ? L10n.tr("解析中…") : L10n.tr("重新解析"), action: onRetry).disabled(isRetrying)
                if resource.requestState != .resolved {
                    if let onAuthenticate { Button(L10n.tr("登录并解析"), action: onAuthenticate).disabled(isRetrying) }
                    else { Button(L10n.tr("配置登录…"), action: onConfigureAuthentication) }
                }
                Menu(L10n.tr("更多")) {
                    if let url = URL(string: resource.normalizedURL) { Link(L10n.tr("打开网页"), destination: url) }
                    Button(L10n.tr("配置兜底标题…"), action: onConfigureFallback)
                    Button(L10n.tr("配置登录…"), action: onConfigureAuthentication)
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
    private func formatted(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.language.locale))
    }
    private var resolverName: String {
        switch entry.latestAttempt?.resolver ?? resource.resolutionSource {
        case .anonymousHTTP: L10n.tr("网页请求")
        case .browserExtension: L10n.tr("Chrome 扩展")
        case .webKit: L10n.tr("已登录网页")
        case .siteAPI: L10n.tr("站点接口")
        case .fallbackRule: L10n.tr("URL 兜底规则")
        case nil: L10n.tr("解析方式未知")
        }
    }
    private var statusColor: Color {
        if resource.requestState == .resolved { return .green }
        if resource.requestState == .pending { return .secondary }
        return entry.cannotAccess ? .red : .orange
    }
}
