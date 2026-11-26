using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace Pasteory.Windows;

internal sealed class AiReadingTools(AiInput[] items, Dictionary<Guid, AiResource[]>? resources = null)
{
    private readonly Dictionary<Guid, AiInput> clips = items.ToDictionary(clip => clip.Id);
    private readonly Dictionary<string, AiInput> byKey = items.Select((clip, index) => (Key: AiTaskWorkspace.ItemKey(index), clip))
        .ToDictionary(item => item.Key, item => item.clip, StringComparer.Ordinal);
    private readonly Dictionary<Guid, string> keys = items.Select((clip, index) => (clip.Id, Key: AiTaskWorkspace.ItemKey(index)))
        .ToDictionary(item => item.Id, item => item.Key);

    internal object[] Definitions(bool story)
    {
        var tools = new List<object>(TextDefinitions);
        if (!story) tools.Add(StageDefinition);
        if (resources is { Count: > 0 }) tools.Add(AiTaskResources.Definition);
        return tools.ToArray();
    }

    private static readonly object StageDefinition = new
    {
        type = "function",
        function = new
        {
            name = "stage_assignments",
            description = "Save up to 48 item classifications to this task only. Reusing an item key updates its staged classification.",
            parameters = new
            {
                type = "object",
                properties = new
                {
                    assignments = new
                    {
                        type = "array", maxItems = 48,
                        items = new
                        {
                            type = "object",
                            properties = new
                            {
                                item = new { type = "string" },
                                groupKeys = new { type = "array", items = new { type = "string" } },
                                reason = new { type = "string" }
                            },
                            required = new[] { "item", "groupKeys" }
                        }
                    }
                },
                required = new[] { "assignments" }
            }
        }
    };

    private static readonly object[] TextDefinitions =
    [
        new
        {
            type = "function",
            function = new
            {
                name = "clips_list",
                description = "List a page from all eligible items in the saved task, with stable item keys, previews and any staged assignments.",
                parameters = new
                {
                    type = "object",
                    properties = new { offset = new { type = "integer" }, limit = new { type = "integer" } },
                    required = new[] { "offset", "limit" }
                }
            }
        },
        new
        {
            type = "function",
            function = new
            {
                name = "clips_get",
                description = "Read a page of complete saved text, note, or title. Use the stable item key or clip UUID.",
                parameters = new
                {
                    type = "object",
                    properties = new
                    {
                        id = new { type = "string" },
                        offset = new { type = "integer" },
                        maxChars = new { type = "integer" },
                        field = new { type = "string", @enum = new[] { "text", "note", "title" } }
                    },
                    required = new[] { "id", "offset", "maxChars" }
                }
            }
        },
        new
        {
            type = "function",
            function = new
            {
                name = "clips_search",
                description = "Find a page of matching excerpts across the saved task.",
                parameters = new
                {
                    type = "object",
                    properties = new { query = new { type = "string" }, offset = new { type = "integer" } },
                    required = new[] { "query" }
                }
            }
        }
    ];

    internal object List(int offset, int limit, IReadOnlyDictionary<string, AiAssignment>? staged = null) => new
    {
        total = items.Length, offset,
        nextOffset = offset + limit < items.Length ? (int?)(offset + limit) : null,
        items = items.Skip(offset).Take(limit).Select(clip =>
        {
            string key = keys[clip.Id];
            return new
            {
                key, clip.Id, clip.Kind, title = AiTasks.Compact(clip.Title, 150),
                text = AiTasks.Compact(clip.Text, 380), note = AiTasks.Compact(clip.Note, 160),
                source = AiTasks.Compact(clip.Source, 100), clip.CopiedAt, clip.PastedAt, clip.LocalResources,
                assignment = staged?.GetValueOrDefault(key)
            };
        })
    };

