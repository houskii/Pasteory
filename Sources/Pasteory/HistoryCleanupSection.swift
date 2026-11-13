import PasteoryCore
import SwiftUI

struct HistoryCleanupSection: View {
    @ObservedObject var state: AppState
    let period: StorageAnalyticsPeriod
    @State private var days = "30"
    @State private var sizeMB = "1"
    @State private var preview: HistoryCleanupPreview?
    @State private var showingPreview = false
    @State private var previewing = false
    @State private var message: String?

    private var criteria: (cutoff: Date, bytes: Int64)? {
        guard let days = Int(days.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...36_500).contains(days),
              let size = Double(sizeMB.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...1_000_000).contains(size),
              let cutoff = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -days, to: Date()) else { return nil }
        return (cutoff, Int64(size * 1_000_000))
    }

    var body: some View {
        Section(L10n.tr("清理历史")) {
            HStack(spacing: 8) {
                Text(L10n.tr("最后使用早于"))
                TextField(L10n.tr("天数"), text: $days)
                    .labelsHidden()
                    .frame(width: 58)
                    .accessibilityLabel(L10n.tr("最后使用早于多少天"))
                Text(L10n.tr("天前，单条大小大于"))
                TextField(L10n.tr("大小"), text: $sizeMB)
                    .labelsHidden()
                    .frame(width: 65)
                    .accessibilityLabel(L10n.tr("单条大小大于多少 MB"))
                Text("MB")
            }
            .disabled(previewing || state.isBusy)
            Text(L10n.tr("两项条件都要满足。按最后复制或粘贴时间计算，跳过收藏、置顶、分组和聚合中的内容。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(previewing ? L10n.tr("正在预览…") : L10n.tr("预览清理…"), action: loadPreview)
                    .disabled(previewing || state.isBusy || criteria == nil)
            }
            if let message { Text(message).font(.caption) }
        }
        .sheet(isPresented: $showingPreview) {
            if let preview {
                previewSheet(preview)
            }
        }
    }

    private func loadPreview() {
        guard let criteria else { return }
        previewing = true
        message = nil
        Task {
            defer { previewing = false }
            do {
                preview = try await state.repository.previewHistoryCleanup(
                    olderThan: criteria.cutoff, largerThan: criteria.bytes
                )
                showingPreview = true
            } catch { message = error.localizedDescription }
        }
    }

    private func deleteHistory(_ preview: HistoryCleanupPreview) {
        showingPreview = false
        Task {
            do {
                let result = try await state.cleanHistory(preview)
                let released = FileSizeFormatter.string(forByteCount: result.freedBytes)
                let remaining = result.failedFileCount == 0 ? "" : L10n.tr("；另有 \(result.failedFileCount) 个文件未能移除")
                message = L10n.tr("已删除 \(result.deletedCount) 条历史，释放约 \(released)\(remaining)")
                await state.refreshStorageAnalytics(period: period)
            } catch { message = error.localizedDescription }
        }
    }

    private func previewSheet(_ preview: HistoryCleanupPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("清理历史预览")).font(.title2.bold())
            if preview.entries.isEmpty {
                Text(L10n.tr("没有符合条件的历史记录。"))
                    .foregroundStyle(.secondary)
            } else {
                let size = FileSizeFormatter.string(forByteCount: preview.reclaimableBytes)
                Text(L10n.tr("找到 \(preview.entries.count) 条记录，预计释放 \(size) 的附件和归档空间。"))
                List(preview.entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            Text(entry.lastUsedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.language.locale)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(FileSizeFormatter.string(forByteCount: entry.byteCount))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(height: 240)
                Text(L10n.tr("这些历史将永久删除。其他记录仍在使用的附件会保留，文件引用指向的原文件也会保留。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(preview.entries.isEmpty ? L10n.tr("关闭") : L10n.tr("取消")) { showingPreview = false }
                    .keyboardShortcut(.cancelAction)
                if !preview.entries.isEmpty {
                    Button(L10n.tr("永久删除 \(preview.entries.count) 条记录"), role: .destructive) { deleteHistory(preview) }
                        .disabled(state.isBusy)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
