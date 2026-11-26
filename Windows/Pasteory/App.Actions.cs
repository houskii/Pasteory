using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Pasteory.Core;
using ActivityKind = Pasteory.Core.ActivityKind;
using Drawing = System.Drawing;

namespace Pasteory.Windows;

public partial class App
{
    private readonly Dictionary<Guid, ImageSource?> thumbnails = [];
    private readonly Dictionary<string, ImageSource?> appIcons = new(StringComparer.OrdinalIgnoreCase);
    private readonly LinkResolver links = new();
    internal LinkSignIn LinkSessions { get; } = new();
    private readonly FileCommandRunner fileCommands = new();

    internal bool UpdateClip(Guid id, Func<Clip, Clip> update)
    {
        bool saved = false;
        if (ChangeHistory(() => saved = history.Update(id, update)) && !saved)
            Notify("Could not save changes to this clip.");
        return saved;
    }
    internal bool EditClip(Guid id, Func<Clip, Clip> change) =>
        UpdateClip(id, clip => ClipActivity.Record(change(clip), ActivityKind.Edit, DateTimeOffset.UtcNow));

    internal void ToggleFavorite(Clip clip) => UpdateClip(clip.Id, current => current with { Favorite = !current.Favorite });
    internal void TogglePin(Clip clip) => UpdateClip(clip.Id, current => current with { Pinned = !current.Pinned });
    internal void TrashClip(Clip clip) => ChangeHistory(() => history.Trash(clip.Id));
    internal void RestoreClip(Clip clip) => ChangeHistory(() => history.Restore(clip.Id));
    internal void EraseClip(Clip clip) => ChangeHistory(() => history.Delete(clip));
    internal void EmptyTrash() => ChangeHistory(history.EmptyTrash);
    internal void ToggleArchive(Clip clip) => ChangeHistory(() => history.SetArchived(clip.Id, clip.ArchivedAt is null));
    internal void RunArchiveNow() => ChangeHistory(() => history.RunMaintenance(DateTimeOffset.Now, Settings.ArchiveAfterDays));
    internal void ExportBackup(string path)
    {
        try { history.ExportBackup(path); Notify("Backup exported."); }
        catch (Exception error) when (IsLocalError(error)) { Notify(error.Message); }
    }
    internal void ImportBackup(string path)
    {
        int count = 0;
        try
        {
            if (ChangeHistory(() => count = history.ImportBackup(path)))
                Notify(Labels.Format("Imported {0} clips.", count));
        }
        catch (Exception error) when (error is InvalidDataException or System.Text.Json.JsonException) { Notify(error.Message); }
    }
    internal void ImportMacBackup(string path)
    {
        try
        {
            (int Count, LinkFallbackRule[] Fallbacks) result = (0, []);
            if (!ChangeHistory(() => result = new MacBackupReader(path).Import(history))) return;
            if (result.Fallbacks.Length > 0)
                SaveSettings(Settings with { LinkFallbacks = Settings.LinkFallbacks.Concat(result.Fallbacks).Distinct().ToArray() });
            Notify(Labels.Format("Imported {0} clips.", result.Count));
        }
        catch (Exception error) when (error is InvalidDataException or System.Text.Json.JsonException or FormatException or
            InvalidOperationException or NotSupportedException or System.Runtime.InteropServices.COMException)
        { Notify(error.Message); }
    }
    internal void RemoveMember(Guid parent, Guid child) => UpdateClip(parent,
        clip => clip with { Members = clip.Members.Where(id => id != child).ToArray() });
    internal void FavoriteMembers(Clip aggregate) => ChangeHistory(() => history.FavoriteMembers(aggregate.Members));

    internal ClipCollection? SaveCollection(Guid? id, string name, SmartRules? rules)
    {
        ClipCollection? group = null;
        ChangeHistory(() => group = history.SaveCollection(id, name, rules));
        return group;
    }

    internal void DeleteCollection(ClipCollection group) => ChangeHistory(() => history.DeleteCollection(group.Id));
    internal void MoveCollection(Guid id, Guid? before) => ChangeHistory(() => history.MoveCollection(id, before));
    internal void MoveCollectionWithinType(Guid id, Guid before) => ChangeHistory(() => history.MoveCollectionWithinType(id, before));

    internal Clip? SaveAggregation(Guid? id, string title, string note, IEnumerable<Guid> members, string? origin)
    {
        Clip? clip = null;
        if (ChangeHistory(() => clip = history.SaveAggregation(id, title, note, members, origin)))
            Notify(Labels.Format("Aggregated {0} clips", clip!.Members.Length));
        return clip;
    }

