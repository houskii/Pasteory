using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Pasteory.Core;

public sealed partial class HistoryStore
{
    private sealed record CatalogRow(Clip Clip, long Position, PackedPayload? Packed);
    private Dictionary<Guid, CatalogRow> catalogRows = [];

    private const string CatalogSchema = """
        CREATE TABLE library (id INTEGER PRIMARY KEY CHECK (id = 1), collections TEXT NOT NULL, ai_undo TEXT);
        CREATE TABLE clips (
            row_id INTEGER PRIMARY KEY, id BLOB NOT NULL UNIQUE, position INTEGER NOT NULL, payload TEXT NOT NULL,
            packed_hash TEXT, packed_size INTEGER, search_text TEXT NOT NULL
        );
        CREATE INDEX clips_position ON clips(position DESC);
        CREATE INDEX clips_search_keys ON clips(row_id, id);
        CREATE VIRTUAL TABLE clip_fts USING fts5(
            search_text, content='clips', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER clips_fts_insert AFTER INSERT ON clips BEGIN
            INSERT INTO clip_fts(rowid, search_text) VALUES (new.rowid, new.search_text);
        END;
        CREATE TRIGGER clips_fts_delete AFTER DELETE ON clips BEGIN
            INSERT INTO clip_fts(clip_fts, rowid, search_text) VALUES ('delete', old.rowid, old.search_text);
        END;
        CREATE TRIGGER clips_fts_update AFTER UPDATE OF search_text ON clips
        WHEN new.search_text <> old.search_text BEGIN
            INSERT INTO clip_fts(clip_fts, rowid, search_text) VALUES ('delete', old.rowid, old.search_text);
            INSERT INTO clip_fts(rowid, search_text) VALUES (new.rowid, new.search_text);
        END;
        PRAGMA user_version=1;
        """;

