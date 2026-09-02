import PasteoryCore
import SwiftUI

struct LinkResolutionSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let onPrepareChrome: () -> Void

    @State private var selectedSection: LinkSettingsSection = .unresolved
    @State private var editingGroup: LinkFailureGroup?
    @State private var authenticationRequest: LinkAuthenticationRequest?
    @State private var showingManualLinkEditor = false
    @State private var rulePendingRemoval: URLFallbackRule?
    @State private var sessionRevision = UUID()

    private enum LinkSettingsSection: String, CaseIterable, Identifiable {
        case unresolved
        case resolved
        case rules
        case connections

        var id: String { rawValue }
        var title: String {
            switch self {
            case .unresolved: "未解析"
            case .resolved: "已解析"
            case .rules: "兜底规则"
            case .connections: "连接"
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("网页标题", systemImage: "globe")
                    .font(.headline)
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSwitchRow(isOn: $settings.linkResolutionEnabled) {
                            Text("自动访问网页并解析标题")
                        }
                        Divider()
                    Text("URL 识别和兜底标题始终在本机完成。打开后，Pasteory 才会访问目标网站获取真实标题。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Divider()
                        summary
                    }
                }
            }

            HStack(spacing: 12) {
                Picker("内容", selection: $selectedSection) {
                    ForEach(LinkSettingsSection.allCases) { section in Text(section.title).tag(section) }
                }
                .pickerStyle(.segmented)
                Button("添加链接…") { showingManualLinkEditor = true }
            }

            Group {
                switch selectedSection {
                case .unresolved: unresolved
                case .resolved: resolved
                case .rules: rules
                case .connections: connections
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await state.refreshLinkResolutionData() }
        .sheet(item: $editingGroup) { group in
            FallbackRuleEditorSheet(group: group) { name, title in
                await state.createFallbackRule(for: group, name: name, titleTemplate: title)
            }
        }
        .sheet(item: $authenticationRequest) { request in
            SiteLoginSheet(request: request) {
                sessionRevision = UUID()
                authenticationRequest = nil
                if let group = request.group {
                    Task { await state.retryAuthenticatedLinkResolution(group) }
                } else {
                    Task { await state.retryAuthenticatedLinkResolutions(for: request.site) }
                }
            }
        }
        .sheet(isPresented: $showingManualLinkEditor) {
            ManualLinkEditorSheet { value, mode in
                await state.addManualLink(value, mode: mode)
            }
        }
        .confirmationDialog(
            "移除兜底规则？",
            isPresented: Binding(
                get: { rulePendingRemoval != nil },
                set: { if !$0 { rulePendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: rulePendingRemoval
        ) { rule in
            Button("移除“\(rule.name)”", role: .destructive) {
                Task { await state.removeFallbackRule(rule) }
                rulePendingRemoval = nil
            }
            Button("取消", role: .cancel) { rulePendingRemoval = nil }
        } message: { _ in
            Text("受影响的链接会恢复为内置规则或通用 URL 兜底标题。")
        }
    }

    private var summary: some View {
        let groups = state.linkFailureGroups
        let needsLogin = groups.filter {
            $0.latestRequestState == .needsAuthentication
                || $0.latestRequestState == .verificationRequired
                || $0.latestRequestState == .forbidden
        }.count
        let generic = groups.filter { $0.latestRequestState == .genericTitle }.count
        return HStack(spacing: 18) {
            metric("待处理路由", value: groups.count, symbol: "exclamationmark.circle")
            metric("需要登录", value: needsLogin, symbol: "person.crop.circle.badge.exclamationmark")
            metric("通用标题", value: generic, symbol: "text.badge.xmark")
            metric("用户规则", value: state.fallbackRules.count, symbol: "wand.and.stars")
        }
        .padding(.vertical, 4)
    }

    private func metric(_ title: String, value: Int, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)").font(.headline.monospacedDigit())
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var unresolved: some View {
        Group {
            if state.linkFailureGroups.isEmpty {
                ContentUnavailableView(
                    "没有待处理链接",
                    systemImage: "checkmark.circle",
                    description: Text(settings.linkResolutionEnabled ? "新链接解析失败后会按 URL 路由聚合到这里。" : "打开自动解析后，请求失败的链接会出现在这里。")
                )
            } else {
                List(state.linkFailureGroups) { group in
                    LinkFailureGroupRow(
                        group: group,
                        isRetrying: state.linkResolutionBusyRouteKeys.contains(group.routeSignature.key),
                        onRetry: { state.retryLinkResolution(group) },
                        onAuthenticate: LinkAuthenticationSite.matching(host: group.routeSignature.host).map { site in
                            { authenticationRequest = LinkAuthenticationRequest(site: site, group: group) }
                        },
                        onConfigureFallback: { editingGroup = group }
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var resolved: some View {
        Group {
            if state.resolvedLinkResources.isEmpty {
                ContentUnavailableView(
                    "还没有已解析链接",
                    systemImage: "checkmark.circle",
                    description: Text("解析出可区分标题的链接会按具体 URL 显示在这里。")
                )
            } else {
                List(state.resolvedLinkResources) { summary in
                    ResolvedLinkRow(
                        summary: summary,
                        isRetrying: state.linkResolutionBusyResourceIDs.contains(summary.id),
                        onRetry: { state.reparseResolvedLink(summary) }
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var rules: some View {
        Group {
            if state.fallbackRules.isEmpty {
                ContentUnavailableView(
                    "还没有用户规则",
                    systemImage: "wand.and.stars",
                    description: Text("从“未解析”列表选择一组 URL，Pasteory 会根据样本生成匹配模板。")
                )
            } else {
                List(state.fallbackRules) { rule in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: rule.enabled ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(rule.enabled ? .green : .secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.name).font(.headline)
                            Text(rulePattern(rule)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Text("→ \(rule.titleTemplate)").font(.caption).lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { enabled in
                                var value = rule
                                value.enabled = enabled
                                Task { _ = await state.saveFallbackRule(value) }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        Button(role: .destructive) { rulePendingRemoval = rule } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    private var connections: some View {
        let chromeStatus = ChromeExtensionIntegration.status()
        _ = sessionRevision
        return Form {
            Section("Pasteory 登录会话") {
                ForEach(LinkAuthenticationSite.allCases) { site in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.key")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.title).font(.headline)
                            Text(site.domainDescription).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let updatedAt = LinkAuthenticationSession.lastUpdatedAt(site) {
                                Text("最近更新：\(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("尚未建立登录会话")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(LinkAuthenticationSession.lastUpdatedAt(site) == nil ? "登录…" : "更新登录…") {
                            authenticationRequest = LinkAuthenticationRequest(site: site, group: nil)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Text("登录发生在 Pasteory 独立的 WebKit 会话中，不读取 Chrome Cookie。登录数据和 WebCrypto 钥匙串账户按 Bundle ID 隔离，正式包与 QA 包互不共享。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("浏览器兼容标识", value: chromeCompatibilityLabel)
            }
            Section("Google Chrome") {
                LabeledContent("插件文件", value: chromeStatus.extensionAvailable ? "已准备" : "缺失")
                LabeledContent("原生消息桥", value: chromeStatus.nativeHostRegistered ? "已注册" : "未注册")
                if let lastContactAt = chromeStatus.lastContactAt {
                    LabeledContent("最近连接", value: lastContactAt.formatted(date: .abbreviated, time: .standard))
                } else {
                    LabeledContent("最近连接", value: "尚未连接")
                }
                HStack {
                    Spacer(minLength: 0)
                    Button("准备 Chrome 插件…", action: onPrepareChrome)
                }
                .frame(maxWidth: .infinity)
                Text("浏览器插件负责从已登录的 Chrome 页面获取复制上下文；Pasteory WebKit 登录会话负责解析从其他应用复制来的受保护 URL。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("访问边界") {
                Label("普通请求不携带 Cookie；只有主动选择“登录并解析”才使用 WebKit 会话", systemImage: "lock.shield")
                Label("登录解析只保存 URL、标题候选和诊断状态，不保存网页正文", systemImage: "doc.badge.ellipsis")
                Label("localhost、局域网 IP 和高风险操作路径会被拦截", systemImage: "network.badge.shield.half.filled")
            }
        }
        .formStyle(.grouped)
    }

    private func rulePattern(_ rule: URLFallbackRule) -> String {
        let query = rule.requiredQueryKeys.isEmpty ? "" : "?" + rule.requiredQueryKeys.map { "\($0)={\($0)}" }.joined(separator: "&")
        return "\(rule.hostPattern)\(rule.pathTemplate)\(query)"
    }

    private var chromeCompatibilityLabel: String {
        let marker = "Chrome/"
        guard let range = LinkWebKitConfiguration.compatibilityUserAgent.range(of: marker) else { return "Chrome 兼容" }
        let version = LinkWebKitConfiguration.compatibilityUserAgent[range.upperBound...].split(separator: " ").first ?? ""
        return "Chrome \(version)"
    }
}

enum ManualLinkResolutionMode: String, CaseIterable, Identifiable {
    case saveOnly
    case anonymous
    case authenticated

    var id: String { rawValue }
}

private struct ManualLinkEditorSheet: View {
    let onSave: (String, ManualLinkResolutionMode) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var isSaving = false

    private var normalizedURL: URL? { URLFallbackEngine.normalizedWebURL(value) }
    private var site: LinkAuthenticationSite? {
        normalizedURL.flatMap { LinkAuthenticationSite.matching(host: $0.host ?? "") }
    }
    private var hasAuthenticatedSession: Bool {
        site.flatMap(LinkAuthenticationSession.lastUpdatedAt) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加链接").font(.title2.bold())
            Text("不需要先放进系统剪贴板。Pasteory 会把链接保存到资料库，再按你选择的方式解析标题。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("https://example.com/path", text: $value)
                .textFieldStyle(.roundedBorder)
            if let site {
                Label(
                    hasAuthenticatedSession ? "可以使用 \(site.title) 登录会话" : "\(site.title) 尚未建立登录会话",
                    systemImage: hasAuthenticatedSession ? "checkmark.shield" : "person.crop.circle.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(hasAuthenticatedSession ? Color.secondary : Color.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("仅保存") { save(.saveOnly) }
                    .disabled(isSaving || normalizedURL == nil)
                Button("匿名解析") { save(.anonymous) }
                    .disabled(isSaving || normalizedURL == nil)
                if site != nil {
                    Button("使用登录会话") { save(.authenticated) }
                        .disabled(isSaving || !hasAuthenticatedSession)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func save(_ mode: ManualLinkResolutionMode) {
        isSaving = true
        Task {
            if await onSave(value, mode) { dismiss() }
            isSaving = false
        }
    }
}

private struct LinkFailureGroupRow: View {
    let group: LinkFailureGroup
    let isRetrying: Bool
    let onRetry: () -> Void
    let onAuthenticate: (() -> Void)?
    let onConfigureFallback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.routeSignature.displayValue).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(group.latestRequestState.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            Text("\(group.uniqueURLCount) 个 URL · \(group.clipCount) 条记录 · 复制 \(group.copyCount) 次 · 解析 \(group.attemptCount) 次")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("当前兜底")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(group.currentFallbackTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(group.currentFallbackState.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                Spacer()
                Button(isRetrying ? "解析中…" : "重新解析", action: onRetry).disabled(isRetrying)
                if let onAuthenticate {
                    Button("登录并解析", action: onAuthenticate).disabled(isRetrying)
                }
                Button("配置兜底", action: onConfigureFallback)
            }
            Text(group.sampleURL).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.vertical, 5)
    }

    private var statusColor: Color {
        switch group.latestRequestState {
        case .needsAuthentication, .verificationRequired, .forbidden: .orange
        case .genericTitle, .missingTitle: Color.accentColor
        default: .red
        }
    }
}

private struct ResolvedLinkRow: View {
    let summary: ResolvedLinkSummary
    let isRetrying: Bool
    let onRetry: () -> Void

    private var resource: LinkResource { summary.resource }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(resource.resolvedTitle ?? resource.fallbackTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            Text(URLFallbackEngine.redactedDisplayURL(resource.normalizedURL))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 7) {
                Text(resource.resolutionSource?.displayName ?? "未知来源")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                Text("\(summary.clipCount) 条记录 · 复制 \(summary.copyCount) 次 · 解析 \(resource.attemptCount) 次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastAttemptAt = resource.lastAttemptAt {
                    Text("最近 \(lastAttemptAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(isRetrying ? "解析中…" : "重新解析", action: onRetry)
                    .disabled(isRetrying)
            }
        }
        .padding(.vertical, 5)
    }

    private var statusText: String {
        resource.requestState == .resolved
            ? resource.titleQuality.displayName
            : "最近重试失败 · \(resource.requestState.displayName)"
    }

    private var statusColor: Color {
        resource.requestState == .resolved ? .green : .orange
    }
}

private struct FallbackRuleEditorSheet: View {
    let group: LinkFailureGroup
    let onSave: (String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var titleTemplate: String
    @State private var isSaving = false

    init(group: LinkFailureGroup, onSave: @escaping (String, String) async -> Bool) {
        self.group = group
        self.onSave = onSave
        _name = State(initialValue: Self.suggestedName(group))
        _titleTemplate = State(initialValue: Self.suggestedTitleTemplate(group))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建兜底规则").font(.title2.bold())
            Text("Pasteory 已根据失败样本生成匹配模板。保存前请确认范围和标题。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                LabeledContent("匹配网站", value: group.routeSignature.host)
                LabeledContent("路径模板", value: group.routeSignature.pathTemplate)
                if !group.routeSignature.requiredQueryKeys.isEmpty {
                    LabeledContent("要求参数", value: group.routeSignature.requiredQueryKeys.joined(separator: "、"))
                }
                TextField("规则名称", text: $name)
                TextField("兜底标题", text: $titleTemplate)
                if !availableVariables.isEmpty {
                    LabeledContent("可用变量", value: availableVariables.joined(separator: "、"))
                }
                LabeledContent("影响范围", value: "\(group.uniqueURLCount) 个 URL，\(group.clipCount) 条记录")
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    isSaving = true
                    Task {
                        if await onSave(name, titleTemplate) { dismiss() }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560, height: 430)
    }

    private var availableVariables: [String] {
        let pattern = #"\{([^}]+)\}"#
        let pathVariables: [String]
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let value = group.routeSignature.pathTemplate
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            pathVariables = regex.matches(in: value, range: range).compactMap { match in
                guard let range = Range(match.range(at: 1), in: value) else { return nil }
                return "{{path.\(value[range])}}"
            }
        } else {
            pathVariables = []
        }
        return pathVariables + group.routeSignature.requiredQueryKeys.map { "{{query.\($0)}}" }
    }

    private static func suggestedName(_ group: LinkFailureGroup) -> String {
        let path = group.routeSignature.pathTemplate.split(separator: "/").last.map(String.init) ?? "链接"
        return "\(group.routeSignature.host) · \(path)"
    }

    private static func suggestedTitleTemplate(_ group: LinkFailureGroup) -> String {
        if let builtIn = URLFallbackRule.builtIns.first(where: {
            let hostMatches = $0.hostPattern == group.routeSignature.host
                || ($0.hostPattern.hasPrefix("*.") && group.routeSignature.host.hasSuffix(String($0.hostPattern.dropFirst())))
            return hostMatches
                && $0.pathTemplate == group.routeSignature.pathTemplate
                && $0.requiredQueryKeys.sorted() == group.routeSignature.requiredQueryKeys.sorted()
        }) {
            return builtIn.titleTemplate
        }
        return group.currentFallbackTitle
    }
}
