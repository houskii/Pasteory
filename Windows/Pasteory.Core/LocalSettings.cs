using System.Text.Json;

namespace Pasteory.Core;

public sealed record LocalSettings
{
    public bool Paused { get; init; }
    public bool UseAlternateShortcut { get; init; }
    public string[] IgnoredApps { get; init; } = [];

    private static readonly HashSet<string> PasswordApps = new(StringComparer.OrdinalIgnoreCase)
    {
        "1Password", "1Password-BrowserSupport", "Bitwarden", "KeePass", "KeePassXC",
        "Dashlane", "ProtonPass", "NordPass", "RoboForm"
    };

    public bool ShouldIgnore(string source) =>
        string.IsNullOrWhiteSpace(source) || PasswordApps.Contains(source) ||
        IgnoredApps.Contains(source, StringComparer.OrdinalIgnoreCase);

    public static LocalSettings Load(string dataDirectory) =>
        LocalJson.Read<LocalSettings>(Path.Combine(dataDirectory, "settings.json")) ?? new();

    public void Save(string dataDirectory) =>
        LocalJson.Write(Path.Combine(dataDirectory, "settings.json"), this);
}

internal static class LocalJson
{
    internal static T? Read<T>(string path) where T : class
    {
        if (!File.Exists(path)) return null;
        using var stream = File.OpenRead(path);
        return JsonSerializer.Deserialize<T>(stream) ?? throw new JsonException("Missing local data.");
    }

    internal static void Write<T>(string path, T value) =>
        WriteFile(path, stream => JsonSerializer.Serialize(stream, value));

    internal static void WriteFile(string path, Action<FileStream> write)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write))
            {
                write(stream);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            Discard(temporary);
        }
    }

    internal static void Discard(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
