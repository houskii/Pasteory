import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    let onStart: () -> Void
    let onTestShortcut: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            VStack(spacing: 6) {
                Text("欢迎使用 Pasteory").font(.largeTitle.bold())
                Text(PasteoryBrand.tagline).font(.title3).foregroundStyle(.secondary)
                Text(PasteoryBrand.taglineChinese).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                feature("本地保存", "内容保存在这台 Mac，不会上传网络。", "internaldrive")
                feature("敏感保护", "默认忽略密码、钥匙串和隐藏剪贴板内容。", "lock.shield")
                feature("随时找回", "按 \(globalShortcutLabel) 搜索并粘贴历史内容。", "command")
            }
            .frame(maxWidth: 720)
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button("测试 \(globalShortcutLabel)") { onTestShortcut() }
                    Button {
                        settings.completedOnboarding = true; onStart()
                    } label: {
                        Text("开始使用").frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
                Text("Pasteory 已开始记录新复制的内容；已有剪贴板不会被导入，可随时从菜单栏暂停。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(36).frame(minWidth: 760, minHeight: 560).pasteoryTheme(settings.themeColor)
    }

    private var globalShortcutLabel: String {
        guard let shortcut = settings.globalShortcut else { return "快捷键" }
        return ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }

    private func feature(_ title: String, _ detail: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(settings.themeColor.accentColor)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}
