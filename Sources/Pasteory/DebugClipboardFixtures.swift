#if DEBUG
import AppKit
import PasteoryAI
import PasteoryCore

@MainActor
struct DebugClipboardFixtures {
    let state: AppState
    let settings: AppSettings

    private func seedReadmeData() async {
        func localized(_ english: String, _ chinese: String) -> String {
            settings.appLanguage == .english ? english : chinese
        }
        func accept(_ uti: String, _ data: Data, _ app: String, _ bundle: String) async {
            await state.accept(PasteboardCapture(
                items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: uti, data: data)])],
                source: ClipSource(appName: app, bundleIdentifier: bundle, confidence: .high)
            ))
        }
        await accept("public.utf8-plain-text", Data("#7C3AED".utf8), "Figma", "com.figma.Desktop")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pasteory-Readme-Demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("project-notes.md")
        try? Data("# Project Notes\n\nIdeas worth keeping.\n".utf8).write(to: file)
        await accept("public.file-url", Data(file.absoluteString.utf8), "Finder", "com.apple.finder")
        let image = NSImage(size: NSSize(width: 360, height: 160))
        image.lockFocus()
        for (index, color) in [NSColor.systemIndigo, .systemCyan, .systemOrange].enumerated() {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: CGFloat(12 + index * 116), y: 12, width: 104, height: 136), xRadius: 14, yRadius: 14).fill()
        }
        image.unlockFocus()
        if let data = image.tiffRepresentation { await accept("public.tiff", data, "Preview", "com.apple.Preview") }
        await accept("public.swift-source", Data("let ideas = clipboard.history\n    .filter { $0.isFavorite }\n    .sorted { $0.date > $1.date }".utf8), "Xcode", "com.apple.dt.Xcode")
        await accept("public.url", Data("https://github.com/houskii/Pasteory".utf8), "Safari", "com.apple.Safari")
        let text = localized("A small place for everything you copy.\nKeep the useful bits. Find them when you need them.", "为每一次复制，留一个位置。\n留下有用的片段，在需要的时候找到它们。")
        await accept("public.utf8-plain-text", Data(text.utf8), "Notes", "com.apple.Notes")
        if var clip = state.quickClips.first {
            clip.title = localized("Ideas worth keeping", "值得留下的灵感")
            clip.note = localized("A thought for the next release", "留给下个版本的一点想法")
            clip.isFavorite = true
            clip.isPinned = true
            clip.copyCount = 3
            clip.pasteCount = 2
            state.update(clip)
        }
        _ = await state.addCollection(name: localized("Design", "设计灵感"), smart: false)
        _ = await state.addCollection(name: localized("Development", "开发资料"), smart: false)
        _ = await state.addCollection(name: localized("Writing", "写作片段"), smart: false)
        await state.refreshQuick()
        await state.refreshLibrary()
        state.quickSelectionID = state.quickClips.first?.id
        state.selectedClipID = state.clips.first?.id
    }

    private func seedAIData() async {
        func localized(_ en: String, _ zh: String) -> String { settings.appLanguage == .english ? en : zh }
        do {
            let recent = Array(state.quickClips.filter { [.text, .code].contains($0.primaryKind) }.prefix(2))
            guard recent.count == 2 else { return }
            let capture = PasteboardCapture(
                items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("Completed project: retain original decisions for future reference.".utf8))])],
                source: ClipSource(appName: "Notes", bundleIdentifier: "com.apple.Notes", confidence: .high),
                capturedAt: Date().addingTimeInterval(-90 * 86_400))
            guard let old = ClipClassifier.makeClip(from: capture) else { return }
            try await state.repository.save(old)
            let activeID = UUID(), archivedID = UUID(), bundleID = UUID()
            var changes = AIChangeSet()
            changes.clipRevisions = Dictionary(uniqueKeysWithValues: (recent + [old]).map { ($0.id, $0.aiRevision) })
            changes.commands = [
                AICommand(kind: .createGroup, targetID: activeID, name: localized("Pasteory AI design", "Pasteory AI 设计"), definition: localized("Design decisions and implementation material for the next release.", "下个版本的产品设计决策与实现资料。")),
                AICommand(kind: .addItems, targetID: activeID, clipIDs: recent.map(\.id)),
                AICommand(kind: .updateOverview, targetID: activeID, clipIDs: recent.map(\.id), overview: localized("Two source items about organizing ideas and their implementation.", "两条关于想法整理与实现方式的资料，保留独立原文。")),
                AICommand(kind: .createGroup, targetID: archivedID, name: localized("Completed project", "已完成项目"), definition: localized("Historical decisions for later reference.", "保留历史决策，供以后查阅。")),
                AICommand(kind: .addItems, targetID: archivedID, clipIDs: [old.id]),
                AICommand(kind: .createAggregation, targetID: bundleID, clipIDs: recent.map(\.id), name: localized("Next release brief", "下个版本资料包")),
                AICommand(kind: .setSummary, targetID: bundleID, claims: [AIClaim(kind: .fact, text: localized("Keep the original source alongside reusable ideas.", "有用的想法与原始依据一起保留。"), evidence: [AIEvidence(clipID: recent[0].id, quote: String(recent[0].previewText.prefix(30)))])])
            ]
            try await state.repository.applyAIChangeSet(changes)
            let usage = (0..<7).map { offset -> AIUsageRecord in
                var record = AIUsageRecord(runID: UUID(), requestedModel: "demo/model", inputTokens: 1200 + offset * 250, outputTokens: 240 + offset * 30, estimated: true, succeeded: true, trigger: "demo")
                record.date = Date().addingTimeInterval(-Double(offset) * 86_400); return record
            }
            try await state.repository.updateAIState { $0.usage = usage }
            try await state.intelligence.reload()
            await state.refreshCollections(); await state.refreshLibrary(); await state.refreshQuick(); await state.refreshAggregations()
        } catch { state.show(error) }
    }

    func seed() async {
        if ProcessInfo.processInfo.arguments.contains("--debug-session-refresh-seed") {
            for site in LinkAuthenticationSite.allCases {
                state.linkSessionRefresh.markSignedIn(.builtIn(site))
            }
            state.linkSessionRefresh.setInterval(.sevenDays, for: .builtIn(.lark))
            state.linkSessionRefresh.setInterval(.thirtyDays, for: .builtIn(.codebase))
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-readme-seed") {
            await seedReadmeData()
            if ProcessInfo.processInfo.arguments.contains("--debug-story-seed") { await seedStoryData() }
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--debug-story-report-file"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1]))
                    let report = try JSONDecoder().decode(AIStoryReport.self, from: data)
                    settings.aiConfiguration.storyEnabled = true
                    try await state.repository.updateAIState { $0.stories = [report] }
                    await state.story.load()
                } catch { state.show(error) }
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-story-empty") { settings.aiConfiguration.storyEnabled = true }
            if ProcessInfo.processInfo.arguments.contains("--debug-image-ocr-seed"),
               var image = state.quickClips.first(where: { $0.primaryKind == .image }) {
                image.title = ""
                image.note = settings.appLanguage == .english ? "Release planning reference" : "下次整理前先核对分组内容"
                image.isPinned = true
                do {
                    try await state.repository.updateExisting(image)
                    let text = settings.appLanguage == .english
                        ? "The grouping plan contains seven themes.\nReview each group before applying the plan.\nRecognized image text can be searched and edited.\nAdditional lines remain available in the library."
                        : "分组整理完成，生成 7 个主题。\n可以先查看各组内容，再决定是否应用整份方案。\n图片识别文字支持搜索，也可以在备注中修改。\n这是一段用于验证长 OCR 阅读效果的示例文字。"
                    _ = try await state.repository.saveLocalOCR(LocalOCRResult(contentHash: image.contentHash, text: text), clipID: image.id)
                    await state.refreshQuick(); await state.refreshLibrary()
                } catch { state.show(error) }
            }
            if ProcessInfo.processInfo.arguments.contains("--debug-ai-seed") { await seedAIData() }
            if ProcessInfo.processInfo.arguments.contains("--debug-story-disabled") { settings.aiConfiguration.storyEnabled = false }
            if ProcessInfo.processInfo.arguments.contains("--debug-group-seed") { await seedOrganizationDemo() }
            return
        }
        let samples = [
            ("这是一条用于验证超长文本截断和布局边界的剪贴板内容，它不应该把时间、来源应用或快捷键挤出卡片，也不能覆盖相邻的条目。", "com.apple.Terminal", "一个名称同样非常长的测试来源应用"),
            ("What was broken", "com.apple.Terminal", "终端"),
            ("你要解决一下这个问题，无论是用户切换", "com.openai.chat", "ChatGPT"),
            ("Lark Open API 调试记录", "com.google.Chrome", "Google Chrome"),
            ("KMP 构建命令与排查结果", "com.googlecode.iterm2", "iTerm2"),
            ("左边来源 App 和类型保持不变", "com.openai.chat", "ChatGPT")
        ]
        for sample in samples {
            let capture = PasteboardCapture(
                items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(sample.0.utf8))])],
                source: ClipSource(appName: sample.2, bundleIdentifier: sample.1, confidence: .high)
            )
            await state.accept(capture)
        }
        if var metadataSample = state.quickClips.first {
            if ProcessInfo.processInfo.arguments.contains("--debug-screenshot-seed") {
                metadataSample.title = "快捷面板类型标识实际测试：超长标题需要在标签前截断"
                metadataSample.note = "备注、正文、类型标签和复制次数不能互相覆盖"
            } else {
                metadataSample.title = String(repeating: "这是一个很长的用户标题，用来验证标题会在卡片边界内截断。", count: 5)
                metadataSample.note = String(repeating: "这是一条很长的备注，用于确认标题、正文、备注、复制次数和图钉同时存在时仍然清晰。", count: 10)
            }
            metadataSample.isPinned = true
            metadataSample.copyCount = 128
            metadataSample.pasteCount = 37
            state.update(metadataSample)
        }
        if let longSampleIndex = state.quickClips.firstIndex(where: { $0.source.appName.contains("名称同样非常长") }) {
            var longSample = state.quickClips[longSampleIndex]
            longSample.copyCount = 9_999
            longSample.pasteCount = 888
            state.update(longSample)
        }
        let colorCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("#7C3AED".utf8))])],
            source: ClipSource(appName: "设计工具", bundleIdentifier: "com.apple.Preview", confidence: .high)
        )
        await state.accept(colorCapture)
        if let image = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil), let data = image.tiffRepresentation {
            let capture = PasteboardCapture(
                items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.tiff", data: data)])],
                source: ClipSource(appName: "预览", bundleIdentifier: "com.apple.Preview", confidence: .high)
            )
            await state.accept(capture)
        }
        let linkCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.url", data: Data("https://pasteory.app/design/type-marker".utf8))])],
            source: ClipSource(appName: "Safari", bundleIdentifier: "com.apple.Safari", confidence: .high)
        )
        await state.accept(linkCapture)
        let codeCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [CapturedRepresentation(
                uti: "public.swift-source",
                data: Data("import SwiftUI\n\nstruct CodePreview: View {\n    var body: some View { Text(\"Hello, Pasteory\") }\n}".utf8)
            )])],
            source: ClipSource(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", confidence: .high)
        )
        await state.accept(codeCapture)
        let debugFileDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Pasteory-File-Preview-QA", isDirectory: true)
        try? FileManager.default.createDirectory(at: debugFileDirectory, withIntermediateDirectories: true)
        let debugFileURL = debugFileDirectory.appendingPathComponent("mac_lock_screen.txt")
        try? Data("⌃⌘Q\n".utf8).write(to: debugFileURL, options: .atomic)
        var debugFileRepresentations = [
            CapturedRepresentation(uti: "public.file-url", data: Data(debugFileURL.absoluteString.utf8)),
            CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(debugFileURL.lastPathComponent.utf8))
        ]
        if let icon = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil),
           let iconData = icon.tiffRepresentation {
            debugFileRepresentations.insert(CapturedRepresentation(uti: "com.apple.icns", data: iconData), at: 0)
        }
        let fileCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: debugFileRepresentations)],
            source: ClipSource(appName: "访达", bundleIdentifier: "com.apple.finder", confidence: .high)
        )
        await state.accept(fileCapture)
        if ProcessInfo.processInfo.arguments.contains("--debug-seed-multi-file") {
            let packageURL = debugFileDirectory.appendingPathComponent("entry-default-signed.hap")
            let logURL = debugFileDirectory.appendingPathComponent("install-result.log")
            try? Data("debug hap".utf8).write(to: packageURL, options: .atomic)
            try? Data("install succeeded".utf8).write(to: logURL, options: .atomic)
            if let fileList = try? PropertyListSerialization.data(
                fromPropertyList: [packageURL.path, logURL.path, debugFileURL.path],
                format: .binary,
                options: 0
            ) {
                let capture = PasteboardCapture(
                    items: [CapturedItem(order: 0, representations: [
                        CapturedRepresentation(uti: "NSFilenamesPboardType", data: fileList)
                    ])],
                    source: ClipSource(appName: "访达", bundleIdentifier: "com.apple.finder", confidence: .high)
                )
                await state.accept(capture)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-seed-missing-file") {
            try? FileManager.default.removeItem(at: debugFileURL)
        }
        _ = await state.addCollection(name: "开发资料", smart: false)
        _ = await state.addCollection(name: "Lark Open API", smart: false)
        _ = await state.addCollection(name: "KMP", smart: false)
        _ = await state.addCollection(name: "最近来源", smart: true)
        let sourceContext = CapturedSourceContext(
            kind: .webPage,
            strategyIdentifier: "chrome.extension.web-context.v1",
            summary: "BITS · [Feature] Android KMP ABMock 优化·合码请求",
            payload: [
                "url": "https://bits.bytedance.net/devops/1486828802/code/detail/8376268",
                "pageTitle": "[Feature] Android KMP ABMock 优化·合码请求",
                "repository": "Douyin",
                "branch": "p/pengzipei/abmock-kmp-manager-optimize",
                "targetBranch": "rc/develop",
                "selectedText": "p/pengzipei/abmock-kmp-manager-optimize",
                "relatedText": "Douyin · 源分支 · 目标分支"
            ]
        )
        let contextCapture = PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [
                CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("p/pengzipei/abmock-kmp-manager-optimize".utf8))
            ])],
            source: ClipSource(appName: "Google Chrome", bundleIdentifier: "com.google.Chrome", confidence: .high),
            sourceContext: sourceContext
        )
        await state.accept(contextCapture)
        if ProcessInfo.processInfo.arguments.contains("--debug-seed-aggregation") {
            let members = Array(state.quickClips.prefix(3).map(\.id))
            if members.count >= 2 {
                let aggregation = ClipAggregation(
                    title: "abmock 相关内容",
                    note: "",
                    memberClipIDs: members,
                    origin: .search(query: "abmock")
                )
                _ = try? await state.repository.saveAggregation(aggregation)
                await state.refreshAggregations()
                state.quickExpandedAggregationIDs.insert(aggregation.id)
                state.libraryExpandedAggregationIDs.insert(aggregation.id)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-settings-storage")
            || ProcessInfo.processInfo.arguments.contains("--debug-settings-storage-thirty-days") {
            let calendar = Calendar.autoupdatingCurrent
            let todayStart = calendar.startOfDay(for: Date())
            let distributed = state.quickClips.enumerated().map { index, clip in
                var value = clip
                let dayOffset = -(index % 7)
                value.lastCopiedAt = calendar.date(
                    byAdding: .hour,
                    value: 10,
                    to: calendar.date(byAdding: .day, value: dayOffset, to: todayStart) ?? todayStart
                ) ?? value.lastCopiedAt
                return value
            }
            try? await state.repository.saveBatch(distributed)
            await state.refreshQuick()
            await state.refreshLibrary()
        }
        state.quickSelectionID = state.quickClips.first?.id
    }

    private func seedStoryData() async {
        settings.aiConfiguration.storyEnabled = true
        let english = settings.appLanguage == .english
        let texts = english ? [
            "Verify Pasteory updates: check the new version, install it, and confirm clipboard data is retained.",
            "Image cards should emphasize OCR text. Plain text copy for images and files should use the editable note.",
            "Activity should start at 100%. Copy and paste increase the reuse coefficient. Review the decay curve first."
        ] : [
            "验证 Pasteory 升级：检查更新能发现新版，下载安装后确认版本和剪贴板数据保留。",
            "图片卡片要突出 OCR 正文；图片与文件的纯文本复制使用备注中的识别文字。",
            "活跃度新内容从 100% 起算，复制和成功粘贴提高复用系数。先看衰减曲线。"
        ]
        do {
            let clips = try texts.map { text in
                guard let clip = ClipClassifier.makeClip(from: PasteboardCapture(
                    items: [.init(order: 0, representations: [.init(uti: "public.utf8-plain-text", data: Data(text.utf8))])],
                    source: .init(appName: "Story Demo", bundleIdentifier: "test.story.demo"))) else { throw AIError.invalid("Story demo") }
                return clip
            }
            try await state.repository.saveBatch(clips)
            let titles = english ? ["Verify the update path", "Make OCR easier to use", "Rethink activity scores"] : ["验证升级流程", "让图片文字更好用", "重新设计活跃度"]
            let sections = zip(clips, titles).map { clip, title in
                AIStorySection(title: title, text: clip.previewText, evidence: [.init(clipID: clip.id, quote: clip.previewText)])
            }
            let story = AIStoryReport(id: UUID(), title: english ? "A week of making your tools feel right" : "这一周，你在把工具变得更顺手",
                introduction: english ? "You have been working through the small details that shape everyday use: updates, image text, and how useful material stays close at hand."
                    : "升级以后资料还在不在，图片里的字能不能直接复制，都是你这几天在试的事。还有常用内容的活跃度，该怎么随时间慢慢降下来。",
                recentWork: sections, observations: [AIStorySection(title: english ? "You keep asking how it works in practice" : "你在持续追问实际使用的效果",
                    text: english ? "Your notes connect visible behavior with repeatable checks, from installing an update to copying recognized text."
                        : "你把升级流程和数据保留放在一起检查，也在核对识别文字能不能实际复制出来。",
                    evidence: sections[0].evidence + sections[1].evidence)],
                encouragement: english ? "These changes may look small on their own. Together they can remove friction from the tools you use every day. It is fine to finish one clear improvement at a time."
                    : "升级后旧东西还在不在，你没漏掉这件事。先把它试踏实，其他小地方可以慢慢调。",
                periodStart: Date().addingTimeInterval(-7 * 86_400), periodEnd: Date(), sourceCount: clips.count,
                sourceRevisions: Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.aiContentRevision) }))
            try await state.repository.updateAIState { $0.stories = [story] }
            await state.story.load()
        } catch { state.show(error) }
    }

    private func seedOrganizationDemo() async {
        let names = settings.appLanguage == .english ? ["Pasteory", "Claude", "Orca", "Mobile Dev", "AI Assets", "Networking", "Releases"] : ["Pasteory", "Claude", "Orca", "移动开发", "AI 资产", "网络排查", "发布运维"]
        do {
            var draft = AIChangeSet()
            for (index, name) in names.enumerated() {
                let group = UUID(); var members = [UUID]()
                for sample in 0..<3 {
                    let text = "\(name) · \(sample + 1)\nPublic synthetic example for checking the group layout."
                    let capture = PasteboardCapture(items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))])],
                                                   source: ClipSource(appName: "Notes", bundleIdentifier: "com.apple.Notes", confidence: .high),
                                                   capturedAt: Date().addingTimeInterval(-Double(index * 5 * 86_400 + sample * 60)))
                    guard let clip = ClipClassifier.makeClip(from: capture) else { continue }
                    try await state.repository.save(clip); members.append(clip.id); draft.clipRevisions[clip.id] = clip.aiRevision
                }
                draft.commands.append(AICommand(kind: .createGroup, targetID: group, name: name, definition: "\(name) — public synthetic topic for UI verification"))
                draft.commands.append(AICommand(kind: .addItems, targetID: group, clipIDs: members))
            }
            try await state.repository.applyAIChangeSet(draft)
            try await state.intelligence.reload(); state.intelligence.refreshRecommendations()
            await state.refreshCollections(); await state.refreshLibrary(); await state.refreshQuick()
        } catch { state.show(error) }
    }
}
#endif
