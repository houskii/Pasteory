import Foundation
import SQLite3
import Testing
@testable import PasteoryCore

@Test func builtInFallbackRulesCoverBitsBuildCloudTOSAndLarkWiki() throws {
    let build = try #require(URLFallbackEngine.normalizedWebURL("https://bits.bytedance.net/space/legacy/build/logs?jobId=856332530"))
    let buildFallback = URLFallbackEngine.fallback(for: build, rules: [])
    #expect(buildFallback.title == "报告流水线 · 856332530")
    #expect(buildFallback.routeSignature.key == "bits.bytedance.net/space/legacy/build/logs")
    #expect(buildFallback.state == .matchedBuiltInRule)

    let bucket = try #require(URLFallbackEngine.normalizedWebURL("https://cloud.bytedance.net/tos/bucket/23511400/overview"))
    let bucketFallback = URLFallbackEngine.fallback(for: bucket, rules: [])
    #expect(bucketFallback.title == "TOS Bucket · 23511400")
    #expect(bucketFallback.routeSignature.pathTemplate == "/tos/bucket/{bucketID}/overview")

    let wiki = try #require(URLFallbackEngine.normalizedWebURL("https://bytedance.larkoffice.com/wiki/KUNxwc586ivE9MkI1otcBQWPngf"))
    let wikiFallback = URLFallbackEngine.fallback(for: wiki, rules: [])
    #expect(wikiFallback.title == "飞书 Wiki · KUNxwc586ivE9MkI1otcBQWPngf")

    let codebase = try #require(URLFallbackEngine.normalizedWebURL("https://code.byted.org/ugc-android/ByteX/merge_requests/912"))
    let codebaseFallback = URLFallbackEngine.fallback(for: codebase, rules: [])
    #expect(codebaseFallback.title == "ByteX MR · !912")
    #expect(codebaseFallback.routeSignature.pathTemplate == "/{group}/{project}/merge_requests/{mergeRequestID}")
}

@Test func verificationRequiredHasExplicitUserFacingState() {
    #expect(LinkRequestState.verificationRequired.displayName == "Page verification required")
    #expect(LinkRequestState.verificationRequired.needsAttention)
}

@Test func userFallbackRuleOverridesBuiltInAndRedactsSensitiveQueryValues() throws {
    let url = try #require(URLFallbackEngine.normalizedWebURL("https://bits.bytedance.net/space/legacy/build/logs?jobId=856332530&token=secret"))
    let rule = URLFallbackRule(
        name: "我的流水线",
        hostPattern: "bits.bytedance.net",
        pathTemplate: "/space/legacy/build/logs",
        requiredQueryKeys: ["jobId", "token"],
        titleTemplate: "构建 · {{query.jobId}} · {{query.token}}"
    )
    let fallback = URLFallbackEngine.fallback(for: url, rules: [rule])
    #expect(fallback.title == "构建 · 856332530 · ••••")
    #expect(fallback.state == .matchedUserRule)
    #expect(fallback.matchedRuleID == rule.id)
    #expect(URLFallbackEngine.redactedDisplayURL(url.absoluteString).contains("token=••••"))
    #expect(!URLFallbackEngine.redactedDisplayURL(url.absoluteString).contains("secret"))
}

@Test func inferredRouteSignatureGroupsDifferentResourceIdentifiers() throws {
    let first = try #require(URL(string: "https://example.com/items/123456/detail?from=chat&view=full"))
    let second = try #require(URL(string: "https://example.com/items/987654/detail?view=compact"))
    let firstSignature = URLFallbackEngine.inferredRouteSignature(for: first)
    let secondSignature = URLFallbackEngine.inferredRouteSignature(for: second)
    #expect(firstSignature.pathTemplate == "/items/{segment2}/detail")
    #expect(firstSignature.pathTemplate == secondSignature.pathTemplate)
    #expect(firstSignature.requiredQueryKeys == ["view"])
    #expect(secondSignature.requiredQueryKeys == ["view"])
    #expect(firstSignature.key == secondSignature.key)
}

