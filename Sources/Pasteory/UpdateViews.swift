import PasteoryCore
import AppKit
import SwiftUI

/// Semantic update colors deliberately do not inherit the app's accent tint.
enum UpdatePalette {
    struct Colors {
        let foreground: Color
        let background: Color
        let border: Color
    }

    static func colors(theme: PasteoryThemeColor, scheme: ColorScheme) -> Colors {
        if theme == .orange {
            return scheme == .dark
                ? Colors(foreground: Color(hex: 0x77D9EE), background: Color(hex: 0x17373F), border: Color(hex: 0x407F8C))
                : Colors(foreground: Color(hex: 0x00617A), background: Color(hex: 0xE6F7FC), border: Color(hex: 0x4D9AB0))
        }
        return scheme == .dark
            ? Colors(foreground: Color(hex: 0xFFD166), background: Color(hex: 0x3D321E), border: Color(hex: 0xA47E30))
            : Colors(foreground: Color(hex: 0x8A5B00), background: Color(hex: 0xFFF3CC), border: Color(hex: 0xB48928))
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct UpdateBadge: View {
    @ObservedObject var service: UpdateService
    let theme: PasteoryThemeColor
    let onOpen: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let update = service.availableUpdate {
            let colors = UpdatePalette.colors(theme: theme, scheme: scheme)
            Button(action: onOpen) {
                HStack(spacing: 4) {
                    Text(L10n.tr("更新"))
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(colors.foreground)
                .frame(width: L10n.language == .english ? 70 : 56, height: 26)
                .background(colors.background, in: Capsule())
                .overlay(Capsule().stroke(colors.border, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(L10n.tr("发现新版本 v\(update.version)，查看更新内容"))
            .accessibilityLabel(L10n.tr("更新，发现新版本 \(update.version)"))
            .accessibilityHint(L10n.tr("查看更新说明，确认后下载并安装"))
        }
    }
}

struct UpdateDialogView: View {
    @ObservedObject var service: UpdateService
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title2.bold())
                    Text(L10n.tr("当前版本 \(service.currentVersion)（Build \(service.currentBuild)）"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let update = service.availableUpdate, service.stage != .checking {
                HStack {
                    Text(L10n.tr("新版本 \(update.version)（Build \(update.build)）")).font(.headline)
                    Spacer()
                    if let date = update.publishedAt {
                        Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    Text(service.releaseNotes.isEmpty ? update.notes : service.releaseNotes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(minHeight: 150, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }

            if service.isBusy {
                VStack(alignment: .leading, spacing: 8) {
                    if service.stage == .downloading || service.stage == .extracting {
                        ProgressView(value: service.progress)
                    } else { ProgressView().controlSize(.small) }
                    Text(progressLabel).font(.caption).foregroundStyle(.secondary)
                }
            } else if service.stage == .failed || service.stage == .current {
                Text(service.lastError ?? L10n.tr("当前已经是最新版本。"))
                    .foregroundStyle(service.stage == .failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }

            if service.stage == .available {
                Text(L10n.tr("更新包来自 GitHub。确认后将自动下载、校验并安装；完成后会重启 Pasteory。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            HStack {
                if let url = service.availableUpdate?.releaseURL {
                    Link(L10n.tr("在 GitHub 查看"), destination: url).font(.caption)
                }
                Spacer()
                Button(service.stage == .available ? L10n.tr("稍后") : service.isBusy ? L10n.tr("取消") : L10n.tr("关闭")) {
                    service.closeDialog()
                }
                .disabled(!service.canCloseDialog)
                .keyboardShortcut(.cancelAction)
                if service.stage == .available {
                    Button(L10n.tr("下载并安装")) { service.installUpdate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!service.canInstall)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: .infinity, minHeight: 340, idealHeight: 540, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .pasteoryTheme(settings.themeColor, language: settings.appLanguage)
    }

    private var title: String {
        switch service.stage {
        case .checking: L10n.tr("正在检查更新")
        case .current: L10n.tr("检查完成")
        case .downloading: L10n.tr("正在下载更新")
        case .extracting: L10n.tr("正在准备安装")
        case .installing: L10n.tr("正在安装更新")
        case .failed: L10n.tr("暂时无法更新")
        default: L10n.tr("发现新版本")
        }
    }

    private var progressLabel: String {
        switch service.stage {
        case .checking: L10n.tr("正在获取最新版本信息…")
        case .downloading: L10n.tr("正在从 GitHub 下载… \(Int(service.progress * 100))%")
        case .extracting: L10n.tr("正在校验并解压更新…")
        case .installing: L10n.tr("正在安装，Pasteory 即将重启…")
        default: ""
        }
    }
}
