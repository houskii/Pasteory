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
    private readonly Dictionary<(Guid Id, string? Hash), ImagePreview> thumbnails = [];
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
    internal void RestoreClip(Clip clip)
    {
        if (ChangeHistory(() => history.Restore(clip.Id)) && clip.OcrPending) _ = RecognizePendingImagesAsync();
    }
    internal void EraseClip(Clip clip) => ChangeHistory(() => history.Delete(clip));
    internal void EmptyTrash() => ChangeHistory(history.EmptyTrash);
    internal void ToggleArchive(Clip clip) => ChangeHistory(() => history.SetArchived(clip.Id, clip.ArchivedAt is null));
    internal void RunArchiveNow() => ChangeHistory(() => history.RunMaintenance(DateTimeOffset.Now, Settings.ArchiveAfterDays));
    internal Task<HistoryCleanupPreview> PreviewCleanupAsync(DateTimeOffset cutoff, long bytes) =>
        history.PreviewCleanupAsync(cutoff, bytes, lifetime.Token);

    internal HistoryCleanupResult? CleanHistory(HistoryCleanupPreview preview)
    {
        HistoryCleanupResult? result = null;
        return ChangeHistory(() => result = history.CleanHistory(preview)) ? result : null;
    }

    internal void ExportBackup(string path)
    {
        try { history.ExportBackup(path); Notify("Backup exported."); }
        catch (Exception error) when (IsLocalError(error) || error is InvalidDataException) { Notify(error.Message); }
    }
    internal void ExportMacBackup(string parent)
    {
        string name = $"Pasteory-{DateTime.Now:yyyy-MM-dd-HHmmss}";
        string target = Path.Combine(parent, name + ".pasteorybackup");
        for (int suffix = 2; Directory.Exists(target) || File.Exists(target); suffix++)
            target = Path.Combine(parent, $"{name}-{suffix}.pasteorybackup");
        try
        {
            new MacBackupWriter(history, Ai, Settings.LinkFallbacks).Export(target);
            Notify(Labels.Format("Mac backup exported to {0}.", target));
        }
        catch (Exception error) when (AiTasks.Expected(error)) { Notify(error.Message); }
    }
    internal void ImportBackup(string path)
    {
        int count = 0;
        try
        {
            if (ChangeHistory(() => count = history.ImportBackup(path)))
            {
                Notify(Labels.Format("Imported {0} clips.", count));
                if (count != 0) _ = RecognizePendingImagesAsync();
            }
        }
        catch (Exception error) when (error is InvalidDataException or System.Text.Json.JsonException) { Notify(error.Message); }
    }
    internal void ImportMacBackup(string path)
    {
        try
        {
            (int Count, LinkFallbackRule[] Fallbacks, MacBackupAiArchive Ai) result = (0, [], MacBackupAiArchive.Empty);
            if (!ChangeHistory(() => result = new MacBackupReader(path).Import(history))) return;
            Ai.ImportArchive(result.Ai);
            if (result.Fallbacks.Length > 0)
                SaveSettings(Settings with { LinkFallbacks = Settings.LinkFallbacks.Concat(result.Fallbacks)
                    .DistinctBy(rule => (rule.Route?.Id, rule.Pattern, rule.Title)).ToArray() });
            Notify(Labels.Format("Imported {0} clips.", result.Count));
            if (result.Count != 0) _ = RecognizePendingImagesAsync();
        }
        catch (Exception error) when (AiTasks.Expected(error) || error is FormatException or
            NotSupportedException or System.Runtime.InteropServices.COMException)
        { Notify(error.Message); }
    }
    internal void RemoveMember(Guid parent, Guid child)
    {
        bool dissolved = false;
        if (ChangeHistory(() => dissolved = history.RemoveAggregationMember(parent, child)) && dissolved)
            Notify("Aggregation dissolved. Its clips were kept.");
    }
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

    internal Clip? SaveAggregation(Guid? id, string title, string note, IEnumerable<Guid> members, string? origin, bool fromSearch = false)
    {
        Clip? clip = null;
        if (ChangeHistory(() => clip = history.SaveAggregation(id, title, note, members, origin, fromSearch)))
        {
            Notify(id is null ? Labels.Format("Aggregated {0} clips", clip!.Members.Length) : "Aggregation saved.");
            if (id is null)
            {
                window.OfferAggregationUndo(clip!.Id);
                settingsWindow?.OfferAggregationUndo(clip.Id);
            }
        }
        return clip;
    }

    internal void UndoAggregation(Guid id)
    {
        if (Clips.FirstOrDefault(clip => clip.Id == id && clip.Kind == ClipKind.Aggregate) is { } aggregate &&
            ChangeHistory(() => history.Delete(aggregate)))
            Notify("Aggregation undone.");
    }

    internal Clip? SaveManual(string text, string title)
    {
        var (kind, language) = TextTools.Classify(text);
        Clip? saved = null;
        var clip = new Clip
        {
            Kind = kind, CodeLanguage = language, Text = text, Title = title.Trim(), Source = "Pasteory", CopyCount = 0, IsManual = true
        };
        if (kind == ClipKind.Link) clip = clip with { LinkDetails = LinkFallback(clip) };
        if (!string.IsNullOrWhiteSpace(text) && ChangeHistory(() => history.Capture(clip, null, out saved)) && saved is not null)
            _ = EnrichLinkAsync(saved);
        return saved;
    }

    internal bool EditManualText(Guid id, string text)
    {
        bool changed = false;
        if (ChangeHistory(() => changed = history.UpdateManualText(id, text, LinkFallback)) && !changed)
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

    internal ImagePreview ClipThumbnail(Clip clip)
    {
        var key = (clip.Id, clip.ImageHash);
        if (thumbnails.TryGetValue(key, out var cached)) return cached;
        if (thumbnails.Count >= 180) thumbnails.Remove(thumbnails.Keys.First());
        return thumbnails[key] = ClipImagePreview(clip, 126);
    }

    internal ImagePreview ClipImagePreview(Clip clip, int maximumDimension)
    {
        int width = clip.ImageWidth, height = clip.ImageHeight, size = clip.ImageSize;
        try
        {
            byte[] bytes = ReadImage(clip);
            size = bytes.Length;
            var (actualWidth, actualHeight) = ClipboardImage.Dimensions(bytes);
            if (actualWidth > 0 && actualHeight > 0) (width, height) = (actualWidth, actualHeight);
            return new(ClipboardImage.Preview(bytes, maximumDimension, width, height), width, height, size, clip.ImageExtension);
        }
        catch (Exception error) when (IsLocalError(error) || ClipboardImage.DecoderFailure(error))
        {
            return new(null, width, height, size, clip.ImageExtension);
        }
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
                    string image = WritePreviewFile(clip.ImageExtension, ReadImage(clip));
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
        foreach (string reference in files)
        {
            var file = FileReference.FromPath(reference);
            string path = file.Path;
            if (!Path.IsPathFullyQualified(path) || (!File.Exists(path) && !Directory.Exists(path)))
            {
                Notify(Labels.Format("File is missing: {0}", file.Name));
                return false;
            }
            var rule = Settings.FileRules.Where(entry => entry.Extension.Length > 0 && path.EndsWith(
                "." + entry.Extension.Trim('.'), StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(entry => entry.Extension.Length).FirstOrDefault();
            if (rule is null || string.IsNullOrWhiteSpace(rule.Command) &&
                (string.IsNullOrWhiteSpace(rule.ApplicationPath) || !File.Exists(rule.ApplicationPath)))
            {
                Notify(Labels.Format("Choose an open rule for {0}.", file.Name));
                return false;
            }
            actions.Add((path, rule));
        }
        foreach (var (path, rule) in actions)
        {
            if (!string.IsNullOrWhiteSpace(rule.Command))
                _ = RunFileCommandAsync(rule, path);
            else StartApp(rule.ApplicationPath!, path);
        }
        return actions.Count > 0;
    }

    internal FileCommandRunner FileCommands => fileCommands;

    private async Task RunFileCommandAsync(FileOpenRule rule, string path)
    {
        var result = await fileCommands.RunAsync(dataDirectory, rule, path);
        if (Exiting || result is null) return;
        if (result.Error is { } error) Notify(error);
        else if (result.ExitCode is not 0)
            Notify(Labels.Format("File command exited with code {0}. See Command output in Open With.", result.ExitCode));
    }

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

    private async Task EnrichLinkAsync(Clip clip)
    {
        if (clip.Kind == ClipKind.Link && Settings.ResolveLinks &&
            (clip.LinkDetails is null or { Status: "Not attempted" } ||
                DateTimeOffset.UtcNow - clip.LinkDetails.AttemptedAt >= TimeSpan.FromMinutes(clip.LinkDetails.Status == "Resolved" ? 1440 : 5)))
            await ResolveLinkAsync(clip);
    }

    internal async Task ResolveLinkAsync(Clip clip)
    {
        if (clip.Kind != ClipKind.Link || clip.Text is not { } raw || !links.TryStart(clip.Id)) return;
        try
        {
            LinkDetails result;
            if (Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri) && LinkResolver.Allowed(uri))
            {
                var signIn = Settings.LinkSignIns.Where(rule => rule.Enabled).OrderBy(LinkTitles.IsBuiltInSignIn)
                    .FirstOrDefault(rule => LinkResolver.MatchRule(rule.Pattern, uri) is not null);
                result = signIn is null ? await links.ResolveAsync(raw, lifetime.Token) :
                    await LinkSessions.ResolveAsync(dataDirectory, signIn, uri, new WindowInteropHelper(window).EnsureHandle(), lifetime.Token);
            }
            else result = new("Invalid link", null, DateTimeOffset.UtcNow);
            if (!Exiting) UpdateClip(clip.Id, current => current.Text == raw ?
                current with { LinkDetails = LinkTitles.RecordAttempt(current, result, Settings.LinkFallbacks) } : current);
        }
        catch (OperationCanceledException) when (Exiting) { }
        finally { links.Finish(clip.Id); }
    }

    private LinkDetails? LinkFallback(Clip clip) => LinkTitles.UpdateFallback(clip, Settings.LinkFallbacks);

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
