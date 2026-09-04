import AppKit
import PasteoryCore
import SwiftUI

struct OpenBehaviorSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var viewedExecution: FileCommandExecution?
    @State private var fileTypeSelection: FileTypeSelection?

    var body: some View {
        Form {
            Section("链接") {
                applicationRow(
                    title: "指定浏览器",
                    bundleIdentifier: $settings.browserBundleIdentifier,
                    placeholder: "选择浏览器",
                    pickerTitle: "选择链接浏览器"
                )
                Text("未选择浏览器时，快捷面板不会打开链接。")
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

            Section("文件") {
                Picker("命令 Shell", selection: $settings.fileCommandShell) {
                    ForEach(FileCommandShell.allCases, id: \.self) { shell in
                        Text(shell.displayName).tag(shell)
                    }
                }
                .pickerStyle(.segmented)

                Picker("命令执行方式", selection: $settings.fileCommandPresentation) {
                    ForEach(FileCommandPresentation.allCases, id: \.self) { presentation in
                        Text(presentation.displayName).tag(presentation)
                    }
                }
                .pickerStyle(.segmented)

                Text(commandPresentationDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.fileOpenRules.isEmpty {
                    ContentUnavailableView(
                        "尚未设置文件打开规则",
                        systemImage: "doc.badge.gearshape",
                        description: Text("可以按预设或自定义后缀选择 App，也可以执行使用 $file 的命令。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 110)
                } else {
                    ForEach(settings.fileOpenRules) { rule in
                        fileRuleRow(rule)
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    if settings.fileCommandLogsDirectory != nil {
                        Button("打开静默命令日志目录", systemImage: "folder") {
                            revealFileCommandLogs()
                        }
                    }
                    Menu {
                        Button("预设文件后缀", systemImage: "square.grid.2x2") {
                            settings.addFileOpenRule()
                        }
                        .disabled(configuredFileExtensions.count >= FileIconResolver.allFileExtensions.count)
                        Button("自定义后缀", systemImage: "textformat") {
                            settings.addCustomFileOpenRule()
                        }
                    } label: {
                        Label("添加文件规则", systemImage: "plus")
                    }
                }
                Text("每条规则只匹配一个后缀。可以从预设目录选择，也可以输入 .hap、.tar.gz 等自定义后缀；同名时自定义规则优先。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $viewedExecution) { execution in
            FileCommandLogViewer(
                settings: settings,
                fileType: execution.fileType,
                initialLogURL: execution.logURL
            )
        }
        .sheet(item: $fileTypeSelection) { selection in
            FileExtensionSelectionView(
                selectedFileExtension: settings.fileOpenRules.first(where: { $0.id == selection.id })?.normalizedFileExtension ?? "",
                unavailableFileExtensions: configuredFileExtensions.subtracting([
                    settings.fileOpenRules.first(where: { $0.id == selection.id })?.normalizedFileExtension ?? ""
                ])
            ) { descriptor in
                settings.updateFileOpenRuleCatalogExtension(id: selection.id, descriptor: descriptor)
                fileTypeSelection = nil
            }
        }
#if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--debug-file-type-picker"),
               let rule = settings.fileOpenRules.first(where: {
                   $0.matchKind == .catalogExtension || $0.matchKind == .fileType
               }) {
                fileTypeSelection = FileTypeSelection(id: rule.id)
            }
            guard ProcessInfo.processInfo.arguments.contains("--debug-file-command-log") else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                viewedExecution = settings.recentFileCommandExecution(for: "extension:swift")
            }
        }
#endif
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                switch rule.matchKind {
                case .fileType:
                    fileTypeButton(rule)
                case .catalogExtension:
                    catalogExtensionButton(rule)
                case .fileExtension:
                    customExtensionEditor(rule)
                }

                Picker("处理方式", selection: actionBinding(for: rule)) {
                    ForEach(FileOpenAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.segmented)

                Button(role: .destructive) {
                    settings.removeFileOpenRule(id: rule.id)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("删除这条规则")
            }

            switch rule.action {
            case .application:
                ApplicationSelectionControl(
                    bundleIdentifier: bundleIdentifierBinding(for: rule),
                    additionalApplications: [],
                    placeholder: "选择打开应用",
                    pickerTitle: "选择用于\(ruleDisplayName(rule))的应用"
                )
                .frame(maxWidth: .infinity)
            case .command:
                FileCommandEditor(command: rule.command) { command in
                    settings.updateFileOpenRuleCommand(id: rule.id, command: command)
                }
                Text("Pasteory 会把原文件的绝对路径放入 $file，并把工作目录设为文件所在目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let execution = settings.recentFileCommandExecution(for: rule.matchIdentifier) {
                    HStack(spacing: 8) {
                        Label(execution.status.displayName, systemImage: executionStatusSymbol(execution.status))
                            .foregroundStyle(executionStatusColor(execution.status))
                        Text(execution.startedAt.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("查看本次命令输出") { viewedExecution = execution }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var configuredFileExtensions: Set<String> {
        Set(settings.fileOpenRules.compactMap { rule in
            guard rule.matchKind == .catalogExtension || rule.matchKind == .fileExtension else { return nil }
            return rule.normalizedFileExtension
        })
    }

    private func catalogExtensionButton(_ rule: FileOpenRule) -> some View {
        let descriptor = FileIconResolver.fileExtension(rule.normalizedFileExtension)
            ?? FileExtensionDescriptor(
                fileExtension: rule.normalizedFileExtension,
                assetName: rule.fileType,
                displayName: FileIconResolver.fileType(assetName: rule.fileType)?.displayName ?? "文件",
                label: FileIconResolver.fileType(assetName: rule.fileType)?.label ?? "FILE"
            )
        return Button {
            fileTypeSelection = FileTypeSelection(id: rule.id)
        } label: {
            HStack(spacing: 10) {
                FileTypeIcon(assetName: descriptor.assetName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.pattern)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(descriptor.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(width: 300, height: 44)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
        .help("只匹配 \(descriptor.pattern)")
    }

    private func fileTypeButton(_ rule: FileOpenRule) -> some View {
        let fileType = FileIconResolver.fileType(assetName: rule.fileType)
            ?? FileIconResolver.fileType(assetName: "generic")!
        return Button {
            fileTypeSelection = FileTypeSelection(id: rule.id)
        } label: {
            HStack(spacing: 10) {
                FileTypeIcon(assetName: fileType.assetName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileType.primaryPattern)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(fileType.coverageSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(width: 300, height: 44)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
        .help("覆盖：\(fileType.suffixSummary)")
    }

    private func customExtensionEditor(_ rule: FileOpenRule) -> some View {
        let descriptor = FileIconResolver.descriptor(fileName: "file.\(rule.normalizedFileExtension)")
        return HStack(spacing: 10) {
            FileTypeIcon(assetName: descriptor.assetName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(".")
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                    FileExtensionEditor(fileExtension: rule.fileExtension) { fileExtension in
                        settings.updateFileOpenRuleExtension(id: rule.id, fileExtension: fileExtension)
                    }
                }
                Text("自定义后缀")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 300, height: 44, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
    }

    private var commandPresentationDescription: String {
        switch settings.fileCommandPresentation {
        case .terminalWindow:
            "每次执行会新建一个 Terminal.app 窗口，只显示简短的启动命令和实际输出，不展开 $file、PATH 等内部参数。命令完成后保留结果 3 秒，再关闭这个新窗口。首次使用需要允许 Pasteory 控制终端。"
        case .silent:
            "文件命令在后台执行，不显示窗口，也不读取 bash 或 zsh 的登录配置。命令的 stdout 和 stderr 会写入下方的静默命令日志，不包含 Pasteory App 日志。需要输入或确认的命令请使用终端窗口。"
        }
    }

    private func actionBinding(for rule: FileOpenRule) -> Binding<FileOpenAction> {
        Binding(
            get: { rule.action },
            set: { value in
                var updated = rule
                updated.action = value
                settings.updateFileOpenRule(updated)
            }
        )
    }

    private func bundleIdentifierBinding(for rule: FileOpenRule) -> Binding<String> {
        Binding(
            get: { rule.bundleIdentifier },
            set: { value in
                var updated = rule
                updated.bundleIdentifier = value
                settings.updateFileOpenRule(updated)
            }
        )
    }

    private func ruleDisplayName(_ rule: FileOpenRule) -> String {
        switch rule.matchKind {
        case .fileType:
            FileIconResolver.fileType(assetName: rule.fileType)?.displayName ?? "该文件类型"
        case .catalogExtension, .fileExtension:
            rule.normalizedFileExtension.isEmpty ? "该自定义后缀" : ".\(rule.normalizedFileExtension)"
        }
    }

    private func revealFileCommandLogs() {
        guard let directory = settings.fileCommandLogsDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func executionStatusSymbol(_ status: FileCommandExecutionStatus) -> String {
        switch status {
        case .running: "clock.arrow.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func executionStatusColor(_ status: FileCommandExecutionStatus) -> Color {
        switch status {
        case .running: .secondary
        case .succeeded: .green
        case .failed: .red
        }
    }
}

private struct FileTypeSelection: Identifiable {
    let id: UUID
}

private struct FileTypeIcon: View {
    let assetName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image = PasteoryFileIconStore.image(assetName: assetName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "doc.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct FileExtensionSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let selectedFileExtension: String
    let unavailableFileExtensions: Set<String>
    let onSelect: (FileExtensionDescriptor) -> Void
    @State private var query = ""

    private var fileExtensions: [FileExtensionDescriptor] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return FileIconResolver.allFileExtensions }
        return FileIconResolver.allFileExtensions.filter { descriptor in
            descriptor.pattern.localizedCaseInsensitiveContains(trimmedQuery)
                || descriptor.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || descriptor.label.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择文件后缀")
                        .font(.title2.bold())
                    Text("每条规则只匹配一个后缀，并按后缀升序排列。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            List(fileExtensions) { descriptor in
                Button {
                    onSelect(descriptor)
                } label: {
                    HStack(spacing: 12) {
                        FileTypeIcon(assetName: descriptor.assetName, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(descriptor.pattern)
                                .font(.system(.body, design: .monospaced, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(descriptor.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if descriptor.fileExtension == selectedFileExtension {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        } else if unavailableFileExtensions.contains(descriptor.fileExtension) {
                            Text("已添加")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .disabled(
                    descriptor.fileExtension != selectedFileExtension
                        && unavailableFileExtensions.contains(descriptor.fileExtension)
                )
                .help("只匹配 \(descriptor.pattern)")
            }
            .listStyle(.inset)
            .searchable(text: $query, placement: .toolbar, prompt: "搜索后缀或类型")
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FileCommandEditor: View {
    let command: String
    let onChange: (String) -> Void
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(command: String, onChange: @escaping (String) -> Void) {
        self.command = command
        self.onChange = onChange
        _draft = State(initialValue: command)
    }

    var body: some View {
        TextField("命令，例如：open -a Xcode \"$file\"", text: $draft)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .font(.system(.body, design: .monospaced))
            .focused($isFocused)
            .onChange(of: draft) { _, value in
                onChange(value)
            }
            .onChange(of: command) { _, value in
                if !isFocused, draft != value { draft = value }
            }
    }
}

private struct FileExtensionEditor: View {
    let fileExtension: String
    let onChange: (String) -> Void
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(fileExtension: String, onChange: @escaping (String) -> Void) {
        self.fileExtension = fileExtension
        self.onChange = onChange
        _draft = State(initialValue: Self.sanitize(fileExtension))
    }

    var body: some View {
        TextField("hap", text: Binding(
            get: { draft },
            set: { value in
                let sanitized = Self.sanitize(value)
                draft = sanitized
                onChange(sanitized)
            }
        ))
        .textFieldStyle(.plain)
        .labelsHidden()
        .font(.system(.body, design: .monospaced, weight: .semibold))
        .focused($isFocused)
        .onChange(of: fileExtension) { _, value in
            let sanitized = Self.sanitize(value)
            if !isFocused, draft != sanitized { draft = sanitized }
        }
    }

    private static func sanitize(_ value: String) -> String {
        value
            .filter { !$0.isWhitespace }
            .filter { $0.isLetter || $0.isNumber || ".-_+".contains($0) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}

private struct FileCommandLogViewer: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    let fileType: String
    let initialLogURL: URL
    @State private var content = "正在读取日志…"

    private var execution: FileCommandExecution? {
        settings.recentFileCommandExecution(for: fileType)
    }

    private var logURL: URL { execution?.logURL ?? initialLogURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("文件静默命令日志").font(.title2.bold())
                    Text(execution?.status.displayName ?? "历史日志")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.bordered)
                Button { dismiss() } label: {
                    Text("关闭").foregroundStyle(.primary)
                }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(18)
        .frame(width: 720, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: logURL) {
            while !Task.isCancelled {
                content = readLogTail(from: logURL)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func readLogTail(from url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "日志文件暂不可用。" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let maximumBytes: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > maximumBytes ? size - maximumBytes : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let body = String(decoding: data, as: UTF8.self)
        return size > maximumBytes ? "…仅显示最后 256 KB…\n\n\(body)" : body
    }
}