@Test func canonicalResourceKeyUsesTheWholePathAndIgnoresQueryAndFragment() throws {
    let first = try #require(URLFallbackEngine.normalizedWebURL(
        "https://bits.bytedance.net/devops/1486828802/code/detail/8390888?devops_space_type=client"
    ))
    let second = try #require(URLFallbackEngine.normalizedWebURL(
        "https://BITS.bytedance.net/devops/1486828802/code/detail/8390888/?tab=all#changes"
    ))
    #expect(URLFallbackEngine.canonicalResourceKey(for: first)
        == "bits.bytedance.net:/devops/1486828802/code/detail/8390888")
    #expect(URLFallbackEngine.canonicalResourceKey(for: first)
        == URLFallbackEngine.canonicalResourceKey(for: second))
}

@Test func cacheMaintenanceScansOneHundredItemsAndKeepsTenUniquePaths() throws {
    func clip(_ value: String, index: Int) throws -> Clip {
        try #require(ClipClassifier.makeClip(from: PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [
                CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(value.utf8))
            ])],
            source: ClipSource(appName: "测试", bundleIdentifier: "app.test", confidence: .high),
            capturedAt: Date(timeIntervalSince1970: Double(index))
        )))
    }
    var ordered = [Clip]()
    ordered.append(try clip("https://example.com/items/1?tab=first", index: 0))
    ordered.append(try clip("https://example.com/items/1?tab=second", index: 1))
    for index in 2...12 {
        ordered.append(try clip("https://example.com/items/\(index)", index: index))
    }
    while ordered.count < LinkCacheRefreshPolicy.scanLimit {
        ordered.append(try clip("普通文本 \(ordered.count)", index: ordered.count))
    }
    ordered.append(try clip("https://example.com/outside/101", index: 101))

    let candidates = LinkCacheRefreshPolicy.maintenanceCandidates(from: ordered)
    #expect(candidates.count == LinkCacheRefreshPolicy.resourceLimit)
    #expect(candidates.first?.previewText.contains("items/1") == true)
    #expect(candidates.last?.previewText.contains("items/10") == true)
    #expect(!candidates.contains { $0.previewText.contains("outside/101") })
}

@Test func repositoryReusesLinkResourceForTheSamePathWithDifferentQueries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryCanonicalLinkTests-\(UUID().uuidString)", isDirectory: true)
    let directories = try AppDirectories(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let rawURLs = [
        "https://bits.bytedance.net/devops/1486828802/code/detail/8390888?devops_space_type=client",
        "https://bits.bytedance.net/devops/1486828802/code/detail/8390888?tab=all&cr_tab=All"
    ]
    var resourceIDs = [UUID]()
    for (index, rawURL) in rawURLs.enumerated() {
        let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [
                CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(rawURL.utf8))
            ])],
            source: ClipSource(appName: "测试", bundleIdentifier: "app.test", confidence: .high),
            capturedAt: Date(timeIntervalSince1970: Double(index + 1))
        )))
        try await repository.save(clip)
        let url = try #require(URLFallbackEngine.normalizedWebURL(rawURL))
        let fallback = URLFallbackEngine.fallback(for: url, rules: [])
        let resource = try await repository.associateLink(
            clipID: clip.id,
            resource: LinkResource(
                normalizedURL: rawURL,
                host: "bits.bytedance.net",
                routeSignature: fallback.routeSignature,
                fallbackTitle: fallback.title,
                fallbackState: fallback.state
            )
        )
        resourceIDs.append(resource.id)
    }

    #expect(resourceIDs.count == 2)
    #expect(Set(resourceIDs).count == 1)
    let stored = try #require(try await repository.linkResource(normalizedURL: rawURLs[1]))
    #expect(stored.effectiveCanonicalResourceKey
        == "bits.bytedance.net:/devops/1486828802/code/detail/8390888")
}

