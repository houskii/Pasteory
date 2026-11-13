import CryptoKit
import Foundation
import SQLite3
import PasteoryAI

public actor SQLiteClipRepository: ClipRepository {
    nonisolated(unsafe) private let database: OpaquePointer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let storageRoot: URL
    private let intelligencePayloads: ContentPayloadStore
    private var applyingIntelligence = false
    private var intelligenceMaintenance = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct LinkGroupAccumulator {
        var group: LinkFailureGroup
        var resourceIDs = Set<UUID>()
    }

    public init(databaseURL: URL, normalizeExistingData: Bool = true) throws {
        let storageRoot = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
        let payloads = try ContentPayloadStore(
            root: storageRoot.appendingPathComponent("AIContent"),
            rawDirectory: storageRoot.appendingPathComponent("Attachments/AIContentRaw"),
            packedDirectory: storageRoot.appendingPathComponent("Archives/AIContent/Packed"),
            codec: AIPayloadLZFSECodec()
        )
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            throw RepositoryError.openDatabase(pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? L10n.tr("未知错误"))
        }
        self.database = pointer
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.storageRoot = storageRoot
        self.intelligencePayloads = payloads
        self.encoder.dateEncodingStrategy = .millisecondsSince1970
        self.decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            try Self.execute(pointer, "PRAGMA journal_mode=WAL;")
            try Self.execute(pointer, "PRAGMA foreign_keys=ON;")
            try Self.execute(pointer, "PRAGMA busy_timeout=5000;")
            try Self.migrate(pointer)
            if normalizeExistingData {
                try Self.normalizeGeneratedFallbackRules(pointer, decoder: self.decoder, encoder: self.encoder)
                try Self.normalizeStoredLinkRouteKeys(pointer, decoder: self.decoder)
                try Self.normalizeStoredLinkCanonicalKeys(pointer, decoder: self.decoder, encoder: self.encoder)
            }
        } catch {
            sqlite3_close(pointer)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func saveCaptured(_ clip: Clip, context: CapturedSourceContext?) throws -> Clip {
        // Publish the attachment and its reference on the same actor as cleanup.
        var incoming = try AttachmentStore.externalize(clip, into: storageRoot.appendingPathComponent("Attachments"))
        incoming.intelligenceActivity = ContentActivity(lastUsedAt: incoming.createdAt)
        incoming.intelligenceActivity?.record(.copy, at: incoming.createdAt)
        if incoming.identityKey == nil {
            incoming.identityKey = (try? ClipIdentity.key(for: incoming, loadData: loadRepresentationData))
                ?? "legacy:\(incoming.contentHash)"
        }
        var stored = incoming
        try transaction {
            if var previous = try activeClip(identityKey: incoming.deduplicationKey, kind: incoming.primaryKind) {
                previous.copyCount += max(1, incoming.copyCount)
                var activity = previous.activity
                activity.record(.copy, at: incoming.createdAt)
                previous.intelligenceActivity = activity
                previous.lifecycleEvaluation = nil
                previous.lastCopiedAt = max(previous.lastCopiedAt, incoming.createdAt)
                previous.updatedAt = max(previous.updatedAt, incoming.createdAt)
                previous.source = incoming.source
                previous.isArchived = false
                previous.archivePath = nil
                previous.previewText = incoming.previewText
                previous.contentHash = incoming.contentHash
                previous.identityKey = incoming.identityKey
                previous.byteSize = incoming.byteSize
                previous.items = incoming.items
                previous.secondaryKinds.formUnion(incoming.secondaryKinds)
                if previous.automaticTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    previous.automaticTitle = incoming.automaticTitle
                }
                if incoming.codeMetadata != nil { previous.codeMetadata = incoming.codeMetadata }
                if incoming.fileMetadata != nil { previous.fileMetadata = incoming.fileMetadata }
                for transformation in incoming.quickTextTransformations ?? [] {
                    if previous.quickTextTransformations?.contains(transformation) == true { continue }
                    previous.quickTextTransformations = (previous.quickTextTransformations ?? []) + [transformation]
                    if !previous.note.isEmpty { previous.note += "\n\n" }
                    previous.note += transformation.note
                }
                try save(previous)
                stored = previous
            } else {
                try save(incoming)
            }
            try saveCaptureEvent(ClipCaptureEvent(
                clipID: stored.id,
                capturedAt: incoming.createdAt,
                source: incoming.source,
                context: context
            ))
        }
        return stored
    }

    public func save(_ clip: Clip) throws {
        let oldMemberships = applyingIntelligence ? nil : try self.clip(id: clip.id)?.collectionIDs
        let payload = try encoder.encode(clip)
        let sql = """
        INSERT INTO clips (
          id, created_at, updated_at, last_copied_at, last_pasted_at, last_used_at, kind, title, note, priority,
          favorite, pinned, archived, source_name, source_bundle, source_confidence,
          preview_text, content_hash, identity_key, byte_size, copy_count, deleted_at, payload_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          updated_at=excluded.updated_at, last_copied_at=excluded.last_copied_at,
          last_pasted_at=excluded.last_pasted_at, last_used_at=excluded.last_used_at,
          kind=excluded.kind, title=excluded.title, note=excluded.note,
          priority=excluded.priority, favorite=excluded.favorite, pinned=excluded.pinned,
          archived=excluded.archived, source_name=excluded.source_name,
          source_bundle=excluded.source_bundle, source_confidence=excluded.source_confidence,
          preview_text=excluded.preview_text, content_hash=excluded.content_hash,
          identity_key=excluded.identity_key,
          byte_size=excluded.byte_size, copy_count=excluded.copy_count,
          deleted_at=excluded.deleted_at, payload_json=excluded.payload_json;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(clip.id.uuidString, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, clip.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, clip.updatedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, clip.lastCopiedAt.timeIntervalSince1970)
        if let lastPastedAt = clip.lastPastedAt { sqlite3_bind_double(statement, 5, lastPastedAt.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 5) }
        sqlite3_bind_double(statement, 6, clip.lastUsedAt.timeIntervalSince1970)
        bind(clip.primaryKind.rawValue, at: 7, to: statement)
        bind(clip.displayTitle, at: 8, to: statement)
        bind(clip.note, at: 9, to: statement)
        sqlite3_bind_int(statement, 10, Int32(clip.priority))
        sqlite3_bind_int(statement, 11, clip.isFavorite ? 1 : 0)
        sqlite3_bind_int(statement, 12, clip.isPinned ? 1 : 0)
        sqlite3_bind_int(statement, 13, clip.isArchived ? 1 : 0)
        bind(clip.source.appName, at: 14, to: statement)
        bindOptional(clip.source.bundleIdentifier, at: 15, to: statement)
        bind(clip.source.confidence.rawValue, at: 16, to: statement)
        bind(clip.previewText, at: 17, to: statement)
        bind(clip.contentHash, at: 18, to: statement)
        bindOptional(clip.identityKey, at: 19, to: statement)
        sqlite3_bind_int64(statement, 20, Int64(clip.byteSize))
        sqlite3_bind_int(statement, 21, Int32(clip.copyCount))
        if let deletedAt = clip.deletedAt { sqlite3_bind_double(statement, 22, deletedAt.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 22) }
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 23, bytes.baseAddress, Int32(payload.count), Self.transient)
        }
        try stepDone(statement)
        try syncCollections(for: clip)
        try updateFTS(for: clip)
        if let oldMemberships, oldMemberships != clip.collectionIDs {
            try recordManualAIMembershipChange(before: oldMemberships, clip: clip)
        }
    }

    public func saveBatch(_ clips: [Clip]) throws {
        try transaction {
            for clip in clips { try save(clip) }
        }
    }

    public func updateExisting(_ clip: Clip) throws {
        try transaction {
            let statement = try prepare("SELECT 1 FROM clips WHERE id=?;")
            defer { sqlite3_finalize(statement) }
            bind(clip.id.uuidString, at: 1, to: statement)
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try save(clip)
            case SQLITE_DONE: return
            default: throw sqliteError()
            }
        }
    }

    public func saveArchived(_ clip: Clip, replacing original: Clip) throws -> Bool {
        // Compare at the same precision as the persisted record.
        let expected = try decoder.decode(Clip.self, from: encoder.encode(original))
        var saved = false
        try transaction {
            guard try self.clip(id: original.id) == expected else { return }
            try save(clip)
            saved = true
        }
        return saved
    }

    public func consolidateDuplicateClips() throws -> Int {
        var mergedCount = 0
        try transaction {
            try backfillIdentityKeys()
            mergedCount = try consolidateActiveDuplicateClips()
        }
        return mergedCount
    }

    public func clip(id: UUID) throws -> Clip? {
        let statement = try prepare("SELECT payload_json FROM clips WHERE id=? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeClip(statement, column: 0)
    }

    public func clips(ids: [UUID]) throws -> [Clip] {
        var seen = Set<UUID>()
        let uniqueIDs = ids.filter { seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return [] }
        var byID = [UUID: Clip]()
        let chunkSize = 500
        for start in stride(from: 0, to: uniqueIDs.count, by: chunkSize) {
            let end = min(start + chunkSize, uniqueIDs.count)
            let chunk = Array(uniqueIDs[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let statement = try prepare("SELECT payload_json FROM clips WHERE id IN (\(placeholders));")
            defer { sqlite3_finalize(statement) }
            for (index, id) in chunk.enumerated() {
                bind(id.uuidString, at: Int32(index + 1), to: statement)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let value = try decodeClip(statement, column: 0)
                byID[value.id] = value
            }
        }
        return uniqueIDs.compactMap { byID[$0] }
    }

    public func recordPaste(id: UUID, at date: Date) throws -> Clip? {
        guard var clip = try clip(id: id) else { return nil }
        clip.pasteCount = clip.recordedPasteCount + 1
        clip.lastPastedAt = date
        var activity = clip.activity; activity.record(.paste, at: date)
        clip.intelligenceActivity = activity; clip.lifecycleEvaluation = nil
        clip.updatedAt = date
        try save(clip)
        return clip
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
        let ordering = "c.pinned DESC, c.last_used_at DESC"
        let sql = "SELECT c.payload_json FROM clips c \(join) WHERE \(whereSQL) ORDER BY \(ordering) LIMIT ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { bind(value, at: Int32(index + 1), to: statement) }
        sqlite3_bind_int(statement, Int32(bindings.count + 1), Int32(max(1, min(limit, 100_000))))
        var clips = [Clip]()
        while sqlite3_step(statement) == SQLITE_ROW { clips.append(try decodeClip(statement, column: 0)) }
        return clips
    }

    public func removePermanently(id: UUID) async throws {
        guard !intelligenceMaintenance else { throw AIError.conflict("Storage maintenance is in progress; retry shortly") }
        intelligenceMaintenance = true; defer { intelligenceMaintenance = false }
        try transaction {
            try deleteClipRows(id: id)
            try Self.execute(database, "DELETE FROM clip_merge_backups WHERE canonical_id=?;", bindings: [id.uuidString])
            try removeUnusedClipMetadata()
        }
        _ = try await reconcileAIPayloads(purge: true)
    }

    private func deleteClipRows(id: UUID) throws {
        try pruneAIContent(id: id)
        try Self.execute(database, "DELETE FROM clip_fts WHERE id=?;", bindings: [id.uuidString])
        try Self.execute(database, "DELETE FROM clips WHERE id=?;", bindings: [id.uuidString])
    }

    private func removeUnusedClipMetadata() throws {
        try Self.execute(database, "DELETE FROM aggregations WHERE (SELECT COUNT(*) FROM aggregation_members m WHERE m.aggregation_id=aggregations.id)<2;")
        try Self.execute(database, "DELETE FROM context_entities WHERE NOT EXISTS (SELECT 1 FROM capture_event_entities j WHERE j.entity_id=context_entities.id);")
    }

    public func previewHistoryCleanup(olderThan cutoff: Date, largerThan minimumBytes: Int64) throws -> HistoryCleanupPreview {
        let statement = try prepare("""
            SELECT c.payload_json FROM clips c
            WHERE c.last_used_at < ? AND c.favorite=0 AND c.pinned=0
              AND NOT EXISTS (SELECT 1 FROM clip_collections cc WHERE cc.clip_id=c.id)
              AND NOT EXISTS (SELECT 1 FROM aggregation_members am WHERE am.clip_id=c.id)
            ORDER BY c.last_used_at, c.id;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        var entries = [HistoryCleanupEntry]()
        var candidates = [HistoryStoredFile: HistoryFileSize]()
        var sizes = [HistoryStoredFile: HistoryFileSize]()
        var missing = Set<HistoryStoredFile>()
        func size(of file: HistoryStoredFile) -> HistoryFileSize? {
            if let size = sizes[file] { return size }
            guard !missing.contains(file), let size = file.size(in: storageRoot) else {
                missing.insert(file)
                return nil
            }
            sizes[file] = size
            return size
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteError() }
            let clip = try decodeClip(statement, column: 0)
            let files = clip.historyStoredFiles
            let byteCount = clip.items.flatMap(\.representations).reduce(Int64(0)) { count, representation in
                if case .inline(let data) = representation.storage { return count + Int64(data.count) }
                return count
            } + files.reduce(Int64(0)) { $0 + (size(of: $1)?.logical ?? 0) }
            guard byteCount > minimumBytes else { continue }
            entries.append(HistoryCleanupEntry(
                id: clip.id, title: String((clip.displayTitle.isEmpty ? clip.previewText : clip.displayTitle).prefix(160)),
                lastUsedAt: clip.lastUsedAt,
                byteCount: byteCount, updatedAt: clip.updatedAt
            ))
            for file in files { candidates[file] = size(of: file) }
        }

        if !entries.isEmpty {
            let selected = Set(entries.map { $0.id.uuidString })
            let references = try prepare("""
                SELECT b.id, b.canonical_id, b.payload_json FROM clip_merge_backups b
                UNION ALL
                SELECT c.id, NULL, c.payload_json FROM clips c;
                """)
            defer { sqlite3_finalize(references) }
            var retained = Set<HistoryStoredFile>()
            while true {
                let step = sqlite3_step(references)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW, let rowID = sqlite3_column_text(references, 0) else { throw sqliteError() }
                if let canonical = sqlite3_column_text(references, 1) {
                    let files = try decodeClip(references, column: 2).historyStoredFiles
                    if selected.contains(String(cString: canonical)) {
                        for file in files { candidates[file] = size(of: file) }
                    } else { retained.formUnion(files) }
                } else if !selected.contains(String(cString: rowID)), !candidates.isEmpty {
                    retained.formUnion(try decodeClip(references, column: 2).historyStoredFiles)
                }
            }
            // Treat case variants as shared too on case-insensitive volumes.
            let retainedPaths = Set(retained.map { "\($0.directory)/\($0.relativePath.lowercased())" })
            candidates = candidates.filter { !retainedPaths.contains("\($0.key.directory)/\($0.key.relativePath.lowercased())") }
        }
        return HistoryCleanupPreview(
            cutoff: cutoff, minimumBytes: minimumBytes, entries: entries,
            reclaimableBytes: candidates.values.reduce(0) { $0 + $1.allocated }, files: candidates
        )
    }

    public func cleanHistory(_ preview: HistoryCleanupPreview) async throws -> HistoryCleanupResult {
        guard !preview.entries.isEmpty else { return HistoryCleanupResult(deletedCount: 0, freedBytes: 0, failedFileCount: 0) }
        guard !intelligenceMaintenance else { throw AIError.conflict("Storage maintenance is in progress; retry shortly") }
        intelligenceMaintenance = true; defer { intelligenceMaintenance = false }
        try transaction {
            guard try previewHistoryCleanup(olderThan: preview.cutoff, largerThan: preview.minimumBytes) == preview else {
                throw HistoryCleanupError.previewChanged
            }
            for entry in preview.entries {
                try deleteClipRows(id: entry.id)
                try Self.execute(database, "DELETE FROM clip_merge_backups WHERE canonical_id=?;", bindings: [entry.id.uuidString])
            }
            try removeUnusedClipMetadata()
        }
        var freedBytes: Int64 = 0
        var failedFileCount = 0
        for (file, size) in preview.files {
            if file.relativePath.hasPrefix("AIContentRaw/") || file.relativePath.hasPrefix("AIContent/Packed/") { continue }
            if file.remove(in: storageRoot, expectedSize: size) { freedBytes += size.allocated }
            else { failedFileCount += 1 }
        }
        freedBytes += Int64(try await reconcileAIPayloads(purge: true))
        return HistoryCleanupResult(deletedCount: preview.entries.count, freedBytes: freedBytes, failedFileCount: failedFileCount)
    }

    public func purgeTrash(olderThan date: Date) async throws -> Int {
        let ids = try idsForSQL("SELECT id FROM clips WHERE deleted_at IS NOT NULL AND deleted_at < ?;", double: date.timeIntervalSince1970)
        for id in ids { try await removePermanently(id: id) }
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

    public func storedClipKindCounts(since startDate: Date?, before endDate: Date?) throws -> [ClipKindCount] {
        var conditions = ["deleted_at IS NULL"]
        if startDate != nil { conditions.append("last_copied_at>=?") }
        if endDate != nil { conditions.append("last_copied_at<?") }
        let sql = "SELECT kind, COUNT(*) FROM clips WHERE \(conditions.joined(separator: " AND ")) GROUP BY kind;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var bindingIndex: Int32 = 1
        if let startDate {
            sqlite3_bind_double(statement, bindingIndex, startDate.timeIntervalSince1970)
            bindingIndex += 1
        }
        if let endDate { sqlite3_bind_double(statement, bindingIndex, endDate.timeIntervalSince1970) }

        var result = [ClipKindCount]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kindText = sqlite3_column_text(statement, 0),
                  let kind = ClipKind(rawValue: String(cString: kindText)) else { continue }
            result.append(ClipKindCount(kind: kind, count: Int(sqlite3_column_int64(statement, 1))))
        }
        return result.sorted { $0.kind.rawValue < $1.kind.rawValue }
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
        let oldName = applyingIntelligence ? nil : try collections().first(where: { $0.id == collection.id })?.name
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
        if !applyingIntelligence {
            try rebuildSearchIndex()
            if let oldName, oldName != collection.name {
                try updateAIState { state in
                    if var group = state.groups[collection.id] {
                        group.name = collection.name; group.nameIsManual = true; group.revision += 1
                        state.groups[group.id] = group
                    }
                }
            }
        }
    }

    public func removeCollection(id: UUID) throws {
        func work() throws {
            let oldApplying = applyingIntelligence; applyingIntelligence = true
            defer { applyingIntelligence = oldApplying }
            for var clip in try allClips() where clip.collectionIDs.contains(id) {
                clip.collectionIDs.remove(id); try save(clip)
            }
            if !oldApplying { try updateAIState { state in state.groups.removeValue(forKey: id) } }
            let statement = try prepare("DELETE FROM collections WHERE id=?;")
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, to: statement); try stepDone(statement)
            try rebuildSearchIndex()
        }
        if sqlite3_get_autocommit(database) == 0 { try work() } else { try transaction(work) }
    }

    public func allClips() throws -> [Clip] {
        let statement = try prepare("SELECT payload_json FROM clips ORDER BY created_at;")
        defer { sqlite3_finalize(statement) }
        var result = [Clip]()
        while sqlite3_step(statement) == SQLITE_ROW { result.append(try decodeClip(statement, column: 0)) }
        return result
    }

    public func aggregations() throws -> [ClipAggregation] {
        let statement = try prepare("SELECT payload_json FROM aggregations ORDER BY pinned DESC,updated_at DESC;")
        defer { sqlite3_finalize(statement) }
        var result = [ClipAggregation]()
        while sqlite3_step(statement) == SQLITE_ROW {
            var value = try decode(ClipAggregation.self, statement: statement, column: 0)
            value.memberClipIDs = try aggregationMemberIDs(value.id)
            value.normalizeMembers()
            if value.memberClipIDs.count >= 2 { result.append(value) }
        }
        return result
    }

    public func aggregation(id: UUID) throws -> ClipAggregation? {
        let statement = try prepare("SELECT payload_json FROM aggregations WHERE id=? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        var value = try decode(ClipAggregation.self, statement: statement, column: 0)
        value.memberClipIDs = try aggregationMemberIDs(value.id)
        value.normalizeMembers()
        return value.memberClipIDs.count >= 2 ? value : nil
    }

    @discardableResult
    public func saveAggregation(_ aggregation: ClipAggregation) throws -> ClipAggregation {
        var value = aggregation
        value.normalizeMembers()
        var validIDs = [UUID]()
        for id in value.memberClipIDs {
            if let member = try clip(id: id), member.deletedAt == nil { validIDs.append(id) }
        }
        value.memberClipIDs = validIDs
        guard value.memberClipIDs.count >= 2 else { throw RepositoryError.aggregationNeedsMultipleItems }
        value.title = String(value.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        value.note = String(value.note.prefix(4_000))
        let data = try encoder.encode(value)
        try transaction {
            let statement = try prepare("INSERT INTO aggregations(id,title,note,created_at,updated_at,favorite,pinned,membership_mode,payload_json) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,note=excluded.note,updated_at=excluded.updated_at,favorite=excluded.favorite,pinned=excluded.pinned,membership_mode=excluded.membership_mode,payload_json=excluded.payload_json;")
            bind(value.id.uuidString, at: 1, to: statement)
            bind(value.displayTitle, at: 2, to: statement)
            bind(value.note, at: 3, to: statement)
            sqlite3_bind_double(statement, 4, value.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, value.updatedAt.timeIntervalSince1970)
            sqlite3_bind_int(statement, 6, value.isFavorite ? 1 : 0)
            sqlite3_bind_int(statement, 7, value.isPinned ? 1 : 0)
            bind(value.membershipMode.rawValue, at: 8, to: statement)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 9, $0.baseAddress, Int32(data.count), Self.transient) }
            try stepDone(statement)
            sqlite3_finalize(statement)

            let remove = try prepare("DELETE FROM aggregation_members WHERE aggregation_id=?;")
            bind(value.id.uuidString, at: 1, to: remove)
            try stepDone(remove)
            sqlite3_finalize(remove)
            for (position, clipID) in value.memberClipIDs.enumerated() {
                let insert = try prepare("INSERT INTO aggregation_members(aggregation_id,clip_id,position) VALUES(?,?,?);")
                bind(value.id.uuidString, at: 1, to: insert)
                bind(clipID.uuidString, at: 2, to: insert)
                sqlite3_bind_int(insert, 3, Int32(position))
                try stepDone(insert)
                sqlite3_finalize(insert)
            }
        }
        return value
    }

    public func removeAggregation(id: UUID) throws {
        let statement = try prepare("DELETE FROM aggregations WHERE id=?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        try stepDone(statement)
    }

    private func aggregationMemberIDs(_ aggregationID: UUID) throws -> [UUID] {
        let statement = try prepare("SELECT clip_id FROM aggregation_members WHERE aggregation_id=? ORDER BY position;")
        defer { sqlite3_finalize(statement) }
        bind(aggregationID.uuidString, at: 1, to: statement)
        var result = [UUID]()
        while sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: raw)) {
            result.append(id)
        }
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
        let key = proposed.effectiveCanonicalResourceKey
        let existing = try linkResource(canonicalResourceKey: key)
        var resource = existing ?? proposed
        resource.canonicalResourceKey = key
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
        guard let url = URLFallbackEngine.normalizedWebURL(normalizedURL) else { return nil }
        return try linkResource(canonicalResourceKey: URLFallbackEngine.canonicalResourceKey(for: url))
    }

    public func linkResource(canonicalResourceKey: String) throws -> LinkResource? {
        let statement = try prepare("SELECT payload_json FROM link_resources WHERE canonical_resource_key=? ORDER BY updated_at DESC LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(canonicalResourceKey, at: 1, to: statement)
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
        let statement = try prepare("INSERT INTO link_resources(id,normalized_url,canonical_resource_key,host,route_key,request_state,title_quality,fallback_state,updated_at,last_attempt_at,attempt_count,failed_attempt_count,payload_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET normalized_url=excluded.normalized_url,canonical_resource_key=excluded.canonical_resource_key,host=excluded.host,route_key=excluded.route_key,request_state=excluded.request_state,title_quality=excluded.title_quality,fallback_state=excluded.fallback_state,updated_at=excluded.updated_at,last_attempt_at=excluded.last_attempt_at,attempt_count=excluded.attempt_count,failed_attempt_count=excluded.failed_attempt_count,payload_json=excluded.payload_json;")
        defer { sqlite3_finalize(statement) }
        bind(resource.id.uuidString, at: 1, to: statement)
        bind(resource.normalizedURL, at: 2, to: statement)
        bind(resource.effectiveCanonicalResourceKey, at: 3, to: statement)
        bind(resource.host, at: 4, to: statement)
        bind(resource.routeSignature.key, at: 5, to: statement)
        bind(resource.requestState.rawValue, at: 6, to: statement)
        bind(resource.titleQuality.rawValue, at: 7, to: statement)
        bind(resource.fallbackState.rawValue, at: 8, to: statement)
        sqlite3_bind_double(statement, 9, resource.updatedAt.timeIntervalSince1970)
        if let lastAttemptAt = resource.lastAttemptAt { sqlite3_bind_double(statement, 10, lastAttemptAt.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 10) }
        sqlite3_bind_int(statement, 11, Int32(resource.attemptCount))
        sqlite3_bind_int(statement, 12, Int32(resource.failedAttemptCount))
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 13, $0.baseAddress, Int32(data.count), Self.transient) }
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

    private func activeClip(identityKey: String, kind: ClipKind) throws -> Clip? {
        let statement = try prepare("SELECT payload_json FROM clips WHERE deleted_at IS NULL AND identity_key=? AND kind=? ORDER BY created_at LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(identityKey, at: 1, to: statement)
        bind(kind.rawValue, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeClip(statement, column: 0)
    }

    private func backfillIdentityKeys() throws {
        let statement = try prepare("SELECT payload_json FROM clips WHERE identity_key IS NULL OR identity_key='';")
        var clips = [Clip]()
        while sqlite3_step(statement) == SQLITE_ROW {
            clips.append(try decodeClip(statement, column: 0))
        }
        sqlite3_finalize(statement)

        for var clip in clips {
            clip.identityKey = (try? ClipIdentity.key(for: clip, loadData: loadRepresentationData))
                ?? "legacy:\(clip.contentHash)"
            try save(clip)
        }
    }

    private func consolidateActiveDuplicateClips() throws -> Int {
        let groups = try prepare("SELECT kind,identity_key FROM clips WHERE deleted_at IS NULL GROUP BY kind,identity_key HAVING COUNT(*)>1;")
        var identities = [(String, String)]()
        while sqlite3_step(groups) == SQLITE_ROW,
              let kind = sqlite3_column_text(groups, 0),
              let hash = sqlite3_column_text(groups, 1) {
            identities.append((String(cString: kind), String(cString: hash)))
        }
        sqlite3_finalize(groups)

        var removed = 0
        for (kind, identityKey) in identities {
            let statement = try prepare("SELECT payload_json FROM clips WHERE deleted_at IS NULL AND kind=? AND identity_key=? ORDER BY created_at,id;")
            bind(kind, at: 1, to: statement)
            bind(identityKey, at: 2, to: statement)
            var members = [Clip]()
            while sqlite3_step(statement) == SQLITE_ROW { members.append(try decodeClip(statement, column: 0)) }
            sqlite3_finalize(statement)
            guard members.count > 1 else { continue }
            try mergeDuplicateGroup(members)
            removed += members.count - 1
        }
        try Self.execute(database, "DELETE FROM aggregations WHERE (SELECT COUNT(*) FROM aggregation_members m WHERE m.aggregation_id=aggregations.id)<2;")
        return removed
    }

    private func mergeDuplicateGroup(_ members: [Clip]) throws {
        guard var canonical = members.first else { return }
        let originalAI = try aiState()
        for member in members { try ensureCaptureEventExists(for: member) }

        let latest = members.max { $0.lastUsedAt < $1.lastUsedAt } ?? canonical
        canonical.createdAt = members.map(\.createdAt).min() ?? canonical.createdAt
        canonical.updatedAt = members.map(\.updatedAt).max() ?? canonical.updatedAt
        canonical.lastCopiedAt = members.map(\.lastCopiedAt).max() ?? canonical.lastCopiedAt
        canonical.lastPastedAt = members.compactMap(\.lastPastedAt).max()
        canonical.source = latest.source
        canonical.previewText = latest.previewText
        canonical.contentHash = latest.contentHash
        canonical.identityKey = latest.identityKey
        canonical.byteSize = latest.byteSize
        canonical.items = latest.items
        canonical.archivePath = latest.archivePath
        canonical.fileMetadata = latest.fileMetadata
        canonical.copyCount = members.reduce(0) { $0 + max(1, $1.copyCount) }
        canonical.pasteCount = members.reduce(0) { $0 + $1.recordedPasteCount }
        canonical.isFavorite = members.contains(where: \.isFavorite)
        canonical.isPinned = members.contains(where: \.isPinned)
        canonical.isArchived = members.allSatisfy(\.isArchived)
        canonical.aiAnalysisExcluded = members.contains { $0.aiAnalysisExcluded == true } ? true : canonical.aiAnalysisExcluded
        let activitySamples = Set(members.flatMap { $0.activity.samples }).sorted { $0.at < $1.at }
        canonical.intelligenceActivity = ContentActivity(lastUsedAt: members.map { $0.activity.lastUsedAt }.max() ?? canonical.lastUsedAt,
                                                        samples: Array(activitySamples.suffix(4096)))
        canonical.lifecycleEvaluation = nil
        canonical.priority = members.map(\.priority).max() ?? canonical.priority
        canonical.collectionIDs = members.reduce(into: Set<UUID>()) { $0.formUnion($1.collectionIDs) }
        canonical.secondaryKinds = members.reduce(into: Set<ClipKind>()) { $0.formUnion($1.secondaryKinds) }
        canonical.title = firstNonempty(members.map(\.title))
        canonical.note = firstNonempty(members.map(\.note))
        let transformations = members.flatMap { $0.quickTextTransformations ?? [] }
            .reduce(into: [QuickTextTransformation]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
        canonical.quickTextTransformations = transformations.isEmpty ? nil : transformations
        for transformation in transformations where !canonical.note.contains(transformation.note) {
            if !canonical.note.isEmpty { canonical.note += "\n\n" }
            canonical.note += transformation.note
        }
        canonical.automaticTitle = members.compactMap(\.automaticTitle).first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        canonical.codeMetadata = members.compactMap(\.codeMetadata).first
        try save(canonical)

        for duplicate in members.dropFirst() {
            let backupData = try encoder.encode(duplicate)
            let backup = try prepare("INSERT OR REPLACE INTO clip_merge_backups(id,canonical_id,merged_at,payload_json) VALUES(?,?,?,?);")
            bind(duplicate.id.uuidString, at: 1, to: backup)
            bind(canonical.id.uuidString, at: 2, to: backup)
            sqlite3_bind_double(backup, 3, Date().timeIntervalSince1970)
            _ = backupData.withUnsafeBytes { sqlite3_bind_blob(backup, 4, $0.baseAddress, Int32(backupData.count), Self.transient) }
            try stepDone(backup)
            sqlite3_finalize(backup)
            try moveCaptureEvents(from: duplicate.id, to: canonical.id)
            try copyJoinRows(
                insertSQL: "INSERT OR IGNORE INTO clip_links(clip_id,link_resource_id) SELECT ?,link_resource_id FROM clip_links WHERE clip_id=?;",
                deleteSQL: "DELETE FROM clip_links WHERE clip_id=?;",
                from: duplicate.id,
                to: canonical.id
            )
            try copyJoinRows(
                insertSQL: "INSERT OR IGNORE INTO aggregation_members(aggregation_id,clip_id,position) SELECT aggregation_id,?,position FROM aggregation_members WHERE clip_id=?;",
                deleteSQL: "DELETE FROM aggregation_members WHERE clip_id=?;",
                from: duplicate.id,
                to: canonical.id
            )
            let fts = try prepare("DELETE FROM clip_fts WHERE id=?;")
            bind(duplicate.id.uuidString, at: 1, to: fts)
            try stepDone(fts)
            sqlite3_finalize(fts)
            let delete = try prepare("DELETE FROM clips WHERE id=?;")
            bind(duplicate.id.uuidString, at: 1, to: delete)
            try stepDone(delete)
            sqlite3_finalize(delete)
        }
        var state = try aiState()
        let identities = Set(members.map(\.id)), removed = identities.subtracting([canonical.id])
        for (id, var group) in state.groups {
            guard let previous = originalAI.groups[id], !previous.memberIDs.isDisjoint(with: identities) || !previous.excludedClipIDs.isDisjoint(with: identities) else { continue }
            let manual = members.contains { $0.collectionIDs.contains(id) && !previous.aiMemberIDs.contains($0.id) }
            group.memberIDs.subtract(identities); group.aiMemberIDs.subtract(identities)
            if canonical.collectionIDs.contains(id) {
                group.memberIDs.insert(canonical.id)
                if !manual { group.aiMemberIDs.insert(canonical.id) }
            }
            if !previous.excludedClipIDs.isDisjoint(with: identities) {
                group.excludedClipIDs.subtract(identities); group.excludedClipIDs.insert(canonical.id)
            }
            group.revision += 1; group.overviewMemberFingerprint = ""; state.groups[id] = group
        }
        state.summaries = state.summaries.filter { Set($0.value.sourceRevisions.keys).isDisjoint(with: removed) }
        let invalid = state.changes.filter { !Set($0.clipRevisions.keys).isDisjoint(with: identities) }.map(\.id)
        state.changes.removeAll { !Set($0.clipRevisions.keys).isDisjoint(with: identities) }
        for id in invalid { try Self.execute(database, "DELETE FROM intelligence_undo WHERE id=?;", bindings: [id.uuidString]) }
        if let checkpoint = state.checkpoint, !Set(checkpoint.clipIDs).isDisjoint(with: identities) { state.checkpoint = nil }
        try writeAIState(state)
    }

    private func firstNonempty(_ values: [String]) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    private func ensureCaptureEventExists(for clip: Clip) throws {
        let statement = try prepare("SELECT 1 FROM clip_capture_events WHERE clip_id=? LIMIT 1;")
        bind(clip.id.uuidString, at: 1, to: statement)
        let exists = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)
        guard !exists else { return }
        try saveCaptureEvent(ClipCaptureEvent(
            clipID: clip.id,
            capturedAt: clip.lastCopiedAt,
            source: clip.source
        ))
    }

    private func moveCaptureEvents(from oldID: UUID, to newID: UUID) throws {
        let statement = try prepare("SELECT id,event_json FROM clip_capture_events WHERE clip_id=?;")
        bind(oldID.uuidString, at: 1, to: statement)
        var events = [(String, ClipCaptureEvent)]()
        while sqlite3_step(statement) == SQLITE_ROW,
              let id = sqlite3_column_text(statement, 0) {
            events.append((String(cString: id), try decode(ClipCaptureEvent.self, statement: statement, column: 1)))
        }
        sqlite3_finalize(statement)
        for (id, original) in events {
            var event = original
            event.clipID = newID
            let data = try encoder.encode(event)
            let update = try prepare("UPDATE clip_capture_events SET clip_id=?,event_json=? WHERE id=?;")
            bind(newID.uuidString, at: 1, to: update)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(update, 2, $0.baseAddress, Int32(data.count), Self.transient) }
            bind(id, at: 3, to: update)
            try stepDone(update)
            sqlite3_finalize(update)
        }
    }

    private func copyJoinRows(insertSQL: String, deleteSQL: String, from oldID: UUID, to newID: UUID) throws {
        let insert = try prepare(insertSQL)
        bind(newID.uuidString, at: 1, to: insert)
        bind(oldID.uuidString, at: 2, to: insert)
        try stepDone(insert)
        sqlite3_finalize(insert)
        let delete = try prepare(deleteSQL)
        bind(oldID.uuidString, at: 1, to: delete)
        try stepDone(delete)
        sqlite3_finalize(delete)
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

    private func loadRepresentationData(_ representation: ClipRepresentation) throws -> Data {
        try AttachmentStore.loadData(for: representation, storageRoot: storageRoot)
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
            let message = error.map { String(cString: $0) } ?? L10n.tr("未知 SQLite 错误")
            sqlite3_free(error)
            throw RepositoryError.sqlite(message)
        }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String, bindings: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS intelligence_state(id INTEGER PRIMARY KEY CHECK(id=1), payload_json BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS intelligence_undo(id TEXT PRIMARY KEY, payload_json BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS clips(
          id TEXT PRIMARY KEY, created_at REAL NOT NULL, updated_at REAL NOT NULL, last_copied_at REAL NOT NULL,
          last_pasted_at REAL, last_used_at REAL NOT NULL,
          kind TEXT NOT NULL, title TEXT NOT NULL, note TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0,
          favorite INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
          source_name TEXT NOT NULL, source_bundle TEXT, source_confidence TEXT NOT NULL,
          preview_text TEXT NOT NULL, content_hash TEXT NOT NULL, identity_key TEXT, byte_size INTEGER NOT NULL,
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
          canonical_resource_key TEXT NOT NULL,
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
        CREATE TABLE IF NOT EXISTS aggregations(
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          note TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          favorite INTEGER NOT NULL DEFAULT 0,
          pinned INTEGER NOT NULL DEFAULT 0,
          membership_mode TEXT NOT NULL,
          payload_json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_aggregations_recent ON aggregations(pinned DESC,updated_at DESC);
        CREATE TABLE IF NOT EXISTS aggregation_members(
          aggregation_id TEXT NOT NULL REFERENCES aggregations(id) ON DELETE CASCADE,
          clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          PRIMARY KEY(aggregation_id,clip_id)
        );
        CREATE INDEX IF NOT EXISTS idx_aggregation_members_clip ON aggregation_members(clip_id,aggregation_id);
        CREATE TABLE IF NOT EXISTS clip_merge_backups(
          id TEXT PRIMARY KEY,
          canonical_id TEXT NOT NULL,
          merged_at REAL NOT NULL,
          payload_json BLOB NOT NULL
        );
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
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(5, strftime('%s','now'));
        """)
        try ensureColumn(database, table: "clips", column: "last_pasted_at", definition: "REAL")
        try ensureColumn(database, table: "clips", column: "last_used_at", definition: "REAL")
        try ensureColumn(database, table: "clips", column: "identity_key", definition: "TEXT")
        try ensureColumn(database, table: "link_resources", column: "canonical_resource_key", definition: "TEXT")
        try execute(database, "UPDATE clips SET last_used_at=last_copied_at WHERE last_used_at IS NULL;")
        try execute(database, "CREATE INDEX IF NOT EXISTS idx_clips_used ON clips(deleted_at,archived,pinned DESC,last_used_at DESC);")
        try execute(database, "CREATE INDEX IF NOT EXISTS idx_clips_identity ON clips(identity_key,kind,created_at);")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(6,strftime('%s','now'));")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(8,strftime('%s','now'));")
    }

    private static func ensureColumn(
        _ database: OpaquePointer,
        table: String,
        column: String,
        definition: String
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW,
              let name = sqlite3_column_text(statement, 1) {
            if String(cString: name) == column { return }
        }
        try execute(database, "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
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

    private static func normalizeStoredLinkCanonicalKeys(
        _ database: OpaquePointer,
        decoder: JSONDecoder,
        encoder: JSONEncoder
    ) throws {
        let selectSQL = "SELECT id,payload_json FROM link_resources;"
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(database, selectSQL, -1, &select, nil) == SQLITE_OK, let select else {
            throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(select) }
        var groups = [String: [(id: String, resource: LinkResource)]]()
        while sqlite3_step(select) == SQLITE_ROW,
              let idValue = sqlite3_column_text(select, 0),
              let bytes = sqlite3_column_blob(select, 1) {
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(select, 1)))
            guard var resource = try? decoder.decode(LinkResource.self, from: data),
                  let url = URLFallbackEngine.normalizedWebURL(resource.normalizedURL) else { continue }
            let key = URLFallbackEngine.canonicalResourceKey(for: url)
            resource.canonicalResourceKey = key
            if resource.lastResolvedAt == nil, resource.requestState == .resolved {
                resource.lastResolvedAt = resource.lastAttemptAt ?? resource.updatedAt
            }
            groups[key, default: []].append((String(cString: idValue), resource))
        }

        for (key, values) in groups {
            let ordered = values.sorted { lhs, rhs in
                let lhsResolved = lhs.resource.resolvedTitle != nil
                let rhsResolved = rhs.resource.resolvedTitle != nil
                if lhsResolved != rhsResolved { return lhsResolved }
                let lhsDate = lhs.resource.lastResolvedAt ?? lhs.resource.lastAttemptAt ?? lhs.resource.updatedAt
                let rhsDate = rhs.resource.lastResolvedAt ?? rhs.resource.lastAttemptAt ?? rhs.resource.updatedAt
                return lhsDate > rhsDate
            }
            guard var canonicalEntry = ordered.first else { continue }
            canonicalEntry.resource.canonicalResourceKey = key
            canonicalEntry.resource.createdAt = values.map(\.resource.createdAt).min() ?? canonicalEntry.resource.createdAt
            canonicalEntry.resource.updatedAt = values.map(\.resource.updatedAt).max() ?? canonicalEntry.resource.updatedAt
            canonicalEntry.resource.lastAttemptAt = values.compactMap(\.resource.lastAttemptAt).max()
            canonicalEntry.resource.lastResolvedAt = values.compactMap(\.resource.lastResolvedAt).max()
            canonicalEntry.resource.attemptCount = values.reduce(0) { $0 + $1.resource.attemptCount }
            canonicalEntry.resource.failedAttemptCount = values.reduce(0) { $0 + $1.resource.failedAttemptCount }

            for duplicate in ordered.dropFirst() {
                try execute(
                    database,
                    "INSERT OR IGNORE INTO clip_links(clip_id,link_resource_id) SELECT clip_id,? FROM clip_links WHERE link_resource_id=?;",
                    bindings: [canonicalEntry.id, duplicate.id]
                )
                try execute(database, "DELETE FROM clip_links WHERE link_resource_id=?;", bindings: [duplicate.id])
                try execute(
                    database,
                    "UPDATE link_resolution_attempts SET link_resource_id=? WHERE link_resource_id=?;",
                    bindings: [canonicalEntry.id, duplicate.id]
                )
                try execute(database, "DELETE FROM link_resources WHERE id=?;", bindings: [duplicate.id])
            }

            let payload = try encoder.encode(canonicalEntry.resource)
            let updateSQL = "UPDATE link_resources SET canonical_resource_key=?,request_state=?,title_quality=?,fallback_state=?,updated_at=?,last_attempt_at=?,attempt_count=?,failed_attempt_count=?,payload_json=? WHERE id=?;"
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(database, updateSQL, -1, &update, nil) == SQLITE_OK, let update else {
                throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(update) }
            sqlite3_bind_text(update, 1, key, -1, transient)
            sqlite3_bind_text(update, 2, canonicalEntry.resource.requestState.rawValue, -1, transient)
            sqlite3_bind_text(update, 3, canonicalEntry.resource.titleQuality.rawValue, -1, transient)
            sqlite3_bind_text(update, 4, canonicalEntry.resource.fallbackState.rawValue, -1, transient)
            sqlite3_bind_double(update, 5, canonicalEntry.resource.updatedAt.timeIntervalSince1970)
            if let lastAttemptAt = canonicalEntry.resource.lastAttemptAt {
                sqlite3_bind_double(update, 6, lastAttemptAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(update, 6)
            }
            sqlite3_bind_int(update, 7, Int32(canonicalEntry.resource.attemptCount))
            sqlite3_bind_int(update, 8, Int32(canonicalEntry.resource.failedAttemptCount))
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(update, 9, $0.baseAddress, Int32(payload.count), transient) }
            sqlite3_bind_text(update, 10, canonicalEntry.id, -1, transient)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
        try execute(database, "CREATE UNIQUE INDEX IF NOT EXISTS idx_link_resources_canonical ON link_resources(canonical_resource_key);")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(7,strftime('%s','now'));")
    }
}

extension SQLiteClipRepository {
    public func aiContext(ids: [UUID], includeNotes: Bool, includeSource: Bool) throws -> [AIClipDocument] {
        guard ids.count <= 100 else { throw AIError.invalid("Context batch is too large") }
        return try clips(ids: ids).filter(\.mayParticipateInAI).compactMap { clip in
            var body = clip.previewText
            if [.text, .code, .color].contains(clip.primaryKind) {
                for r in clip.items.flatMap(\.representations) where ["public.utf8-plain-text", "public.plain-text", "public.swift-source"].contains(r.uti) && r.storage.byteCount <= 2_097_152 {
                    if let text = String(data: try loadRepresentationData(r), encoding: .utf8) { body = text; break }
                }
            }
            guard Clip.isSafeAIText(body) else { return nil }
            var doc = clip.aiDocument(includeNotes: includeNotes, includeSource: includeSource, body: String(body.prefix(60_000)))
            doc.truncated = doc.truncated || body.count > 60_000
            return doc
        }
    }

    public func aiState() throws -> AIOrganizationState {
        let s = try prepare("SELECT payload_json FROM intelligence_state WHERE id=1;")
        defer { sqlite3_finalize(s) }
        switch sqlite3_step(s) {
        case SQLITE_ROW: return try decode(AIOrganizationState.self, statement: s, column: 0)
        case SQLITE_DONE: return AIOrganizationState()
        default: throw sqliteError()
        }
    }

    public func updateAIState(_ mutation: @Sendable (inout AIOrganizationState) throws -> Void) throws {
        func work() throws { var state = try aiState(); try mutation(&state); state.compact(); try writeAIState(state) }
        if sqlite3_get_autocommit(database) == 0 { try work() } else { try transaction(work) }
    }

    private func writeAIState(_ state: AIOrganizationState) throws {
        let bytes = try encoder.encode(state)
        let s = try prepare("INSERT INTO intelligence_state(id,payload_json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload_json=excluded.payload_json;")
        defer { sqlite3_finalize(s) }
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(s, 1, $0.baseAddress, Int32(bytes.count), Self.transient) }
        try stepDone(s)
    }

    private func recordManualAIMembershipChange(before: Set<UUID>, clip: Clip) throws {
        var state = try aiState(); var changed = false
        for id in before.symmetricDifference(clip.collectionIDs) {
            guard var group = state.groups[id] else { continue }
            if clip.collectionIDs.contains(id) {
                group.memberIDs.insert(clip.id); group.excludedClipIDs.remove(clip.id)
                group.aiMemberIDs.remove(clip.id)
            } else {
                group.memberIDs.remove(clip.id); group.aiMemberIDs.remove(clip.id)
                group.excludedClipIDs.insert(clip.id)
            }
            group.revision += 1; state.groups[id] = group; changed = true
        }
        if changed { try writeAIState(state) }
    }

    public func recordHumanActivity(id: UUID, event: ContentActivity.Event, at date: Date) throws {
        guard var clip = try clip(id: id), clip.deletedAt == nil else { return }
        var activity = clip.activity; activity.record(event, at: date)
        clip.intelligenceActivity = activity; clip.lifecycleEvaluation = nil
        try updateExisting(clip)
    }

    public func updateAIGroupDefinition(id: UUID, name: String, definition: String, retained: Bool, expectedVersion: Int) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, definition.count <= 2000 else { throw AIError.invalid("Invalid group definition") }
        try transaction {
            var state = try aiState()
            guard var profile = state.groups[id], profile.definitionVersion == expectedVersion,
                  var collection = try collections().first(where: { $0.id == id }) else { throw AIError.conflict("Topic definition") }
            let oldApplying = applyingIntelligence; applyingIntelligence = true
            defer { applyingIntelligence = oldApplying }
            if collection.name != name { profile.nameIsManual = true }
            collection.name = name; try saveCollection(collection)
            profile.name = name; profile.definition = definition; profile.definitionIsManual = true
            profile.definitionVersion += 1; profile.revision += 1; profile.retained = retained
            profile.overviewMemberFingerprint = ""
            state.groups[id] = profile; try writeAIState(state); try rebuildSearchIndex()
        }
    }

    public func applyAIChangeSet(_ proposed: AIChangeSet) throws {
        guard proposed.commands.count <= 20_000, !proposed.isRejected, !proposed.isUndone else { throw AIError.invalid("Invalid change set") }
        try transaction {
            var state = try aiState()
            if let stored = state.changes.first(where: { $0.id == proposed.id }), stored.isApplied {
                guard stored.fingerprint == proposed.fingerprint else { throw AIError.conflict("A different result already used this change-set ID") }
                return
            }
            if let stored = state.changes.first(where: { $0.id == proposed.id }) {
                guard proposed.commands.allSatisfy({ stored.commands.contains($0) }),
                      proposed.clipRevisions == stored.clipRevisions, proposed.groupRevisions == stored.groupRevisions else {
                    throw AIError.invalid("Only an unchanged subset of the recorded draft may be applied")
                }
            }
            let currentClips = try allClips()
            var clipsByID = Dictionary(uniqueKeysWithValues: currentClips.map { ($0.id, $0) })
            for (id, version) in proposed.clipRevisions {
                guard let clip = clipsByID[id], clip.mayParticipateInAI, clip.aiRevision == version else { throw AIError.conflict(id.uuidString) }
            }
            for (id, version) in proposed.groupRevisions {
                guard state.groups[id]?.revision == version else { throw AIError.conflict(id.uuidString) }
            }
            var undo = AIUndoRecord(beforeMemberships: [:], afterMemberships: [:], beforeGroups: [:], afterGroups: [:],
                                    createdGroupIDs: [], createdAggregations: [], beforeSummaries: [:], changedSummaryIDs: [])
            var changedGroups = Set<UUID>()
            var changedClips = Set<UUID>()
            var createdAggregations = [UUID: ClipAggregation]()
            var targetMap = [UUID: UUID]()
            let existingAggregations = try aggregations()
            let oldApplying = applyingIntelligence; applyingIntelligence = true
            defer { applyingIntelligence = oldApplying }
            for cmd in proposed.commands {
                guard cmd.name.count <= 120, cmd.definition.count <= 2000, cmd.overview.count <= 2000,
                      cmd.reason.count <= 1000, cmd.clipIDs.count <= 100,
                      Set(cmd.clipIDs).count == cmd.clipIDs.count else { throw AIError.invalid("Invalid command bounds") }
                if [.addItems, .removeItems, .createAggregation, .updateOverview].contains(cmd.kind) {
                    for id in cmd.clipIDs {
                        guard proposed.clipRevisions[id] != nil, clipsByID[id]?.mayParticipateInAI == true else {
                            throw AIError.invalid("Unread or excluded content in a command")
                        }
                    }
                }
                switch cmd.kind {
                case .createGroup:
                    guard state.groups[cmd.targetID] == nil, !cmd.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          cmd.name.count <= 40, !cmd.definition.isEmpty,
                          !(try collections()).contains(where: { $0.id == cmd.targetID }) else { throw AIError.invalid("Invalid new group") }
                    let collection = ClipCollection(id: cmd.targetID, name: cmd.name, kind: .normal, sortOrder: try collections().count)
                    try saveCollection(collection)
                    state.groups[cmd.targetID] = AIGroupProfile(id: cmd.targetID, name: cmd.name, definition: cmd.definition)
                    undo.createdGroupIDs.insert(cmd.targetID); changedGroups.insert(cmd.targetID)
                case .addItems, .removeItems, .updateOverview:
                    guard var profile = state.groups[cmd.targetID],
                          undo.createdGroupIDs.contains(cmd.targetID) || proposed.groupRevisions[cmd.targetID] != nil else {
                        throw AIError.invalid("Only versioned AI groups can be changed")
                    }
                    if !undo.createdGroupIDs.contains(profile.id), undo.beforeGroups[profile.id] == nil { undo.beforeGroups[profile.id] = profile }
                    if cmd.kind == .updateOverview {
                        guard !cmd.clipIDs.isEmpty, Set(cmd.clipIDs).isSubset(of: profile.memberIDs), !cmd.overview.isEmpty else { throw AIError.invalid("Invalid overview coverage") }
                        profile.overview = cmd.overview
                        profile.overviewMemberFingerprint = Set(cmd.clipIDs) == profile.memberIDs ? profile.membershipFingerprint : ""
                    } else {
                        for id in cmd.clipIDs {
                            guard var clip = clipsByID[id] else { throw AIError.invalid("Unknown content") }
                            if undo.beforeMemberships[id] == nil { undo.beforeMemberships[id] = clip.collectionIDs }
                            if cmd.kind == .addItems {
                                guard !profile.excludedClipIDs.contains(id) else { throw AIError.invalid("This member was excluded by the user") }
                                if !clip.collectionIDs.contains(profile.id) { profile.aiMemberIDs.insert(id) }
                                profile.memberIDs.insert(id); clip.collectionIDs.insert(profile.id)
                            } else {
                                guard profile.aiMemberIDs.contains(id) else { throw AIError.invalid("Cannot remove a manually assigned member") }
                                profile.memberIDs.remove(id); profile.aiMemberIDs.remove(id); clip.collectionIDs.remove(profile.id)
                            }
                            clipsByID[id] = clip; changedClips.insert(id)
                        }
                    }
                    state.groups[profile.id] = profile; changedGroups.insert(profile.id)
                case .createAggregation:
                    guard cmd.clipIDs.count >= 2, !cmd.name.isEmpty,
                          createdAggregations[cmd.targetID] == nil,
                          !existingAggregations.contains(where: { $0.id == cmd.targetID }) else { throw AIError.invalid("Invalid aggregation") }
                    // Repeated analysis of the same AI bundle reuses its identity.
                    if let existing = existingAggregations.first(where: {
                        state.summaries[$0.id] != nil && $0.title == cmd.name && Set($0.memberClipIDs) == Set(cmd.clipIDs)
                    }) { targetMap[cmd.targetID] = existing.id; createdAggregations[cmd.targetID] = existing }
                    else {
                        let aggregation = ClipAggregation(id: cmd.targetID, title: cmd.name, memberClipIDs: cmd.clipIDs,
                                                          membershipMode: .automatic, origin: .condition(summary: "AI"))
                        createdAggregations[cmd.targetID] = aggregation; undo.createdAggregations.append(aggregation)
                    }
                case .setSummary:
                    guard let target = createdAggregations[cmd.targetID], !cmd.claims.isEmpty, cmd.claims.count <= 20 else { throw AIError.invalid("Unknown summary target") }
                    let resolved = targetMap[cmd.targetID] ?? cmd.targetID
                    var revisions = [UUID: String]()
                    for claim in cmd.claims {
                        guard !claim.text.isEmpty, claim.text.count <= 1200, !claim.evidence.isEmpty, claim.evidence.count <= 10 else { throw AIError.invalid("Invalid claim") }
                        for ref in claim.evidence {
                            guard target.memberClipIDs.contains(ref.clipID), let clip = clipsByID[ref.clipID],
                                  let revision = proposed.clipRevisions[ref.clipID], !ref.quote.isEmpty, ref.quote.count <= 800,
                                  try evidenceText(for: clip).contains(ref.quote) else { throw AIError.invalid("Invalid original-text evidence") }
                            _ = revision
                            revisions[ref.clipID] = clip.aiContentRevision
                        }
                    }
                    if let old = state.summaries[resolved], undo.beforeSummaries[resolved] == nil { undo.beforeSummaries[resolved] = old }
                    undo.changedSummaryIDs.insert(resolved)
                    state.summaries[resolved] = AISummary(targetID: resolved, claims: cmd.claims, sourceRevisions: revisions)
                }
            }
            for id in changedGroups {
                guard var profile = state.groups[id], !undo.createdGroupIDs.contains(id) || !profile.memberIDs.isEmpty else { throw AIError.invalid("Cannot commit an empty AI group") }
                profile.revision += 1; state.groups[id] = profile; undo.afterGroups[id] = profile
            }
            for id in changedClips {
                guard let clip = clipsByID[id] else { continue }
                try save(clip); undo.afterMemberships[id] = clip.collectionIDs
            }
            for aggregation in undo.createdAggregations { _ = try saveAggregation(aggregation) }
            var applied = proposed; applied.isApplied = true
            state.changes.removeAll { $0.id == applied.id }; state.changes.append(applied); state.compact()
            try writeAIState(state)
            let bytes = try encoder.encode(undo)
            let s = try prepare("INSERT INTO intelligence_undo(id,payload_json) VALUES(?,?);")
            defer { sqlite3_finalize(s) }; bind(applied.id.uuidString, at: 1, to: s)
            _ = bytes.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32(bytes.count), Self.transient) }
            try stepDone(s)
        }
    }

    public func undoAIChangeSet(_ id: UUID) throws {
        try transaction {
            var state = try aiState()
            guard let index = state.changes.firstIndex(where: { $0.id == id && $0.isApplied && !$0.isUndone }) else { throw AIError.invalid("No undoable change set") }
            let s = try prepare("SELECT payload_json FROM intelligence_undo WHERE id=?;")
            defer { sqlite3_finalize(s) }; bind(id.uuidString, at: 1, to: s)
            guard sqlite3_step(s) == SQLITE_ROW else { throw AIError.invalid("Missing undo record") }
            let undo = try decode(AIUndoRecord.self, statement: s, column: 0)
            for (groupID, expected) in undo.afterGroups {
                guard state.groups[groupID] == expected else { throw AIError.conflict("Group changed after this organization") }
            }
            for (clipID, expected) in undo.afterMemberships {
                guard try clip(id: clipID)?.collectionIDs == expected else { throw AIError.conflict("Membership changed after this organization") }
            }
            for expected in undo.createdAggregations {
                guard try aggregation(id: expected.id) == expected else { throw AIError.conflict("Aggregation changed after this organization") }
            }
            let oldApplying = applyingIntelligence; applyingIntelligence = true
            defer { applyingIntelligence = oldApplying }
            for (clipID, memberships) in undo.beforeMemberships {
                guard var current = try clip(id: clipID) else { throw AIError.conflict("Content was removed") }
                current.collectionIDs = memberships; try save(current)
            }
            for groupID in undo.createdGroupIDs { try removeCollection(id: groupID); state.groups.removeValue(forKey: groupID) }
            for (groupID, profile) in undo.beforeGroups { state.groups[groupID] = profile }
            for aggregation in undo.createdAggregations { try removeAggregation(id: aggregation.id) }
            for target in undo.changedSummaryIDs { state.summaries[target] = undo.beforeSummaries[target] }
            state.changes[index].isUndone = true
            try writeAIState(state)
        }
    }

    private func evidenceText(for clip: Clip) throws -> String {
        var body = clip.previewText
        if [.text, .code, .color].contains(clip.primaryKind) {
            for r in clip.items.flatMap(\.representations) where ["public.utf8-plain-text", "public.plain-text", "public.swift-source"].contains(r.uti) && r.storage.byteCount <= 2_097_152 {
                if let value = String(data: try loadRepresentationData(r), encoding: .utf8) { body = value; break }
            }
        }
        return [clip.displayTitle, body, clip.note].joined(separator: "\n")
    }

    public func compressAIGroup(id groupID: UUID?, policy: LifecyclePolicy, now: Date) async throws -> Int {
        try policy.validate()
        guard !intelligenceMaintenance else { throw AIError.conflict("Storage maintenance is in progress; retry shortly") }
        intelligenceMaintenance = true; defer { intelligenceMaintenance = false }
        _ = try await reconcileAIPayloads()
        let initial = try allClips()
        let aggregations = try aggregations()
        let selected = initial.filter {
            $0.deletedAt == nil && !$0.isPinned && !$0.isFavorite &&
            (groupID == nil || $0.collectionIDs.contains(groupID!)) && policy.evaluate($0.activity, now: now).compressionEligible
        }
        let beforeManifest = await intelligencePayloads.snapshot()
        let selectedIDs = Set(selected.map(\.id))
        var ownersByHash = [String: Set<String>](), selectedOwners = [String: Set<String>]()
        var representations = [String: ClipRepresentation](), activityByOwner = [String: Date]()
        // Build the reverse index once. A 5,000-item library must not rehash and
        // scan every other item for each selected representation.
        for clip in initial {
            for rep in clip.items.flatMap(\.representations) where rep.storage.byteCount <= 536_870_912 {
                let hash = payloadID(rep)
                let owners = payloadOwners(clip: clip, representationID: rep.id, aggregations: aggregations)
                ownersByHash[hash, default: []].formUnion(owners)
                for owner in owners { activityByOwner[owner] = clip.activity.lastUsedAt }
                if selectedIDs.contains(clip.id) {
                    let chosen = groupID.map { id in owners.filter { $0.hasPrefix("group:" + id.uuidString + ":") } } ?? owners
                    selectedOwners[hash, default: []].formUnion(chosen); representations[hash] = rep
                }
            }
        }
        var touched = Set<String>()
        for hash in representations.keys.sorted() {
            try Task.checkCancellation()
            if let representation = representations[hash] {
                let data = try loadRepresentationData(representation)
                guard AIHash.digest(data) == hash else { throw StorageError.checksumMismatch }
                var owners = Array(ownersByHash[hash] ?? []), toPack = Array(selectedOwners[hash] ?? [])
                let canonical = "canonical:" + hash
                owners.append(canonical); toPack.append(canonical)
                _ = try await intelligencePayloads.register(data, ownerIDs: owners)
                // A genuinely re-used content version restores its raw demand;
                // model-maintained overview timestamps never reach this check.
                for owner in owners where !owner.hasPrefix("canonical:") {
                    if let old = beforeManifest.references[owner], old.mode == .packed,
                       let lastUsed = activityByOwner[owner], lastUsed > old.changedAt { try await intelligencePayloads.restoreRaw(ownerID: owner) }
                }
                _ = try await intelligencePayloads.pack(ownerIDs: Array(Set(toPack)))
                touched.insert(hash)
            }
        }
        _ = try await reconcileAIPayloads()
        let manifest = await intelligencePayloads.snapshot()
        var modes = [String: PayloadReferenceMode]()
        for hash in touched { modes[hash] = await intelligencePayloads.referenceCounts(for: hash).raw == 0 ? .packed : .raw }
        // Commit all database representations before considering any raw unlink.
        // saveArchived compares the persisted object, including manual changes.
        for original in try allClips() {
            var changed = original
            for item in changed.items.indices {
                for index in changed.items[item].representations.indices {
                    let rep = changed.items[item].representations[index]
                    let hash = payloadID(rep)
                    guard let mode = modes[hash], let record = manifest.records[hash], record.verified else { continue }
                    if mode == .packed {
                        changed.items[item].representations[index].storage = .archived(relativePath: "AIContent/Packed/" + record.packedFilename,
                                                                                     checksum: hash, size: record.originalSize)
                    } else {
                        changed.items[item].representations[index].storage = .attachment(relativePath: "AIContentRaw/" + record.rawFilename,
                                                                                       checksum: hash, size: record.originalSize)
                    }
                }
            }
            if changed.items != original.items { _ = try saveArchived(changed, replacing: original) }
        }
        var external = Set<String>()
        for clip in try allClips() {
            for rep in clip.items.flatMap(\.representations) {
                if case .archived(let path, _, _) = rep.storage, path.hasPrefix("AIContent/Packed/") { continue }
                external.insert(payloadID(rep))
            }
        }
        var released = try await intelligencePayloads.releaseUnreferencedRaw(excluding: external)
        // Remove superseded legacy files only after the DB commit and a fresh
        // reachability scan, including consolidation recovery records.
        let heldFiles = Set(try (allClips() + mergeBackupClips()).flatMap { $0.historyStoredFiles })
        for clip in initial {
            for rep in clip.items.flatMap(\.representations) where touched.contains(payloadID(rep)) {
                guard let file = HistoryStoredFile(storage: rep.storage),
                      !file.relativePath.hasPrefix("AIContent"), !heldFiles.contains(file),
                      let size = file.size(in: storageRoot),
                      manifest.records[payloadID(rep)]?.verified == true else { continue }
                if file.remove(in: storageRoot, expectedSize: size) { released += Int(size.logical) }
            }
        }
        return released
    }

    private func payloadID(_ representation: ClipRepresentation) -> String {
        switch representation.storage {
        case .inline(let data): AIHash.digest(data)
        case .attachment(_, let checksum, _), .archived(_, let checksum, _): checksum
        }
    }
    private func payloadOwners(clip: Clip, representationID: UUID, aggregations: [ClipAggregation]) -> [String] {
        let suffix = ":" + clip.id.uuidString + ":" + representationID.uuidString
        var owners = clip.collectionIDs.map { "group:" + $0.uuidString + suffix }
        owners += aggregations.filter { $0.memberClipIDs.contains(clip.id) }.map { "aggregation:" + $0.id.uuidString + suffix }
        if owners.isEmpty { owners.append("library" + suffix) }
        if clip.isPinned || clip.isFavorite || clip.deletedAt != nil { owners.append("protected" + suffix) }
        return owners
    }

    private func mergeBackupClips() throws -> [Clip] {
        let s = try prepare("SELECT payload_json FROM clip_merge_backups;"); defer { sqlite3_finalize(s) }
        var values = [Clip]()
        while sqlite3_step(s) == SQLITE_ROW { values.append(try decodeClip(s, column: 0)) }
        return values
    }

    private func reconcileAIPayloads(purge: Bool = false) async throws -> Int {
        let manifest = await intelligencePayloads.snapshot()
        let snapshotAt = Date()
        let bundles = try aggregations()
        var desired = [PayloadReference](); var live = Set<String>(); var forceRaw = Set<String>()
        for clip in try allClips() {
            for rep in clip.items.flatMap(\.representations) {
                let hash = payloadID(rep); guard manifest.records[hash] != nil else { continue }
                live.insert(hash)
                let mode: PayloadReferenceMode
                if case .archived = rep.storage { mode = .packed } else { mode = .raw }
                for owner in payloadOwners(clip: clip, representationID: rep.id, aggregations: bundles) {
                    let protected = owner.hasPrefix("protected:")
                    if protected { forceRaw.insert(owner) }
                    desired.append(PayloadReference(ownerID: owner, contentID: hash, mode: protected ? .raw : mode))
                }
            }
        }
        for clip in try mergeBackupClips() {
            for rep in clip.items.flatMap(\.representations) {
                let hash = payloadID(rep); guard manifest.records[hash] != nil else { continue }
                live.insert(hash)
                let mode: PayloadReferenceMode
                if case .archived = rep.storage { mode = .packed } else { mode = .raw }
                desired.append(PayloadReference(ownerID: "recovery:" + clip.id.uuidString + ":" + rep.id.uuidString,
                                                contentID: hash, mode: mode))
            }
        }
        for hash in live {
            desired.append(PayloadReference(ownerID: "canonical:" + hash, contentID: hash,
                                            mode: manifest.records[hash]?.verified == true ? .packed : .raw))
        }
        return try await intelligencePayloads.reconcile(desired, snapshotAt: snapshotAt, purgeUnreferenced: purge, forceRawOwners: forceRaw)
    }

    private func pruneAIContent(id: UUID) throws {
        var state = try aiState()
        for (key, var group) in state.groups {
            if group.memberIDs.remove(id) != nil { group.revision += 1 }
            group.aiMemberIDs.remove(id); group.excludedClipIDs.remove(id); state.groups[key] = group
        }
        state.summaries = state.summaries.filter { $0.value.sourceRevisions[id] == nil }
        let removed = state.changes.filter { $0.clipRevisions[id] != nil }.map(\.id)
        state.changes.removeAll { $0.clipRevisions[id] != nil }
        for change in removed { try Self.execute(database, "DELETE FROM intelligence_undo WHERE id=?;", bindings: [change.uuidString]) }
        if state.checkpoint?.clipIDs.contains(id) == true || state.checkpoint?.draft.clipRevisions[id] != nil { state.checkpoint = nil }
        try writeAIState(state)
    }

    public func exportAIContent(to destination: URL) async throws {
        guard !intelligenceMaintenance else { throw AIError.conflict("Storage maintenance is in progress; retry shortly") }
        intelligenceMaintenance = true; defer { intelligenceMaintenance = false }
        try await intelligencePayloads.exportArchive(to: destination)
    }
    public func importAIContent(from source: URL) async throws {
        guard !intelligenceMaintenance else { throw AIError.conflict("Storage maintenance is in progress; retry shortly") }
        intelligenceMaintenance = true; defer { intelligenceMaintenance = false }
        try await intelligencePayloads.importArchive(from: source)
    }
}