    private static SqliteConnection OpenCatalog(string path, SqliteOpenMode mode)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path, Mode = mode, DefaultTimeout = 5, Pooling = false
        }.ToString());
        try
        {
            connection.Open();
            return connection;
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    private LibraryState ReadCatalog()
    {
        try
        {
            using var connection = OpenCatalog(catalogPath, SqliteOpenMode.ReadOnly);
            using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA user_version;";
            if (command.ExecuteScalar() is not 1L)
                throw new InvalidDataException("Unsupported Windows history database format.");
            command.CommandText = "SELECT collections, ai_undo FROM library WHERE id = 1;";
            List<ClipCollection> groups;
            AiUndoRecord? undo;
            using (var metadata = command.ExecuteReader())
            {
                if (!metadata.Read()) throw new InvalidDataException("Missing library configuration.");
                groups = JsonSerializer.Deserialize<List<ClipCollection>>(metadata.GetString(0))
                    ?? throw new JsonException("Missing groups.");
                undo = metadata.IsDBNull(1) ? null : JsonSerializer.Deserialize<AiUndoRecord>(metadata.GetString(1));
            }

            var clips = new List<Clip>();
            var packed = new Dictionary<Guid, PackedPayload>();
            command.CommandText = "SELECT id, position, payload, packed_hash, packed_size FROM clips ORDER BY position DESC;";
            using var rows = command.ExecuteReader();
            while (rows.Read())
            {
                var clip = JsonSerializer.Deserialize<Clip>(rows.GetString(2))
                    ?? throw new JsonException("Missing clip.");
                if (clip.Id != new Guid(rows.GetFieldValue<byte[]>(0)))
                    throw new InvalidDataException("Clip identity does not match the catalog.");
                PackedPayload? entry = null;
                if (!rows.IsDBNull(3))
                {
                    entry = new(rows.GetString(3), rows.GetInt32(4));
                    clip = ReadPacked(clip, entry);
                    packed.Add(clip.Id, entry);
                }
                clips.Add(clip);
                catalogRows.Add(clip.Id, new(clip, rows.GetInt64(1), entry));
            }
            return new(clips, groups, AiUndo: undo, Payloads: packed);
        }
        catch (SqliteException error) { throw new IOException("The Windows history database could not be read.", error); }
    }

    private Dictionary<Guid, PackedPayload> WriteCatalog(List<Clip> clips, List<ClipCollection> groups,
        AiUndoRecord? undo, Dictionary<Guid, PackedPayload>? migrating, IReadOnlyList<ClipCollection> previousGroups)
    {
        var oldNames = previousGroups.ToDictionary(group => group.Id, group => group.Name);
        var names = groups.ToDictionary(group => group.Id, group => group.Name);
        var changedNames = oldNames.Keys.Union(names.Keys)
            .Where(id => oldNames.GetValueOrDefault(id) != names.GetValueOrDefault(id)).ToHashSet();
        var compress = groups.Where(group => group.PackPayloads).Select(group => group.Id).ToHashSet();
        var rows = new Dictionary<Guid, CatalogRow>(clips.Count);
        var packed = new Dictionary<Guid, PackedPayload>();
        bool initialize = !File.Exists(catalogPath);
        string path = initialize ? catalogPath + "." + Guid.NewGuid().ToString("N") + ".tmp" : catalogPath;
        Directory.CreateDirectory(Path.GetDirectoryName(catalogPath)!);
        try
        {
            using (var connection = OpenCatalog(path, initialize ? SqliteOpenMode.ReadWriteCreate : SqliteOpenMode.ReadWrite))
            {
                if (initialize)
                {
                    using var schema = connection.CreateCommand();
                    schema.CommandText = CatalogSchema;
                    schema.ExecuteNonQuery();
                }

                using var transaction = connection.BeginTransaction();
                using var upsert = connection.CreateCommand();
                upsert.Transaction = transaction;
                upsert.CommandText = """
                    INSERT INTO clips(id, position, payload, packed_hash, packed_size, search_text)
                    VALUES ($id, $pos, $payload, $hash, $size, $search)
                    ON CONFLICT(id) DO UPDATE SET position=excluded.position, payload=excluded.payload,
                        packed_hash=excluded.packed_hash, packed_size=excluded.packed_size, search_text=excluded.search_text;
                    """;
                var idParam = upsert.Parameters.Add("$id", SqliteType.Blob);
                var positionParam = upsert.Parameters.Add("$pos", SqliteType.Integer);
                var payloadParam = upsert.Parameters.Add("$payload", SqliteType.Text);
                var hashParam = upsert.Parameters.Add("$hash", SqliteType.Text);
                var sizeParam = upsert.Parameters.Add("$size", SqliteType.Integer);
                var searchParam = upsert.Parameters.Add("$search", SqliteType.Text);
                upsert.Prepare();

                long position = 0;
                for (int index = clips.Count - 1; index >= 0; index--)
                {
                    var clip = clips[index];
                    var previous = catalogRows.GetValueOrDefault(clip.Id);
                    position = Math.Max(previous?.Position ?? 0, checked(position + 1));
                    var archive = migrating is null ? PackForDisk(clip, compress, previous) : migrating.GetValueOrDefault(clip.Id);
                    rows.Add(clip.Id, new(clip, position, archive));
                    if (archive is not null) packed.Add(clip.Id, archive);
                    bool reindexGroup = changedNames.Count != 0 && clip.CollectionIds.Any(changedNames.Contains);
                    if (!initialize && previous is not null && ReferenceEquals(clip, previous.Clip) &&
                        position == previous.Position && archive == previous.Packed && !reindexGroup) continue;

                    idParam.Value = clip.Id.ToByteArray();
                    positionParam.Value = position;
                    payloadParam.Value = JsonSerializer.Serialize(archive is null ? clip : clip with { Text = null, Html = null, Rtf = null });
                    hashParam.Value = (object?)archive?.Hash ?? DBNull.Value;
                    sizeParam.Value = (object?)archive?.Size ?? DBNull.Value;
                    searchParam.Value = SearchText(clip, names);
                    upsert.ExecuteNonQuery();
                }

                using var delete = connection.CreateCommand();
                delete.Transaction = transaction;
                delete.CommandText = "DELETE FROM clips WHERE id = $id;";
                var removed = delete.Parameters.Add("$id", SqliteType.Blob);
                foreach (var id in catalogRows.Keys)
                {
                    if (rows.ContainsKey(id)) continue;
                    removed.Value = id.ToByteArray();
                    delete.ExecuteNonQuery();
                }

                using var metadata = connection.CreateCommand();
                metadata.Transaction = transaction;
                metadata.CommandText = """
                    INSERT INTO library VALUES (1, $groups, $undo)
                    ON CONFLICT(id) DO UPDATE SET collections=excluded.collections, ai_undo=excluded.ai_undo;
                    """;
                metadata.Parameters.AddWithValue("$groups", JsonSerializer.Serialize(groups));
                metadata.Parameters.AddWithValue("$undo", undo is null ? DBNull.Value : JsonSerializer.Serialize(undo));
                metadata.ExecuteNonQuery();
                transaction.Commit();
                if (initialize)
                {
                    using var wal = connection.CreateCommand();
                    wal.CommandText = "PRAGMA journal_mode=WAL;";
                    wal.ExecuteNonQuery();
                }
            }
            if (initialize) File.Move(path, catalogPath);
            catalogRows = rows;
            return packed;
        }
        catch (SqliteException error) { throw new IOException("The Windows history database could not be saved.", error); }
        finally
        {
            if (initialize)
            {
                LocalJson.Discard(path);
                LocalJson.Discard(path + "-wal");
                LocalJson.Discard(path + "-shm");
                LocalJson.Discard(path + "-journal");
            }
        }
    }

    public List<Guid> SearchIds(string query, int limit = int.MaxValue, CancellationToken cancellation = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(limit);
        if (!File.Exists(catalogPath)) return [];
        string[] terms = NormalizeSearch(query).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Distinct().ToArray();
        var (indexed, shortTerms) = (new List<string>(), new List<string>());
        foreach (string term in terms)
        {
            cancellation.ThrowIfCancellationRequested();
            if (term.EnumerateRunes().Take(3).Count() == 3) indexed.Add("\"" + term.Replace("\"", "\"\"") + "\"");
            else shortTerms.Add(term);
        }
        try
        {
            using var connection = OpenCatalog(catalogPath, SqliteOpenMode.ReadOnly);
            using var command = connection.CreateCommand();
            var clauses = new List<string>();
            string table = "clips";
            if (indexed.Count > 0)
            {
                table = shortTerms.Count == 0
                    ? "clip_fts CROSS JOIN clips INDEXED BY clips_search_keys ON clips.row_id = clip_fts.rowid"
                    : "clip_fts CROSS JOIN clips ON clips.row_id = clip_fts.rowid";
                clauses.Add("clip_fts MATCH $query");
                command.Parameters.AddWithValue("$query", string.Join(" AND ", indexed));
            }
            for (int index = 0; index < shortTerms.Count; index++)
            {
                string parameter = "$short" + index;
                clauses.Add($"instr(clips.search_text, {parameter}) > 0");
                command.Parameters.AddWithValue(parameter, shortTerms[index]);
            }
            string filter = clauses.Count > 0 ? " WHERE " + string.Join(" AND ", clauses) : "";
            string order = terms.Length == 0 ? " ORDER BY clips.position DESC" : "";
            command.CommandText = "SELECT clips.id FROM " + table + filter + order + " LIMIT $limit;";
            command.Parameters.AddWithValue("$limit", limit);
            using var rows = command.ExecuteReader();
            var result = new List<Guid>();
            byte[] id = new byte[16];
            while (rows.Read())
            {
                cancellation.ThrowIfCancellationRequested();
                if (rows.GetBytes(0, 0, id, 0, id.Length) != id.Length)
                    throw new InvalidDataException("Invalid clipboard identity in the search index.");
                result.Add(new Guid(id));
            }
            return result;
        }
        catch (SqliteException error) { throw new IOException("Clipboard history could not be searched.", error); }
    }

    private static string SearchText(Clip clip, Dictionary<Guid, string> groups)
    {
        var fields = new List<string?> { clip.Title, clip.Note, clip.Text, clip.RecognizedImageText, clip.LinkDetails?.Title, clip.LinkDetails?.FallbackTitle,
            clip.Source, clip.SourceIdentifier, clip.Group };
        fields.AddRange(clip.Files);
        fields.AddRange(clip.CollectionIds.Select(id => groups.GetValueOrDefault(id)));
        foreach (var capture in clip.Captures)
        {
            fields.Add(capture.Source);
            fields.Add(capture.Context);
            fields.Add(capture.Url);
            if (capture.Details is { } details) fields.AddRange(details.Values);
        }
        return NormalizeSearch(string.Join("\n", fields.Where(field => !string.IsNullOrEmpty(field))));
    }

    public static string NormalizeSearch(string value)
    {
        string normalized;
        try { normalized = value.Normalize(NormalizationForm.FormKD); }
        catch (ArgumentException) { normalized = value; }
        normalized = normalized.ToUpperInvariant();
        StringBuilder? text = null;
        int offset = 0;
        foreach (var rune in normalized.EnumerateRunes())
        {
            bool mark = Rune.GetUnicodeCategory(rune) == UnicodeCategory.NonSpacingMark;
            int length = rune.Utf16SequenceLength;
            if (mark || rune.Value == 0)
            {
                text ??= new StringBuilder(normalized.Length).Append(normalized.AsSpan(0, offset));
                if (rune.Value == 0) text.Append(' ');
            }
            else text?.Append(normalized.AsSpan(offset, length));
            offset += length;
        }
        return (text?.ToString() ?? normalized).Trim();
    }
}