@Test func repositoryMigratesLegacyQueryVariantsIntoOneCanonicalResource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryCanonicalMigrationTests-\(UUID().uuidString)", isDirectory: true)
    let directories = try AppDirectories(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    var database: OpaquePointer?
    #expect(sqlite3_open(directories.databaseFile.path, &database) == SQLITE_OK)
    let pointer = try #require(database)
    let createSQL = """
    CREATE TABLE link_resources(
      id TEXT PRIMARY KEY,normalized_url TEXT NOT NULL UNIQUE,host TEXT NOT NULL,route_key TEXT NOT NULL,
      request_state TEXT NOT NULL,title_quality TEXT NOT NULL,fallback_state TEXT NOT NULL,updated_at REAL NOT NULL,
      last_attempt_at REAL,attempt_count INTEGER NOT NULL DEFAULT 0,failed_attempt_count INTEGER NOT NULL DEFAULT 0,payload_json BLOB NOT NULL
    );
    """
    #expect(sqlite3_exec(pointer, createSQL, nil, nil, nil) == SQLITE_OK)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let rawURLs = [
        "https://bits.bytedance.net/devops/1486828802/code/detail/8390888?devops_space_type=client",
        "https://bits.bytedance.net/devops/1486828802/code/detail/8390888?tab=all"
    ]
    for (index, rawURL) in rawURLs.enumerated() {
        let url = try #require(URLFallbackEngine.normalizedWebURL(rawURL))
        let fallback = URLFallbackEngine.fallback(for: url, rules: [])
        var resource = LinkResource(
            normalizedURL: rawURL,
            host: "bits.bytedance.net",
            routeSignature: fallback.routeSignature,
            fallbackTitle: fallback.title,
            fallbackState: fallback.state,
            resolvedTitle: index == 0 ? "合码请求·抖音" : "[Optimize] fix compile",
            titleQuality: .distinctive,
            requestState: .resolved,
            updatedAt: Date(timeIntervalSince1970: Double(100 + index)),
            lastAttemptAt: Date(timeIntervalSince1970: Double(100 + index)),
            attemptCount: 2,
            failedAttemptCount: 1
        )
        resource.canonicalResourceKey = nil
        resource.lastResolvedAt = nil
        let payload = try encoder.encode(resource)
        var insert: OpaquePointer?
        let sql = "INSERT INTO link_resources(id,normalized_url,host,route_key,request_state,title_quality,fallback_state,updated_at,last_attempt_at,attempt_count,failed_attempt_count,payload_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?);"
        #expect(sqlite3_prepare_v2(pointer, sql, -1, &insert, nil) == SQLITE_OK)
        let statement = try #require(insert)
        sqlite3_bind_text(statement, 1, resource.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, rawURL, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 3, resource.host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 4, resource.routeSignature.key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 5, resource.requestState.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 6, resource.titleQuality.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 7, resource.fallbackState.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(statement, 8, resource.updatedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 9, resource.lastAttemptAt!.timeIntervalSince1970)
        sqlite3_bind_int(statement, 10, Int32(resource.attemptCount))
        sqlite3_bind_int(statement, 11, Int32(resource.failedAttemptCount))
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 12, $0.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
    }
    sqlite3_close(pointer)

    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let first = try #require(try await repository.linkResource(normalizedURL: rawURLs[0]))
    let second = try #require(try await repository.linkResource(normalizedURL: rawURLs[1]))
    #expect(first.id == second.id)
    #expect(first.resolvedTitle == "[Optimize] fix compile")
    #expect(first.attemptCount == 4)
    #expect(first.lastResolvedAt != nil)
}

@Test func routeGroupingIgnoresOptionalQueryKeysAndGeneratedRulesOnlyRequireUsedVariables() throws {
    let first = try #require(URL(string: "https://bits.bytedance.net/devops/1499118338/pipeline/pipeline/history/detail?pipeline_id=101099346&devops_space_type=client"))
    let second = try #require(URL(string: "https://bits.bytedance.net/devops/1499374082/pipeline/pipeline/history/detail?pipeline_id=101099323&devops_space_type=client&tab=dag"))
    let firstSignature = URLFallbackEngine.inferredRouteSignature(for: first)
    let secondSignature = URLFallbackEngine.inferredRouteSignature(for: second)
    #expect(firstSignature.key == secondSignature.key)

    let group = LinkFailureGroup(
        routeSignature: secondSignature,
        uniqueURLCount: 2,
        clipCount: 2,
        copyCount: 5,
        attemptCount: 3,
        failedAttemptCount: 3,
        latestRequestState: .genericTitle,
        latestTitleQuality: .generic,
        currentFallbackTitle: "bits.bytedance.net · detail",
        currentFallbackState: .genericURLFallback,
        sampleURL: second.absoluteString,
        lastSeenAt: Date(),
        lastAttemptAt: Date()
    )
    let staticRule = URLFallbackEngine.suggestedRule(for: group, name: "BITS Pipeline", titleTemplate: "BITS Pipeline")
    #expect(staticRule.requiredQueryKeys.isEmpty)
    let identifierRule = URLFallbackEngine.suggestedRule(
        for: group,
        name: "BITS Pipeline",
        titleTemplate: "BITS Pipeline · {{query.pipeline_id}}"
    )
    #expect(identifierRule.requiredQueryKeys == ["pipeline_id"])
}

