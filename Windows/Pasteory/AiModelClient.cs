using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed class AiModelClient(HttpClient? transport = null)
{
    private static readonly HttpClient DefaultClient = new(new SocketsHttpHandler
    {
        UseCookies = false, AllowAutoRedirect = false, MaxResponseHeadersLength = 32
    }) { Timeout = TimeSpan.FromSeconds(90) };
    private readonly HttpClient client = transport ?? DefaultClient;

    internal sealed record Model(string Id, string[] Reasoning);
    internal sealed record ToolCall(string Id, string Name, string Arguments, JsonElement Wire);
    internal sealed record Completion(string Content, int Input, int Output, int Cached, int Reasoning, bool Estimated, ToolCall[] Tools);

    internal static bool TryEndpoint(string raw, out Uri endpoint)
    {
        bool valid = Uri.TryCreate(raw.Trim().TrimEnd('/') + "/", UriKind.Absolute, out var parsed) &&
            (parsed.Scheme == "https" || parsed.Scheme == "http" && parsed.IsLoopback) &&
            parsed.UserInfo.Length == 0 && parsed.Query.Length == 0 && parsed.Fragment.Length == 0;
        endpoint = valid ? parsed! : null!;
        return valid;
    }

    internal async Task<Model[]> ModelsAsync(string endpoint, string key, CancellationToken cancel)
    {
        using var request = Request(endpoint, "models", key, HttpMethod.Get);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
        using var document = await ReadJsonAsync(response, cancel);
        return document.RootElement.GetProperty("data").EnumerateArray()
            .Select(item =>
            {
                string name = item.GetProperty("id").GetString() ?? "";
                var options = item.TryGetProperty("reasoning_levels", out var levels) ||
                    item.TryGetProperty("supported_reasoning_levels", out levels) ? levels : default;
                string[] reasoning = options.ValueKind == JsonValueKind.Array ? options.EnumerateArray()
                    .Where(level => level.ValueKind == JsonValueKind.String).Select(level => level.GetString()!)
                    .Where(level => level.Length > 0).Distinct(StringComparer.Ordinal).ToArray() : [];
                return new Model(name, reasoning);
            }).Where(model => model.Id.Length > 0).DistinctBy(model => model.Id).OrderBy(model => model.Id).ToArray();
    }

    private static Dictionary<string, object?> ChatBody(AiPreferences settings, int outputLimit,
        IReadOnlyList<object> conversation, object[]? tools)
    {
        var body = new Dictionary<string, object?>
        {
            ["model"] = settings.Model, ["max_tokens"] = outputLimit, ["stream"] = false,
            ["messages"] = conversation
        };
        if (!string.IsNullOrWhiteSpace(settings.Reasoning) && settings.Reasoning != "auto")
            body["reasoning_effort"] = settings.Reasoning;
        if (tools is { Length: > 0 }) body["tools"] = tools;
        return body;
    }

    internal static int EstimateRequest(AiPreferences settings, int outputLimit, IReadOnlyList<object> conversation, object[]? tools)
    {
        var text = conversation.Where(message => message is not AiResourceMessage).ToArray();
        int bytes = JsonSerializer.SerializeToUtf8Bytes(ChatBody(settings, outputLimit, text, tools), AiFile.Wire).Length;
        // Image URLs contain encoded pixels. Count their estimated model cost separately.
        return (bytes + 1) / 2 + 1500 * (conversation.Count - text.Length);
    }

    internal async Task<Completion> CompleteAsync(AiPreferences settings, string key, int outputLimit, int estimatedInput,
        IReadOnlyList<object> conversation, object[]? tools, CancellationToken cancel)
    {
        using var request = Request(settings.Endpoint, "chat/completions", key, HttpMethod.Post);
        request.Content = JsonContent.Create(ChatBody(settings, outputLimit, conversation, tools), options: AiFile.Wire);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
        using var document = await ReadJsonAsync(response, cancel);
        var root = document.RootElement;
        var message = root.GetProperty("choices")[0].GetProperty("message");
        string content = message.TryGetProperty("content", out var contentValue) && contentValue.ValueKind == JsonValueKind.String ?
            contentValue.GetString() ?? "" : "";
        ToolCall[] requested = message.TryGetProperty("tool_calls", out var calls) && calls.ValueKind == JsonValueKind.Array ?
            calls.EnumerateArray().Take(8).Select(call =>
            {
                var function = call.GetProperty("function");
                return new ToolCall(call.GetProperty("id").GetString() ?? "", function.GetProperty("name").GetString() ?? "",
                    function.GetProperty("arguments").GetString() ?? "", call.Clone());
            }).ToArray() : [];
        if (content.Length == 0 && requested.Length == 0) throw new InvalidDataException("The model returned no content.");
        bool usage = root.TryGetProperty("usage", out var tokens) && tokens.ValueKind == JsonValueKind.Object;
        int? inputCount = TokenCount(tokens, "prompt_tokens"), outputCount = TokenCount(tokens, "completion_tokens");
        return new Completion(content, inputCount ?? estimatedInput, outputCount ?? outputLimit,
            usage && tokens.TryGetProperty("prompt_tokens_details", out var details) ? TokenCount(details, "cached_tokens") ?? 0 : 0,
            usage && tokens.TryGetProperty("completion_tokens_details", out var output) ? TokenCount(output, "reasoning_tokens") ?? 0 : 0,
            inputCount is null || outputCount is null, requested);
    }

    private static int? TokenCount(JsonElement element, string name) => element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int number)
        ? Math.Max(0, number) : null;

    private static HttpRequestMessage Request(string endpoint, string suffix, string key, HttpMethod method)
    {
        if (!TryEndpoint(endpoint, out var url)) throw new ArgumentException("Use an HTTPS API endpoint or a loopback HTTP endpoint.");
        var request = new HttpRequestMessage(method, new Uri(url, suffix));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (key.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        return request;
    }

    private static async Task<JsonDocument> ReadJsonAsync(HttpResponseMessage response, CancellationToken cancel)
    {
        if (!response.IsSuccessStatusCode) throw new HttpRequestException($"Model API HTTP {(int)response.StatusCode}");
        await using var source = await response.Content.ReadAsStreamAsync(cancel);
        var limit = new byte[2 * 1024 * 1024 + 1];
        int bytes = await source.ReadAtLeastAsync(limit, limit.Length, false, cancel);
        if (bytes == limit.Length) throw new InvalidDataException("The model response is too large.");
        return JsonDocument.Parse(limit.AsMemory(0, bytes));
    }
}

