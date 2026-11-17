import PasteoryCore
import SwiftUI

private struct AuthenticationRuleEditorRequest: Identifiable {
    let id = UUID()
    let group: LinkFailureGroup?
}

struct LinkResolutionSettingsView: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let onPrepareChrome: () -> Void

    @State private var selectedSection: LinkSettingsSection = .unresolved
    @State private var dateScope: LinkResolutionDateScope = .all
    @State private var selectedDay = Date()
    @State private var issueFilter: LinkResolutionIssueFilter = .all
    @State private var search = ""
    @State private var editingGroup: LinkFailureGroup?
    @State private var authenticationRequest: LinkAuthenticationRequest?
    @State private var authenticationRuleEditorRequest: AuthenticationRuleEditorRequest?
    @State private var pendingAuthenticationTarget: LinkAuthenticationTarget?
    @State private var rulePendingRemoval: URLFallbackRule?
    @State private var authenticatedRulePendingRemoval: AuthenticatedLinkRule?

    private enum LinkSettingsSection: String, CaseIterable, Identifiable {
        case all
        case unresolved
        case resolved
        case rules
        case connections

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: L10n.tr("全部链接")
            case .unresolved: L10n.tr("待处理")
            case .resolved: L10n.tr("已解析")
            case .rules: L10n.tr("兜底规则")
            case .connections: L10n.tr("连接")
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.tr("链接解析"), systemImage: "globe")
                    .font(.headline)
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSwitchRow(isOn: $settings.linkResolutionEnabled) {
                            Text(L10n.tr("自动访问网页并解析标题"))
                        }
                        Divider()
                    Text(L10n.tr("URL 识别和兜底标题始终在本机完成。打开后，Pasteory 才会访问目标网站获取真实标题。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Divider()
                        summary
                    }
                }
            }

            HStack(spacing: 12) {
                Picker(L10n.tr("内容"), selection: $selectedSection) {
                    ForEach(LinkSettingsSection.allCases) { section in Text(section.title).tag(section) }
                }
                .pickerStyle(.segmented)
                Button(L10n.tr("刷新记录")) { Task { await state.refreshLinkResolutionData() } }
                Button(L10n.tr("添加登录解析…")) {
                    authenticationRuleEditorRequest = AuthenticationRuleEditorRequest(group: nil)
                }
            }

            if selectedSection == .all || selectedSection == .unresolved || selectedSection == .resolved {
                filters
            }
            Group {
                switch selectedSection {
                case .all, .unresolved, .resolved: entriesList
                case .rules: rules
                case .connections: connections
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await state.refreshLinkResolutionData() }
        .onChange(of: settings.linkResolutionEnabled) { _, enabled in
            if enabled { Task { await state.refreshDueLinkSessions() } }
        }
        .onAppear {
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--debug-link-connections") {
                selectedSection = .connections
            }
            if arguments.contains("--debug-link-auth-editor") {
                let sampleURL = "https://code.byted.org/ugc-android/ByteX/merge_requests/912"
                let group = LinkFailureGroup(
                    routeSignature: URLRouteSignature(
                        host: "code.byted.org",
                        pathTemplate: "/ugc-android/ByteX/merge_requests/{segment4}"
                    ),
                    uniqueURLCount: 3,
                    clipCount: 4,
                    copyCount: 7,
                    attemptCount: 5,
                    failedAttemptCount: 5,
                    latestRequestState: .needsAuthentication,
                    latestTitleQuality: .loginOrError,
                    currentFallbackTitle: "ByteX MR · !912",
                    currentFallbackState: .matchedBuiltInRule,
                    sampleURL: sampleURL,
                    lastSeenAt: Date(),
                    lastAttemptAt: Date()
                )
                authenticationRuleEditorRequest = AuthenticationRuleEditorRequest(group: group)
            }
#endif
        }
        .sheet(item: $editingGroup) { group in
            FallbackRuleEditorSheet(group: group) { name, title in
                await state.createFallbackRule(for: group, name: name, titleTemplate: title)
            }
        }
        .sheet(item: $authenticationRequest) { request in
            SiteLoginSheet(request: request, cache: state.webCacheMaintenance) {
                state.linkSessionRefresh.markSignedIn(request.target)
                authenticationRequest = nil
                if let group = request.group {
                    Task { await state.retryAuthenticatedLinkResolution(group, using: request.target) }
                } else {
                    Task { await state.retryAuthenticatedLinkResolutions(for: request.target) }
                }
            }
        }
        .sheet(
            item: $authenticationRuleEditorRequest,
            onDismiss: {
                if let target = pendingAuthenticationTarget {
                    pendingAuthenticationTarget = nil
                    authenticationRequest = LinkAuthenticationRequest(target: target, group: nil)
                }
            }
        ) { request in
            AuthenticationRuleEditorSheet(
                seedGroup: request.group,
                groups: state.linkFailureGroups
            ) { name, pattern, startURL in
                guard let target = state.addAuthenticatedLinkRule(
                    name: name,
                    pattern: pattern,
                    startURL: startURL
                ) else { return false }
                pendingAuthenticationTarget = target
                return true
            }
        }
        .confirmationDialog(
            L10n.tr("移除兜底规则？"),
            isPresented: Binding(
                get: { rulePendingRemoval != nil },
                set: { if !$0 { rulePendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: rulePendingRemoval
        ) { rule in
            Button(L10n.tr("移除“\(rule.name)”"), role: .destructive) {
                Task { await state.removeFallbackRule(rule) }
                rulePendingRemoval = nil
            }
            Button(L10n.tr("取消"), role: .cancel) { rulePendingRemoval = nil }
        } message: { _ in
            Text(L10n.tr("受影响的链接会恢复为内置规则或通用 URL 兜底标题。"))
        }
        .confirmationDialog(
            L10n.tr("移除登录解析规则？"),
            isPresented: Binding(
                get: { authenticatedRulePendingRemoval != nil },
                set: { if !$0 { authenticatedRulePendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: authenticatedRulePendingRemoval
        ) { rule in
            Button(L10n.tr("移除“\(rule.name)”"), role: .destructive) {
                state.removeAuthenticatedLinkRule(rule)
                authenticatedRulePendingRemoval = nil
            }
            Button(L10n.tr("取消"), role: .cancel) { authenticatedRulePendingRemoval = nil }
        } message: { _ in
            Text(L10n.tr("以后命中的链接不会再自动使用登录会话，已保存的剪贴板记录不会删除。"))
        }
    }

    private var summary: some View {
        let entries = state.linkResolutionEntries
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                metric(L10n.tr("解析成功"), value: entries.filter { $0.resource.requestState == .resolved }.count, symbol: "checkmark.circle") {
                    selectedSection = .resolved; issueFilter = .all
                }
                metric(L10n.tr("待处理链接"), value: entries.filter { $0.resource.requestState != .resolved }.count, symbol: "exclamationmark.circle") {
                    selectedSection = .unresolved; issueFilter = .all
                }
                metric(L10n.tr("登录或验证"), value: entries.filter(\.needsLogin).count, symbol: "person.crop.circle.badge.exclamationmark") {
                    selectedSection = .unresolved; issueFilter = .needsLogin
                }
                metric(L10n.tr("无法访问"), value: entries.filter(\.cannotAccess).count, symbol: "link.badge.plus") {
                    selectedSection = .unresolved; issueFilter = .cannotAccess
                }
            }
            Text(L10n.tr("按具体链接统计最新结果。登录、权限、页面不存在和网络失败分别标记；保留旧标题不代表本次访问成功。"))
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    private func metric(_ title: String, value: Int, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(pasteoryAccentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(value)").font(.headline.monospacedDigit()).foregroundStyle(.primary)
                    Text(title).font(.caption2).foregroundStyle(.secondary)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker(L10n.tr("日期"), selection: $dateScope) {
                    ForEach(LinkResolutionDateScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 170)
                if dateScope == .selectedDay {
                    DatePicker(L10n.tr("日期"), selection: $selectedDay, displayedComponents: .date).labelsHidden()
                }
                Picker(L10n.tr("状态"), selection: $issueFilter) {
                    ForEach(LinkResolutionIssueFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 190)
                TextField(L10n.tr("搜索网址、标题或采集应用"), text: $search).textFieldStyle(.roundedBorder)
            }
            Text(L10n.tr("按最近一次解析日期分组；尚未请求的链接按收录日期分组。"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var filteredEntries: [LinkResolutionEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.linkResolutionEntries.filter { entry in
            let stateMatches = selectedSection == .all
                || (selectedSection == .unresolved && entry.resource.requestState != .resolved)
                || (selectedSection == .resolved && entry.resource.requestState == .resolved)
            return stateMatches && issueFilter.includes(entry)
                && dateScope.contains(entry.activityDate, selectedDay: selectedDay)
                && (query.isEmpty || ([entry.resource.displayTitle, URLFallbackEngine.redactedDisplayURL(entry.resource.normalizedURL)] + entry.sourceApplications)
                    .joined(separator: "\n").localizedCaseInsensitiveContains(query))
        }
    }

    private var entriesList: some View {
        Group {
            if filteredEntries.isEmpty {
                ContentUnavailableView(L10n.tr("没有符合条件的链接"), systemImage: "link",
                    description: Text(L10n.tr("可切换日期、状态或搜索条件。新链接的解析结果会出现在这里。")))
            } else {
                List {
                    ForEach(LinkResolutionDay.grouped(filteredEntries)) { day in
                        Section {
                            ForEach(day.entries) { entry in
                                let group = failureGroup(entry)
                                let target = URLFallbackEngine.normalizedWebURL(entry.resource.normalizedURL).flatMap {
                                    LinkAuthenticationTarget.matching(url: $0, customRules: settings.authenticatedLinkRules)
                                }
                                LinkResolutionEntryRow(entry: entry,
                                    isRetrying: state.linkResolutionBusyResourceIDs.contains(entry.id),
                                    onRetry: { state.reparseResolvedLink(ResolvedLinkSummary(resource: entry.resource, clipCount: entry.clipCount, copyCount: entry.copyCount)) },
                                    onAuthenticate: target.map { target in
                                        { authenticationRequest = LinkAuthenticationRequest(target: target, group: group) }
                                    },
                                    onConfigureAuthentication: { authenticationRuleEditorRequest = AuthenticationRuleEditorRequest(group: group) },
                                    onConfigureFallback: { editingGroup = group })
                            }
                        } header: {
                            HStack {
                                Text(day.id.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(L10n.language.locale)))
                                Spacer()
                                Text(L10n.tr("\(day.entries.count) 个链接"))
                            }.font(.caption)
                        }
                    }
                }.listStyle(.inset)
            }
        }
    }

    private func failureGroup(_ entry: LinkResolutionEntry) -> LinkFailureGroup {
        let resource = entry.resource
        return LinkFailureGroup(routeSignature: resource.routeSignature, uniqueURLCount: 1,
            clipCount: entry.clipCount, copyCount: entry.copyCount, attemptCount: resource.attemptCount,
            failedAttemptCount: resource.failedAttemptCount, latestRequestState: resource.requestState,
            latestTitleQuality: resource.titleQuality, currentFallbackTitle: resource.fallbackTitle,
            currentFallbackState: resource.fallbackState, sampleURL: resource.normalizedURL,
            lastSeenAt: resource.updatedAt, lastAttemptAt: resource.lastAttemptAt)
    }

    private var rules: some View {
        Group {
            if state.fallbackRules.isEmpty {
                ContentUnavailableView(
                    L10n.tr("还没有用户规则"),
                    systemImage: "wand.and.stars",
                    description: Text(L10n.tr("从“未解析”列表选择一组 URL，Pasteory 会根据样本生成匹配模板。"))
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
        let authenticationTargets = LinkAuthenticationTarget.all(customRules: settings.authenticatedLinkRules)
        return Form {
            Section(L10n.tr("Pasteory 登录会话")) {
                if !settings.linkResolutionEnabled {
                    Label(L10n.tr("自动解析已关闭，后台会话刷新已暂停。仍可手动刷新。"), systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(authenticationTargets) { target in
                    LinkSessionConnectionRow(target: target, refresh: state.linkSessionRefresh) {
                        authenticationRequest = LinkAuthenticationRequest(target: target, group: nil)
                    } onRemove: {
                        authenticatedRulePendingRemoval = target.customRule
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    Button(L10n.tr("添加登录解析…")) {
                        authenticationRuleEditorRequest = AuthenticationRuleEditorRequest(group: nil)
                    }
                }
                Text(L10n.tr("登录发生在 Pasteory 独立的 WebKit 会话中，不读取 Chrome Cookie。登录数据和 WebCrypto 钥匙串账户按 Bundle ID 隔离，正式包与 QA 包互不共享。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("按所选周期在后台访问登录入口，让网站处理会话续期。周期不代表 Token 有效期；检测到登录页后会暂停刷新，请重新登录。网络失败会在一小时后重试。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(L10n.tr("浏览器兼容标识"), value: chromeCompatibilityLabel)
            }
            Section("Google Chrome") {
                LabeledContent(L10n.tr("插件文件"), value: chromeStatus.extensionAvailable ? L10n.tr("已准备") : L10n.tr("缺失"))
                LabeledContent(L10n.tr("原生消息桥"), value: chromeStatus.nativeHostRegistered ? L10n.tr("已注册") : L10n.tr("未注册"))
                if let lastContactAt = chromeStatus.lastContactAt {
                    LabeledContent(L10n.tr("最近连接"), value: lastContactAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.language.locale)))
                } else {
                    LabeledContent(L10n.tr("最近连接"), value: L10n.tr("尚未连接"))
                }
                HStack {
                    Spacer(minLength: 0)
                    Button(L10n.tr("准备 Chrome 插件…"), action: onPrepareChrome)
                }
                .frame(maxWidth: .infinity)
                Text(L10n.tr("浏览器插件负责从已登录的 Chrome 页面获取复制上下文；Pasteory WebKit 登录会话负责解析从其他应用复制来的受保护 URL。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.tr("访问边界")) {
                Label(L10n.tr("普通请求不携带 Cookie；命中登录解析规则且已有会话时才使用 WebKit"), systemImage: "lock.shield")
                Label(L10n.tr("登录解析只保存 URL、标题候选和诊断状态，不保存网页正文"), systemImage: "doc.badge.ellipsis")
                Label(L10n.tr("localhost、局域网 IP 和高风险操作路径会被拦截"), systemImage: "network.badge.shield.half.filled")
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
        guard let range = LinkWebKitConfiguration.compatibilityUserAgent.range(of: marker) else { return L10n.tr("Chrome 兼容") }
        let version = LinkWebKitConfiguration.compatibilityUserAgent[range.upperBound...].split(separator: " ").first ?? ""
        return "Chrome \(version)"
    }
}

private struct LinkSessionConnectionRow: View {
    @Environment(\.pasteoryAccentColor) private var accent
    let target: LinkAuthenticationTarget
    @ObservedObject var refresh: LinkSessionRefreshService
    let onSignIn: () -> Void
    let onRemove: () -> Void

    private func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.language.locale))
    }

    var body: some View {
        let record = refresh.record(for: target)
        let signedInAt = refresh.lastSignedInAt(target)
        let refreshing = refresh.refreshingTargetIDs.contains(target.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.key").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title).font(.headline)
                    Text(target.domainDescription).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if refreshing {
                    ProgressView().controlSize(.small)
                }
                Button(L10n.tr("立即刷新")) { Task { await refresh.refresh(target) } }
                    .disabled(signedInAt == nil || refreshing)
                Button(signedInAt == nil ? L10n.tr("登录…") : L10n.tr("更新登录…"), action: onSignIn)
                if target.customRule != nil {
                    Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 18) {
                Toggle(L10n.tr("自动刷新"), isOn: Binding(
                    get: { refresh.record(for: target).automatic },
                    set: { refresh.setAutomatic($0, for: target) }
                ))
                .toggleStyle(.switch)
                .fixedSize()
                Picker(L10n.tr("刷新周期"), selection: Binding(
                    get: { refresh.record(for: target).interval },
                    set: { refresh.setInterval($0, for: target) }
                )) {
                    ForEach(LinkSessionRefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .frame(width: 180)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                if let signedInAt {
                    Text(L10n.tr("上次登录：\(dateText(signedInAt))"))
                } else {
                    Text(L10n.tr("尚未建立登录会话"))
                }
                if let attempted = record.lastAttemptAt {
                    Text(L10n.tr("上次刷新：\(dateText(attempted)) · \(refreshing ? L10n.tr("正在刷新…") : record.outcome?.title ?? L10n.tr("未完成"))"))
                        .foregroundStyle(record.outcome == .needsAuthentication ? .orange : .secondary)
                }
                if let next = refresh.nextRefreshAt(target) {
                    Text(L10n.tr("下次刷新：\(dateText(next))"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct AuthenticationRuleEditorSheet: View {
    let seedGroup: LinkFailureGroup?
    let groups: [LinkFailureGroup]
    let onSave: (String, String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var pattern: String
    @State private var startURL: String
    @State private var lastSuggestedStartURL: String
    @State private var isSaving = false

    init(
        seedGroup: LinkFailureGroup?,
        groups: [LinkFailureGroup],
        onSave: @escaping (String, String, String) async -> Bool
    ) {
        self.seedGroup = seedGroup
        self.groups = groups
        self.onSave = onSave
        let suggestedPattern = seedGroup.map {
            AuthenticatedLinkPattern.suggestedPattern(for: $0.routeSignature)
        } ?? ""
        let samples = groups.map(\.sampleURL)
        let suggestedStartURL = AuthenticatedLinkPattern.inferredStartURL(
            pattern: suggestedPattern,
            sampleURLs: samples
        )?.absoluteString ?? ""
        _name = State(initialValue: seedGroup?.routeSignature.host ?? "")
        _pattern = State(initialValue: suggestedPattern)
        _startURL = State(initialValue: suggestedStartURL)
        _lastSuggestedStartURL = State(initialValue: suggestedStartURL)
    }

    private var availableGroups: [LinkFailureGroup] {
        guard let seedGroup,
              !groups.contains(where: { $0.routeSignature.key == seedGroup.routeSignature.key }) else { return groups }
        return [seedGroup] + groups
    }
    private var sampleURLs: [String] { availableGroups.map(\.sampleURL) }
    private var matchingGroups: [LinkFailureGroup] {
        availableGroups.filter { group in
            guard let url = URLFallbackEngine.normalizedWebURL(group.sampleURL) else { return false }
            return AuthenticatedLinkPattern.matches(pattern, url: url)
        }
    }
    private var matchingURLCount: Int { matchingGroups.reduce(0) { $0 + $1.uniqueURLCount } }
    private var patternError: String? { AuthenticatedLinkPattern.validationError(pattern) }
    private var normalizedStartURL: URL? { URLFallbackEngine.normalizedWebURL(startURL) }
    private var canSave: Bool {
        !isSaving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && patternError == nil
            && normalizedStartURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("添加登录解析")).font(.title2.bold())
            Text(L10n.tr("这里只配置需要登录的网站。普通网页仍会自动匿名解析，不需要逐条添加。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                TextField(L10n.tr("规则名称"), text: $name)
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent(L10n.tr("匹配正则")) {
                        TextField("^code\\.byted\\.org/.+$", text: $pattern)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minWidth: 440)
                    }
                    Text(L10n.tr("匹配范围是 host + path，可以直接写正则，不需要输入 https://。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let patternError, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(patternError).font(.caption).foregroundStyle(.red)
                    }
                }
                TextField(L10n.tr("登录入口"), text: $startURL)
                LabeledContent(L10n.tr("当前覆盖"), value: L10n.tr("\(matchingGroups.count) 组，\(matchingURLCount) 个链接"))
                if let sample = matchingGroups.first?.sampleURL {
                    LabeledContent(L10n.tr("命中示例"), value: sample)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }
                Button(L10n.tr("保存并登录")) { save() }
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 760, height: 450)
        .onChange(of: pattern) { _, value in
            let suggested = AuthenticatedLinkPattern.inferredStartURL(
                pattern: value,
                sampleURLs: sampleURLs
            )?.absoluteString ?? ""
            if startURL.isEmpty || startURL == lastSuggestedStartURL {
                startURL = suggested
            }
            lastSuggestedStartURL = suggested
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let host = URLFallbackEngine.normalizedWebURL(suggested)?.host {
                name = host
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            if await onSave(name, pattern, startURL) { dismiss() }
            isSaving = false
        }
    }
}

private struct LinkFailureGroupRow: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
    let group: LinkFailureGroup
    let isRetrying: Bool
    let onRetry: () -> Void
    let onAuthenticate: (() -> Void)?
    let onConfigureAuthentication: () -> Void
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
            Text(L10n.tr("\(group.uniqueURLCount) 个 URL · \(group.clipCount) 条记录 · 复制 \(group.copyCount) 次 · 解析 \(group.attemptCount) 次"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(L10n.tr("当前兜底"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(group.currentFallbackTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(group.currentFallbackState.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(pasteoryAccentColor.opacity(0.1), in: Capsule())
                Spacer()
                Button(isRetrying ? L10n.tr("解析中…") : L10n.tr("重新解析"), action: onRetry).disabled(isRetrying)
                if let onAuthenticate {
                    Button(L10n.tr("登录并解析"), action: onAuthenticate).disabled(isRetrying)
                } else {
                    Button(L10n.tr("添加登录解析"), action: onConfigureAuthentication).disabled(isRetrying)
                }
                Button(L10n.tr("配置兜底"), action: onConfigureFallback)
            }
            Text(group.sampleURL).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.vertical, 5)
    }

    private var statusColor: Color {
        switch group.latestRequestState {
        case .needsAuthentication, .verificationRequired, .forbidden: .orange
        case .genericTitle, .missingTitle: pasteoryAccentColor
        default: .red
        }
    }
}

private struct ResolvedLinkRow: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
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
                Text(resource.resolutionSource?.displayName ?? L10n.tr("未知来源"))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(pasteoryAccentColor.opacity(0.1), in: Capsule())
                Text(L10n.tr("\(summary.clipCount) 条记录 · 复制 \(summary.copyCount) 次 · 解析 \(resource.attemptCount) 次"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastAttemptAt = resource.lastAttemptAt {
                    Text(L10n.tr("最近 \(lastAttemptAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.language.locale)))"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(isRetrying ? L10n.tr("解析中…") : L10n.tr("重新解析"), action: onRetry)
                    .disabled(isRetrying)
            }
        }
        .padding(.vertical, 5)
    }

    private var statusText: String {
        resource.requestState == .resolved
            ? resource.titleQuality.displayName
            : L10n.tr("最近重试失败 · \(resource.requestState.displayName)")
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
            Text(L10n.tr("创建兜底规则")).font(.title2.bold())
            Text(L10n.tr("Pasteory 已根据失败样本生成匹配模板。保存前请确认范围和标题。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                LabeledContent(L10n.tr("匹配网站"), value: group.routeSignature.host)
                LabeledContent(L10n.tr("路径模板"), value: group.routeSignature.pathTemplate)
                if !group.routeSignature.requiredQueryKeys.isEmpty {
                    LabeledContent(L10n.tr("要求参数"), value: group.routeSignature.requiredQueryKeys.joined(separator: "、"))
                }
                TextField(L10n.tr("规则名称"), text: $name)
                TextField(L10n.tr("兜底标题"), text: $titleTemplate)
                if !availableVariables.isEmpty {
                    LabeledContent(L10n.tr("可用变量"), value: availableVariables.joined(separator: "、"))
                }
                LabeledContent(L10n.tr("影响范围"), value: L10n.tr("\(group.uniqueURLCount) 个 URL，\(group.clipCount) 条记录"))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }
                Button(L10n.tr("保存")) {
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
        let path = group.routeSignature.pathTemplate.split(separator: "/").last.map(String.init) ?? L10n.tr("链接")
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
