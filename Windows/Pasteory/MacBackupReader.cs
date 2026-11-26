using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LzfseSharp;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed class MacBackupReader(string root)
{
    private const int MaximumRepresentation = HistoryStore.MaximumRepresentationBytes;
    private readonly string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
    private readonly Dictionary<string, string> checksums = new(StringComparer.Ordinal);

    internal (int Count, LinkFallbackRule[] Fallbacks, MacBackupAiArchive Ai) Import(HistoryStore store)
    {
        using var manifest = JsonDocument.Parse(File.ReadAllBytes(Resolve("manifest.json")));
        var description = manifest.RootElement;
        if (Int(description, "formatVersion") is < 1 or > 5)
            throw new InvalidDataException("Unsupported Mac backup version.");
        foreach (var entry in description.GetProperty("fileChecksums").EnumerateObject())
        {
            string? checksum = entry.Value.GetString();
            if (checksum is not { Length: 64 }) throw new InvalidDataException("Missing backup checksum.");
            string path = Resolve(entry.Name);
            using var file = File.OpenRead(path);
            if (!DigestMatches(SHA256.HashData(file), checksum)) throw new InvalidDataException("Mac backup checksum mismatch.");
            checksums.Add(entry.Name, checksum);
        }

        var events = ReadLines("capture-events.jsonl").GroupBy(item => Id(item, "clipID"))
            .ToDictionary(group => group.Key, group => group.Select(ToCapture).OrderByDescending(item => item.CapturedAt).ToArray());
        var ai = checksums.ContainsKey("ai-state.json") ?
            MacBackupAiState.Read(Verified("ai-state.json")) : MacBackupAiArchive.Empty;
        var collections = ReadCollections().Select(collection => ai.Groups.TryGetValue(collection.Id, out var theme) ?
            collection with
            {
                IsAi = true, Definition = theme.Definition, Overview = theme.Overview, Locked = theme.Retained,
                ExcludedClips = theme.ExcludedClipIds
            } : collection).ToList();
        var fallback = ReadLines("url-fallback-rules.jsonl").Select(ToFallback).OfType<LinkFallbackRule>().ToArray();
        var clips = new List<Clip>();
        string staging = Directory.CreateTempSubdirectory("Pasteory-MacImport-").FullName;
        try
        {
            foreach (var item in ReadLines("clips.jsonl", required: true))
                clips.Add(ConvertClip(item, events, staging));
            clips.AddRange(ReadLines("aggregations.jsonl").Select(ConvertAggregation));
            var existing = collections.Select(group => group.Id).ToHashSet();
            foreach (var missing in clips.SelectMany(clip => clip.CollectionIds).Distinct().Where(id => !existing.Contains(id)))
                collections.Add(new ClipCollection(missing, "Recovered " + missing.ToString("D")));
            int count = store.ImportClips(clips, collections, clip => File.ReadAllBytes(Path.Combine(staging, clip.ImageFileName)),
                rep => ReadStaged(staging, rep));
            return (count, fallback, ai);
        }
        finally
        {
            try { Directory.Delete(staging, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private Clip ConvertClip(JsonElement item, Dictionary<Guid, CaptureEvent[]> events, string staging)
    {
        Guid id = Id(item, "id");
        var kind = Kind(String(item, "primaryKind"));
        var source = Child(item, "source");
        var created = Date(item, "createdAt") ?? DateTimeOffset.Now;
        var copiedAt = Date(item, "lastCopiedAt") ?? created;
        var ocr = Child(item, "localOCR");
        string? contentHash = Optional(item, "contentHash");
        string? recognized = Int(ocr, "version", 0) == 1 && MatchesContent(ocr, contentHash) ? Optional(ocr, "text") : null;
        var request = Child(item, "localOCRRequest");
        var clip = new Clip
        {
            Id = id, Kind = kind, CreatedAt = created, CapturedAt = copiedAt, LastPastedAt = Date(item, "lastPastedAt"),
            TrashedAt = Date(item, "deletedAt"), ArchivedAt = Bool(item, "isArchived") ? Date(item, "updatedAt") ?? copiedAt : null,
            Source = String(source, "appName"), SourceIdentifier = Optional(source, "bundleIdentifier"),
            SourceConfidence = Optional(source, "confidence") ?? "Unknown", Title = String(item, "title"), Note = String(item, "note"),
            Priority = (ClipPriority)Math.Clamp(Int(item, "priority"), 0, 3), Favorite = Bool(item, "isFavorite"), Pinned = Bool(item, "isPinned"),
            CopyCount = Math.Max(0, Int(item, "copyCount", 1)), PasteCount = Math.Max(0, Int(item, "pasteCount")),
            CollectionIds = Guids(item, "collectionIDs"), Captures = events.GetValueOrDefault(id, []),
            ExcludeFromAi = Bool(item, "aiAnalysisExcluded"),
            CodeLanguage = CodeExtension(Optional(Child(item, "codeMetadata"), "language")), RecognizedText = recognized,
            RecognizedAt = recognized is null ? null : Date(ocr, "recognizedAt"),
            OcrInNote = recognized is not null && Optional(ocr, "appendedNote") is not null,
            OcrMode = recognized is null ? null : OcrMode(ocr),
            Conversions = Array(item, "quickTextTransformations").Select(ToConversion).OfType<ConversionRecord>().ToArray()
        };
        if (Optional(item, "automaticTitle") is { } title)
            clip = clip with { LinkDetails = new("Resolved", title, copiedAt, "Mac backup") };

        var originals = new List<ClipboardItem>();
        var texts = new List<string>();
        string? html = null, rtf = null;
        var files = new List<string>();
        ClipboardImage? image = null;
        foreach (var selection in Array(item, "items").OrderBy(selection => Int(selection, "order")))
        {
            var representations = new List<ClipboardRepresentation>();
            foreach (var rep in Array(selection, "representations"))
            {
                string uti = String(rep, "uti");
                if (string.IsNullOrWhiteSpace(uti)) throw new InvalidDataException("Missing clipboard representation type.");
                byte[] bytes = ReadRepresentation(Child(rep, "storage"));
                string hash = Convert.ToHexString(SHA256.HashData(bytes));
                var original = new ClipboardRepresentation(GuidOrNew(rep, "id"), uti, hash, bytes.Length);
                string path = Path.Combine(staging, hash + ".bin");
                if (!File.Exists(path)) File.WriteAllBytes(path, bytes);
                representations.Add(original);
            }
            var originalItem = new ClipboardItem(GuidOrNew(selection, "id"), Int(selection, "order"), representations.ToArray());
            originals.Add(originalItem);
            var projected = MacClipboardFormats.Project(originalItem, rep => ReadStaged(staging, rep),
                image is null && kind is ClipKind.Image or ClipKind.Mixed);
            if (projected.Text is not null) texts.Add(projected.Text);
            html ??= projected.Html;
            rtf ??= projected.Rtf;
            files.AddRange(projected.Files);
            image ??= projected.Image;
        }
        string? text = texts.Count > 0 ? string.Join(Environment.NewLine, texts) : null;
        if (originals.Count > 1 && text is not null) html = rtf = null;
        var fileDetails = Child(item, "fileMetadata");
        var paths = Strings(fileDetails, "filePaths");
        if (paths.Length > 0) files = paths.ToList();
        else if (files.Count == 0) files.AddRange(Strings(fileDetails, "fileNames"));

        if (image is not null)
        {
            clip = clip with
            {
                ImageFormat = image.Format, ImageSize = image.Bytes.Length, ImageWidth = image.Width, ImageHeight = image.Height,
                ImageHash = Convert.ToHexString(SHA256.HashData(image.Bytes))
            };
            File.WriteAllBytes(Path.Combine(staging, clip.ImageFileName), image.Bytes);
        }
        else if (kind == ClipKind.Image)
        {
            clip = clip with { Kind = ClipKind.Text };
            text ??= $"[Mac image] {String(item, "previewText")}";
        }
        if (recognized is null && MatchesContent(request, contentHash) && (image is not null ||
            originals.SelectMany(selection => selection.Representations).Any(rep => MacClipboardFormats.IsImage(rep.Uti))))
            clip = clip with { OcrPending = true, OcrMode = OcrMode(request) ?? ImageOcrMode.Accurate };
        if (text is null && html is null && rtf is null && image is null && files.Count == 0) text = String(item, "previewText");
        return clip with { Text = text, Html = html, Rtf = rtf, Files = files.Where(path => path.Length > 0).Distinct().ToArray(),
            OriginalItems = originals.Count == 0 ? null : originals.ToArray(),
            OriginalMacIdentity = originals.Count == 0 ? null : new(String(item, "primaryKind"), Strings(item, "secondaryKinds"),
                contentHash, Optional(item, "identityKey")) };
    }

    private static bool MatchesContent(JsonElement data, string? contentHash) => !string.IsNullOrEmpty(contentHash) &&
        string.Equals(Optional(data, "contentHash"), contentHash, StringComparison.OrdinalIgnoreCase);

    private static ImageOcrMode? OcrMode(JsonElement data) => Optional(data, "method") switch
    {
        "visionFast" => ImageOcrMode.Fast,
        "visionAccurate" => ImageOcrMode.Accurate,
        _ => null
    };

    private static byte[] ReadStaged(string staging, ClipboardRepresentation rep) =>
        File.ReadAllBytes(Path.Combine(staging, rep.Hash + ".bin"));

    private byte[] ReadRepresentation(JsonElement storage)
    {
        string type = String(storage, "type");
        if (type == "inline")
        {
            var data = Child(storage, "data");
            if (data.ValueKind != JsonValueKind.String || (data.GetString()?.Length ?? 0) > MaximumRepresentation * 2)
                throw new InvalidDataException("Invalid inline payload.");
            byte[] bytes = data.GetBytesFromBase64();
            if (bytes.Length > MaximumRepresentation) throw new InvalidDataException("The inline clipboard representation is too large.");
            return bytes;
        }
        int size = Int(storage, "size", -1);
        string hash = String(storage, "checksum");
        string relative = String(storage, "relativePath");
        if (size is < 0 or > MaximumRepresentation || hash.Length != 64 || !hash.All(char.IsAsciiHexDigit) ||
            type is not ("attachment" or "archived")) throw new InvalidDataException("Invalid backup representation.");
        string archive = type == "archived" ? "Archives/" + relative : "Attachments/" + relative;
        bool compressed = type == "archived";
        string key = "data/" + archive;
        if (!checksums.ContainsKey(key) && type == "attachment")
        {
            string portable = "ai-content/Packed/" + hash + ".packed";
            key = checksums.ContainsKey(portable) ? portable : "data/Archives/AIContent/Packed/" + hash + ".packed";
            compressed = true;
        }
        using var file = File.OpenRead(Verified(key));
        byte[] decoded = new byte[size];
        if (!compressed)
        {
            if (file.Length != size) throw new InvalidDataException("Unexpected attachment length.");
            file.ReadExactly(decoded);
        }
        else if (size > 0)
        {
            try
            {
                using var output = new MemoryStream(decoded, writable: true);
                output.SetLength(0);
                LzfseDecoder.Decompress(file, output);
                if (output.Length != size) throw new InvalidDataException("Unexpected archive length.");
            }
            catch (Exception error) when (error is NotSupportedException or ArgumentException)
            { throw new InvalidDataException("Invalid Mac archive payload.", error); }
        }
        if (!DigestMatches(SHA256.HashData(decoded), hash)) throw new InvalidDataException("Mac attachment checksum mismatch.");
        return decoded;
    }

    private IEnumerable<ClipCollection> ReadCollections()
    {
        if (!checksums.ContainsKey("collections.json")) yield break;
        using var document = JsonDocument.Parse(File.ReadAllBytes(Verified("collections.json")));
        foreach (var collection in document.RootElement.EnumerateArray().OrderBy(item => Int(item, "sortOrder")))
        {
            Guid id = Id(collection, "id");
            SmartRules? rule = Child(collection, "windowsRuleSet") is { ValueKind: JsonValueKind.Object } windowsRule ?
                windowsRule.Deserialize<SmartRules>(AiFile.Wire) :
                String(collection, "kind") == "smart" ? ReadRule(Child(collection, "ruleSet")) : null;
            yield return new ClipCollection(id, String(collection, "name"), rule);
        }
    }

    private static SmartRules? ReadRule(JsonElement value) => value.ValueKind == JsonValueKind.Object
        ? new SmartRules(String(value, "mode") != "any", Array(value, "conditions").Select(ReadCondition).ToArray(),
            Array(value, "groups").Select(ReadRule).OfType<SmartRules>().ToArray())
        : null;

    private static SmartCondition ReadCondition(JsonElement rule)
    {
        string value = String(rule, "value");
        RuleField field = String(rule, "field") switch
        {
            "sourceApp" => RuleField.Source, "sourceConfidence" => RuleField.SourceConfidence, "createdAt" => RuleField.CreatedAt,
            "kind" => RuleField.Kind, "title" => RuleField.Title, "body" => RuleField.Text, "note" => RuleField.Note,
            "byteSize" => RuleField.ByteSize, "priority" => RuleField.Priority, "favorite" => RuleField.Favorite,
            "copyCount" => RuleField.CopyCount, "quickTextAction" => RuleField.Conversion,
            _ => throw new InvalidDataException("Unknown Mac smart group field.")
        };
        if (field == RuleField.Kind) value = Kind(value).ToString();
        if (field == RuleField.Priority && int.TryParse(value, out int priority)) value = ((ClipPriority)Math.Clamp(priority, 0, 3)).ToString();
        if (field == RuleField.Conversion && Enum.TryParse(value, true, out TextTool tool)) value = tool.ToString();
        if (!Enum.TryParse(String(rule, "operation"), true, out RuleComparison comparison)) throw new InvalidDataException("Unknown Mac smart group operator.");
        return new SmartCondition(field, comparison, value);
    }

    private static CaptureEvent ToCapture(JsonElement item)
    {
        var source = Child(item, "source");
        var context = Child(item, "context");
        if (context.ValueKind == JsonValueKind.Undefined) context = Child(item, "sourceContext");
        var payload = Child(context, "payload");
        var details = payload.ValueKind == JsonValueKind.Object ? payload.EnumerateObject()
            .Where(field => field.Value.ValueKind == JsonValueKind.String).ToDictionary(field => field.Name, field => field.Value.GetString()!) : null;
        return new CaptureEvent(Date(item, "capturedAt") ?? DateTimeOffset.UnixEpoch, String(source, "appName"), Optional(context, "summary"),
            Optional(payload, "url"), details);
    }

    private static ConversionRecord? ToConversion(JsonElement item) => Enum.TryParse(String(item, "action"), true, out TextTool tool)
        ? new ConversionRecord(tool, String(item, "originalText"), String(Child(item, "source"), "appName")) : null;

    private static LinkFallbackRule? ToFallback(JsonElement item)
    {
        string pattern = String(item, "pattern");
        string title = String(item, "titleTemplate");
        if (title.Length == 0) return null;
        if (pattern.Length > 0) return new(pattern, title);
        string host = String(item, "hostPattern").Trim().ToLowerInvariant();
        if (host.Length == 0) return null;
        string path = Optional(item, "pathTemplate") ?? "/";
        return new(host + path, title, new(GuidOrNew(item, "id"), String(item, "name"), host, path,
            Strings(item, "requiredQueryKeys"), Child(item, "enabled").ValueKind != JsonValueKind.False, Int(item, "priority", 100)));
    }

    private static Clip ConvertAggregation(JsonElement item)
    {
        var origin = Child(item, "origin");
        var created = Date(item, "createdAt") ?? DateTimeOffset.Now;
        string? query = Optional(Child(origin, "search"), "query");
        return new Clip
        {
            Id = Id(item, "id"), Kind = ClipKind.Aggregate, CapturedAt = created, CreatedAt = created,
            Title = String(item, "title"), Note = String(item, "note"), Pinned = Bool(item, "isPinned"), Favorite = Bool(item, "isFavorite"),
            CopyCount = 0, CollectionIds = Guids(item, "collectionIDs"), Members = Guids(item, "memberClipIDs"),
            AggregationFromSearch = query is not null, AggregationUpdatedAt = Date(item, "updatedAt"),
            AggregationOrigin = query ?? Optional(Child(origin, "condition"), "summary") ?? "Manual"
        };
    }

    private IEnumerable<JsonElement> ReadLines(string path, bool required = false)
    {
        if (!required && !checksums.ContainsKey(path)) yield break;
        foreach (string line in File.ReadLines(Verified(path), Encoding.UTF8))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            using var document = JsonDocument.Parse(line);
            yield return document.RootElement.Clone();
        }
    }

    private string Verified(string relative) => checksums.ContainsKey(relative) ? Resolve(relative) :
        throw new InvalidDataException("Backup file is missing from its manifest.");

    private string Resolve(string relative)
    {
        string[] parts = relative.Split('/');
        if (parts.Any(part => part.Length == 0 || part is "." or ".." || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
            part.Contains('\\') || part.EndsWith('.') || part.EndsWith(' ')))
            throw new InvalidDataException("Invalid path in Mac backup.");
        string path = root;
        foreach (string part in parts)
        {
            path = Path.Combine(path, part);
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Backup paths cannot be Windows reparse points.");
        }
        return path;
    }

    private static bool DigestMatches(byte[] digest, string expected) => Convert.ToHexString(digest).Equals(expected, StringComparison.OrdinalIgnoreCase);
    private static ClipKind Kind(string value) => value.Equals("file", StringComparison.OrdinalIgnoreCase) ? ClipKind.Files :
        Enum.TryParse(value, true, out ClipKind kind) && kind != ClipKind.Aggregate ? kind : ClipKind.Text;
    private static string? CodeExtension(string? language) => language switch
    {
        "python" => "py", "javascript" => "js", "typescript" => "ts", "kotlin" => "kt", "shell" => "sh", _ => language
    };
    private static JsonElement Child(JsonElement item, string name) => item.ValueKind == JsonValueKind.Object &&
        item.TryGetProperty(name, out var element) ? element : default;
    private static IEnumerable<JsonElement> Array(JsonElement item, string key) =>
        Child(item, key) is { ValueKind: JsonValueKind.Array } array ? array.EnumerateArray() : [];
    private static string String(JsonElement item, string key) => Optional(item, key) ?? "";
    private static string? Optional(JsonElement item, string key) => Child(item, key) is { ValueKind: JsonValueKind.String } value
        ? value.GetString() : null;
    private static string[] Strings(JsonElement item, string key) => Array(item, key).Select(value => value.GetString() ?? "").ToArray();
    private static Guid Id(JsonElement item, string key) => Guid.TryParse(String(item, key), out var id) ? id :
        throw new InvalidDataException("Invalid identifier in Mac backup.");
    private static Guid GuidOrNew(JsonElement item, string key) => Guid.TryParse(String(item, key), out var id) ? id : Guid.NewGuid();
    private static Guid[] Guids(JsonElement item, string key) => Array(item, key).Select(value => value.GetGuid()).ToArray();
    private static bool Bool(JsonElement item, string key) => Child(item, key).ValueKind == JsonValueKind.True;
    private static int Int(JsonElement item, string key, int fallback = 0) => Child(item, key) is { ValueKind: JsonValueKind.Number } value &&
        value.TryGetInt32(out int integer) ? integer : fallback;
    private static DateTimeOffset? Date(JsonElement item, string key) => DateTimeOffset.TryParse(String(item, key),
        CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed) ? parsed : null;
}