@Test func repositoryMergesSamePathWhenOptionalQueryKeysDiffer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryRouteGroupTests-\(UUID().uuidString)", isDirectory: true)
    let directories = try AppDirectories(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let rawURLs = [
        "https://bits.bytedance.net/devops/1499118338/pipeline/pipeline/history/detail?pipeline_id=101099346&devops_space_type=client",
        "https://bits.bytedance.net/devops/1499374082/pipeline/pipeline/history/detail?pipeline_id=101099323&devops_space_type=client&tab=dag"
    ]
    for (index, rawURL) in rawURLs.enumerated() {
        let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [
                CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(rawURL.utf8))
            ])],
            source: ClipSource(appName: "ChatGPT", bundleIdentifier: "com.openai.codex", confidence: .high),
            capturedAt: Date().addingTimeInterval(Double(index))
        )))
        try await repository.save(clip)
        let url = try #require(URLFallbackEngine.normalizedWebURL(rawURL))
        let fallback = URLFallbackEngine.fallback(for: url, rules: [])
        var resource = try await repository.associateLink(
            clipID: clip.id,
            resource: LinkResource(
                normalizedURL: rawURL,
                host: "bits.bytedance.net",
                routeSignature: fallback.routeSignature,
                fallbackTitle: fallback.title,
                fallbackState: fallback.state
            )
        )
        resource.requestState = .genericTitle
        resource.titleQuality = .generic
        resource.attemptCount = 1
        resource.failedAttemptCount = 1
        resource.lastAttemptAt = Date()
        try await repository.saveLinkResolution(resource, attempt: LinkResolutionAttempt(
            linkResourceID: resource.id,
            startedAt: Date(),
            resolver: .anonymousHTTP,
            requestState: .genericTitle,
            candidateTitle: "Bits",
            candidateFingerprint: "bits",
            quality: .generic,
            durationMilliseconds: 10
        ))
    }

    let groups = try await repository.unresolvedLinkGroups(limit: 10)
    #expect(groups.count == 1)
    let group = try #require(groups.first)
    #expect(group.uniqueURLCount == 2)
    #expect(group.routeSignature.key == "bits.bytedance.net/devops/{segment2}/pipeline/pipeline/history/detail")

    let rule = URLFallbackEngine.suggestedRule(for: group, name: "BITS Pipeline", titleTemplate: "BITS Pipeline")
    #expect(rule.requiredQueryKeys.isEmpty)
    try await repository.saveFallbackRule(rule)
    for rawURL in rawURLs {
        #expect(try await repository.linkResource(normalizedURL: rawURL)?.fallbackTitle == "BITS Pipeline")
    }
}

@Test func htmlExtractorCollectsMetadataHeadingAndDocumentTitle() {
    let html = """
    <html><head>
    <meta property="og:title" content="一篇具体文章">
    <meta name='twitter:title' content='一篇具体文章'>
    <title>一篇具体文章 - 示例站点</title>
    </head><body><h1>一篇具体文章</h1></body></html>
    """
    let candidates = HTMLTitleExtractor.candidates(from: Data(html.utf8))
    #expect(candidates.contains(LinkTitleCandidate(value: "一篇具体文章", source: .openGraph)))
    #expect(candidates.contains(LinkTitleCandidate(value: "一篇具体文章", source: .mainHeading)))
    #expect(candidates.contains(LinkTitleCandidate(value: "一篇具体文章 - 示例站点", source: .documentTitle)))
}

