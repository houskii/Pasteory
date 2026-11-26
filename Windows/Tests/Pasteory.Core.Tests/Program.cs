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
    Check(reopened.SearchIds("测试 ＭＥＥＴＩＮＧ Work project").SequenceEqual([first.Id]) &&
        reopened.SearchIds("测试 absence").Count == 0, "Index short Chinese and folded text across fields");

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
    Directory.CreateDirectory(Path.Combine(failure, HistoryStore.CatalogFileName));
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
    CheckLibrary(root);
    await CheckCleanup(root);
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

static async Task CheckCleanup(string root)
{
    string folder = Path.Combine(root, "cleanup");
    var store = new HistoryStore(folder);
    var today = DateTimeOffset.UtcNow;
    var old = today.AddDays(-45);
    var shared = new string('a', 4096) + " shared archive";
    var expired = new Clip { Text = shared, CapturedAt = old, ArchivedAt = old };
    var retained = new Clip { Kind = ClipKind.Code, Text = shared, CapturedAt = old, ArchivedAt = old, Favorite = true };
    var attachment = new Clip { Kind = ClipKind.Image, ImageHash = "synthetic", ImageSize = 32_768, CapturedAt = old };
    var protectedGroup = store.SaveCollection(null, "Protected", null);
    var grouped = new Clip { Text = "grouped", CapturedAt = old, CollectionIds = [protectedGroup.Id] };
    var member = new Clip { Text = "aggregate member", CapturedAt = old };
    var pinned = new Clip { Text = "pinned", CapturedAt = old, Pinned = true };
    var recentlyUsed = new Clip { Text = "recent paste", CapturedAt = old, LastPastedAt = today };
    string original = Path.Combine(root, "referenced external file.txt");
    File.WriteAllText(original, "external file kept by cleanup");
    var reference = new Clip { Kind = ClipKind.Files, Files = [original], CapturedAt = old };
    foreach (var clip in new[] { expired, retained, grouped, member, pinned, recentlyUsed, reference })
        Check(store.Capture(clip), "Seed cleanup fixture");
    Check(store.Capture(attachment, new byte[attachment.ImageSize]), "Seed a managed attachment");
    store.SaveAggregation(null, "Protected aggregation", "", [member.Id, pinned.Id], null);

    var cutoff = today.AddDays(-30);
    var selection = await store.PreviewCleanupAsync(cutoff, 0);
    var selectedIds = new HashSet<Guid> { expired.Id, attachment.Id, reference.Id };
    Check(selection.Entries.Select(entry => entry.Id).ToHashSet().SetEquals(selectedIds), "Preview excludes recent use and protected history");
    Check(store.SearchIds("referenced external file").SequenceEqual([reference.Id]), "Index the external file reference");
    Check((await store.PreviewCleanupAsync(cutoff, 32_768)).Entries.Count == 0, "Match both conditions and respect an exact size boundary");
    string image = Directory.GetFiles(Path.Combine(folder, "images")).Single();
    Check(selection.ReclaimableBytes == LocalStorage.AllocatedBytes(image) && selection.ReclaimableBytes > 0,
        "Estimate allocated space for only the unshared attachment");
    Check(store.Update(attachment.Id, clip => clip with { Favorite = true }), "Change protection after preview");
    try
    {
        store.CleanHistory(selection);
        throw new InvalidOperationException("Expected a stale cleanup preview to fail");
    }
    catch (IOException) { }
    Check(store.Clips.Any(clip => clip.Id == attachment.Id) && File.Exists(image), "Stale cleanup leaves the catalog and files intact");

    Check(store.Update(attachment.Id, clip => clip with { Favorite = false }), "Restore the fixture selection");
    var current = await store.PreviewCleanupAsync(cutoff, 0);
    var result = store.CleanHistory(current);
    var reopened = new HistoryStore(folder);
    Check(result is { DeletedCount: 3, FailedFiles: 0 } && result.ReclaimedBytes == current.ReclaimableBytes &&
        !File.Exists(image) && File.Exists(original) && reopened.Clips.Single(clip => clip.Id == retained.Id).Text == shared &&
        reopened.SearchIds("referenced external file").Count == 0 && reopened.Clips.All(clip => !selectedIds.Contains(clip.Id)),
        "Delete only previewed records, keeping shared archives and original external files");
}