    internal Clip? SaveManual(string text, string title)
    {
        var (kind, language) = TextTools.Classify(text);
        Clip? saved = null;
        if (!string.IsNullOrWhiteSpace(text) && ChangeHistory(() => history.Capture(new Clip
            { Kind = kind, CodeLanguage = language, Text = text, Title = title.Trim(), Source = "Pasteory", CopyCount = 0, IsManual = true },
            null, out saved)) && saved is not null)
            _ = EnrichAsync(saved, null);
        return saved;
    }

    internal bool EditManualText(Guid id, string text)
    {
        bool changed = false;
        if (ChangeHistory(() => changed = history.UpdateManualText(id, text)) && !changed)
            Notify("Could not save changes to this clip.");
        return changed;
    }

    internal void ConvertClip(Clip clip, TextTool tool)
    {
        if (clip.PlainText is not { Length: > 0 } original)
        {
            Notify("This clip has no text to convert.");
            return;
        }
        try
        {
            string text = TextTools.ConvertText(tool, original);
            var (kind, language) = TextTools.Classify(text);
            var converted = new Clip
            {
                Kind = kind, CodeLanguage = language, Source = "Pasteory", Text = text, CopyCount = 0,
                Note = Labels.Format("{0} ({1})\nSource: {2}", original, Labels.Get(ClipMenus.ToolLabel(tool)), clip.Source),
                Conversions = [new ConversionRecord(tool, original, clip.Source)]
            };
            if (!ChangeHistory(() =>
            {
                if (!history.Capture(converted)) throw new ArgumentException(Labels.Get("The result exceeds the history limit."));
            })) return;
            Clipboard.SetDataObject(ClipboardFormats.Create(converted, true, null), copy: true);
            observedSequence = NativeMethods.GetClipboardSequenceNumber();
            Notify("Converted and copied.");
        }
        catch (ExternalException) { Notify("The clipboard is busy. Try again."); }
        catch (Exception error) when (error is FormatException or ArgumentException)
        {
            Notify("The text is not valid for this conversion.");
        }
    }

    internal ImageSource? ClipThumbnail(Clip clip)
    {
        if (thumbnails.TryGetValue(clip.Id, out var cached)) return cached;
        try { cached = ClipboardFormats.DecodePreview(ReadImage(clip), 126); }
        catch (Exception error) when (IsLocalError(error) || error is NotSupportedException or ArgumentException or FileFormatException)
        {
            cached = null;
        }
        if (thumbnails.Count >= 180) thumbnails.Clear();
        thumbnails[clip.Id] = cached;
        return cached;
    }

    internal ImageSource? SourceIcon(string? file)
    {
        if (file is null) return null;
        if (appIcons.TryGetValue(file, out var image)) return image;
        try
        {
            if (!Path.IsPathFullyQualified(file) || file.StartsWith(@"\\", StringComparison.Ordinal) ||
                !file.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(file)) return null;
            using var applicationIcon = Drawing.Icon.ExtractAssociatedIcon(file);
            if (applicationIcon is not null)
            {
                image = Imaging.CreateBitmapSourceFromHIcon(applicationIcon.Handle, Int32Rect.Empty,
                    BitmapSizeOptions.FromWidthAndHeight(32, 32));
                image.Freeze();
            }
        }
        catch (Exception error) when (IsLocalError(error) || error is Win32Exception or ArgumentException or ExternalException) { }
        if (appIcons.Count >= 180) appIcons.Clear();
        appIcons[file] = image;
        return image;
    }