@Test func titleEvaluatorRejectsSiteShellsAndLoginPages() throws {
    let bits = try #require(URL(string: "https://bits.bytedance.net/devops/1486828802/code/detail/8376268"))
    let bitsAssessment = LinkTitleQualityEvaluator.assess(
        candidates: [LinkTitleCandidate(value: "Bits", source: .documentTitle)],
        requestedURL: bits,
        finalURL: bits
    )
    #expect(bitsAssessment.quality == .generic)
    #expect(bitsAssessment.selectedTitle == nil)

    let cloud = try #require(URL(string: "https://cloud.bytedance.net/tos/bucket/23511400/overview"))
    let cloudAssessment = LinkTitleQualityEvaluator.assess(
        candidates: [LinkTitleCandidate(value: "ByteCloud - One-stop development platform for ByteDancer", source: .documentTitle)],
        requestedURL: cloud,
        finalURL: cloud
    )
    #expect(cloudAssessment.quality == .generic)

    let wiki = try #require(URL(string: "https://bytedance.larkoffice.com/wiki/token"))
    let login = try #require(URL(string: "https://accounts.feishu.cn/accounts/page/login"))
    let loginAssessment = LinkTitleQualityEvaluator.assess(
        candidates: [LinkTitleCandidate(value: "飞书登录", source: .documentTitle)],
        requestedURL: wiki,
        finalURL: login
    )
    #expect(loginAssessment.quality == .loginOrError)

    let titlelessLoginAssessment = LinkTitleQualityEvaluator.assess(
        candidates: [],
        requestedURL: wiki,
        finalURL: login
    )
    #expect(titlelessLoginAssessment.quality == .loginOrError)
    #expect(titlelessLoginAssessment.evidence == [.redirectedToLogin])

    let larkDocument = try #require(URL(string: "https://bytedance.larkoffice.com/wiki/document-token"))
    let larkShell = LinkTitleQualityEvaluator.assess(
        candidates: [LinkTitleCandidate(value: "Docs", source: .documentTitle)],
        requestedURL: larkDocument,
        finalURL: larkDocument
    )
    #expect(larkShell.quality == .generic)
    let larkLoaded = LinkTitleQualityEvaluator.assess(
        candidates: [
            LinkTitleCandidate(value: "Docs", source: .openGraph),
            LinkTitleCandidate(value: "真实飞书文档标题", source: .documentTitle)
        ],
        requestedURL: larkDocument,
        finalURL: larkDocument
    )
    #expect(larkLoaded.selectedTitle == "真实飞书文档标题")
}

@Test func titleEvaluatorAcceptsIndependentMetadataAgreementAndRepeatedRoutes() throws {
    let article = try #require(URL(string: "https://mp.weixin.qq.com/s/article-token"))
    let accepted = LinkTitleQualityEvaluator.assess(
        candidates: [
            LinkTitleCandidate(value: "9月上市！全球首款AI智能体手机正式获得入网许可证", source: .openGraph),
            LinkTitleCandidate(value: "9月上市！全球首款AI智能体手机正式获得入网许可证", source: .twitterCard)
        ],
        requestedURL: article,
        finalURL: article
    )
    #expect(accepted.quality == .distinctive)
    #expect(accepted.selectedTitle != nil)

    let repeated = LinkTitleQualityEvaluator.assess(
        candidates: [LinkTitleCandidate(value: "项目详情", source: .documentTitle)],
        requestedURL: try #require(URL(string: "https://example.com/projects/1005")),
        finalURL: nil,
        repetition: LinkTitleRepetitionStats(routeDistinctURLCount: 4, routeFingerprintURLCount: 4)
    )
    #expect(repeated.quality == .generic)
    #expect(repeated.evidence.contains(.repeatedAcrossRoute))
}