static void CheckLibrary(string root)
{
    string folder = Path.Combine(root, "legacy library");
    Directory.CreateDirectory(folder);
    var text = new Clip { Text = " release notes ", Group = "Design", Source = "Editor", CopyCount = 2 };
    File.WriteAllText(Path.Combine(folder, "history.json"), JsonSerializer.Serialize(new[] { text }));
    var store = new HistoryStore(folder, maxClips: 3, archiveOverflow: true);
    var group = store.Collections.Single();
    Check(group.Name == "Design" && store.Clips[0].CollectionIds.SequenceEqual([group.Id]), "Migrate legacy groups");
    string copied = File.ReadAllText(Path.Combine(folder, "history.json"));
    Check(copied.Contains(text.Id.ToString()) && File.Exists(Path.Combine(folder, HistoryStore.CatalogFileName)) &&
        store.SearchIds("design notes").SequenceEqual([text.Id]), "Migrate and index the original clip and group");
    store.SaveCollection(group.Id, "DesignRetitled", null);
    Check(store.SearchIds("DesignRetitled notes").SequenceEqual([text.Id]) &&
        store.SearchIds("\"unknown\"").Count == 0, "Reindex group names and quote punctuation");
    var docs = new Clip { Kind = ClipKind.Link, Text = "https://EXAMPLE.com/project/?view=all", Source = "Chrome" };
    Check(store.Capture(docs) && store.Capture(docs with { Id = Guid.NewGuid(), Text = "https://example.com/project#latest" }),
        "Capture repeated link with different query and tracking");
    Check(store.Clips.Count == 2 && store.Clips[0].Id == docs.Id && store.Clips[0].CopyCount == 2 &&
        store.Clips[0].Captures.Length == 2, "Use logical link identity and keep copy events");
    store.RecordPaste(docs.Id);
    var saved = store.Clips[0];
    Check(saved.PasteCount == 1 && saved.CopyCount == 2 && saved.CapturedAt == docs.CapturedAt, "Pasting preserves capture order");

    var rule = new SmartRules(true, [new(RuleField.Source, RuleComparison.Contains, "chrome")],
        [new SmartRules(false, [new(RuleField.Kind, RuleComparison.Equals, "Link"),
            new(RuleField.Text, RuleComparison.Contains, "release")], [])]);
    var smart = store.SaveCollection(null, "Work links", rule);
    store.MoveCollection(smart.Id, group.Id);
    Check(rule.Matches(saved, DateTimeOffset.Now) && !rule.Matches(text, DateTimeOffset.Now), "Nested smart rules");
    var aggregation = store.SaveAggregation(null, "Release", "", [text.Id, docs.Id, text.Id], "Manual");
    Check(aggregation.Members.Length == 2, "Aggregate unique members");

    var image = new Clip { Kind = ClipKind.Mixed, Text = "caption", ImageSize = 3, ImageHash = "fixture" };
    Check(store.Capture(image, [1, 2, 3]), "Capture mixed image payload");
    var extra = new Clip { Kind = ClipKind.Code, Text = "using System;", CodeLanguage = "cs" };
    Check(store.Capture(extra) && store.Clips.Count(clip => clip.ArchivedAt is not null) == 1, "Capacity archives instead of deleting");
    store.Trash(image.Id);
    Check(store.ReadImage(image).Length == 3 && store.Clips.First(clip => clip.Id == image.Id).TrashedAt is not null, "Trash preserves image");
    store.Restore(image.Id);
    Check(store.Clips.First(clip => clip.Id == image.Id).TrashedAt is null, "Restore from Trash");

    var copy = new HistoryStore(folder);
    Check(copy.Collections[0].Id == smart.Id && copy.Clips.Single(clip => clip.Id == aggregation.Id).Members.Contains(text.Id),
        "Persist collections, ordering and aggregations");
    Check(copy.Clips.Single(clip => clip.Id == text.Id).Text == text.Text &&
        Directory.EnumerateFiles(Path.Combine(folder, "archives"), "*.br").Any(), "Read archived original text losslessly");
    string backup = Path.Combine(root, "library.zip");
    copy.ExportBackup(backup);
    var restored = new HistoryStore(Path.Combine(root, "restored"));
    Check(restored.ImportBackup(backup) == copy.Clips.Count && restored.ImportBackup(backup) == 0 &&
        restored.ReadImage(image).SequenceEqual(new byte[] { 1, 2, 3 }), "Backup restores clips, groups and image bytes idempotently");
    Check(TextTools.ConvertText(TextTool.Base64Decode, "5L2g5aW9") == "你好" &&
        TextTools.ConvertText(TextTool.UrlDecode, "a+b%20c") == "a+b c" &&
        TextTools.ConvertText(TextTool.RgbaToHex, "rgba(124, 58, 237, 0.5)") == "#7C3AED80" &&
        TextTools.ConvertText(TextTool.Md5, "hello") == "5d41402abc4b2a76b9719d911017c592",
        "Text conversions preserve UTF-8, literal plus and alpha roundoff");
    int organized = copy.ApplyAiTopics([new("Project topics", "Test topic", [text.Id, docs.Id, image.Id])]);
    Check(organized == 3 && copy.Collections.Single(group => group.IsAi).Name == "Project topics", "Apply reviewed topic atomically");
    var withUndo = new HistoryStore(folder);
    withUndo.Update(text.Id, item => item with { Note = "Keep this later note" });
    withUndo.UndoAiTopics();
    Check(!withUndo.Collections.Any(group => group.IsAi) && withUndo.Clips.Single(clip => clip.Id == text.Id).Note == "Keep this later note",
        "Undo reviewed organization after restart preserves unrelated edits");
    var now = DateTimeOffset.UtcNow;
    var idle = new Clip { CreatedAt = now.AddHours(-48), CapturedAt = now.AddHours(-48) };
    var values = new ActivityPreferences();
    Check(Math.Abs(ClipActivity.Percentage(idle, values, now) - 50) < .01, "Activity halves after 48 hours");
    var reused = ClipActivity.Record(idle, ActivityKind.Paste, now.AddHours(-24));
    Check(ClipActivity.Percentage(reused, values, now) > 75, "Real pasted use resets age and applies the decaying boost");
}
