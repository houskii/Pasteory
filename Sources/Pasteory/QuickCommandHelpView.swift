import PasteoryCore
import SwiftUI

struct QuickCommandHelpView: View {
    @ObservedObject var settings: AppSettings
    let scrollEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.tr("Command 快捷操作")).font(.caption.weight(.semibold))
                Spacer()
                Text(L10n.tr("松开 ⌘ 隐藏")).font(.caption2).foregroundStyle(.tertiary)
            }

            if scrollEnabled {
                ScrollView(.vertical) {
                    commandHelpSections
                }
                .scrollIndicators(.visible)
            } else {
                commandHelpSections
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.65), lineWidth: 1))
    }

    private var commandHelpSections: some View {
        VStack(alignment: .leading, spacing: 11) {
            commandHelpSection(L10n.tr("粘贴与复制"), actions: [.directPaste, .copyOnly, .plainTextPaste, .plainTextCopy])
            commandHelpSection(L10n.tr("内容打开"), actions: [.openSelected])
            commandHelpSection(L10n.tr("搜索"), actions: [.toggleSearch])
            commandHelpSection(L10n.tr("文本工具"), actions: [.quickActions])
            commandHelpSection(
                L10n.tr("整理当前项目"),
                actions: [
                    .toggleFavorite, .togglePinned, .editMetadata, .setCollection,
                    .createCollection, .aggregateContent, .expandAggregation, .collapseAggregation, .moveToTrash
                ]
            )
            commandHelpSection(L10n.tr("窗口与页面"), actions: [.openLibrary, .openSettings, .closePanel])
            VStack(alignment: .leading, spacing: 6) {
                commandHelpSectionTitle(L10n.tr("固定导航快捷键"))
                commandHelpItem(shortcut: "↑↓ / ←→", title: L10n.tr("选择内容 / 切换分组"))
                commandHelpItem(shortcut: "⌘1～⌘9", title: L10n.tr("快速粘贴前 9 项"))
                commandHelpItem(shortcut: "Esc", title: L10n.tr("关闭当前编辑层"))
            }
        }
    }

    private func commandHelpSection(_ title: String, actions: [QuickPanelAction]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            commandHelpSectionTitle(title)
            ForEach(actions) { action in
                if let shortcut = settings.quickShortcut(for: action) {
                    commandHelpItem(
                        shortcut: ShortcutFormatter.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers),
                        title: action.title
                    )
                }
            }
        }
    }

    private func commandHelpSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commandHelpItem(shortcut: String, title: String) -> some View {
        HStack(spacing: 5) {
            Text(shortcut)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(settings.themeColor.accentColor)
                .frame(width: 64, alignment: .trailing)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
