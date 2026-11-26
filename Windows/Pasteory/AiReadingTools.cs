using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace Pasteory.Windows;

internal sealed class AiReadingTools(IEnumerable<AiInput> input, Dictionary<Guid, AiResource[]>? resources = null)
{
    private readonly Dictionary<Guid, AiInput> clips = input.ToDictionary(clip => clip.Id);
    internal object[] Definitions => resources is { Count: > 0 } ? [.. TextDefinitions, AiTaskResources.Definition] : TextDefinitions;
    private static readonly object[] TextDefinitions =
    [
        new
        {
            type = "function",
            function = new
            {
                name = "clips_get",
                description = "Read a bounded page from the complete saved text of one item in this task.",
                parameters = new
                {
                    type = "object",
                    properties = new
                    {
                        id = new { type = "string" },
                        offset = new { type = "integer" },
                        maxChars = new { type = "integer" }
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
                description = "Find excerpts in eligible text from this task. Returned IDs are references, not new assignment scope.",
                parameters = new
                {
                    type = "object",
                    properties = new { query = new { type = "string" } },
                    required = new[] { "query" }
                }
            }
        }
    ];

    internal string Reply(AiModelClient.ToolCall call)
    {
        if (call.Arguments.Length > 5120) return Error("Invalid tool arguments");
        try
        {
            using var document = JsonDocument.Parse(call.Arguments);
            var args = document.RootElement;
            if (args.ValueKind != JsonValueKind.Object) return Error("Invalid tool arguments");
            return call.Name switch
            {
                "clips_get" => Read(args), "clips_search" => Search(args), _ => Error("Unknown tool")
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
            if (args.ValueKind != JsonValueKind.Object || !args.TryGetProperty("id", out var item) ||
                !item.TryGetGuid(out Guid id) || !clips.ContainsKey(id) || !resources.TryGetValue(id, out var files))
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
        if (!args.TryGetProperty("id", out var id) || !id.TryGetGuid(out Guid key) || !clips.TryGetValue(key, out var clip))
            return Error("Item is outside this task");
        int start = Math.Clamp(Number(args, "offset", 0), 0, clip.Text.Length);
        int length = Math.Min(Math.Clamp(Number(args, "maxChars", 1200), 1, 4000), clip.Text.Length - start);
        return JsonSerializer.Serialize(new
        {
            id = key, offset = start, text = clip.Text.Substring(start, length), totalChars = clip.Text.Length,
            nextOffset = start + length < clip.Text.Length ? (int?)(start + length) : null,
            title = start == 0 ? clip.Title : null, note = start == 0 ? clip.Note : null
        });
    }

    private string Search(JsonElement args)
    {
        string query = args.TryGetProperty("query", out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() ?? "" : "";
        if (query.Length is < 1 or > 400) return Error("Enter a search term");
        var hits = clips.Values.Select(clip => (Clip: clip, At: clip.Text.IndexOf(query, StringComparison.OrdinalIgnoreCase)))
            .Where(match => match.At >= 0 || match.Clip.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                match.Clip.Note.Contains(query, StringComparison.OrdinalIgnoreCase)).Take(10);
        return JsonSerializer.Serialize(hits.Select(match =>
        {
            int start = Math.Max(0, match.At - 50);
            return new { id = match.Clip.Id, title = match.Clip.Title, text = match.Clip.Text.Substring(start, Math.Min(300, match.Clip.Text.Length - start)) };
        }));
    }

    private static int Number(JsonElement args, string name, int fallback) => args.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int parsed) ? parsed : fallback;
    private static string Error(string message) => JsonSerializer.Serialize(new { error = message });
}
