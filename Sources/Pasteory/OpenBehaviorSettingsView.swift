import SwiftUI

struct OpenBehaviorSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("网页") {
                applicationRow(
                    title: "指定浏览器",
                    bundleIdentifier: $settings.browserBundleIdentifier,
                    placeholder: "选择浏览器",
                    pickerTitle: "选择网页浏览器"
                )
                Text("未选择浏览器时，快捷面板不会打开网页。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("图片") {
                LabeledContent("打开方式", value: "系统图片预览器（预览）")
            }

            Section("代码") {
                applicationRow(
                    title: "代码编辑器",
                    bundleIdentifier: $settings.codeEditorBundleIdentifier,
                    placeholder: "选择代码编辑器",
                    pickerTitle: "选择代码编辑器"
                )
                Text("代码会按识别出的语言生成临时文件，再交给所选编辑器打开。未选择编辑器时不执行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文件后缀") {
                if settings.fileOpenRules.isEmpty {
                    ContentUnavailableView(
                        "尚未设置文件打开规则",
                        systemImage: "doc.badge.gearshape",
                        description: Text("例如为 pdf 选择预览，为 psd 选择图像编辑器。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 110)
                } else {
                    ForEach(settings.fileOpenRules) { rule in
                        fileRuleRow(rule)
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    Button("添加后缀规则", systemImage: "plus") {
                        settings.addFileOpenRule()
                    }
                }
                Text("只有后缀和应用都配置完整的规则才会生效；没有匹配规则的文件不会被打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func applicationRow(
        title: String,
        bundleIdentifier: Binding<String>,
        placeholder: String,
        pickerTitle: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            ApplicationSelectionControl(
                bundleIdentifier: bundleIdentifier,
                additionalApplications: [],
                placeholder: placeholder,
                pickerTitle: pickerTitle
            )
            .frame(width: 300)
            Button {
                bundleIdentifier.wrappedValue = ""
            } label: {
                Image(systemName: "xmark.circle")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary.opacity(bundleIdentifier.wrappedValue.isEmpty ? 0.4 : 1))
            .disabled(bundleIdentifier.wrappedValue.isEmpty)
            .help("清除所选应用")
        }
        .frame(maxWidth: .infinity)
    }

    private func fileRuleRow(_ rule: FileOpenRule) -> some View {
        HStack(spacing: 10) {
            TextField(
                "后缀",
                text: Binding(
                    get: { rule.fileExtension },
                    set: { value in
                        var updated = rule
                        updated.fileExtension = value
                        settings.updateFileOpenRule(updated)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)

            Spacer(minLength: 4)

            ApplicationSelectionControl(
                bundleIdentifier: Binding(
                    get: { rule.bundleIdentifier },
                    set: { value in
                        var updated = rule
                        updated.bundleIdentifier = value
                        settings.updateFileOpenRule(updated)
                    }
                ),
                additionalApplications: [],
                placeholder: "选择打开应用",
                pickerTitle: "选择用于 .\(displayExtension(rule.fileExtension)) 文件的应用"
            )
            .frame(width: 300)

            Button(role: .destructive) {
                settings.removeFileOpenRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("删除这条规则")
        }
        .frame(maxWidth: .infinity)
    }

    private func displayExtension(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? "文件" : normalized.lowercased()
    }
}