    internal string Reply(AiModelClient.ToolCall call, Dictionary<string, AiAssignment>? staged = null)
    {
        if (call.Arguments.Length > 32_768) return Error("Invalid tool arguments");
        try
        {
            using var document = JsonDocument.Parse(call.Arguments);
            var args = document.RootElement;
            if (args.ValueKind != JsonValueKind.Object) return Error("Invalid tool arguments");
            return call.Name switch
            {
                "clips_list" => JsonSerializer.Serialize(List(Math.Clamp(Number(args, "offset", 0), 0, items.Length),
                    Math.Clamp(Number(args, "limit", 12), 1, 24), staged), AiFile.Wire),
                "clips_get" => Read(args),
                "clips_search" => Search(args),
                "stage_assignments" when staged is not null => Stage(args, staged),
                _ => Error("Unknown tool")
            };
        }
        catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException)
        {
            return Error("Invalid tool arguments");
        }
    }

    internal AiResourceReply ResourceReply(AiModelClient.ToolCall call, bool allowAttachment)
    {
        if (resources is null || call.Arguments.Length > 5120)
            return new(Error("Resource reading is disabled"));
        try
        {
            using var document = JsonDocument.Parse(call.Arguments);
            var args = document.RootElement;
            if (args.ValueKind != JsonValueKind.Object || Find(args) is not { } clip || !resources.TryGetValue(clip.Id, out var files))
                return new(Error("Item is outside this task"));
            int index = Number(args, "index", -1);
            if (index < 0 || index >= files.Length) return new(Error("Resource index is outside this item"));
            return AiTaskResources.Read(files[index], Number(args, "offset", 0), allowAttachment);
        }
        catch (Exception error) when (AiTasks.Expected(error) || error is NotSupportedException)
        {
            return new(Error("Resource could not be read"));
        }
    }

    private string Read(JsonElement args)
    {
        if (Find(args) is not { } clip) return Error("Item is outside this task");
        string field = args.TryGetProperty("field", out var value) && value.ValueKind == JsonValueKind.String ?
            value.GetString() ?? "text" : "text";
        string text = field switch { "note" => clip.Note, "title" => clip.Title, _ => clip.Text };
        int start = Math.Clamp(Number(args, "offset", 0), 0, text.Length);
        int length = Math.Min(Math.Clamp(Number(args, "maxChars", 1200), 1, 4000), text.Length - start);
        return JsonSerializer.Serialize(new
        {
            key = keys[clip.Id], clip.Id, field, offset = start, text = text.Substring(start, length), totalChars = text.Length,
            nextOffset = start + length < text.Length ? (int?)(start + length) : null
        }, AiFile.Wire);
    }

    private string Search(JsonElement args)
    {
        string query = args.TryGetProperty("query", out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() ?? "" : "";
        if (query.Length is < 1 or > 400) return Error("Enter a search term");
        var hits = clips.Values.Select(clip => (Clip: clip, At: clip.Text.IndexOf(query, StringComparison.OrdinalIgnoreCase)))
            .Where(match => match.At >= 0 || match.Clip.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                match.Clip.Note.Contains(query, StringComparison.OrdinalIgnoreCase))
            .Skip(Math.Max(0, Number(args, "offset", 0))).Take(10);
        return JsonSerializer.Serialize(hits.Select(match =>
        {
            int start = Math.Max(0, match.At - 50);
            return new
            {
                key = keys[match.Clip.Id], match.Clip.Id, title = AiTasks.Compact(match.Clip.Title, 150),
                text = match.Clip.Text.Substring(start, Math.Min(300, match.Clip.Text.Length - start))
            };
        }), AiFile.Wire);
    }

    private string Stage(JsonElement args, Dictionary<string, AiAssignment> staged)
    {
        if (!args.TryGetProperty("assignments", out var value) || value.ValueKind != JsonValueKind.Array ||
            value.GetArrayLength() is < 1 or > 48)
            return Error("Send between one and 48 assignments.");
        var entries = value.Deserialize<AiAssignment[]>(AiFile.Wire)!;
        var submitted = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in entries)
        {
            if (entry?.Item is null || !byKey.ContainsKey(entry.Item) || !submitted.Add(entry.Item) ||
                entry.GroupKeys is null || entry.GroupKeys.Length > 8 || entry.GroupKeys.Distinct().Count() != entry.GroupKeys.Length ||
                entry.GroupKeys.Any(key => key is not { Length: > 0 and <= 40 }) ||
                entry.GroupKeys.Length == 0 && string.IsNullOrWhiteSpace(entry.Reason))
                return Error("Use distinct task item keys, distinct group keys and a reason for each unassigned item.");
        }
        foreach (var entry in entries) staged[entry.Item] = entry with { Reason = AiTasks.Compact(entry.Reason ?? "", 1000) };
        return JsonSerializer.Serialize(new { saved = submitted, classified = staged.Count, total = items.Length }, AiFile.Wire);
    }

    private AiInput? Find(JsonElement args) => args.TryGetProperty("id", out var value) &&
        value.ValueKind == JsonValueKind.String && value.GetString() is { } id ?
        byKey.GetValueOrDefault(id) ?? (Guid.TryParse(id, out Guid guid) ? clips.GetValueOrDefault(guid) : null) : null;

    private static int Number(JsonElement args, string name, int fallback) => args.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int parsed) ? parsed : fallback;
    private static string Error(string message) => JsonSerializer.Serialize(new { error = message });
}
