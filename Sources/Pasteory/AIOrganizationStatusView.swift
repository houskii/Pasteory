import PasteoryCore
import SwiftUI

struct AIOrganizationStatusView: View {
    @ObservedObject var controller: AIOrganizationController
    @State private var confirmingDiscard = false

    var body: some View {
        if controller.needsAttention {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if controller.running {
                        ProgressView().controlSize(.mini)
                        Text(controller.status).lineLimit(2)
                        Spacer(minLength: 0)
                        Button(L10n.tr("暂停分析")) { controller.pause() }
                    } else if controller.pending != nil {
                        Image(systemName: "checkmark.circle")
                        Text(L10n.tr("整理方案已生成，应用后更新分组"))
                        Spacer(minLength: 0)
                        Button(L10n.tr("检查整理建议")) { controller.showingReview = true }
                    } else if controller.state.checkpoint != nil {
                        Image(systemName: controller.error == nil ? "pause.circle" : "exclamationmark.triangle")
                        Text(controller.error == nil ? L10n.tr("整理已暂停：\(controller.checkpointProgress)") : L10n.tr("整理未完成：\(controller.checkpointProgress)"))
                        Spacer(minLength: 0)
                        Button(L10n.tr("继续整理")) { controller.analyze(resume: true) }
                            .disabled(controller.storageBusy)
                        Button(L10n.tr("放弃任务"), role: .destructive) { confirmingDiscard = true }
                            .disabled(controller.storageBusy)
                    }
                }
                if !controller.running, let error = controller.error {
                    Text(error).foregroundStyle(.red).lineLimit(3).textSelection(.enabled).help(error)
                }
                if let recovery = controller.checkpointRecovery {
                    Text(recovery).font(.caption2)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .alert(L10n.tr("放弃这次未完成的整理？"), isPresented: $confirmingDiscard) {
                Button(L10n.tr("取消"), role: .cancel) {}
                Button(L10n.tr("放弃任务"), role: .destructive) { Task { await controller.discardCheckpoint() } }
            } message: {
                Text(L10n.tr("仅放弃未应用的整理进度，原有分组和内容保持不变。之后可以重新开始整理。"))
            }
        }
    }
}
