import SwiftUI

struct WebCacheSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var cache: WebCacheMaintenance

    var body: some View {
        Section("网页缓存") {
            Toggle("自动清理网页缓存", isOn: $settings.automaticWebCacheCleanup)
                .onChange(of: settings.automaticWebCacheCleanup) { _, enabled in
                    if enabled { Task { await cache.check() } }
                }
            Text("距上次清理满 24 小时或占用超过 100 MB 时，等链接解析和网页登录结束后清理。已保存的标题和登录状态会保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("最近清理") {
                Text(settings.lastWebCacheCleanup?.formatted(date: .abbreviated, time: .shortened) ?? "尚未清理")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(cache.isClearing ? "正在清理…" : cache.manualPending ? "等待网页空闲…" : "清除网页缓存") {
                    Task { await cache.check(manual: true) }
                }
                .disabled(cache.isClearing || cache.manualPending)
            }
        }
    }
}
