import Foundation
import SQLite3

public actor SQLiteClipRepository: ClipRepository {
    nonisolated(unsafe) private let database: OpaquePointer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct LinkGroupAccumulator {
        var group: LinkFailureGroup
        var resourceIDs = Set<UUID>()
    }

    public init(databaseURL: URL) throws {
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            throw RepositoryError.openDatabase(pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "未知错误")
        }
        self.database = pointer
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .millisecondsSince1970
        self.decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            try Self.execute(pointer, "PRAGMA journal_mode=WAL;")
            try Self.execute(pointer, "PRAGMA foreign_keys=ON;")
            try Self.execute(pointer, "PRAGMA busy_timeout=5000;")
            try Self.migrate(pointer)
            try Self.normalizeGeneratedFallbackRules(pointer, decoder: self.decoder, encoder: self.encoder)
            try Self.normalizeStoredLinkRouteKeys(pointer, decoder: self.decoder)
        } catch {
            sqlite3_close(pointer)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func saveCaptured(_ clip: Clip, context: CapturedSourceContext?) throws -> Clip {
        var stored = clip
        try transaction {
            if var previous = try latestActiveClip(),
               previous.contentHash == clip.contentHash,
               previous.primaryKind == clip.primaryKind,
               previous.source.bundleIdentifier == clip.source.bundleIdentifier,
               clip.createdAt.timeIntervalSince(previous.createdAt) <= 60 {
                previous.copyCount += 1
                previous.lastCopiedAt = clip.createdAt
                previous.updatedAt = clip.createdAt
                try save(previous)
                stored = previous
            } else {
                try save(clip)
            }
        }
        try? saveCaptureEvent(ClipCaptureEvent(
            clipID: stored.id,
            capturedAt: clip.createdAt,
            source: clip.source,
            context: context
        ))
        return stored
    }

    public func save(_ clip: Clip) throws {
        let payload = try encoder.encode(clip)
        let sql = """
        INSERT INTO clips (
          id, created_at, updated_at, last_copied_at, kind, title, note, priority,
          favorite, pinned, archived, source_name, source_bundle, source_confidence,
          preview_text, content_hash, byte_size, copy_count, deleted_at, payload_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          updated_at=excluded.updated_at, last_copied_at=excluded.last_copied_at,
          kind=excluded.kind, title=excluded.title, note=excluded.note,
          priority=excluded.priority, favorite=excluded.favorite, pinned=excluded.pinned,
          archived=excluded.archived, source_name=excluded.source_name,
          source_bundle=excluded.source_bundle, source_confidence=excluded.source_confidence,
          preview_text=excluded.preview_text, content_hash=excluded.content_hash,
          byte_size=excluded.byte_size, copy_count=excluded.copy_count,
          deleted_at=excluded.deleted_at, payload_json=excluded.payload_json;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(clip.id.uuidString, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, clip.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, clip.updatedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, clip.lastCopiedAt.timeIntervalSince1970)
        bind(clip.primaryKind.rawValue, at: 5, to: statement)
        bind(clip.displayTitle, at: 6, to: statement)
        bind(clip.note, at: 7, to: statement)
        sqlite3_bind_int(statement, 8, Int32(clip.priority))
        sqlite3_bind_int(statement, 9, clip.isFavorite ? 1 : 0)
        sqlite3_bind_int(statement, 10, clip.isPinned ? 1 : 0)
        sqlite3_bind_int(statement, 11, clip.isArchived ? 1 : 0)
        bind(clip.source.appName, at: 12, to: statement)
        bindOptional(clip.source.bundleIdentifier, at: 13, to: statement)
        bind(clip.source.confidence.rawValue, at: 14, to: statement)
        bind(clip.previewText, at: 15, to: statement)
        bind(clip.contentHash, at: 16, to: statement)
        sqlite3_bind_int64(statement, 17, Int64(clip.byteSize))
        sqlite3_bind_int(statement, 18, Int32(clip.copyCount))
        if let deletedAt = clip.deletedAt { sqlite3_bind_double(statement, 19, deletedAt.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 19) }
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 20, bytes.baseAddress, Int32(payload.count), Self.transient)
        }
        try stepDone(statement)
        try syncCollections(for: clip)
        try updateFTS(for: clip)
    }

    public func saveBatch(_ clips: [Clip]) throws {
        try transaction {
            for clip in clips { try save(clip) }
        }
    }

    public func clip(id: UUID) throws -> Clip? {
        let statement = try prepare("SELECT payload_json FROM clips WHERE id=? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeClip(statement, column: 0)
    }

    public func list(filter: ClipFilter, query: String, limit: Int = 500) throws -> [Clip] {
        var clauses = [String]()
        var bindings = [String]()
        switch filter {
        case .all:
            clauses += ["c.deleted_at IS NULL", "c.archived=0"]
        case .favorite:
            clauses += ["c.deleted_at IS NULL", "c.favorite=1"]
        case .recent:
            clauses += ["c.deleted_at IS NULL", "c.archived=0"]
        case .archived:
            clauses += ["c.deleted_at IS NULL", "c.archived=1"]
        case .trash:
            clauses += ["c.deleted_at IS NOT NULL"]
        case .kind(let kind):
            clauses += ["c.deleted_at IS NULL", "c.kind=?"]
            bindings.append(kind.rawValue)
        case .collection(let id):
            clauses += ["c.deleted_at IS NULL", "EXISTS (SELECT 1 FROM clip_collections cc WHERE cc.clip_id=c.id AND cc.collection_id=?)"]
            bindings.append(id.uuidString)
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let join = ""
        if !trimmed.isEmpty {
            if trimmed.count >= 3 {
                clauses.append("c.id IN (SELECT id FROM clip_fts WHERE clip_fts MATCH ? ORDER BY rowid DESC LIMIT 2000)")
                bindings.append(ftsQuery(trimmed))
            } else {
                clauses.append("(c.title LIKE ? ESCAPE '\\' OR c.note LIKE ? ESCAPE '\\' OR c.preview_text LIKE ? ESCAPE '\\' OR c.source_name LIKE ? ESCAPE '\\')")
                let like = "%\(escapeLike(trimmed))%"
                bindings += [like, like, like, like]
            }
        }
        let whereSQL = clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
        let ordering = "c.pinned DESC, c.last_copied_at DESC"
        let sql = "SELECT c.payload_json FROM clips c \(join) WHERE \(whereSQL) ORDER BY \(ordering) LIMIT ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { bind(value, at: Int32(index + 1), to: statement) }
        sqlite3_bind_int(statement, Int32(bindings.count + 1), Int32(max(1, min(limit, 100_000))))
        var clips = [Clip]()
        while sqlite3_step(statement) == SQLITE_ROW { clips.append(try decodeClip(statement, column: 0)) }
        return clips
    }

    public func removePermanently(id: UUID) throws {
        try transaction {
            let fts = try prepare("DELETE FROM clip_fts WHERE id=?;")
            bind(id.uuidString, at: 1, to: fts); try stepDone(fts); sqlite3_finalize(fts)
            let clip = try prepare("DELETE FROM clips WHERE id=?;")
            bind(id.uuidString, at: 1, to: clip); try stepDone(clip); sqlite3_finalize(clip)
            try Self.execute(database, "DELETE FROM context_entities WHERE NOT EXISTS (SELECT 1 FROM capture_event_entities j WHERE j.entity_id=context_entities.id);")
        }
    }

    public func purgeTrash(olderThan date: Date) throws -> Int {
        let ids = try idsForSQL("SELECT id FROM clips WHERE deleted_at IS NOT NULL AND deleted_at < ?;", double: date.timeIntervalSince1970)
        for id in ids { try removePermanently(id: id) }
        return ids.count
    }

    public func archiveCandidates(olderThan date: Date, hotLimit: Int) throws -> [Clip] {
        let sql = """
        SELECT payload_json FROM clips c
        WHERE deleted_at IS NULL AND archived=0 AND favorite=0 AND pinned=0
          AND NOT EXISTS (SELECT 1 FROM clip_collections cc JOIN collections co ON co.id=cc.collection_id WHERE cc.clip_id=c.id AND co.kind='normal')
        ORDER BY created_at ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var eligible = [Clip]()
        while sqlite3_step(statement) == SQLITE_ROW { eligible.append(try decodeClip(statement, column: 0)) }
        let activeCount = try scalarInt("SELECT COUNT(*) FROM clips WHERE deleted_at IS NULL AND archived=0;")
        let overflow = max(0, activeCount - hotLimit)
        let old = eligible.filter { $0.createdAt < date }
        if old.count >= overflow { return old }
        return Array(eligible.prefix(overflow))
    }

    public func activeClipCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM clips WHERE deleted_at IS NULL AND archived=0;")
    }

    public func recentClipCount(since date: Date) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM clips WHERE deleted_at IS NULL AND last_copied_at>=?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func collections() throws -> [ClipCollection] {
        let statement = try prepare("SELECT payload_json FROM collections ORDER BY sort_order, name;")
        defer { sqlite3_finalize(statement) }
        var result = [ClipCollection]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            result.append(try decoder.decode(ClipCollection.self, from: data))
        }
        return result
    }

    public func saveCollection(_ collection: ClipCollection) throws {
        let duplicate = try prepare("SELECT 1 FROM collections WHERE id<>? AND lower(trim(name))=lower(trim(?)) LIMIT 1;")
        bind(collection.id.uuidString, at: 1, to: duplicate)
        bind(collection.name, at: 2, to: duplicate)
        let nameExists = sqlite3_step(duplicate) == SQLITE_ROW
        sqlite3_finalize(duplicate)
        guard !nameExists else { throw RepositoryError.duplicateCollectionName }
        let data = try encoder.encode(collection)
        let statement = try prepare("INSERT INTO collections(id,name,kind,sort_order,payload_json) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,kind=excluded.kind,sort_order=excluded.sort_order,payload_json=excluded.payload_json;")
        defer { sqlite3_finalize(statement) }
        bind(collection.id.uuidString, at: 1, to: statement); bind(collection.name, at: 2, to: statement)
        bind(collection.kind.rawValue, at: 3, to: statement); sqlite3_bind_int(statement, 4, Int32(collection.sortOrder))
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(data.count), Self.transient) }
        try stepDone(statement)
        try rebuildSearchIndex()
    }

    public func removeCollection(id: UUID) throws {
        let statement = try prepare("DELETE FROM collections WHERE id=?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement); try stepDone(statement)
        try rebuildSearchIndex()
    }

    public func allClips() throws -> [Clip] {
        let statement = try prepare("SELECT payload_json FROM clips ORDER BY created_at;")
        defer { sqlite3_finalize(statement) }
        var result = [Clip]()
        while sqlite3_step(statement) == SQLITE_ROW { result.append(try decodeClip(statement, column: 0)) }
        return result
    }

    public func captureEvents(for clipID: UUID, limit: Int = 50) throws -> [ClipCaptureEvent] {
        let statement = try prepare("SELECT event_json FROM clip_capture_events WHERE clip_id=? ORDER BY captured_at DESC LIMIT ?;")
        defer { sqlite3_finalize(statement) }
        bind(clipID.uuidString, at: 1, to: statement)
        sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 10_000))))
        var result = [ClipCaptureEvent]()
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decode(ClipCaptureEvent.self, statement: statement, column: 0))
        }
        return result
    }

    public func allCaptureEvents() throws -> [ClipCaptureEvent] {
        let statement = try prepare("SELECT event_json FROM clip_capture_events ORDER BY captured_at;")
        defer { sqlite3_finalize(statement) }
        var result = [ClipCaptureEvent]()
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decode(ClipCaptureEvent.self, statement: statement, column: 0))
        }
        return result
    }

    public func saveCaptureEvents(_ events: [ClipCaptureEvent]) throws {
        try transaction {
            for event in events { try saveCaptureEvent(event) }
        }
    }

    public func contextAggregates(kind: SourceContextEntityKind? = nil, limit: Int = 500) throws -> [SourceContextAggregate] {
        let predicate = kind == nil ? "" : "WHERE e.kind=?"
        let sql = """
        SELECT e.payload_json, COUNT(DISTINCT ce.clip_id), COUNT(*), MAX(ce.captured_at)
        FROM context_entities e
        JOIN capture_event_entities j ON j.entity_id=e.id
        JOIN clip_capture_events ce ON ce.id=j.event_id
        \(predicate)
        GROUP BY e.id
        ORDER BY MAX(ce.captured_at) DESC
        LIMIT ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let kind { bind(kind.rawValue, at: index, to: statement); index += 1 }
        sqlite3_bind_int(statement, index, Int32(max(1, min(limit, 10_000))))
        var result = [SourceContextAggregate]()
        while sqlite3_step(statement) == SQLITE_ROW {
            let entity = try decode(SourceContextEntity.self, statement: statement, column: 0)
            result.append(SourceContextAggregate(
                entity: entity,
                clipCount: Int(sqlite3_column_int64(statement, 1)),
                captureCount: Int(sqlite3_column_int64(statement, 2)),
                lastCapturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return result
    }

    public func associateLink(clipID: UUID, resource proposed: LinkResource) throws -> LinkResource {
        let existing = try linkResource(normalizedURL: proposed.normalizedURL)
        var resource = existing ?? proposed
        let fallbackChanged = resource.host != proposed.host
            || resource.routeSignature != proposed.routeSignature
            || resource.fallbackTitle != proposed.fallbackTitle
            || resource.fallbackState != proposed.fallbackState
            || resource.matchedFallbackRuleID != proposed.matchedFallbackRuleID
        if fallbackChanged {
            resource.host = proposed.host
            resource.routeSignature = proposed.routeSignature
            resource.fallbackTitle = proposed.fallbackTitle
            resource.fallbackState = proposed.fallbackState
            resource.matchedFallbackRuleID = proposed.matchedFallbackRuleID
        }
        if existing == nil { try saveLinkResource(resource) }

        let join = try prepare("INSERT OR IGNORE INTO clip_links(clip_id,link_resource_id) VALUES(?,?);")
        defer { sqlite3_finalize(join) }
        bind(clipID.uuidString, at: 1, to: join)
        bind(resource.id.uuidString, at: 2, to: join)
        try stepDone(join)
        let newAssociation = sqlite3_changes(database) > 0
        if existing != nil, fallbackChanged || newAssociation {
            resource.updatedAt = Date()
            try saveLinkResource(resource)
        }
        try applyAutomaticTitle(resource.displayTitle, toClipID: clipID)
        return resource
    }

    public func linkResource(normalizedURL: String) throws -> LinkResource? {
        let statement = try prepare("SELECT payload_json FROM link_resources WHERE normalized_url=? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(normalizedURL, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decode(LinkResource.self, statement: statement, column: 0)
    }

    public func saveLinkResolution(_ resource: LinkResource, attempt: LinkResolutionAttempt) throws {
        try saveLinkResource(resource)
        let data = try encoder.encode(attempt)
        let statement = try prepare("INSERT OR REPLACE INTO link_resolution_attempts(id,link_resource_id,started_at,finished_at,resolver,request_state,title_quality,candidate_fingerprint,error_code,payload_json) VALUES(?,?,?,?,?,?,?,?,?,?);")
        defer { sqlite3_finalize(statement) }
        bind(attempt.id.uuidString, at: 1, to: statement)
        bind(attempt.linkResourceID.uuidString, at: 2, to: statement)
        sqlite3_bind_double(statement, 3, attempt.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, attempt.finishedAt.timeIntervalSince1970)
        bind(attempt.resolver.rawValue, at: 5, to: statement)
        bind(attempt.requestState.rawValue, at: 6, to: statement)
        bind(attempt.quality.rawValue, at: 7, to: statement)
        bindOptional(attempt.candidateFingerprint, at: 8, to: statement)
        bindOptional(attempt.errorCode, at: 9, to: statement)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 10, $0.baseAddress, Int32(data.count), Self.transient) }
        try stepDone(statement)
        try applyAutomaticTitle(resource.displayTitle, toResourceID: resource.id)
    }

    public func unresolvedLinkGroups(limit: Int = 500) throws -> [LinkFailureGroup] {
        let statement = try prepare("SELECT payload_json FROM link_resources WHERE request_state NOT IN (?,?) ORDER BY updated_at DESC;")
        defer { sqlite3_finalize(statement) }
        bind(LinkRequestState.resolved.rawValue, at: 1, to: statement)
        bind(LinkRequestState.pending.rawValue, at: 2, to: statement)
        var accumulators = [String: LinkGroupAccumulator]()
        while sqlite3_step(statement) == SQLITE_ROW {
            let resource = try decode(LinkResource.self, statement: statement, column: 0)
            let stats = try clipStats(for: resource.id)
            let key = resource.routeSignature.key
            if var accumulator = accumulators[key] {
                accumulator.resourceIDs.insert(resource.id)
                accumulator.group.routeSignature.requiredQueryKeys = Array(Set(
                    accumulator.group.routeSignature.requiredQueryKeys + resource.routeSignature.requiredQueryKeys
                )).sorted()
                accumulator.group.uniqueURLCount = accumulator.resourceIDs.count
                accumulator.group.clipCount += stats.clipCount
                accumulator.group.copyCount += stats.copyCount
                accumulator.group.attemptCount += resource.attemptCount
                accumulator.group.failedAttemptCount += resource.failedAttemptCount
                if resource.updatedAt >= accumulator.group.lastSeenAt {
                    accumulator.group.latestRequestState = resource.requestState
                    accumulator.group.latestTitleQuality = resource.titleQuality
                    accumulator.group.currentFallbackTitle = resource.fallbackTitle
                    accumulator.group.currentFallbackState = resource.fallbackState
                    accumulator.group.sampleURL = URLFallbackEngine.redactedDisplayURL(resource.normalizedURL)
                    accumulator.group.lastSeenAt = resource.updatedAt
                    accumulator.group.lastAttemptAt = resource.lastAttemptAt
                }
                accumulators[key] = accumulator
            } else {
                accumulators[key] = LinkGroupAccumulator(
                    group: LinkFailureGroup(
                        routeSignature: resource.routeSignature,
                        uniqueURLCount: 1,
                        clipCount: stats.clipCount,
                        copyCount: stats.copyCount,
                        attemptCount: resource.attemptCount,
                        failedAttemptCount: resource.failedAttemptCount,
                        latestRequestState: resource.requestState,
                        latestTitleQuality: resource.titleQuality,
                        currentFallbackTitle: resource.fallbackTitle,
                        currentFallbackState: resource.fallbackState,
                        sampleURL: URLFallbackEngine.redactedDisplayURL(resource.normalizedURL),
                        lastSeenAt: resource.updatedAt,
                        lastAttemptAt: resource.lastAttemptAt
                    ),
                    resourceIDs: [resource.id]
                )
            }
        }
        return accumulators.values.map(\.group)
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .prefix(max(1, min(limit, 10_000)))
            .map { $0 }
    }

    public func unresolvedLinkResources(routeKey: String) throws -> [LinkResource] {
        let statement = try prepare("SELECT payload_json FROM link_resources WHERE route_key=? AND request_state NOT IN (?,?) ORDER BY updated_at DESC;")
        defer { sqlite3_finalize(statement) }
        bind(routeKey, at: 1, to: statement)
        bind(LinkRequestState.resolved.rawValue, at: 2, to: statement)
        bind(LinkRequestState.pending.rawValue, at: 3, to: statement)
        var result = [LinkResource]()
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decode(LinkResource.self, statement: statement, column: 0))
        }
        return result
    }

    public func resolvedLinkResources(limit: Int = 500) throws -> [ResolvedLinkSummary] {
        let statement = try prepare("SELECT payload_json FROM link_resources ORDER BY updated_at DESC;")
        defer { sqlite3_finalize(statement) }
        var result = [ResolvedLinkSummary]()
        let maximum = max(1, min(limit, 10_000))
        while sqlite3_step(statement) == SQLITE_ROW, result.count < maximum {
            let resource = try decode(LinkResource.self, statement: statement, column: 0)
            guard resource.resolvedTitle != nil else { continue }
            let stats = try clipStats(for: resource.id)
            result.append(ResolvedLinkSummary(
                resource: resource,
                clipCount: stats.clipCount,
                copyCount: stats.copyCount
            ))
        }
        return result
    }

    public func userFallbackRules() throws -> [URLFallbackRule] {
        let statement = try prepare("SELECT payload_json FROM url_fallback_rules WHERE origin=? ORDER BY priority,updated_at DESC;")
        defer { sqlite3_finalize(statement) }
        bind(URLFallbackRuleOrigin.user.rawValue, at: 1, to: statement)
        var result = [URLFallbackRule]()
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decode(URLFallbackRule.self, statement: statement, column: 0))
        }
        return result
    }

    public func saveFallbackRule(_ rule: URLFallbackRule) throws {
        let data = try encoder.encode(rule)
        let statement = try prepare("INSERT INTO url_fallback_rules(id,origin,enabled,host_pattern,path_template,title_template,priority,updated_at,payload_json) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET origin=excluded.origin,enabled=excluded.enabled,host_pattern=excluded.host_pattern,path_template=excluded.path_template,title_template=excluded.title_template,priority=excluded.priority,updated_at=excluded.updated_at,payload_json=excluded.payload_json;")
        defer { sqlite3_finalize(statement) }
        bind(rule.id.uuidString, at: 1, to: statement)
        bind(rule.origin.rawValue, at: 2, to: statement)
        sqlite3_bind_int(statement, 3, rule.enabled ? 1 : 0)
        bind(rule.hostPattern, at: 4, to: statement)
        bind(rule.pathTemplate, at: 5, to: statement)
        bind(rule.titleTemplate, at: 6, to: statement)
        sqlite3_bind_int(statement, 7, Int32(rule.priority))
        sqlite3_bind_double(statement, 8, rule.updatedAt.timeIntervalSince1970)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 9, $0.baseAddress, Int32(data.count), Self.transient) }
        try stepDone(statement)
        _ = try reapplyFallbackRules()
    }

    public func removeFallbackRule(id: UUID) throws {
        let statement = try prepare("DELETE FROM url_fallback_rules WHERE id=? AND origin=?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        bind(URLFallbackRuleOrigin.user.rawValue, at: 2, to: statement)
        try stepDone(statement)
        _ = try reapplyFallbackRules()
    }

    public func reapplyFallbackRules() throws -> Int {
        let rules = try userFallbackRules()
        let statement = try prepare("SELECT payload_json FROM link_resources;")
        defer { sqlite3_finalize(statement) }
        var resources = [LinkResource]()
        while sqlite3_step(statement) == SQLITE_ROW {
            resources.append(try decode(LinkResource.self, statement: statement, column: 0))
        }
        var changed = 0
        for var resource in resources {
            guard let url = URLFallbackEngine.normalizedWebURL(resource.normalizedURL) else { continue }
            let fallback = URLFallbackEngine.fallback(for: url, rules: rules)
            guard resource.fallbackTitle != fallback.title
                    || resource.fallbackState != fallback.state
                    || resource.matchedFallbackRuleID != fallback.matchedRuleID
                    || resource.routeSignature != fallback.routeSignature else { continue }
            resource.fallbackTitle = fallback.title
            resource.fallbackState = fallback.state
            resource.matchedFallbackRuleID = fallback.matchedRuleID
            resource.routeSignature = fallback.routeSignature
            resource.updatedAt = Date()
            try saveLinkResource(resource)
            try applyAutomaticTitle(resource.displayTitle, toResourceID: resource.id)
            changed += 1
        }
        return changed
    }

    public func linkTitleRepetitionStats(host: String, routeKey: String, fingerprint: String) throws -> LinkTitleRepetitionStats {
        let routeDistinct = try distinctResourceCount(whereSQL: "lr.host=? AND lr.route_key=?", bindings: [host, routeKey])
        let routeFingerprint = try distinctResourceCount(whereSQL: "lr.host=? AND lr.route_key=? AND a.candidate_fingerprint=?", bindings: [host, routeKey, fingerprint])
        let hostDistinct = try distinctResourceCount(whereSQL: "lr.host=?", bindings: [host])
        let hostFingerprint = try distinctResourceCount(whereSQL: "lr.host=? AND a.candidate_fingerprint=?", bindings: [host, fingerprint])
        let routeStatement = try prepare("SELECT COUNT(DISTINCT lr.route_key) FROM link_resources lr JOIN link_resolution_attempts a ON a.link_resource_id=lr.id WHERE lr.host=? AND a.candidate_fingerprint=?;")
        defer { sqlite3_finalize(routeStatement) }
        bind(host, at: 1, to: routeStatement)
        bind(fingerprint, at: 2, to: routeStatement)
        let routeCount = sqlite3_step(routeStatement) == SQLITE_ROW ? Int(sqlite3_column_int64(routeStatement, 0)) : 0
        return LinkTitleRepetitionStats(
            routeDistinctURLCount: routeDistinct,
            routeFingerprintURLCount: routeFingerprint,
            hostDistinctURLCount: hostDistinct,
            hostFingerprintURLCount: hostFingerprint,
            hostRouteCount: routeCount
        )
    }

    public func rebuildSearchIndex() throws {
        try Self.execute(database, "DELETE FROM clip_fts;")
        for clip in try allClips() { try updateFTS(for: clip) }
    }

    private func saveLinkResource(_ resource: LinkResource) throws {
        let data = try encoder.encode(resource)
        let statement = try prepare("INSERT INTO link_resources(id,normalized_url,host,route_key,request_state,title_quality,fallback_state,updated_at,last_attempt_at,attempt_count,failed_attempt_count,payload_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET normalized_url=excluded.normalized_url,host=excluded.host,route_key=excluded.route_key,request_state=excluded.request_state,title_quality=excluded.title_quality,fallback_state=excluded.fallback_state,updated_at=excluded.updated_at,last_attempt_at=excluded.last_attempt_at,attempt_count=excluded.attempt_count,failed_attempt_count=excluded.failed_attempt_count,payload_json=excluded.payload_json;")
        defer { sqlite3_finalize(statement) }
        bind(resource.id.uuidString, at: 1, to: statement)
        bind(resource.normalizedURL, at: 2, to: statement)
        bind(resource.host, at: 3, to: statement)
        bind(resource.routeSignature.key, at: 4, to: statement)
        bind(resource.requestState.rawValue, at: 5, to: statement)
        bind(resource.titleQuality.rawValue, at: 6, to: statement)
        bind(resource.fallbackState.rawValue, at: 7, to: statement)
        sqlite3_bind_double(statement, 8, resource.updatedAt.timeIntervalSince1970)
        if let lastAttemptAt = resource.lastAttemptAt { sqlite3_bind_double(statement, 9, lastAttemptAt.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 9) }
        sqlite3_bind_int(statement, 10, Int32(resource.attemptCount))
        sqlite3_bind_int(statement, 11, Int32(resource.failedAttemptCount))
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 12, $0.baseAddress, Int32(data.count), Self.transient) }
        try stepDone(statement)
    }

    private func clipStats(for resourceID: UUID) throws -> (clipCount: Int, copyCount: Int) {
        let statement = try prepare("SELECT COUNT(*),COALESCE(SUM(c.copy_count),0) FROM clip_links cl JOIN clips c ON c.id=cl.clip_id WHERE cl.link_resource_id=?;")
        defer { sqlite3_finalize(statement) }
        bind(resourceID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
    }

    private func applyAutomaticTitle(_ title: String, toResourceID resourceID: UUID) throws {
        let statement = try prepare("SELECT clip_id FROM clip_links WHERE link_resource_id=?;")
        defer { sqlite3_finalize(statement) }
        bind(resourceID.uuidString, at: 1, to: statement)
        var ids = [UUID]()
        while sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: value)) { ids.append(id) }
        for id in ids { try applyAutomaticTitle(title, toClipID: id) }
    }

    private func applyAutomaticTitle(_ title: String, toClipID clipID: UUID) throws {
        guard var clip = try clip(id: clipID), clip.automaticTitle != title else { return }
        clip.automaticTitle = String(title.prefix(1_024))
        try save(clip)
    }

    private func distinctResourceCount(whereSQL: String, bindings: [String]) throws -> Int {
        let sql = "SELECT COUNT(DISTINCT lr.normalized_url) FROM link_resources lr JOIN link_resolution_attempts a ON a.link_resource_id=lr.id WHERE \(whereSQL);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() { bind(binding, at: Int32(index + 1), to: statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func latestActiveClip() throws -> Clip? {
        let statement = try prepare("SELECT payload_json FROM clips WHERE deleted_at IS NULL ORDER BY created_at DESC LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeClip(statement, column: 0)
    }

    private func syncCollections(for clip: Clip) throws {
        let delete = try prepare("DELETE FROM clip_collections WHERE clip_id=?;")
        bind(clip.id.uuidString, at: 1, to: delete); try stepDone(delete); sqlite3_finalize(delete)
        for collectionID in clip.collectionIDs {
            let insert = try prepare("INSERT OR IGNORE INTO clip_collections(clip_id,collection_id) VALUES(?,?);")
            bind(clip.id.uuidString, at: 1, to: insert); bind(collectionID.uuidString, at: 2, to: insert)
            try stepDone(insert); sqlite3_finalize(insert)
        }
    }

    private func updateFTS(for clip: Clip) throws {
        let delete = try prepare("DELETE FROM clip_fts WHERE id=?;")
        bind(clip.id.uuidString, at: 1, to: delete); try stepDone(delete); sqlite3_finalize(delete)
        guard clip.deletedAt == nil else { return }
        let groups = try groupNames(for: clip.id).joined(separator: " ")
        let insert = try prepare("INSERT INTO clip_fts(id,title,body,note,groups,source) VALUES(?,?,?,?,?,?);")
        bind(clip.id.uuidString, at: 1, to: insert); bind(clip.displayTitle, at: 2, to: insert)
        bind(clip.previewText, at: 3, to: insert); bind(clip.note, at: 4, to: insert)
        bind(groups, at: 5, to: insert); bind(clip.source.appName, at: 6, to: insert)
        try stepDone(insert); sqlite3_finalize(insert)
    }

    private func groupNames(for clipID: UUID) throws -> [String] {
        let statement = try prepare("SELECT c.name FROM collections c JOIN clip_collections cc ON cc.collection_id=c.id WHERE cc.clip_id=?;")
        defer { sqlite3_finalize(statement) }
        bind(clipID.uuidString, at: 1, to: statement)
        var names = [String]()
        while sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) { names.append(String(cString: value)) }
        return names
    }

    private func decodeClip(_ statement: OpaquePointer, column: Int32) throws -> Clip {
        try decode(Clip.self, statement: statement, column: column)
    }

    private func decode<T: Decodable>(_ type: T.Type, statement: OpaquePointer, column: Int32) throws -> T {
        guard let bytes = sqlite3_column_blob(statement, column) else { throw RepositoryError.encoding }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        return try decoder.decode(type, from: data)
    }

    private func saveCaptureEvent(_ event: ClipCaptureEvent) throws {
        let data = try encoder.encode(event)
        let statement = try prepare("INSERT OR IGNORE INTO clip_capture_events(id,clip_id,captured_at,source_bundle,strategy_id,summary,event_json) VALUES(?,?,?,?,?,?,?);")
        defer { sqlite3_finalize(statement) }
        bind(event.id.uuidString, at: 1, to: statement)
        bind(event.clipID.uuidString, at: 2, to: statement)
        sqlite3_bind_double(statement, 3, event.capturedAt.timeIntervalSince1970)
        bindOptional(event.source.bundleIdentifier, at: 4, to: statement)
        bindOptional(event.context?.strategyIdentifier, at: 5, to: statement)
        bindOptional(event.context?.summary, at: 6, to: statement)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 7, $0.baseAddress, Int32(data.count), Self.transient) }
        try stepDone(statement)

        guard sqlite3_changes(database) > 0, let context = event.context else { return }
        for entity in context.entities {
            let entityData = try encoder.encode(entity)
            let upsert = try prepare("INSERT INTO context_entities(id,kind,provider,display_name,identity_quality,payload_json) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name,identity_quality=excluded.identity_quality,payload_json=excluded.payload_json;")
            bind(entity.id, at: 1, to: upsert)
            bind(entity.kind.rawValue, at: 2, to: upsert)
            bind(entity.provider, at: 3, to: upsert)
            bind(entity.displayName, at: 4, to: upsert)
            bind(entity.identityQuality.rawValue, at: 5, to: upsert)
            _ = entityData.withUnsafeBytes { sqlite3_bind_blob(upsert, 6, $0.baseAddress, Int32(entityData.count), Self.transient) }
            try stepDone(upsert)
            sqlite3_finalize(upsert)

            let join = try prepare("INSERT OR IGNORE INTO capture_event_entities(event_id,entity_id) VALUES(?,?);")
            bind(event.id.uuidString, at: 1, to: join)
            bind(entity.id, at: 2, to: join)
            try stepDone(join)
            sqlite3_finalize(join)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bindOptional(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        if let value { bind(value, at: index, to: statement) } else { sqlite3_bind_null(statement, index) }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func sqliteError() -> RepositoryError { .sqlite(String(cString: sqlite3_errmsg(database))) }

    private func transaction(_ work: () throws -> Void) throws {
        try Self.execute(database, "BEGIN IMMEDIATE;")
        do { try work(); try Self.execute(database, "COMMIT;") }
        catch { try? Self.execute(database, "ROLLBACK;"); throw error }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func idsForSQL(_ sql: String, double: Double) throws -> [UUID] {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, double)
        var result = [UUID]()
        while sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: value)) { result.append(id) }
        return result
    }

    private func ftsQuery(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "未知 SQLite 错误"
            sqlite3_free(error)
            throw RepositoryError.sqlite(message)
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS clips(
          id TEXT PRIMARY KEY, created_at REAL NOT NULL, updated_at REAL NOT NULL, last_copied_at REAL NOT NULL,
          kind TEXT NOT NULL, title TEXT NOT NULL, note TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0,
          favorite INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
          source_name TEXT NOT NULL, source_bundle TEXT, source_confidence TEXT NOT NULL,
          preview_text TEXT NOT NULL, content_hash TEXT NOT NULL, byte_size INTEGER NOT NULL,
          copy_count INTEGER NOT NULL DEFAULT 1, deleted_at REAL, payload_json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_clips_recent ON clips(deleted_at, archived, last_copied_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clips_hash ON clips(content_hash, created_at DESC);
        CREATE TABLE IF NOT EXISTS collections(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, sort_order INTEGER NOT NULL, payload_json BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS clip_collections(
          clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
          collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
          PRIMARY KEY(clip_id, collection_id)
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS clip_fts USING fts5(
          id UNINDEXED, title, body, note, groups, source, tokenize='trigram'
        );
        CREATE TABLE IF NOT EXISTS clip_capture_events(
          id TEXT PRIMARY KEY,
          clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
          captured_at REAL NOT NULL,
          source_bundle TEXT,
          strategy_id TEXT,
          summary TEXT,
          event_json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_capture_events_clip ON clip_capture_events(clip_id, captured_at DESC);
        CREATE INDEX IF NOT EXISTS idx_capture_events_strategy ON clip_capture_events(strategy_id, captured_at DESC);
        CREATE TABLE IF NOT EXISTS context_entities(
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          provider TEXT NOT NULL,
          display_name TEXT NOT NULL,
          identity_quality TEXT NOT NULL,
          payload_json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_context_entities_kind ON context_entities(kind, display_name);
        CREATE TABLE IF NOT EXISTS capture_event_entities(
          event_id TEXT NOT NULL REFERENCES clip_capture_events(id) ON DELETE CASCADE,
          entity_id TEXT NOT NULL REFERENCES context_entities(id) ON DELETE CASCADE,
          PRIMARY KEY(event_id, entity_id)
        );
        CREATE TABLE IF NOT EXISTS link_resources(
          id TEXT PRIMARY KEY,
          normalized_url TEXT NOT NULL UNIQUE,
          host TEXT NOT NULL,
          route_key TEXT NOT NULL,
          request_state TEXT NOT NULL,
          title_quality TEXT NOT NULL,
          fallback_state TEXT NOT NULL,
          updated_at REAL NOT NULL,
          last_attempt_at REAL,
          attempt_count INTEGER NOT NULL DEFAULT 0,
          failed_attempt_count INTEGER NOT NULL DEFAULT 0,
          payload_json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_link_resources_route ON link_resources(route_key,request_state,updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_link_resources_host ON link_resources(host,request_state);
        CREATE TABLE IF NOT EXISTS clip_links(
          clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
          link_resource_id TEXT NOT NULL REFERENCES link_resources(id) ON DELETE CASCADE,
          PRIMARY KEY(clip_id,link_resource_id)
        );
        CREATE INDEX IF NOT EXISTS idx_clip_links_resource ON clip_links(link_resource_id,clip_id);
        CREATE TABLE IF NOT EXISTS link_resolution_attempts(
          id TEXT PRIMARY KEY,
          link_resource_id TEXT NOT NULL REFERENCES link_resources(id) ON DELETE CASCADE,
          started_at REAL NOT NULL,
          finished_at REAL NOT NULL,
          resolver TEXT NOT NULL,
          request_state TEXT NOT NULL,
          title_quality TEXT NOT NULL,
          candidate_fingerprint TEXT,
          error_code TEXT,
          payload_json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_link_attempts_resource ON link_resolution_attempts(link_resource_id,finished_at DESC);
        CREATE INDEX IF NOT EXISTS idx_link_attempts_fingerprint ON link_resolution_attempts(candidate_fingerprint,request_state);
        CREATE TABLE IF NOT EXISTS url_fallback_rules(
          id TEXT PRIMARY KEY,
          origin TEXT NOT NULL,
          enabled INTEGER NOT NULL,
          host_pattern TEXT NOT NULL,
          path_template TEXT NOT NULL,
          title_template TEXT NOT NULL,
          priority INTEGER NOT NULL,
          updated_at REAL NOT NULL,
          payload_json BLOB NOT NULL
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, strftime('%s','now'));
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(2, strftime('%s','now'));
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(3, strftime('%s','now'));
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(4, strftime('%s','now'));
        """)
    }

    private static func normalizeGeneratedFallbackRules(
        _ database: OpaquePointer,
        decoder: JSONDecoder,
        encoder: JSONEncoder
    ) throws {
        let selectSQL = "SELECT id,payload_json FROM url_fallback_rules WHERE origin='user';"
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(database, selectSQL, -1, &select, nil) == SQLITE_OK, let select else {
            throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(select) }
        var updates = [(String, URLFallbackRule)]()
        while sqlite3_step(select) == SQLITE_ROW,
              let idValue = sqlite3_column_text(select, 0),
              let bytes = sqlite3_column_blob(select, 1) {
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(select, 1)))
            guard var rule = try? decoder.decode(URLFallbackRule.self, from: data) else { continue }
            let referenced = URLFallbackEngine.queryVariables(in: rule.titleTemplate)
            let normalized = rule.requiredQueryKeys.filter(referenced.contains)
            guard normalized != rule.requiredQueryKeys else { continue }
            rule.requiredQueryKeys = normalized
            rule.updatedAt = Date()
            updates.append((String(cString: idValue), rule))
        }
        for (id, rule) in updates {
            let data = try encoder.encode(rule)
            let sql = "UPDATE url_fallback_rules SET payload_json=?,updated_at=? WHERE id=?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient)
            }
            sqlite3_bind_double(statement, 2, rule.updatedAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, id, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static func normalizeStoredLinkRouteKeys(_ database: OpaquePointer, decoder: JSONDecoder) throws {
        let selectSQL = "SELECT id,payload_json FROM link_resources;"
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(database, selectSQL, -1, &select, nil) == SQLITE_OK, let select else {
            throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(select) }
        var updates = [(String, String)]()
        while sqlite3_step(select) == SQLITE_ROW,
              let idValue = sqlite3_column_text(select, 0),
              let bytes = sqlite3_column_blob(select, 1) {
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(select, 1)))
            guard let resource = try? decoder.decode(LinkResource.self, from: data) else { continue }
            updates.append((String(cString: idValue), resource.routeSignature.key))
        }
        for (id, routeKey) in updates {
            let sql = "UPDATE link_resources SET route_key=? WHERE id=?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, routeKey, -1, transient)
            sqlite3_bind_text(statement, 2, id, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
    }
}