internal sealed class AiCredentials(string root)
{
    private sealed record Entry(string Endpoint, string Key);
    private static readonly byte[] Entropy = "Pasteory model credentials"u8.ToArray();
    private readonly string path = Path.Combine(root, "ai-credentials.dat");

    internal string Read(string endpoint)
    {
        if (!File.Exists(path)) return "";
        var bytes = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
        try
        {
            var entry = JsonSerializer.Deserialize<Entry>(bytes);
            return entry?.Endpoint == endpoint.Trim().TrimEnd('/') ? entry.Key : "";
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    internal void Set(string endpoint, string key)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new Entry(endpoint.Trim().TrimEnd('/'), key));
        try
        {
            var encrypted = ProtectedData.Protect(bytes, Entropy, DataProtectionScope.CurrentUser);
            AiFile.Write(path, stream => stream.Write(encrypted));
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
}

internal static class AiFile
{
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };
    internal static readonly JsonSerializerOptions Wire = new(Json) { WriteIndented = false };
    internal static T? Load<T>(string file) where T : class
    {
        if (!File.Exists(file)) return null;
        using var stream = File.OpenRead(file);
        return JsonSerializer.Deserialize<T>(stream, Json);
    }

    internal static void Save<T>(string path, T value) => Write(path, stream => JsonSerializer.Serialize(stream, value, Json));

    internal static void Write(string file, Action<FileStream> writer)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        string temporary = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = File.Open(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                writer(stream);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, file, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
