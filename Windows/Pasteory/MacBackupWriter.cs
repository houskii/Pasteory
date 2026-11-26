using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed partial class MacBackupWriter(HistoryStore store, AiTasks ai, IReadOnlyList<LinkFallbackRule>? fallbacks = null)
{
    private readonly Dictionary<string, string> checksums = new(StringComparer.Ordinal);
    private static readonly JsonSerializerOptions Json = new(AiFile.Wire) { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };
    private string staging = "";

    internal void Export(string destination)
    {
        destination = Path.GetFullPath(destination);
        string parent = Path.GetDirectoryName(destination) ?? throw new ArgumentException("Choose a folder for the backup.");
        if (!Directory.Exists(parent)) throw new DirectoryNotFoundException(parent);
        if (Directory.Exists(destination) || File.Exists(destination)) throw new IOException("The backup folder already exists.");
        staging = Path.Combine(parent, ".pasteory-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            checksums.Clear();
            var clips = store.Clips.Where(clip => clip.Kind != ClipKind.Aggregate).ToArray();
            var aggregations = store.Clips.Where(clip => clip.Kind == ClipKind.Aggregate).ToArray();
            var events = clips.SelectMany(CaptureEvents).ToArray();
            var routes = RouteRules();
            WriteLines("clips.jsonl", clips.Select(ExportClip));
            WriteLines("capture-events.jsonl", events);
            WriteLines("url-fallback-rules.jsonl", routes);
            WriteLines("aggregations.jsonl", aggregations.Select(Aggregation));
            WriteJson("collections.json", store.Collections.Select(Collection).ToArray());
            WriteJson("ai-state.json", MacBackupAiState.Export(store, ai));
            AiFile.Save(Path.Combine(staging, "manifest.json"), new
            {
                formatVersion = 5, appVersion = WindowsUpdates.CurrentVersion.ToString(3), exportedAt = Date(DateTimeOffset.UtcNow),
                clipCount = clips.Length, captureEventCount = events.Length, fallbackRuleCount = routes.Length,
                aggregationCount = aggregations.Length, collectionCount = store.Collections.Count, fileChecksums = checksums
            });
            Directory.Move(staging, destination);
        }
        finally
        {
            // The temporary folder has a random name and is created beside this export only.
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }

    private object ExportClip(Clip clip)
    {
        var items = clip.OriginalItems ?? CreateItems(clip);
        string contentHash = clip.OriginalMacIdentity?.ContentHash ??
            Hash(JsonSerializer.SerializeToUtf8Bytes(items.OrderBy(item => item.Order).Select(item =>
                item.Representations.Select(rep => new { rep.Uti, rep.Hash })), Json));
        var original = clip.OriginalMacIdentity;
        return new
        {
            id = clip.Id, createdAt = Date(clip.CreatedAt ?? clip.CapturedAt), updatedAt = Date(ClipActivity.LastUsed(clip)),
            lastCopiedAt = Date(clip.CapturedAt), lastPastedAt = Date(clip.LastPastedAt),
            primaryKind = original is { Kind.Length: > 0 } ? original.Kind : Kind(clip.Kind),
            secondaryKinds = original?.SecondaryKinds ?? (clip.Kind == ClipKind.Mixed ?
                new[] { clip.HasImage ? "image" : null, clip.Text is not null ? "text" : null, clip.Files.Length > 0 ? "file" : null }
                    .OfType<string>().ToArray() : []),
            title = clip.Title, note = clip.Note, priority = (int)clip.Priority,
            isFavorite = clip.Favorite, isPinned = clip.Pinned, isArchived = clip.ArchivedAt is not null,
            source = Source(clip.Source, clip.SourceIdentifier, clip.SourceConfidence),
            previewText = AiTasks.Compact(clip.PlainText ?? "", 600), contentHash, identityKey = original?.IdentityKey,
            byteSize = items.Sum(item => item.Representations.Sum(rep => (long)rep.Size)), clip.CopyCount, clip.PasteCount,
            deletedAt = Date(clip.TrashedAt), collectionIDs = clip.CollectionIds, aiAnalysisExcluded = clip.ExcludeFromAi,
            automaticTitle = clip.LinkDetails?.Title ?? clip.LinkDetails?.FallbackTitle, codeMetadata = Code(clip),
            fileMetadata = clip.Files.Length == 0 ? null : new { fileNames = clip.Files.Select(Path.GetFileName), filePaths = clip.Files },
            quickTextTransformations = clip.Conversions.Select(conversion => new
            {
                action = conversion.Tool == TextTool.HexToRgba ? "hexToRGBA" : Camel(conversion.Tool.ToString()),
                originalText = conversion.Original, source = Source(conversion.Source, null, "unknown")
            }).ToArray(),
            localOCR = clip.RecognizedText is { Length: > 0 } text ? new
            {
                version = 1, contentHash, text, recognizedAt = Date(ClipActivity.LastUsed(clip))
            } : null,
            items = items.Select(item => new
            {
                item.Id, item.Order, representations = item.Representations.Select(rep => new
                {
                    rep.Id, rep.Uti, storage = new
                    {
                        type = "attachment", relativePath = AttachmentName(rep), checksum = rep.Hash.ToLowerInvariant(), rep.Size
                    }
                }).ToArray()
            }).ToArray()
        };
    }

    private object[] RouteRules() => (fallbacks ?? []).Where(rule => rule.Route is not null).Select(rule =>
    {
        var route = rule.Route!;
        return (object)new
        {
            route.Id, route.Name, origin = "user", route.Enabled, hostPattern = route.Host, pathTemplate = route.Path,
            route.RequiredQueryKeys, titleTemplate = rule.Title, route.Priority, createdAt = Date(DateTimeOffset.UtcNow),
            updatedAt = Date(DateTimeOffset.UtcNow)
        };
    }).ToArray();

    private ClipboardItem[] CreateItems(Clip clip)
    {
        var items = new List<ClipboardItem>();
        var reps = new List<ClipboardRepresentation>();
        if (clip.Text is { } text) reps.Add(New(clip.Kind == ClipKind.Link ? "public.url" : "public.utf8-plain-text", Encoding.UTF8.GetBytes(text)));
        if (clip.Html is { } html) reps.Add(New("public.html", Encoding.UTF8.GetBytes(HtmlFragment(html))));
        if (clip.Rtf is { } rtf) reps.Add(New("public.rtf", Encoding.Latin1.GetBytes(rtf)));
        if (clip.HasImage) reps.Add(New(ImageUti(clip.ImageFormat), store.ReadImage(clip)));
        if (reps.Count > 0) items.Add(new(Guid.NewGuid(), 0, reps.ToArray()));
        foreach (string file in clip.Files)
        {
            Uri.TryCreate(file, UriKind.Absolute, out var uri);
            string value = uri is { IsFile: true } ? uri.AbsoluteUri : file;
            items.Add(new(Guid.NewGuid(), items.Count, [New("public.file-url", Encoding.UTF8.GetBytes(value))]));
        }
        return items.ToArray();

        ClipboardRepresentation New(string uti, byte[] data)
        {
            var rep = new ClipboardRepresentation(Guid.NewGuid(), uti, Hash(data), data.Length);
            WriteAttachment(rep, data);
            return rep;
        }
    }

    private void WriteLines(string name, IEnumerable<object> rows)
    {
        string path = Path.Combine(staging, name);
        using (var file = new StreamWriter(path, append: false, new UTF8Encoding(false)))
        {
            file.NewLine = "\n";
            foreach (var row in rows) file.WriteLine(JsonSerializer.Serialize(row, Json));
        }
        using var stream = File.OpenRead(path);
        checksums[name] = Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    private void WriteJson<T>(string name, T value) => WriteBytes(name, JsonSerializer.SerializeToUtf8Bytes(value, Json));

    private void WriteBytes(string name, byte[] data)
    {
        string path = Path.Combine(staging, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, data);
        checksums.Add(name, Hash(data));
    }

    private string AttachmentName(ClipboardRepresentation rep)
    {
        string path = PathFor(rep);
        if (!checksums.ContainsKey(path)) WriteAttachment(rep, store.ReadRepresentation(rep));
        return path["data/Attachments/".Length..];
    }

    private void WriteAttachment(ClipboardRepresentation rep, byte[] data)
    {
        string path = PathFor(rep);
        if (!checksums.ContainsKey(path)) WriteBytes(path, data);
    }

    private static string PathFor(ClipboardRepresentation rep)
    {
        if (rep.Hash is not { Length: 64 } || !rep.Hash.All(char.IsAsciiHexDigit) ||
            rep.Size is < 0 or > HistoryStore.MaximumRepresentationBytes)
            throw new InvalidDataException("Invalid clipboard representation reference.");
        return "data/Attachments/" + rep.Hash.ToLowerInvariant() + ".bin";
    }

    private static IEnumerable<object> CaptureEvents(Clip clip)
    {
        var events = clip.Captures.Length > 0 ? clip.Captures :
            clip.CopyCount > 0 ? [new CaptureEvent(clip.CapturedAt, clip.Source)] : [];
        return events.Select((capture, index) => new
        {
            id = StableId($"{clip.Id:N}:{capture.CapturedAt.UtcTicks}:{index}"), clipID = clip.Id, capturedAt = Date(capture.CapturedAt),
            source = Source(capture.Source, null, clip.SourceConfidence),
            context = capture.Context is null && capture.Url is null && capture.Details is null ? null : new
            {
                kind = capture.Url is not null ? "webPage" : "conversation", strategyIdentifier = "pasteory.windows",
                strategyVersion = 1, summary = capture.Context ?? "", payload = Payload(capture), entities = Array.Empty<object>()
            }
        });
    }

    private static Dictionary<string, string> Payload(CaptureEvent capture)
    {
        var payload = capture.Details is { } details ? new Dictionary<string, string>(details) : [];
        if (capture.Url is { } url) payload["url"] = url;
        return payload;
    }

    private static object Aggregation(Clip clip) => new
    {
        clip.Id, clip.Title, clip.Note, createdAt = Date(clip.CreatedAt ?? clip.CapturedAt),
        updatedAt = Date(clip.AggregationUpdatedAt ?? clip.CapturedAt),
        isFavorite = clip.Favorite, isPinned = clip.Pinned, collectionIDs = clip.CollectionIds, memberClipIDs = clip.Members,
        membershipMode = "fixed", origin = clip.AggregationOrigin is { Length: > 0 } origin && (clip.AggregationFromSearch || origin != "Manual") ?
            clip.AggregationFromSearch ? (object)new { search = new { query = origin } } : new { condition = new { summary = origin } } :
            new { manual = new { } }, excludedClipIDs = Array.Empty<Guid>()
    };

    private static object Collection(ClipCollection collection, int index)
    {
        object? ruleSet = collection.Rules is { } rules ? SmartRule(rules, nested: false) : null;
        return new { collection.Id, collection.Name, kind = ruleSet is null ? "normal" : "smart", sortOrder = index, ruleSet,
            windowsRuleSet = ruleSet is null ? collection.Rules : null };
    }

    private static object? SmartRule(SmartRules rules, bool nested)
    {
        var conditions = new List<object>();
        foreach (var rule in rules.Conditions)
        {
            string? field = rule.Field switch
            {
                RuleField.Source => "sourceApp", RuleField.Text => "body", RuleField.Conversion => "quickTextAction",
                RuleField.SourceConfidence or RuleField.CreatedAt or RuleField.Kind or RuleField.Title or RuleField.Note or
                    RuleField.ByteSize or RuleField.Priority or RuleField.Favorite or RuleField.CopyCount => Camel(rule.Field.ToString()),
                _ => null
            };
            if (field is null || rule.Comparison is RuleComparison.StartsWith or RuleComparison.EndsWith or RuleComparison.DoesNotContain or
                RuleComparison.DoesNotEqual) return null;
            string value = rule.Field switch
            {
                RuleField.Kind when Enum.TryParse(rule.Value, true, out ClipKind kind) => Kind(kind),
                RuleField.Priority when Enum.TryParse(rule.Value, true, out ClipPriority priority) => ((int)priority).ToString(CultureInfo.InvariantCulture),
                RuleField.Favorite or RuleField.SourceConfidence => rule.Value.ToLowerInvariant(),
                RuleField.Conversion when rule.Value == nameof(TextTool.HexToRgba) => "hexToRGBA",
                RuleField.Conversion => Camel(rule.Value), _ => rule.Value
            };
            conditions.Add(new { id = Guid.NewGuid(), field, operation = Camel(rule.Comparison.ToString()), value });
        }
        var groups = rules.Groups.Select(group => SmartRule(group, nested: true)).ToArray();
        if (groups.Any(group => group is null)) return null;
        return new { id = nested ? (Guid?)Guid.NewGuid() : null, mode = rules.MatchAll ? "all" : "any", conditions, groups };
    }

    internal static string? Date(DateTimeOffset? date) => date?.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    internal static Guid StableId(string source) => new(SHA256.HashData(Encoding.UTF8.GetBytes(source)).AsSpan(0, 16));
    private static string Hash(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
    private static string Camel(string value) => value.Length > 0 ? char.ToLowerInvariant(value[0]) + value[1..] : value;
    private static string Kind(ClipKind kind) => kind == ClipKind.Files ? "file" : kind.ToString().ToLowerInvariant();
    private static object Source(string name, string? app, string confidence) => new
    {
        appName = name, bundleIdentifier = app, confidence = confidence.ToLowerInvariant() is "high" or "low" ? confidence.ToLowerInvariant() : "unknown"
    };

    private static object? Code(Clip clip)
    {
        if (clip.Kind != ClipKind.Code) return null;
        string? language = clip.CodeLanguage?.ToLowerInvariant() switch
        {
            "py" => "python", "js" => "javascript", "ts" => "typescript", "kt" => "kotlin", "sh" or "ps1" => "shell",
            "swift" or "java" or "sql" or "json" or "yaml" or "xml" or "html" or "css" => clip.CodeLanguage.ToLowerInvariant(),
            _ => null
        };
        return new
        {
            subtype = language == "shell" ? "shellCommand" : "sourceCode", language, confidence = 1, codeLineRatio = 1,
            analyzedCharacterCount = clip.Text?.Length ?? 0, wasTruncatedForClassification = false, classifierVersion = 1
        };
    }

    private static string ImageUti(ClipImageFormat format) => format switch
    {
        ClipImageFormat.Jpeg => "public.jpeg", ClipImageFormat.Tiff => "public.tiff",
        ClipImageFormat.Gif => "com.compuserve.gif", ClipImageFormat.Bmp => "com.microsoft.bmp",
        ClipImageFormat.WebP => "org.webmproject.webp", ClipImageFormat.Heif => "public.heic", ClipImageFormat.Avif => "public.avif",
        _ => "public.png"
    };

    private static string HtmlFragment(string html)
    {
        if (!html.StartsWith("Version:", StringComparison.OrdinalIgnoreCase)) return html;
        byte[] bytes = Encoding.UTF8.GetBytes(html);
        int Offset(string key) => int.TryParse(HtmlOffset().Matches(html).FirstOrDefault(match => match.Groups[1].Value == key)?.Groups[2].Value,
            NumberStyles.None, CultureInfo.InvariantCulture, out int value) ? value : -1;
        int start = Offset("StartFragment"), end = Offset("EndFragment");
        return start >= 0 && end >= start && end <= bytes.Length ? Encoding.UTF8.GetString(bytes, start, end - start) : html;
    }

    [GeneratedRegex(@"^(StartFragment|EndFragment):([0-9]+)", RegexOptions.Multiline | RegexOptions.CultureInvariant)]
    private static partial Regex HtmlOffset();
}
