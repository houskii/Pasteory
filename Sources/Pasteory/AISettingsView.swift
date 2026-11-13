import Charts
import PasteoryAI
import PasteoryCore
import SwiftUI

struct AISettingsView: View {
    private enum Tab: String, CaseIterable {
        case connection, analysis, lifecycle, usage
        var title: String {
            switch self {
            case .connection: L10n.tr("模型连接")
            case .analysis: L10n.tr("分析策略")
            case .lifecycle: L10n.tr("生命周期与压缩")
            case .usage: L10n.tr("用量与整理记录")
            }
        }
    }
    @ObservedObject var controller: AIOrganizationController
    @State private var draft: AIConfiguration
    @State private var credential: String
    @State private var tab: Tab = .connection
    @State private var saveError: String?

    init(controller: AIOrganizationController) {
        self.controller = controller
        _draft = State(initialValue: controller.settings.aiConfiguration)
        _credential = State(initialValue: (try? AICredentialStore.load()) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.tr("AI 整理设置"), selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 22).padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = saveError ?? controller.error {
                        Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if !controller.status.isEmpty {
                        HStack { if controller.running { ProgressView().controlSize(.small) }; Text(controller.status).font(.caption).foregroundStyle(.secondary); Spacer() }
                    }
                    switch tab {
                    case .connection: connection
                    case .analysis: analysis
                    case .lifecycle: lifecycle
                    case .usage: usage
                    }
                }.padding(22)
            }
            Divider()
            HStack {
                if controller.running {
                    Text(controller.checkpointProgress).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button(L10n.tr("暂停分析")) { controller.pause() }
                } else if controller.state.checkpoint != nil {
                    Button(L10n.tr("继续上次任务")) { controller.analyze(resume: true) }
                    Button(L10n.tr("放弃上次任务")) { Task { await controller.discardCheckpoint() } }
                }
                Spacer()
                if controller.pending != nil { Button(L10n.tr("检查整理建议")) { controller.showingReview = true } }
                Button(L10n.tr("保存配置")) { save() }.buttonStyle(.borderedProminent)
            }.padding(16)
        }
        .sheet(isPresented: $controller.showingReview) { AIReviewView(controller: controller) }
        .onChange(of: controller.models) { _, models in
            draft.supportedReasoningLevels = models.first { $0.id == draft.model }?.reasoningLevels ?? []
            if !draft.supportedReasoningLevels.contains(draft.reasoning) { draft.reasoning = "auto" }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            AISettingsCard(title: L10n.tr("模型连接")) {
                Toggle(L10n.tr("启用 AI 整理"), isOn: $draft.enabled).toggleStyle(.switch)
                Text(L10n.tr("启用后，允许的标题、正文片段、备注、来源与时间会发送到所选模型。通过本机 Magpie 仍可能转发到云端。"))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L10n.tr("连接方式"), selection: $draft.provider) {
                    Text("Magpie").tag(AIConfiguration.Provider.magpie)
                    Text(L10n.tr("OpenAI 兼容接口")).tag(AIConfiguration.Provider.openAICompatible)
                    Text("Ollama").tag(AIConfiguration.Provider.ollama)
                }.onChange(of: draft.provider) { _, provider in
                    switch provider {
                    case .magpie: draft.endpoint = "http://127.0.0.1:3425/v1"
                    case .ollama: draft.endpoint = "http://127.0.0.1:11434/v1"
                    case .openAICompatible: draft.endpoint = "https://api.openai.com/v1"
                    }
                }
                TextField("Base URL", text: $draft.endpoint).textFieldStyle(.roundedBorder)
                SecureField(L10n.tr("API 密钥或网关凭据"), text: $credential).textFieldStyle(.roundedBorder)
                Text(L10n.tr("凭据仅保存在 macOS 钥匙串，不写入设置、日志或备份。本机无鉴权接口可以留空。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(L10n.tr("模型 ID"), text: $draft.model).textFieldStyle(.roundedBorder)
                        .onChange(of: draft.model) { _, model in
                            draft.supportedReasoningLevels = controller.models.first { $0.id == model }?.reasoningLevels ?? []
                            draft.reasoning = "auto"
                        }
                    if !controller.models.isEmpty {
                        Menu(L10n.tr("选择模型")) {
                            ForEach(controller.models) { model in Button(model.id) { draft.model = model.id; draft.supportedReasoningLevels = model.reasoningLevels } }
                        }
                    }
                    Button(L10n.tr("获取模型")) { Task { await controller.fetchModels(configuration: draft, credential: credential) } }
                }
                Picker(L10n.tr("推理强度"), selection: $draft.reasoning) {
                    Text(L10n.tr("自动" )).tag("auto")
                    ForEach(draft.supportedReasoningLevels, id: \.self) { Text($0).tag($0) }
                }
                Text(L10n.tr("只展示接口已声明的推理档位。未知或不支持时，自动模式不发送推理参数。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(L10n.tr("测试连接")) { Task { await controller.test(configuration: draft, credential: credential) } }.disabled(controller.running) }
            }
            AISettingsCard(title: L10n.tr("整理偏好 Prompt")) {
                TextEditor(text: $draft.prompt).font(.body).frame(minHeight: 150)
                    .padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Text(L10n.tr("可调整主题、组织方式与输出语言。原文保护、读取范围和原子能力由应用校验。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(L10n.tr("恢复默认 Prompt")) { draft.prompt = AIConfiguration.defaultPrompt } }
            }
        }
    }

    private var analysis: some View {
        VStack(alignment: .leading, spacing: 16) {
            AISettingsCard(title: L10n.tr("分析范围与触发")) {
                Stepper(value: $draft.topN, in: 1...500, step: 10) { Text(L10n.tr("最近内容 Top N：\(draft.topN)")) }
                Stepper(value: $draft.batchSize, in: 1...100, step: 5) { Text(L10n.tr("每批最多：\(draft.batchSize) 条")) }
                Text(L10n.tr("按最近复制时间取不同内容。全库任务也按批次处理，保存进度；不会一次发送整个资料库。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.tr("新增内容后分析"), isOn: $draft.analyzeNew).toggleStyle(.switch)
                Text(L10n.tr("连续复制等待 30 秒；累计 5 条或等待 2 分钟进入队列；自动分析至少间隔 5 分钟。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.tr("定时检查变化"), isOn: $draft.timerEnabled).toggleStyle(.switch)
                Stepper(value: $draft.intervalMinutes, in: 1...1440, step: 5) { Text(L10n.tr("检查间隔：\(draft.intervalMinutes) 分钟")) }
                Toggle(L10n.tr("分析用户备注"), isOn: $draft.includeNotes).toggleStyle(.switch)
                Toggle(L10n.tr("分析来源应用名称"), isOn: $draft.includeSource).toggleStyle(.switch)
                Text(L10n.tr("图片和文件仅发送元数据；逐条禁止 AI 的资料及已识别的密钥不参与分析。应用退出或休眠时不运行定时任务。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            AISettingsCard(title: L10n.tr("结果应用方式")) {
                Picker(L10n.tr("应用方式"), selection: $draft.applyMode) {
                    Text(L10n.tr("先检查，再应用")).tag(AIConfiguration.ApplyMode.preview)
                    Text(L10n.tr("自动补充已有 AI 分组")).tag(AIConfiguration.ApplyMode.appendExisting)
                }
                Text(L10n.tr("新分组、聚合和移出操作仍进入预览。用户的主题定义与手动成员受到保护。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(L10n.tr("分批整理全库")) { if save() { controller.analyze(all: true) } }.disabled(controller.running)
                    Button(L10n.tr("分析最近内容")) { if save() { controller.analyze() } }.disabled(controller.running)
                }
            }
            AISettingsCard(title: L10n.tr("预算与调用上限")) {
                Stepper(value: $draft.dailyTokenLimit, in: 1000...10_000_000, step: 10_000) { Text(L10n.tr("每日 token 上限：\(draft.dailyTokenLimit)")) }
                Stepper(value: $draft.dailyAutomaticRuns, in: 1...1000) { Text(L10n.tr("每日自动任务最多：\(draft.dailyAutomaticRuns) 次")) }
                Stepper(value: $draft.maxInputTokens, in: 1000...128_000, step: 1000) { Text(L10n.tr("单次输入预算：\(draft.maxInputTokens) tokens")) }
                Stepper(value: $draft.maxOutputTokens, in: 256...16_384, step: 256) { Text(L10n.tr("单次输出上限：\(draft.maxOutputTokens) tokens")) }
                Text(L10n.tr("每次请求先预留预算。失败或超时的未知用量保守估算，不显示为零。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var lifecycle: some View {
        VStack(alignment: .leading, spacing: 16) {
            AISettingsCard(title: L10n.tr("内容生命周期")) {
                Toggle(L10n.tr("启用内容生命周期"), isOn: $draft.lifecycleEnabled).toggleStyle(.switch)
                Picker(L10n.tr("策略预设"), selection: Binding(get: { draft.lifecycle.preset }, set: { value in
                    if value != .custom { draft.lifecycle = .preset(value) }
                })) {
                    ForEach(LifecyclePreset.allCases) { Text(L10n.text($0.title)).tag($0) }
                }
                Text(L10n.tr("活跃、留存、归档由内容本身的使用记录计算。分组根据成员活跃系数汇总，不单独计时。"))
                    .font(.caption).foregroundStyle(.secondary)
                dayStepper(L10n.tr("降权节点"), value: $draft.lifecycle.deprioritizeDays)
                dayStepper(L10n.tr("压缩候选节点"), value: $draft.lifecycle.compressionDays)
                dayStepper(L10n.tr("归档候选节点"), value: $draft.lifecycle.archiveDays)
                Text(L10n.tr("标准策略为 7 / 14 / 60 天。时间节点不会自动删除资料，收藏和置顶继续保护内容。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            AISettingsCard(title: L10n.tr("计算指标")) {
                metric(L10n.tr("最近使用程度"), value: $draft.lifecycle.recencyWeight)
                metric(L10n.tr("使用频率"), value: $draft.lifecycle.frequencyWeight)
                metric(L10n.tr("不同日期的持续使用"), value: $draft.lifecycle.activeDaysWeight)
                Stepper(value: $draft.lifecycle.frequencyWindowDays, in: 1...366) { Text(L10n.tr("频率统计窗口：\(draft.lifecycle.frequencyWindowDays) 天")) }
                Text(L10n.tr("权重为 0 时关闭该指标，其余权重自动归一化。AI 更新概况、调整分组不刷新使用时间。"))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L10n.tr("事件权重与分组汇总")) {
                    VStack(spacing: 12) {
                        metric(L10n.tr("复制权重"), value: $draft.lifecycle.copyWeight, maximum: 5)
                        metric(L10n.tr("成功粘贴权重"), value: $draft.lifecycle.pasteWeight, maximum: 5)
                        metric(L10n.tr("显式打开权重"), value: $draft.lifecycle.openWeight, maximum: 5)
                        metric(L10n.tr("用户编辑权重"), value: $draft.lifecycle.editWeight, maximum: 5)
                        Stepper(value: $draft.lifecycle.topK, in: 1...100) { Text(L10n.tr("分组最活跃成员数量：\(draft.lifecycle.topK)")) }
                        metric(L10n.tr("Top K 在分组系数中的权重"), value: $draft.lifecycle.topKWeight)
                        metric(L10n.tr("活跃分组阈值"), value: $draft.lifecycle.activeThreshold)
                        metric(L10n.tr("归档分组阈值"), value: $draft.lifecycle.archiveThreshold)
                    }.padding(.top, 10)
                }
            }
            AISettingsCard(title: L10n.tr("无损压缩与共享引用")) {
                Toggle(L10n.tr("自动压缩符合条件的资料"), isOn: $draft.automaticCompression).toggleStyle(.switch)
                Text(L10n.tr("同一材料在多个分组共享一份原文。压缩包持有可恢复副本；只有原文引用归零、压缩校验通过后才回收原文载荷。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.tr("摘要与无损载荷分别保存。元数据、搜索预览和其他分组关系保留，打开时按需恢复。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(L10n.tr("压缩符合条件的资料")) { if save() { Task { await controller.compress(groupID: nil) } } }.disabled(controller.storageBusy || controller.running) }
            }
        }
        .onChange(of: draft.lifecycle.deprioritizeDays) { _, _ in markCustom() }
        .onChange(of: draft.lifecycle.compressionDays) { _, _ in markCustom() }
        .onChange(of: draft.lifecycle.archiveDays) { _, _ in markCustom() }
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                metricTile(L10n.tr("今日总量"), value: controller.todayTokens.formatted())
                metricTile(L10n.tr("输入 tokens"), value: controller.todayUsage.reduce(0) { $0 + $1.inputTokens }.formatted())
                metricTile(L10n.tr("输出 tokens"), value: controller.todayUsage.reduce(0) { $0 + $1.outputTokens }.formatted())
                metricTile(L10n.tr("估算费用"), value: estimatedCost)
            }
            AISettingsCard(title: L10n.tr("今日预算")) {
                ProgressView(value: Double(controller.todayTokens), total: Double(max(1, draft.dailyTokenLimit)))
                Text("\(controller.todayTokens.formatted()) / \(draft.dailyTokenLimit.formatted()) tokens").font(.caption.monospacedDigit())
                Text(L10n.tr("缓存是输入子集，推理可能是输出子集，均不重复加总。混合计量包含服务商返回与本地估算。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            AISettingsCard(title: L10n.tr("近 7 天用量")) {
                Chart(dailyUsage) { day in BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.tokens)) }
                    .frame(height: 150).foregroundStyle(controller.settings.themeColor.accentColor)
            }
            AISettingsCard(title: L10n.tr("费用估算单价")) {
                Text(L10n.tr("单位为 USD / 百万 tokens。留空时费用显示横线；订阅额度不换算成账单。单价随调用保存。"))
                    .font(.caption).foregroundStyle(.secondary)
                price(L10n.tr("普通输入"), value: $draft.inputPricePerMillion)
                price(L10n.tr("缓存读取"), value: $draft.cachedPricePerMillion)
                price(L10n.tr("输出"), value: $draft.outputPricePerMillion)
            }
            AISettingsCard(title: L10n.tr("最近调用")) {
                if controller.state.usage.isEmpty { Text(L10n.tr("尚无模型调用记录")).foregroundStyle(.secondary) }
                ForEach(controller.state.usage.suffix(30).reversed()) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.requestedModel).font(.caption.weight(.medium)).lineLimit(1)
                            Text(item.date.formatted(date: .abbreviated, time: .shortened) + " · " + item.trigger).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(item.inputTokens) / \(item.outputTokens)").font(.caption.monospacedDigit())
                            Text(item.estimated ? L10n.tr("本地估算") : L10n.tr("服务商计量")).font(.caption2).foregroundStyle(item.succeeded ? Color.secondary : Color.orange)
                        }
                    }
                    Divider()
                }
            }
            if controller.latestUndoable != nil {
                HStack { Spacer(); Button(L10n.tr("撤销最近一次整理")) { Task { await controller.undo() } }.disabled(controller.running) }
            }
        }
    }

    private var estimatedCost: String {
        let items = controller.todayUsage
        guard !items.isEmpty, items.allSatisfy({ $0.cost != nil }) else { return "—" }
        return String(format: "$%.4f", items.compactMap(\.cost).reduce(0, +))
    }
    private struct DailyUsage: Identifiable { let date: Date; let tokens: Int; var id: Date { date } }
    private var dailyUsage: [DailyUsage] {
        let calendar = Calendar.current, start = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: start)!
            let total = controller.state.usage.filter { calendar.isDate($0.date, inSameDayAs: date) }.reduce(0) { $0 + $1.totalTokens }
            return DailyUsage(date: date, tokens: total)
        }
    }
    private func dayStepper(_ label: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: 1...3650, step: 1) { HStack { Text(label); Spacer(); Text(L10n.tr("\(Int(value.wrappedValue)) 天")).monospacedDigit().foregroundStyle(.secondary) } }
    }
    private func metric(_ label: String, value: Binding<Double>, maximum: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label); Spacer(); Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: 0...maximum, step: 0.05).onChange(of: value.wrappedValue) { _, _ in markCustom() }
        }.font(.callout)
    }
    private func price(_ label: String, value: Binding<Double?>) -> some View {
        HStack { Text(label); Spacer(); TextField("—", value: value, format: .number.precision(.fractionLength(0...6))).textFieldStyle(.roundedBorder).frame(width: 150) }
    }
    private func metricTile(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
    private func markCustom() {
        guard draft.lifecycle.preset != .custom else { return }
        var comparison = draft.lifecycle; comparison.version = 1
        if comparison != LifecyclePolicy.preset(comparison.preset) { draft.lifecycle.preset = .custom }
    }
    @discardableResult private func save() -> Bool {
        do { try controller.save(configuration: draft, credential: credential); saveError = nil; return true }
        catch { saveError = error.localizedDescription; return false }
    }
}

struct AISettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 13) { Text(title).font(.headline); content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.35)))
    }
}
