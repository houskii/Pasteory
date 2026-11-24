using System.Text.Json;
using Pasteory.Core;

string root = Path.Combine(Path.GetTempPath(), "Pasteory-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    var store = new HistoryStore(root, maxClips: 3);
    var first = new Clip { Kind = ClipKind.Text, Text = "Clipboard 测试", Source = "Editor" };
    var link = new Clip { Kind = ClipKind.Link, Text = "https://example.com" };
    Check(store.Capture(first) && store.Capture(link), "Save text and link");
    Check(store.Edit(first, "Project", "Meeting memo", "Work", pinned: true, favorite: true), "Save metadata");

    var reopened = new HistoryStore(root, maxClips: 3);
    Check(reopened.Capture(first with { Id = Guid.NewGuid(), Source = "NewEditor" }), "Recapture text");
    Check(reopened.Clips.Count == 2 && reopened.Clips[0].Id == first.Id && reopened.Clips[0].Pinned &&
        reopened.Clips[0].Favorite && reopened.Clips[0].Matches("项目") == false &&
        reopened.Clips[0].Matches("测试 meeting work neweditor project"), "Retain metadata and search all fields");

    byte[] png = [1, 2, 3];
    var image = new Clip { Kind = ClipKind.Image, ImageHash = "test-image", ImageSize = png.Length };
    Check(reopened.Capture(image, png) && reopened.ReadImage(image).SequenceEqual(png), "Save image separately");
    var paths = new Clip { Kind = ClipKind.Files, Files = ["C:\\Docs\\report.txt"] };
    Check(reopened.Capture(paths), "Capture file paths");
    Check(!reopened.Clips.Any(clip => clip.Id == link.Id) && paths.Matches("report.txt"), "Prune oldest unprotected clip");
    reopened.ClearUnprotected();
    Check(reopened.Clips.Single().Id == first.Id, "Clear keeps pinned and favorite clips");
    Check(!Directory.EnumerateFiles(Path.Combine(root, "images"), "*.png").Any(), "Pruning removes image payloads");

    var atLimit = new HistoryStore(root, maxClips: 1);
    Check(!atLimit.Capture(link) && atLimit.Clips.Single().Id == first.Id, "Honor retention limits with protected clips");
    atLimit.Delete(first);
    Check(new HistoryStore(root).Clips.Count == 0, "Persist deletion");

    string failure = Path.Combine(root, "write-failure");
    var failingStore = new HistoryStore(failure);
    Directory.CreateDirectory(Path.Combine(failure, "history.json"));
    try
    {
        failingStore.Capture(image, png);
        throw new InvalidOperationException("Expected write failure");
    }
    catch (IOException) { }
    catch (UnauthorizedAccessException) { }
    Check(failingStore.Clips.Count == 0 &&
        !Directory.EnumerateFiles(Path.Combine(failure, "images"), "*.png").Any(), "Roll back incomplete writes");

    string corrupt = Path.Combine(root, "corrupt");
    Directory.CreateDirectory(corrupt);
    var corruptPath = Path.Combine(corrupt, "history.json");
    File.WriteAllText(corruptPath, "{");
    try
    {
        _ = new HistoryStore(corrupt);
        throw new InvalidOperationException("Expected corrupt data error");
    }
    catch (JsonException) { }
    Check(File.ReadAllText(corruptPath) == "{", "Preserve unreadable history");

    new LocalSettings { Paused = true, UseAlternateShortcut = true, IgnoredApps = ["Example"] }.Save(root);
    var settings = LocalSettings.Load(root);
    Check(settings.Paused && settings.UseAlternateShortcut && settings.ShouldIgnore("example") &&
        settings.ShouldIgnore("KEEPASSXC") && settings.ShouldIgnore("") && !settings.ShouldIgnore("Notepad"),
        "Persist settings and honor exclusions");
    Console.WriteLine("Windows history and settings checks passed.");
}
finally
{
    Directory.Delete(root, recursive: true);
}

static void Check(bool condition, string description)
{
    if (!condition) throw new InvalidOperationException(description);
}
