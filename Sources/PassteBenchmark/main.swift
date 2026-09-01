import Foundation
import PassteCore
import SQLite3

@main
struct PassteBenchmark {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func main() async throws {
        let p95At10K = try await benchmark(count: 10_000)
        let p95At100K = try await benchmark(count: 100_000)
        print("search_p95_10k_ms=\(format(p95At10K)) search_p95_100k_ms=\(format(p95At100K))")
        guard p95At10K < 150, p95At100K < 300 else { exit(1) }
    }

    private static func benchmark(count: Int) async throws -> Double {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PassteBenchmark-\(count)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories(root: root)
        try seed(databaseURL: directories.databaseFile, count: count)
        let repository = try SQLiteClipRepository(databaseURL: directories.databaseFile)
        let storedCount = try await repository.activeClipCount()
        precondition(storedCount == count)
        return try await searchP95(repository: repository, query: "常用命令")
    }

    private static func seed(databaseURL: URL, count: Int) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else { throw BenchmarkError.sqlite("open") }
        defer { sqlite3_close(database) }
        try execute(database, """
        PRAGMA journal_mode=MEMORY; PRAGMA synchronous=OFF;
        CREATE TABLE clips(
          id TEXT PRIMARY KEY, created_at REAL NOT NULL, updated_at REAL NOT NULL, last_copied_at REAL NOT NULL,
          kind TEXT NOT NULL, title TEXT NOT NULL, note TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0,
          favorite INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
          source_name TEXT NOT NULL, source_bundle TEXT, source_confidence TEXT NOT NULL,
          preview_text TEXT NOT NULL, content_hash TEXT NOT NULL, byte_size INTEGER NOT NULL,
          copy_count INTEGER NOT NULL DEFAULT 1, deleted_at REAL, payload_json BLOB NOT NULL
        );
        CREATE VIRTUAL TABLE clip_fts USING fts5(id UNINDEXED, title, body, note, groups, source, tokenize='trigram');
        BEGIN;
        """)
        let clipSQL = "INSERT INTO clips VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);"
        let ftsSQL = "INSERT INTO clip_fts(id,title,body,note,groups,source) VALUES(?,?,?,?,?,?);"
        var clipStatement: OpaquePointer?, ftsStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, clipSQL, -1, &clipStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, ftsSQL, -1, &ftsStatement, nil) == SQLITE_OK,
              let clipStatement, let ftsStatement else { throw BenchmarkError.sqlite("prepare") }
        defer { sqlite3_finalize(clipStatement); sqlite3_finalize(ftsStatement) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970

        for index in 0..<count {
            let id = UUID(), text = "常用命令 swift build 编号 \(index)", title = "构建记录 \(index)"
            let data = Data(text.utf8), date = Date(timeIntervalSince1970: Double(index + 1))
            let representation = ClipRepresentation(uti: "public.utf8-plain-text", storage: .inline(data))
            let clip = Clip(id: id, createdAt: date, updatedAt: date, lastCopiedAt: date, primaryKind: .code,
                            title: title, note: "性能样本", source: ClipSource(appName: "Terminal", bundleIdentifier: "com.apple.Terminal", confidence: .high),
                            previewText: text, contentHash: String(index), byteSize: data.count,
                            items: [ClipItem(order: 0, representations: [representation])])
            let payload = try encoder.encode(clip)
            bind(id.uuidString, 1, clipStatement); sqlite3_bind_double(clipStatement, 2, date.timeIntervalSince1970)
            sqlite3_bind_double(clipStatement, 3, date.timeIntervalSince1970); sqlite3_bind_double(clipStatement, 4, date.timeIntervalSince1970)
            bind("code", 5, clipStatement); bind(title, 6, clipStatement); bind("性能样本", 7, clipStatement)
            sqlite3_bind_int(clipStatement, 8, 0); sqlite3_bind_int(clipStatement, 9, 0); sqlite3_bind_int(clipStatement, 10, 0); sqlite3_bind_int(clipStatement, 11, 0)
            bind("Terminal", 12, clipStatement); bind("com.apple.Terminal", 13, clipStatement); bind("high", 14, clipStatement)
            bind(text, 15, clipStatement); bind(String(index), 16, clipStatement); sqlite3_bind_int64(clipStatement, 17, Int64(data.count)); sqlite3_bind_int(clipStatement, 18, 1); sqlite3_bind_null(clipStatement, 19)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(clipStatement, 20, $0.baseAddress, Int32(payload.count), transient) }
            guard sqlite3_step(clipStatement) == SQLITE_DONE else { throw BenchmarkError.sqlite("insert clip") }
            sqlite3_reset(clipStatement); sqlite3_clear_bindings(clipStatement)

            bind(id.uuidString, 1, ftsStatement); bind(title, 2, ftsStatement); bind(text, 3, ftsStatement)
            bind("性能样本", 4, ftsStatement); bind("", 5, ftsStatement); bind("Terminal", 6, ftsStatement)
            guard sqlite3_step(ftsStatement) == SQLITE_DONE else { throw BenchmarkError.sqlite("insert fts") }
            sqlite3_reset(ftsStatement); sqlite3_clear_bindings(ftsStatement)
        }
        try execute(database, "COMMIT;")
    }

    private static func searchP95(repository: SQLiteClipRepository, query: String) async throws -> Double {
        _ = try await repository.list(filter: .all, query: query, limit: 500)
        var samples = [Double]()
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let clips = try await repository.list(filter: .all, query: query, limit: 500)
            precondition(clips.count == 500)
            samples.append(Double(start.duration(to: .now).components.attoseconds) / 1e15)
        }
        samples.sort()
        return samples[Int(ceil(Double(samples.count) * 0.95)) - 1]
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw BenchmarkError.sqlite(String(cString: sqlite3_errmsg(database))) }
    }

    private static func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

enum BenchmarkError: Error { case sqlite(String) }
