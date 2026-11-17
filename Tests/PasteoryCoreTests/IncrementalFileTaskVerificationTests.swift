import Foundation
import PasteoryAI
import PasteoryCore
import Testing
@testable import Pasteory

private actor IncrementalVerificationTransport: AIChatTransport {
    let live: Bool
    let root: URL
    var requestCount = 0
    init(live: Bool, root: URL) { self.live = live; self.root = root }
    func completion(body: Data, configuration: AIConfiguration, credential: String) async throws -> Data {
        requestCount += 1
        try body.write(to: root.appendingPathComponent(String(format: "request-%03d.json", requestCount)))
        if live { return try await OpenAICompatibleClient().completion(body: body, configuration: configuration, credential: credential) }
        if requestCount > 2 {
            let request = try JSONDecoder().decode(JSONValue.self, from: body)
            throw AIError.invalid(request["messages"].array?.last?["content"].string ?? "Unexpected validation retry")
        }
        let message: AIChatMessage
        if requestCount == 1 {
            let script = """
            python3 - <<'PY'
            import json,pathlib
            p=pathlib.Path('.')
            data=json.loads((p/'items.json').read_text())
            profiles=json.loads((p/'existing/groups.json').read_text())
            names=['Pasteory','AppPilot']
            chosen=[next(x for x in profiles if x['name']==name) for name in names]
            groups=[{'key':x['name'],'name':x['name'],'definition':x['definition'],'existing_group_id':x['id'],'overview':'Do not overwrite the old overview','overview_source_item_ids':[next(v['item_id'] for v in data['items'] if x['name'] in v['body'])]} for i,x in enumerate(chosen)]
            assignments=[{'item_id':x['item_id'],'group_keys':[next((name for name in names if name in x['body']), '')] if any(name in x['body'] for name in names) else [],'reason':'匹配已有项目' if any(name in x['body'] for name in names) else '与现有软件项目无关，证据不足以创建新组'} for x in data['items']]
            (p/'output/plan.json').write_text(json.dumps({'task_id':data['task_id'],'preserve_existing_memberships':True,'groups':groups,'assignments':assignments}))
            PY
            """
            message = AIChatMessage(role: "assistant", toolCalls: [AIToolCall(id: "classify-new-input", name: "task_exec", arguments: JSONValue.object(["command": .string(script)]).encoded)])
        } else { message = AIChatMessage(role: "assistant", content: "output/plan.json complete") }
        return try JSONEncoder().encode(JSONValue.object(["model": .string(configuration.model), "choices": .array([.object(["message": try .value(message)])]), "usage": .object(["prompt_tokens": .number(1000), "completion_tokens": .number(100)])]))
    }
}