    internal void OpenClip(Clip clip, Window owner)
    {
        try
        {
            switch (clip.Kind)
            {
                case ClipKind.Link when string.IsNullOrWhiteSpace(Settings.BrowserPath):
                    Notify("Choose a browser in Open With.");
                    break;
                case ClipKind.Link when Uri.TryCreate(clip.Text?.Trim(), UriKind.Absolute, out var url) && url.Scheme is "http" or "https":
                    StartApp(Settings.BrowserPath!, url.AbsoluteUri);
                    MarkOpened(clip);
                    break;
                case ClipKind.Image:
                    string image = WritePreviewFile("png", ReadImage(clip));
                    if (string.IsNullOrWhiteSpace(Settings.ImageViewerPath)) OpenInShell(image);
                    else StartApp(Settings.ImageViewerPath, image);
                    MarkOpened(clip);
                    break;
                case ClipKind.Code when !string.IsNullOrWhiteSpace(Settings.CodeEditorPath):
                    var code = System.Text.Encoding.UTF8.GetBytes(clip.PlainText ?? "");
                    string ext = clip.CodeLanguage is { Length: > 0 and < 16 } extension && extension.All(char.IsAsciiLetterOrDigit)
                        ? extension : "txt";
                    StartApp(Settings.CodeEditorPath, WritePreviewFile(ext, code));
                    MarkOpened(clip);
                    break;
                case ClipKind.Files:
                    if (OpenFiles(clip.Files)) MarkOpened(clip);
                    break;
                case ClipKind.Text or ClipKind.Code:
                    ContentPreview.Show(this, clip, owner);
                    MarkOpened(clip);
                    break;
                default:
                    Notify("This content type cannot be opened.");
                    break;
            }
        }
        catch (Exception error) when (IsLocalError(error) || error is Win32Exception or InvalidOperationException or ArgumentException)
        {
            Notify(error.Message);
        }
    }

    private void MarkOpened(Clip clip) => UpdateClip(clip.Id, current =>
        ClipActivity.Record(current, ActivityKind.Open, DateTimeOffset.UtcNow));

