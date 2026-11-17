import PasteoryAI
import PasteoryCore
import SwiftUI

struct StoryView: View {
    @ObservedObject var controller: StoryController
    @ObservedObject var settings: AppSettings
    let onConfigure: () -> Void
    @Environment(\.pasteoryAccentColor) private var accent
    @State private var selectedID: UUID?

    private var report: AIStoryReport? {
        controller.reports.first { $0.id == selectedID } ?? controller.reports.first
    }
    private func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.language.locale))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let report {
                    Text("\(date(report.periodStart)) – \(date(report.periodEnd))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("最近 7 天")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.reports.count > 1 {
                    Menu(L10n.tr("往期 Story")) {
                        ForEach(controller.reports) { item in
                            Button("\(date(item.periodEnd)) · \(item.title)") { selectedID = item.id }
                        }
                    }
                }
                if controller.running {
                    ProgressView().controlSize(.small)
                    Button(L10n.tr("暂停生成")) { controller.pause() }
                } else if controller.checkpoint != nil {
                    Button(L10n.tr("继续生成")) { controller.generate(resume: true) }
                    Button(L10n.tr("重新生成")) { controller.generate() }
                } else if report != nil {
                    Button(L10n.tr("重新生成")) { controller.generate() }.buttonStyle(.borderedProminent)
                }
                Button(L10n.tr("AI 设置"), action: onConfigure)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            if !controller.status.isEmpty, controller.running || controller.checkpoint != nil {
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 12)
            }
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let report { content(report) } else { empty }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await controller.load() }
        .onChange(of: controller.reports.first?.id) { _, id in selectedID = id }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.pages").font(.system(size: 48)).foregroundStyle(accent)
            Text(L10n.tr("给这一周写一则 Story")).font(.title2.bold())
            Text(L10n.tr("把最近留下的线索串起来，回看在做的事情，也给自己留一点鼓励。"))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(L10n.tr("生成最近 7 天的 Story")) { controller.generate() }
                .buttonStyle(.borderedProminent).disabled(controller.running)
            Text(L10n.tr("只使用允许参与 AI 的内容，沿用备注、来源和 OCR 的分享设置。打开页面不会自动调用模型。"))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 65).padding(.horizontal, 24)
    }

    private func content(_ report: AIStoryReport) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--debug-story-seed") {
                    Text(L10n.tr("演示数据")).font(.caption).foregroundStyle(.secondary)
                }
#endif
                Label(L10n.tr("这一周的你"), systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(accent)
                Text(report.title).font(.system(size: 27, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Text(report.introduction).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                Text(L10n.tr("基于 \(report.sourceCount) 条允许参与 AI 的内容 · \(date(report.generatedAt)) 生成"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

            Text(L10n.tr("最近在做的事")).font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(report.recentWork) { section in StorySectionCard(section: section) }
            }
            Text(L10n.tr("AI 的观察")).font(.title3.bold())
            ForEach(report.observations) { section in StorySectionCard(section: section) }
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.tr("给你的一点鼓励"), systemImage: "sun.max")
                    .font(.headline).foregroundStyle(accent)
                Text(report.encouragement).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            HStack {
                Text(L10n.tr("观察来自这段时间的剪贴板线索。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("查看这次生成记录")) { controller.openTask(report.id) }
                    .font(.caption)
            }
        }
    }
}

private struct StorySectionCard: View {
    let section: AIStorySection
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title).font(.headline)
            Text(section.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
            DisclosureGroup(L10n.tr("查看 \(section.evidence.count) 条依据")) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(section.evidence.enumerated()), id: \.offset) { _, evidence in
                        Text(evidence.quote).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 7)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
    }
}
