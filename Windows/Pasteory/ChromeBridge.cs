using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed record ChromeSelection(DateTimeOffset Time, string Text, string Url, string Title,
    Dictionary<string, string> Details)
{
    internal bool Matches(Clip clip, DateTimeOffset capturedAt) => clip.Source.Equals("chrome", StringComparison.OrdinalIgnoreCase) &&
        (capturedAt - Time).Duration() <= TimeSpan.FromSeconds(5) &&
        clip.Text is { Length: > 0 } raw && raw.Trim().StartsWith(Text, StringComparison.Ordinal) &&
        (Text.Length >= 8192 || raw.Trim().Length == Text.Length);

    internal CaptureEvent Apply(CaptureEvent capture) => capture with { Context = Title, Url = Url, Details = Details };
}

internal static class ChromeBridge
{
    private const string Host = "app.pasteory.web_context";
    internal const string Origin = "chrome-extension://mhmkadhgbgkioefidlaalkbdpndacikd/";
    private const int MaxMessageBytes = 128 * 1024;

    internal static string Register(string root, string executable)
    {
        string source = Path.Combine(AppContext.BaseDirectory, "ChromeExtension");
        string destination = Path.Combine(root, "ChromeExtension");
        if (!File.Exists(Path.Combine(source, "manifest.json"))) throw new IOException("Missing packaged Chrome extension.");
        Directory.CreateDirectory(destination);
        foreach (string file in Directory.EnumerateFiles(source))
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)), overwrite: true);
        string nativeManifest = Path.Combine(root, "chrome-native-host.json");
        File.WriteAllText(nativeManifest, JsonSerializer.Serialize(new
        {
            name = Host,
            description = "Pasteory Web Context",
            path = executable,
            type = "stdio",
            allowed_origins = new[] { Origin }
        }));
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Google\Chrome\NativeMessagingHosts\" + Host);
        key.SetValue("", nativeManifest);
        return destination;
    }

    internal static async Task RunHostAsync(string root)
    {
        using var input = Console.OpenStandardInput();
        using var output = Console.OpenStandardOutput();
        try
        {
            while (await ReadAsync(input, CancellationToken.None) is { } bytes)
            {
                using var request = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 12 });
                var message = request.RootElement;
                string requestId = ReadString(message, "requestId", 100);
                string type = ReadString(message, "type", 30);
                LocalSettings settings = LocalSettings.Load(root);
                bool enabled = settings.IncludeBrowserContext && !settings.Paused && !settings.ShouldIgnore("chrome");
                if (type == "getConfig")
                {
                    bool chinese = settings.Language == "简体中文" || settings.Language == "System" &&
                        CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh";
                    await WriteAsync(output, new { type = "config", requestId, chromeEnabled = enabled, language = chinese ? "zh-Hans" : "en" });
                    continue;
                }
                bool delivered = type == "capture" && enabled && message.TryGetProperty("payload", out var payload) &&
                    ParseSelection(payload) is { } selection && await ForwardAsync(root, selection);
                await WriteAsync(output, new { type = "ack", requestId, ok = delivered });
            }
        }
        catch (Exception error) when (App.IsLocalError(error) || error is JsonException or InvalidOperationException) { }
    }

    internal static async Task ReceiveAsync(string root, Func<ChromeSelection, Task> capture, CancellationToken cancel)
    {
        while (!cancel.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(PipeName(root), PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(cancel).ConfigureAwait(false);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                timeout.CancelAfter(TimeSpan.FromSeconds(2));
                if (await ReadAsync(pipe, timeout.Token).ConfigureAwait(false) is { } data &&
                    JsonSerializer.Deserialize<ChromeSelection>(data) is { } received &&
                    received.Text is { Length: > 0 and <= 8192 } && received.Url.Length <= 8192)
                    await capture(received).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { return; }
            catch (Exception error) when (error is IOException or JsonException or OperationCanceledException)
            {
                if (!cancel.IsCancellationRequested)
                {
                    try { await Task.Delay(100, cancel).ConfigureAwait(false); }
                    catch (OperationCanceledException) { return; }
                }
            }
        }
    }

    private static async Task<bool> ForwardAsync(string root, ChromeSelection selection)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(650));
        await using var pipe = new NamedPipeClientStream(".", PipeName(root), PipeDirection.Out,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try
        {
            await pipe.ConnectAsync(timeout.Token);
            await WriteAsync(pipe, selection, timeout.Token);
            return true;
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or TimeoutException) { return false; }
    }

    private static async Task<byte[]?> ReadAsync(Stream stream, CancellationToken cancel)
    {
        var header = new byte[4];
        if (await stream.ReadAtLeastAsync(header, 4, false, cancel) != 4) return null;
        int length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length is < 1 or > MaxMessageBytes) return null;
        var bytes = new byte[length];
        await stream.ReadExactlyAsync(bytes, cancel);
        return bytes;
    }

    private static async Task WriteAsync<T>(Stream stream, T message, CancellationToken cancel = default)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(message);
        if (bytes.Length > MaxMessageBytes) return;
        byte[] header = new byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
        await stream.WriteAsync(header, cancel);
        await stream.WriteAsync(bytes, cancel);
        await stream.FlushAsync(cancel);
    }

    private static ChromeSelection? ParseSelection(JsonElement payload)
    {
        if (payload.ValueKind != JsonValueKind.Object) return null;
        string text = ReadString(payload, "selectedText", 8192);
        string url = ReadString(payload, "url", 8192);
        if (text.Length == 0 || !Uri.TryCreate(url, UriKind.Absolute, out var origin) ||
            origin.Scheme is not ("http" or "https") || origin.UserInfo.Length > 0) return null;
        if (!DateTimeOffset.TryParse(ReadString(payload, "capturedAt", 48), CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind, out DateTimeOffset time) || (DateTimeOffset.UtcNow - time).Duration().TotalSeconds > 10)
            return null;
        string title = ReadString(payload, "pageTitle", 1024);
        var details = new Dictionary<string, string>();
        Add(payload, "siteName", 256);
        Add(payload, "selectedHTML", 8000);
        if (payload.TryGetProperty("adapter", out var adapter))
            foreach (string name in new[] { "projectId", "mergeRequestId", "repository", "branch", "targetBranch" })
                Add(adapter, name, 256);
        if (payload.TryGetProperty("context", out var context))
            foreach (string name in new[] { "before", "after" }) Add(context, name, 512);
        return new ChromeSelection(time, text, url, title.Length > 0 ? title : origin.Host, details);

        void Add(JsonElement element, string name, int limit)
        {
            string value = ReadString(element, name, limit);
            if (value.Length > 0) details[name] = value;
        }
    }

    private static string ReadString(JsonElement element, string name, int limit) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var field) &&
        field.ValueKind == JsonValueKind.String && field.GetString() is { } value ? value.Trim()[..Math.Min(value.Trim().Length, limit)] : "";

    private static string PipeName(string root) => "Pasteory.Chrome." + Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(root.ToUpperInvariant())))[..24];
}