@Test func repositoryPersistsLinkFailuresAndBackfillsUserFallbackRules() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryLinkTests-\(UUID().uuidString)", isDirectory: true)
    let directories = try AppDirectories(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let rawURL = "https://bits.bytedance.net/space/legacy/build/logs?jobId=856332530"
    let data = Data(rawURL.utf8)
    let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(
        items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: data)])],
        source: ClipSource(appName: "ChatGPT", bundleIdentifier: "com.openai.codex", confidence: .high)
    )))
    try await repository.save(clip)
    let url = try #require(URLFallbackEngine.normalizedWebURL(rawURL))
    let fallback = URLFallbackEngine.fallback(for: url, rules: [])
    var resource = try await repository.associateLink(
        clipID: clip.id,
        resource: LinkResource(
            normalizedURL: rawURL,
            host: "bits.bytedance.net",
            routeSignature: fallback.routeSignature,
            fallbackTitle: fallback.title,
            fallbackState: fallback.state,
            matchedFallbackRuleID: fallback.matchedRuleID
        )
    )
    #expect(try await repository.clip(id: clip.id)?.automaticTitle == "报告流水线 · 856332530")

    resource.requestState = .genericTitle
    resource.titleQuality = .generic
    resource.candidateTitle = "Bits"
    resource.attemptCount = 1
    resource.failedAttemptCount = 1
    resource.lastAttemptAt = Date()
    let attempt = LinkResolutionAttempt(
        linkResourceID: resource.id,
        startedAt: Date(),
        resolver: .anonymousHTTP,
        requestState: .genericTitle,
        httpStatus: 200,
        candidateTitle: "Bits",
        candidateFingerprint: "bits",
        quality: .generic,
        evidence: [.equalsSiteBrand],
        durationMilliseconds: 20
    )
    try await repository.saveLinkResolution(resource, attempt: attempt)
    let group = try #require(try await repository.unresolvedLinkGroups(limit: 10).first)
    #expect(group.uniqueURLCount == 1)
    #expect(group.copyCount == 1)
    #expect(group.attemptCount == 1)
    #expect(group.latestRequestState == .genericTitle)

    let userRule = URLFallbackRule(
        name: "流水线报告",
        hostPattern: "bits.bytedance.net",
        pathTemplate: "/space/legacy/build/logs",
        requiredQueryKeys: ["jobId"],
        titleTemplate: "流水线报告 · {{query.jobId}}"
    )
    try await repository.saveFallbackRule(userRule)
    #expect(try await repository.clip(id: clip.id)?.automaticTitle == "流水线报告 · 856332530")
    #expect(try await repository.userFallbackRules().count == 1)
}

@Test func resolvedListKeepsLastSuccessfulTitleAfterFailedReparse() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteoryResolvedLinkTests-\(UUID().uuidString)", isDirectory: true)
    let directories = try AppDirectories(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
    let rawURL = "https://example.com/articles/42"
    let data = Data(rawURL.utf8)
    let clip = try #require(ClipClassifier.makeClip(from: PasteboardCapture(
        items: [CapturedItem(order: 0, representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: data)])],
        source: ClipSource(appName: "测试", bundleIdentifier: "app.test", confidence: .high)
    )))
    try await repository.save(clip)
    let url = try #require(URLFallbackEngine.normalizedWebURL(rawURL))
    let fallback = URLFallbackEngine.fallback(for: url, rules: [])
    var resource = try await repository.associateLink(
        clipID: clip.id,
        resource: LinkResource(
            normalizedURL: rawURL,
            host: "example.com",
            routeSignature: fallback.routeSignature,
            fallbackTitle: fallback.title,
            fallbackState: fallback.state
        )
    )

    resource.resolvedTitle = "一篇真实文章"
    resource.requestState = .networkError
    resource.titleQuality = .ambiguous
    resource.resolutionSource = .webKit
    resource.attemptCount = 2
    resource.failedAttemptCount = 1
    resource.lastAttemptAt = Date()
    try await repository.saveLinkResolution(
        resource,
        attempt: LinkResolutionAttempt(
            linkResourceID: resource.id,
            startedAt: Date(),
            resolver: .webKit,
            requestState: .networkError,
            quality: .ambiguous,
            durationMilliseconds: 0,
            errorCode: "webkit_navigation_failed"
        )
    )

    let summary = try #require(try await repository.resolvedLinkResources(limit: 10).first)
    #expect(summary.resource.resolvedTitle == "一篇真实文章")
    #expect(summary.resource.requestState == .networkError)
    #expect(summary.clipCount == 1)
    #expect(summary.copyCount == 1)
    #expect(try await repository.unresolvedLinkResources(routeKey: resource.routeSignature.key).count == 1)
    #expect(try await repository.clip(id: clip.id)?.automaticTitle == "一篇真实文章")
}
