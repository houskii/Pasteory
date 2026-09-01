import Foundation
import SQLite3

public actor SQLiteClipRepository: ClipRepository {
    nonisolated(unsafe) private let database: OpaquePointer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
        } catch {
            sqlite3_close(pointer)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func saveCaptured(_ clip: Clip) throws -> Clip {
        if var previous = try latestActiveClip(),
           previous.contentHash == clip.contentHash,
           previous.primaryKind == clip.primaryKind,
           previous.source.bundleIdentifier == clip.source.bundleIdentifier,
           clip.createdAt.timeIntervalSince(previous.createdAt) <= 60 {
            previous.copyCount += 1
            previous.lastCopiedAt = clip.createdAt
            previous.updatedAt = clip.createdAt
            try save(previous)
            return previous
        }
        try save(clip)
        return clip
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
        bind(clip.title, at: 6, to: statement)
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

    public func rebuildSearchIndex() throws {
        try Self.execute(database, "DELETE FROM clip_fts;")
        for clip in try allClips() { try updateFTS(for: clip) }
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
        bind(clip.id.uuidString, at: 1, to: insert); bind(clip.title, at: 2, to: insert)
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
        guard let bytes = sqlite3_column_blob(statement, column) else { throw RepositoryError.encoding }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        return try decoder.decode(Clip.self, from: data)
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
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, strftime('%s','now'));
        """)
    }
}