    private bool OpenFiles(string[] files)
    {
        var actions = new List<(string File, FileOpenRule Rule)>();
        foreach (string path in files)
        {
            if (!Path.IsPathFullyQualified(path) || !File.Exists(path))
            {
                Notify(Labels.Format("File is missing: {0}", Path.GetFileName(path)));
                return false;
            }
            var rule = Settings.FileRules.Where(entry => entry.Extension.Length > 0 && path.EndsWith(
                "." + entry.Extension.Trim('.'), StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(entry => entry.Extension.Length).FirstOrDefault();
            if (rule is null || string.IsNullOrWhiteSpace(rule.Command) &&
                (string.IsNullOrWhiteSpace(rule.ApplicationPath) || !File.Exists(rule.ApplicationPath)))
            {
                Notify(Labels.Format("Choose an open rule for {0}.", Path.GetFileName(path)));
                return false;
            }
            actions.Add((path, rule));
        }
        foreach (var (path, rule) in actions)
        {
            if (!string.IsNullOrWhiteSpace(rule.Command))
                _ = fileCommands.RunAsync(dataDirectory, rule, path);
            else StartApp(rule.ApplicationPath!, path);
        }
        return actions.Count > 0;
    }

    internal FileCommandRunner FileCommands => fileCommands;

    private string WritePreviewFile(string extension, byte[] data)
    {
        string root = Path.Combine(Path.GetTempPath(), "Pasteory-Preview-" + Environment.UserName);
        Directory.CreateDirectory(root);
        foreach (string path in Directory.EnumerateFiles(root, "pasteory-*").Where(path => File.GetLastWriteTimeUtc(path) < DateTime.UtcNow.AddDays(-1)))
        {
            try { File.Delete(path); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        string destination = Path.Combine(root, $"pasteory-{Guid.NewGuid():N}.{extension}");
        File.WriteAllBytes(destination, data);
        return destination;
    }

    internal static void StartApp(string executable, string argument)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false };
        start.ArgumentList.Add(argument);
        using var process = Process.Start(start);
    }

    internal static void OpenInShell(string path)
    {
        using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    private void SetStartAtLogin(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        string entry = Environment.ProcessPath ?? throw new IOException("Pasteory executable is unavailable.");
        string command = Path.GetFileNameWithoutExtension(entry).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
            ? $"\"{entry}\" \"{Assembly.GetExecutingAssembly().Location}\" --tray" : $"\"{entry}\" --tray";
        if (enabled) key.SetValue("Pasteory", command, RegistryValueKind.String);
        else key.DeleteValue("Pasteory", throwOnMissingValue: false);
    }

    private void TryRestoreStartAtLogin()
    {
        try { SetStartAtLogin(Settings.StartAtLogin); }
        catch (Exception error) when (IsLocalError(error) || error is System.Security.SecurityException) { }
    }

    internal void Restart()
    {
        try
        {
            string executable = Environment.ProcessPath ?? throw new IOException("Pasteory executable is unavailable.");
            if (TryLaunchReplacement(executable, waitForExit: true)) Shutdown();
            else Notify("Could not restart Pasteory.");
        }
        catch (Exception error) when (IsLocalError(error) || error is Win32Exception) { Notify(error.Message); }
    }

    private static bool TryLaunchReplacement(string executable, bool waitForExit)
    {
        try
        {
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(executable)! };
            if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
            string[] args = Environment.GetCommandLineArgs();
            for (int i = 1; i < args.Length; i++)
            {
                if (args[i] == "--restart-after") { i++; continue; }
                start.ArgumentList.Add(args[i]);
            }
            if (waitForExit)
            {
                start.ArgumentList.Add("--restart-after");
                start.ArgumentList.Add(Environment.ProcessId.ToString());
            }
            using var process = Process.Start(start);
            return process is not null;
        }
        catch (Exception error) when (IsLocalError(error) || error is Win32Exception or InvalidOperationException) { return false; }
    }

    private static string? FileFingerprint(string[] paths)
    {
        try
        {
            const long maximum = 128L * 1024 * 1024;
            long bytes = 0;
            var hashes = new List<string>();
            foreach (string path in paths)
            {
                if (!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal)) return null;
                var file = new FileInfo(path);
                if (!file.Exists || file.Length > maximum - bytes || file.Attributes.HasFlag(FileAttributes.Offline)) return null;
                bytes += file.Length;
                using var content = file.Open(FileMode.Open, FileAccess.Read, FileShare.Read);
                hashes.Add(Convert.ToHexString(MD5.HashData(content)));
            }
            return string.Join("-", hashes);
        }
        catch (Exception error) when (IsLocalError(error) || error is ArgumentException or NotSupportedException) { return null; }
    }

    private async Task EnrichAsync(Clip clip, byte[]? image)
    {
        if (clip.Kind == ClipKind.Link && Settings.ResolveLinks && clip.LinkDetails?.Status != "Resolved")
            await ResolveLinkAsync(clip);
        if (image is not null && Settings.RecognizeImages && string.IsNullOrEmpty(clip.RecognizedText))
        {
            try
            {
                var recognized = await ImageOcr.ReadAsync(image, Settings.Language, lifetime.Token);
                if (!Exiting && recognized is not null && Settings.RecognizeImages)
                    UpdateClip(clip.Id, current => current.ImageHash == clip.ImageHash ?
                        current with { RecognizedText = recognized } : current);
            }
            catch (OperationCanceledException) when (Exiting) { }
        }
    }

    internal async Task ResolveLinkAsync(Clip clip)
    {
        if (clip.Kind != ClipKind.Link || clip.Text is not { } raw || !links.TryStart(clip.Id)) return;
        try
        {
            LinkDetails result;
            if (Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri) && LinkResolver.Allowed(uri))
            {
                var signIn = Settings.LinkSignIns.FirstOrDefault(rule => rule.Enabled && LinkResolver.MatchRule(rule.Pattern, uri) is not null);
                result = signIn is null ? await links.ResolveAsync(raw, lifetime.Token) :
                    await LinkSessions.ResolveAsync(dataDirectory, signIn, uri, new WindowInteropHelper(window).EnsureHandle(), lifetime.Token);
                if (result.Title is null)
                {
                    foreach (var rule in Settings.LinkFallbacks)
                    {
                        var match = LinkResolver.MatchRule(rule.Pattern, uri);
                        string? title = match is null ? null : LinkResolver.NormalizeTitle(match.Result(rule.Title));
                        if (title is null) continue;
                        result = result with { Title = title, Quality = "Fallback title" };
                        break;
                    }
                }
            }
            else result = new("Invalid link", null, DateTimeOffset.UtcNow);
            if (!Exiting) UpdateClip(clip.Id, current => current.Text == raw ? current with { LinkDetails = result } : current);
        }
        catch (OperationCanceledException) when (Exiting) { }
        finally { links.Finish(clip.Id); }
    }

    internal async Task<int> ResolveMatchingLinksAsync(string? pattern = null)
    {
        var candidates = Clips.Where(clip => clip.Kind == ClipKind.Link && clip.TrashedAt is null && clip.LinkDetails?.Status != "Resolved")
            .Where(clip => pattern is null || Uri.TryCreate(clip.Text?.Trim(), UriKind.Absolute, out var uri) &&
                LinkResolver.MatchRule(pattern, uri) is not null).ToArray();
        foreach (var clip in candidates)
        {
            if (Exiting) break;
            await ResolveLinkAsync(clip);
        }
        return candidates.Length;
    }
}