@MainActor private func verifyIncrementalFileTask(live: Bool) async throws {
    let explicitRoot = ProcessInfo.processInfo.environment["PASTEORY_INCREMENTAL_LIVE_ROOT"]
    let dirs = try AppDirectories(root: live ? URL(fileURLWithPath: try #require(explicitRoot)) : FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let suite = "IncrementalFileVerification." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); if !live { try? FileManager.default.removeItem(at: dirs.root) } }
    let repo = try SQLiteClipRepository(databaseURL: dirs.databaseFile), settings = AppSettings(defaults: defaults)
    var config = AIConfiguration()
    if live {
        let stored = try #require(UserDefaults(suiteName: "app.pasteory.Pasteory")?.data(forKey: "aiOrganizationConfiguration.v1"))
        config = try JSONDecoder().decode(AIConfiguration.self, from: stored)
    }
    config.enabled = true; config.analyzeNew = true; config.topN = 1000; config.maxInputTokens = 128_000
    config.maxOutputTokens = 8000; config.dailyTokenLimit = 2_000_000; config.agentRoundLimit = 30
    config.applyMode = live ? .preview : .appendExisting
    if !live { config.model = "synthetic-file-agent" }
    settings.aiConfiguration = config
    let names = ["Pasteory", "AppPilot", "KAL", "Android", "Harmony", "KMP", "研发基础设施"]
    var catalog = [UUID: AIGroupProfile]()
    func clip(_ text: String) throws -> Clip {
        try #require(ClipClassifier.makeClip(from: PasteboardCapture(items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data(text.utf8))])], source: .init(appName: "Synthetic verification", bundleIdentifier: "test.incremental.files", confidence: .high))))
    }
    for name in names {
        let old = try (0..<3).map { try clip("\(name) existing reference \($0)") }; try await repo.saveBatch(old)
        var group = AIGroupProfile(name: name, definition: name + " 项目专属开发、测试与使用资料；不收录其他项目或生活内容。")
        group.overview = name + " 的已有完整概况"; group.memberIDs = Set(old.map(\.id)); group.aiMemberIDs = group.memberIDs
        catalog[group.id] = group
        try await repo.saveCollection(ClipCollection(id: group.id, name: name, kind: .normal))
        try await repo.saveBatch(old.map { original in var copy = original; copy.collectionIDs.insert(group.id); return copy })
    }
    let savedCatalog = catalog
    try await repo.updateAIState { $0.groups = savedCatalog }
    let texts = ["Pasteory：图片 OCR 列表要显示两行，图片元数据合并。", "Pasteory：新增内容只需要传新资料和已有分组。", "Pasteory：分析设置 Top N 每次调整 100。", "AppPilot：补充设备状态检查和统一动作协议。", "早餐烘焙：可颂面团冷藏后再整形，周末试一次。"]
    let newClips = try texts.map(clip); try await repo.saveBatch(newClips)
    let transport = IncrementalVerificationTransport(live: live, root: dirs.root)
    let controller = AIOrganizationController(repository: repo, settings: settings, transport: transport, credentialProvider: { live ? try AICredentialStore.load() : "synthetic" }, directories: dirs)
    try await controller.reload()
    let now = Date(); controller.clock = { now.addingTimeInterval(-40) }
    for clip in newClips { controller.contentChanged(clip.id) }
    await controller.waitUntilIdle(); controller.clock = { now }
    let started = Date(); await controller.tick(); await controller.waitUntilIdle()
    #expect(controller.error == nil)
    guard controller.error == nil else { throw AIError.invalid(controller.error!) }
    let directory = try #require(controller.latestTaskDirectory)
    let input = try JSONDecoder().decode(AIFileTaskInput.self, from: Data(contentsOf: directory.appendingPathComponent("items.json")))
    let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent("task.json")))
    let exportedGroups = try JSONDecoder().decode([AIGroupProfile].self, from: Data(contentsOf: directory.appendingPathComponent("existing/groups.json")))
    let plan = try AIFileTaskPlan.decode(Data(contentsOf: directory.appendingPathComponent("output/plan.json")))
    #expect(input.items.count == 5 && Set(input.items.map(\.clipID)) == Set(newClips.map(\.id)))
    #expect(exportedGroups.count == 7 && manifest["trigger"].string == "new")
    #expect(manifest["task_kind"].string == "incremental_classification")
    #expect(controller.state.usage.allSatisfy { $0.runID == input.taskID && $0.trigger == "new" })
    #expect(AIUsageTaskPresentation.grouped(controller.state.usage).count == 1)
    #expect(controller.state.groups.count == 7 && controller.state.automation.dirty.isEmpty)
    #expect(controller.state.groups.values.allSatisfy { $0.overview == savedCatalog[$0.id]?.overview })
    #expect(plan.assignments.count == 5 && plan.groups.allSatisfy { $0.existingGroupID != nil })
    let assigned = plan.assignments.filter { !$0.groupKeys.isEmpty }.count
    #expect(assigned == 4)
    if live {
        let report: [String: Any] = ["task_id": input.taskID.uuidString, "directory": directory.path,
            "model": config.model, "reasoning": config.reasoning, "library_count": 26, "new_input_count": 5,
            "existing_groups": 7, "model_requests": await transport.requestCount, "assigned_count": assigned,
            "unassigned_count": 5 - assigned, "automatic_applied": false, "elapsed_seconds": Date().timeIntervalSince(started),
            "usage_records": controller.state.usage.count, "task_rows_in_recent_calls": AIUsageTaskPresentation.grouped(controller.state.usage).count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: dirs.root.appendingPathComponent("verification.json"))
        print("INCREMENTAL_LIVE_VERIFICATION " + JSONValue.object(report.mapValues { value in
            if let n = value as? Int { return .number(Double(n)) }; return .string(String(describing: value))
        }).encoded)
    }
}

@Test @MainActor func fileIncrementalUsesOnlyDirtyContentKeepsCatalogAndGroupsUsageByTask() async throws {
    try await verifyIncrementalFileTask(live: false)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PASTEORY_INCREMENTAL_LIVE_ROOT"] != nil)) @MainActor
func localIncrementalFileTaskLiveVerification() async throws {
    try await verifyIncrementalFileTask(live: true)
}
