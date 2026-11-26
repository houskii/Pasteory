using System.Text.Json;

namespace Pasteory.Core;

public sealed record FileOpenRule(string Extension, string? ApplicationPath = null, string? Command = null,
    bool ShowTerminal = false);

public sealed record LinkSignInRule(Guid Id, string Name, string Pattern, string SignInUrl, bool Enabled = false)
{
    public LinkSessionRefresh Refresh { get; init; } = new();
}
public sealed record LinkFallbackRule(string Pattern, string Title, LinkFallbackRoute? Route = null);
public sealed record LinkFallbackRoute(Guid Id, string Name, string Host, string Path, string[] RequiredQueryKeys,
    bool Enabled = true, int Priority = 100);

public enum SourceCaptureApplication { Chrome, WeChat, Feishu }
public sealed record IgnoredAppIdentity(string Name, string Path);

public sealed record AiPreferences
{
    public bool Enabled { get; init; }
    public string Endpoint { get; init; } = "http://127.0.0.1:3425/v1";
    public string Model { get; init; } = "";
    public string Reasoning { get; init; } = "auto";
    public string Prompt { get; init; } = "";
    public bool ShareNotes { get; init; }
    public bool ShareSource { get; init; }
    public bool ShareOcr { get; init; }
    public bool ShareResources { get; init; }
    public bool AutoOrganize { get; init; } = true;
    public bool IdleOrganize { get; init; } = true;
    public bool WeeklyThemeReview { get; init; } = true;
    public bool AppendExistingAiGroups { get; init; }
    public int IdleStartHour { get; init; } = 1;
    public int IdleEndHour { get; init; } = 2;
    public bool Story { get; init; } = true;
    public int RecentLimit { get; init; } = 100;
    public int TargetGroupCount { get; init; } = 7;
    public int TaskRounds { get; init; } = 80;
    public int DailyTokens { get; init; } = 300_000;
    public int NightlyTokens { get; init; } = 300_000;
    public int DailyAutomaticTasks { get; init; } = 3;
    public ActivityPreferences Activity { get; init; } = new();
}

public sealed record LocalSettings
{
    public bool CompletedOnboarding { get; init; } = true;
    public bool Paused { get; init; }
    public int CaptureIntervalMilliseconds { get; init; }
    public bool UseAlternateShortcut { get; init; }
    public string[] IgnoredApps { get; init; } = [];
    public Dictionary<string, IgnoredAppIdentity> IgnoredAppIdentities { get; init; } = [];
    public string Theme { get; init; } = "BlueViolet";
    public string Appearance { get; init; } = "System";
    public string Language { get; init; } = "System";
    public bool StartAtLogin { get; init; }
    public bool KeepPanelOpen { get; init; }
    public bool GroupSidebar { get; init; }
    public string? QuickGroupPlacement { get; init; }
    public string GroupDisplay { get; init; } = "Common groups";
    public bool RecognizeImages { get; init; }
    public bool IncludeBrowserContext { get; init; }
    public bool IncludeChatContext { get; init; }
    public bool? IncludeWeChatContext { get; init; }
    public bool? IncludeFeishuContext { get; init; }
    public bool ResolveLinks { get; init; }
    public LinkSignInRule[] LinkSignIns { get; init; } = [];
    public LinkFallbackRule[] LinkFallbacks { get; init; } = [];
    public bool AutomaticWebCacheCleanup { get; init; } = true;
    public DateTimeOffset? LastWebCacheCleanup { get; init; }
    public int ArchiveAfterDays { get; init; } = 30;
    public string? BrowserPath { get; init; }
    public string? CodeEditorPath { get; init; }
    public string? ImageViewerPath { get; init; }
    public FileOpenRule[] FileRules { get; init; } = [];
    public Dictionary<string, string> Shortcuts { get; init; } = [];
    public double SettingsWidth { get; init; } = 1360;
    public double SettingsHeight { get; init; } = 820;
    public double PanelWidth { get; init; } = 380;
    public double PanelHeight { get; init; } = 660;
    public string LastSettingsPage { get; init; } = "General";
    public int LastAiTab { get; init; }
    public AiPreferences Ai { get; init; } = new();
    public Guid? SeenStory { get; init; }
    public int StoryOpenings { get; init; }
    public bool CheckUpdatesDaily { get; init; } = true;
    public DateTimeOffset? LastUpdateCheck { get; init; }

    private static readonly HashSet<string> PasswordApps = new(StringComparer.OrdinalIgnoreCase)
    {
        "1Password", "1Password-BrowserSupport", "Bitwarden", "KeePass", "KeePassXC",
        "Dashlane", "ProtonPass", "NordPass", "RoboForm"
    };

    public bool ShouldIgnore(string source) =>
        string.IsNullOrWhiteSpace(source) || PasswordApps.Contains(source) ||
        IgnoredApps.Contains(source, StringComparer.OrdinalIgnoreCase);

    public static SourceCaptureApplication? SourceApplication(string processName) => processName.ToUpperInvariant() switch
    {
        "CHROME" => SourceCaptureApplication.Chrome,
        "WECHAT" or "WEIXIN" => SourceCaptureApplication.WeChat,
        "FEISHU" or "LARK" => SourceCaptureApplication.Feishu,
        _ => null
    };

    public bool SourceContextEnabled(SourceCaptureApplication application) => application switch
    {
        SourceCaptureApplication.Chrome => IncludeBrowserContext,
        SourceCaptureApplication.WeChat => IncludeWeChatContext ?? IncludeChatContext,
        SourceCaptureApplication.Feishu => IncludeFeishuContext ?? IncludeChatContext,
        _ => false
    };

    public bool AllowsSourceContext(string processName) => !Paused && !ShouldIgnore(processName) &&
        SourceApplication(processName) is { } application && SourceContextEnabled(application);

    public int CaptureInterval() => CaptureIntervalMilliseconds is 100 or 500 or 1000 ? CaptureIntervalMilliseconds : 0;

    public static LocalSettings Load(string dataDirectory) =>
        LocalJson.Read<LocalSettings>(Path.Combine(dataDirectory, "settings.json")) ?? new()
        {
            CompletedOnboarding = File.Exists(Path.Combine(dataDirectory, HistoryStore.CatalogFileName)) ||
                File.Exists(Path.Combine(dataDirectory, "history.json"))
        };

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
