using System.Text.Json;
using Microsoft.Data.Sqlite;
using Pasteory.Core;

string root = Path.Combine(Path.GetTempPath(), "Pasteory-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    var fresh = LocalSettings.Load(root);
    Check(!fresh.CompletedOnboarding, "Show onboarding for a fresh installation");
    var store = new HistoryStore(root, maxClips: 3);
    var first = new Clip { Kind = ClipKind.Text, Text = "Clipboard 测试", Source = "Editor" };
    var link = new Clip { Kind = ClipKind.Link, Text = "https://example.com" };
    Check(store.Capture(first) && store.Capture(link), "Save text and link");
    Check(LocalSettings.Load(root).CompletedOnboarding, "Skip onboarding for an existing catalog without settings");
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

    File.WriteAllText(Path.Combine(root, "settings.json"), "{\"Paused\":true}");
    var legacySettings = LocalSettings.Load(root);
    Check(legacySettings.CompletedOnboarding, "Skip onboarding for existing settings");
    Check(legacySettings.QuickPanelPosition is null, "Place the quick panel by the pointer until a position is saved");
    var panelPosition = new PanelPosition(-620, 80);
    (fresh with { CompletedOnboarding = true, Paused = true, UseAlternateShortcut = true, IgnoredApps = ["Example"],
        QuickPanelPosition = panelPosition }).Save(root);
    var settings = LocalSettings.Load(root);
    Check(settings.QuickPanelPosition == panelPosition, "Restore a quick panel moved to a secondary screen");
    Check(settings.CompletedOnboarding && settings.Paused && settings.UseAlternateShortcut && settings.ShouldIgnore("example") &&
        settings.ShouldIgnore("KEEPASSXC") && settings.ShouldIgnore("") && !settings.ShouldIgnore("Notepad"),
        "Persist settings and honor exclusions");
    CheckSourcePreferences(root);
    CheckLibrary(root);
    CheckAiRegrouping(root);
    CheckSearchRepair(root);
    CheckOcrNotes(root);
    CheckLifecycleCompression(root);
    CheckLinkSessionSchedule(root);
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

static void CheckAiRegrouping(string root)
{
    string folder = Path.Combine(root, "regrouping");
    var store = new HistoryStore(folder);
    var manual = store.SaveCollection(null, "Manual folder", null);
    Guid[] ids = Enumerable.Range(0, 6).Select(number =>
    {
        var clip = new Clip { Text = $"Regrouping sample {number}", Note = "Original note", CollectionIds = [manual.Id] };
        Check(store.Capture(clip), "Capture an original clip for regrouping");
        return clip.Id;
    }).ToArray();
    store.ApplyAiTopics([
        new("Release", "First overview", [ids[0], ids[1], ids[2], ids[3]], Definition: "Release notes"),
        new("Development", "Second overview", [ids[0], ids[2], ids[4]], Definition: "Development notes"),
        new("Reference", "Third overview", [ids[0], ids[4], ids[5]], Definition: "Reference notes")]);
    var (release, development, reference) = (store.Collections[1], store.Collections[2], store.Collections[3]);
    var selected = new HashSet<Guid> { release.Id, development.Id };
    var stale = AiGroupSnapshot.Capture(store.Collections, store.Clips, selected);
    Check(stale.SelectMany(item => item.Members).Distinct().Count() == 5, "Deduplicate overlap across selected AI groups");
    store.UpdateAiGroup(release, "Release checklist", "Manually revised release notes", retained: true);
    release = store.Collections.Single(group => group.Id == release.Id);
    Check(release is { NameIsManual: true, DefinitionIsManual: true, Retained: true, DefinitionVersion: 2 },
        "Track user edits and retention independently of membership locks");
    Reject([], stale, "Reject replacement after a theme edit");

    stale = AiGroupSnapshot.Capture(store.Collections, store.Clips, selected);
    store.RemoveFromAiTopic(development.Id, ids[0]);
    Reject([], stale, "Reject replacement after a membership edit");

    var replacing = AiGroupSnapshot.Capture(store.Collections, store.Clips, selected);
    var next = new AiTopicProposal(release.Name, "Replacement overview", [ids[0], ids[1], ids[2]],
        Definition: "New release notes", CreateOnly: true, OverviewSources: [ids[1]]);
    Reject([next with { Members = [ids[0], ids[1]] }], replacing, "Reject an incomplete replacement without removing existing groups");
    Guid task = Guid.NewGuid();
    var reuse = new AiTopicProposal(reference.Name, "", [ids[1]], reference.Id, ExpectedDefinition: reference.Definition);
    Check(store.ApplyAiTopics([next, reuse], task, replacing) == 3, "Apply new topics and reuse a theme outside the selection atomically");
    var reopened = new HistoryStore(folder);
    Check(reopened.UndoableAiTask == task && reopened.ApplyAiTopics([next, reuse], task, replacing) == 0,
        "A restarted apply can acknowledge the same committed task without replacing again");
    var created = reopened.Collections.Single(group => group.Name == release.Name);
    Check(created.Id != release.Id && created.OverviewClips!.SequenceEqual([ids[1]]) &&
        !reopened.Collections.Any(group => selected.Contains(group.Id)) &&
        reopened.Clips.Single(clip => clip.Id == ids[3]).CollectionIds.SequenceEqual([manual.Id]) &&
        reopened.Clips.Single(clip => clip.Id == ids[4]).CollectionIds.ToHashSet().SetEquals([manual.Id, reference.Id]),
        "Allow a new theme with a replaced name and remove only the selected memberships outside the analysis scope");

    var later = reopened.SaveCollection(null, "Added later", null);
    reopened.Update(ids[0], clip => clip with { Note = "Later note", CollectionIds = [.. clip.CollectionIds, later.Id] });
    reopened.UndoAiTopics();
    var undone = new HistoryStore(folder);
    Check(!undone.CanUndoAi && AiGroupSnapshot.IsCurrent(undone.Collections, undone.Clips, replacing) &&
        undone.Clips.Single(clip => clip.Id == ids[0]) is { Note: "Later note" } kept &&
        kept.CollectionIds.ToHashSet().SetEquals([manual.Id, release.Id, reference.Id, later.Id]) &&
        !undone.Clips.Single(clip => clip.Id == ids[1]).CollectionIds.Contains(reference.Id),
        "Undo after restart restores old themes and preserves later notes and unrelated memberships");

    var cleanup = AiGroupSnapshot.Capture(undone.Collections, undone.Clips, new HashSet<Guid> { development.Id });
    undone.ApplyAiTopics([], replacing: cleanup);
    var cleaned = new HistoryStore(folder);
    Check(cleaned.CanUndoAi && cleaned.Clips.Count == ids.Length && !cleaned.Collections.Any(group => group.Id == development.Id) &&
        cleaned.Clips.All(clip => clip.CollectionIds.Contains(manual.Id) && !clip.CollectionIds.Contains(development.Id)),
        "Clear selected groups without making AI proposals or deleting clips");
    cleaned.UndoAiTopics();
    Check(AiGroupSnapshot.IsCurrent(cleaned.Collections, cleaned.Clips, cleanup), "Restore a cleaned group including its exclusions");

    void Reject(AiTopicProposal[] proposals, AiGroupSnapshot[] scope, string description)
    {
        var groupsBefore = store.Collections;
        var clipsBefore = store.Clips;
        try { store.ApplyAiTopics(proposals, replacing: scope); }
        catch (ArgumentException)
        {
            Check(ReferenceEquals(store.Collections, groupsBefore) && ReferenceEquals(store.Clips, clipsBefore), description);
            return;
        }
        throw new InvalidOperationException(description);
    }
}

static void CheckOcrNotes(string root)
{
    string folder = Path.Combine(root, "ocr-notes");
    var store = new HistoryStore(folder);
    byte[] bytes = [1, 2, 3];
    var image = new Clip { Kind = ClipKind.Image, ImageSize = bytes.Length, ImageHash = "ocr-fixture", OcrPending = true, Note = "Caption [ref]" };
    Check(store.Capture(image, bytes) && new HistoryStore(folder).Clips.Single() is { OcrPending: true, OcrMode: null },
        "Keep queued image recognition from older versions across restarts");
    var oldImage = image with { Id = Guid.NewGuid(), ImageHash = "previously-captured", OcrPending = false };
    Check(store.Capture(oldImage, bytes) && store.Capture(oldImage with
        { Id = Guid.NewGuid(), OcrPending = true, OcrMode = ImageOcrMode.Fast }, bytes) &&
        store.Clips.Single(clip => clip.Id == oldImage.Id) is { OcrPending: false, OcrMode: null, CopyCount: 2 },
        "Recapturing an image from before OCR was enabled keeps the original capture policy");
    store.Delete(oldImage);
    Check(store.Capture(image with { Id = Guid.NewGuid(), OcrPending = true, OcrMode = ImageOcrMode.Fast }, bytes) &&
        store.Clips.Single() is { OcrPending: true, OcrMode: null }, "Recapturing a pending image preserves the mode of the first job");
    var now = DateTimeOffset.UtcNow;
    Check(image.WithImageRecognition(" \n", now, ImageOcrMode.Fast) is
        { OcrPending: false, OcrMode: ImageOcrMode.Fast, OcrInNote: false, RecognizedText: "", Note: "Caption [ref]" },
        "A successful scan of a blank image keeps its caption and clears the job");
    const string original = "Original transcription\nAn unbalanced [ bracket and a ] here]";
    Check(store.Update(image.Id, clip => clip.WithImageRecognition(original, now)), "Save recognition on the existing image");
    var saved = store.Clips.Single();
    Check(saved.RecognizedImageText == original && saved.NoteWithoutImageOcr == "Caption [ref]" && saved.RecognizedAt == now &&
        !saved.OcrPending && saved.PlainClipboardText == "Caption [ref]\n\n" + original, "Keep literal brackets and line breaks in the plain clipboard");
    Check(saved.CapturedAt == image.CapturedAt && saved.CopyCount == 2, "Recognition preserves capture activity");
    Check(saved.WithNoteEdit(image, image.Note) == saved && saved.WithNoteEdit(image, "Caption edited during OCR").PlainClipboardText ==
        "Caption edited during OCR\n\n" + original, "A recognition result arriving during an edit survives saving the draft");
    Check(store.Update(image.Id, clip => clip with { Note = " Caption [ref]\n[OCR:Corrected [example]]\nTail [link] " }), "Edit an OCR note");
    var edited = new HistoryStore(folder).Clips.Single();
    Check(edited.RecognizedImageText == "Corrected [example]" && edited.NoteWithoutImageOcr == "Caption [ref]\n\nTail [link]" &&
        edited.PlainClipboardText == " Caption [ref]\nCorrected [example]\nTail [link] " &&
        store.SearchIds("corrected").SequenceEqual([image.Id]) && store.SearchIds("transcription").Count == 0,
        "Edits drive display, plain text and the search index without exposing stale OCR");
    Check(store.Update(image.Id, clip => clip with { Note = "" }) && store.Capture(image with { Id = Guid.NewGuid() }, bytes) &&
        store.Clips.Single() is { OcrInNote: true, OcrPending: false, PlainClipboardText: null } &&
        store.SearchIds("corrected").Count == 0, "Removing the OCR block survives another copy of the same image");

    var legacy = new Clip { Kind = ClipKind.Image, RecognizedText = "Legacy recognized text" };
    Check(legacy.PlainClipboardText == "Legacy recognized text" &&
        (new Clip { Kind = ClipKind.Files, Note = "[OCR:File [ref]", Files = ["C:\\report.txt"] }).PlainClipboardText == "File [ref]" &&
        (new Clip { Kind = ClipKind.Files, Files = ["C:\\report.txt"] }).PlainClipboardText == "C:\\report.txt" &&
        (new Clip { Kind = ClipKind.Text, Text = "  Original text  ", Note = "Separate note" }).PlainClipboardText == "  Original text  ",
        "Preserve plain copy for legacy images, files and ordinary text");
}

static void CheckLifecycleCompression(string root)
{
    var now = DateTimeOffset.UtcNow;
    string folder = Path.Combine(root, "lifecycle-compression");
    var store = new HistoryStore(folder);
    var old = new Clip
    {
        Text = new string('x', 48_000) + " Original ending", Html = "<p>Original formatting</p>", Rtf = @"{\rtf1 Original}",
        CapturedAt = now.AddDays(-20)
    };
    var favorite = new Clip { Text = "Favorite clip", Favorite = true, CapturedAt = now.AddDays(-30) };
    var recent = new Clip { Text = "Recently used", CapturedAt = now.AddDays(-30), LastPastedAt = now.AddDays(-1) };
    byte[] bytes = new byte[128 * 1024];
    Array.Fill(bytes, (byte)0x73);
    string hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
    var image = new Clip { Kind = ClipKind.Image, ImageSize = bytes.Length, ImageHash = hash, CapturedAt = now.AddDays(-20) };
    Check(store.Capture(old) && store.Capture(favorite) && store.Capture(recent) && store.Capture(image, bytes),
        "Seed aged, protected and recently used clipboard payloads");
    var representation = new ClipboardRepresentation(Guid.NewGuid(), "com.example.data", hash, bytes.Length);
    ClipboardItem[] shared = [new(Guid.NewGuid(), 0, [representation])];
    Check(store.ImportClips([new Clip { Kind = ClipKind.Mixed, CapturedAt = now.AddDays(-20), OriginalItems = shared },
            new Clip { Kind = ClipKind.Files, CapturedAt = now, OriginalItems = shared }], [], _ => [], _ => bytes) == 2,
        "Keep multiple owners of a single original representation");
    string sharedPath = Path.Combine(folder, "representations", hash + ".bin");
    var sharedFlags = File.GetAttributes(sharedPath);

    var first = store.CompressEligibleContent(new ActivityPreferences(), now, batchSize: 1);
    var rest = store.CompressEligibleContent(new ActivityPreferences(), now, batchSize: 1);
    var reopened = new HistoryStore(folder);
    var packed = reopened.Clips.Single(clip => clip.Id == old.Id);
    Check(first.TextClips == 1 && first.HasMore && rest is { TextClips: 0, Attachments: 0, HasMore: false } &&
        packed.CompressedTextAt == now && packed.Text == old.Text && packed.Html == old.Html && packed.Rtf == old.Rtf &&
        reopened.Clips.Count(clip => clip.CompressedTextAt is not null) == 1 && reopened.SearchIds("original ending").Contains(old.Id),
        "Compress only cold unprotected text and retain the original formats and search index across restarts");
    Check(reopened.ReadImage(image).SequenceEqual(bytes) && reopened.ReadRepresentation(representation).SequenceEqual(bytes) &&
        File.GetAttributes(sharedPath) == sharedFlags, "Keep attachment bytes intact and honor the current owner of shared data");
    if (first.Attachments == 1)
    {
        string imagePath = Path.Combine(folder, "images", image.ImageFileName);
        Check(File.GetAttributes(imagePath).HasFlag(FileAttributes.Compressed) && LocalStorage.AllocatedBytes(imagePath) < bytes.Length,
            "Use native lossless compression on the managed file when available");
        Console.WriteLine("Verified native compression and byte-for-byte reads for an aged managed attachment.");
    }

    string backup = Path.Combine(root, "lifecycle-compression.zip");
    reopened.ExportBackup(backup);
    var restored = new HistoryStore(Path.Combine(root, "lifecycle-restored"));
    Check(restored.ImportBackup(backup) == 6 && restored.ReadImage(image).SequenceEqual(bytes) &&
        restored.Clips.Single(clip => clip.Id == old.Id).Html == old.Html, "Back up and restore losslessly compressed history");
    reopened.RecordPaste(old.Id);
    Check(!Directory.EnumerateFiles(Path.Combine(folder, "archives"), "*.br").Any() &&
        reopened.Clips.Single(clip => clip.Id == old.Id).Text == old.Text, "Reusing compressed text restores its active representation");
}

static void CheckLinkSessionSchedule(string root)
{
    var signedIn = DateTimeOffset.UtcNow;
    var schedule = new LinkSessionRefresh().Reset(signedIn);
    Check(schedule.NextRefreshAt() == signedIn.AddDays(14) && new LinkSessionRefresh().NextRefreshAt() is null,
        "Refresh only established sessions, every fourteen days by default");
    foreach (int days in LinkSessionRefresh.Intervals)
        Check((schedule with { IntervalDays = days }).NextRefreshAt() == signedIn.AddDays(days), "Use each available per-site interval");
    var attempted = signedIn.AddDays(15);
    var failure = schedule with { LastAttemptAt = attempted, Outcome = LinkSessionOutcome.Failed };
    Check(failure.NextRefreshAt() == attempted.AddHours(1) &&
        (failure with { Outcome = LinkSessionOutcome.PageLoaded, LastRefreshedAt = attempted }).NextRefreshAt() == attempted.AddDays(14),
        "Retry a failed page in one hour and restart the interval after a successful load");
    Check((failure with { Outcome = LinkSessionOutcome.NeedsSignIn }).NextRefreshAt() is null &&
        (failure with { Outcome = LinkSessionOutcome.Blocked }).NextRefreshAt() is null &&
        (schedule with { Automatic = false }).NextRefreshAt() is null, "Pause automation for expired, blocked or manually disabled sessions");
    var rule = new LinkSignInRule(Guid.NewGuid(), "Test", "example", "https://example.com/", true) { Refresh = failure };
    string folder = Path.Combine(root, "web-session-schedule");
    new LocalSettings { LinkSignIns = [rule] }.Save(folder);
    Check(LocalSettings.Load(folder).LinkSignIns.Single() == rule && failure.Reset(attempted).NextRefreshAt() == attempted.AddDays(14),
        "Persist site refresh state and reset failed attempts after reauthentication");
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

static void CheckSourcePreferences(string root)
{
    var defaults = new LocalSettings();
    Check(!defaults.AllowsSourceContext("chrome") && !defaults.AllowsSourceContext("Weixin") && !defaults.AllowsSourceContext("Feishu"),
        "Source details remain opt-in");
    var legacy = JsonSerializer.Deserialize<LocalSettings>("""{"IncludeBrowserContext":true,"IncludeChatContext":true}""")!;
    Check(legacy.AllowsSourceContext("Chrome") && legacy.AllowsSourceContext("Weixin") && legacy.AllowsSourceContext("LARK"),
        "The legacy chat switch continues to enable both conversation sources");
    Check(legacy.CaptureInterval() == 0 && (legacy with { CaptureIntervalMilliseconds = -12 }).CaptureInterval() == 0,
        "Old settings and unsupported intervals keep event-driven immediate capture");
    string folder = Path.Combine(root, "individual sources");
    var identity = new IgnoredAppIdentity("Feishu test app", @"C:\Test\Feishu.exe");
    (legacy with
    {
        IncludeWeChatContext = false, IgnoredApps = ["feishu"], CaptureIntervalMilliseconds = 500,
        IgnoredAppIdentities = new() { ["FEISHU"] = identity }
    }).Save(folder);
    var current = LocalSettings.Load(folder);
    Check(current.CaptureInterval() == 500 && current.IgnoredAppIdentities["FEISHU"] == identity,
        "Persist the detection interval and selected app name and path");
    Check(!current.AllowsSourceContext("WeChat") && !current.AllowsSourceContext("Weixin") && current.AllowsSourceContext("Lark") &&
        !current.AllowsSourceContext("Feishu") && current.AllowsSourceContext("CHROME"),
        "Persist independent source choices and apply process exclusions even while a source is enabled");
    Check(!(current with { Paused = true }).AllowsSourceContext("chrome") &&
        !(current with { IncludeFeishuContext = false }).AllowsSourceContext("Lark") && !current.AllowsSourceContext("Notepad"),
        "Honor pause and explicit overrides without enabling unrelated apps");
}

static void CheckSearchRepair(string root)
{
    string folder = Path.Combine(root, "search repair");
    var store = new HistoryStore(folder);
    store.RebuildSearchIndex();
    var clip = new Clip { Text = "搜索诊断 sample", Note = "Keep this note", Pinned = true };
    Check(store.Capture(clip) && store.SearchIds("诊断 sample").SequenceEqual([clip.Id]), "Index content before testing repair");
    using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
    {
        DataSource = Path.Combine(folder, HistoryStore.CatalogFileName), Pooling = false
    }.ToString()))
    {
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO clip_fts(clip_fts) VALUES('delete-all');";
        command.ExecuteNonQuery();
    }
    Check(store.SearchIds("sample").Count == 0 && store.SearchIds("诊断").SequenceEqual([clip.Id]),
        "A missing full-text index does not erase the stored content");
    store.RebuildSearchIndex();
    store.RebuildSearchIndex();
    var reopened = new HistoryStore(folder);
    Check(reopened.SearchIds("诊断 sample").SequenceEqual([clip.Id]) &&
        reopened.Clips.Single() is { Pinned: true, Note: "Keep this note" }, "Rebuild full-text search from the durable catalog without changing clip metadata");
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
    var aggregation = store.SaveAggregation(null, "Release", "", [text.Id, docs.Id, text.Id], "release", fromSearch: true);
    try
    {
        store.SaveAggregation(aggregation.Id, "  ", "", [text.Id, docs.Id], "release", fromSearch: true);
        throw new InvalidOperationException("An empty title must not replace the original aggregation.");
    }
    catch (ArgumentException) { }
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
    Check(copy.Clips.Single(clip => clip.Id == aggregation.Id) is
        { Title: "Release", AggregationFromSearch: true, AggregationOrigin: "release", AggregationUpdatedAt: not null },
        "Preserve search origin and modification time and reject an empty title without changing an existing aggregation");
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
    var members = new[] { text.Id, docs.Id, image.Id };
    Check(withUndo.ApplyAiTopics([
        new("First theme", "First overview", members, Definition: "Definition one", OverviewSources: [text.Id]),
        new("Second theme", "Second overview", members, Definition: "Definition two", OverviewSources: [docs.Id])]) == 3,
        "Apply overlapping memberships and overview evidence transactionally");
    var overlap = new HistoryStore(folder);
    Check(overlap.Clips.Single(clip => clip.Id == text.Id).CollectionIds.Count(group =>
        overlap.Collections.Any(item => item.Id == group && item.IsAi)) == 2, "Restore overlapping memberships from the catalog");
    var firstTheme = overlap.Collections.Single(group => group.Name == "First theme");
    overlap.ApplyAiTopics([new("First theme", "Updated overview", [text.Id], firstTheme.Id, OverviewSources: [text.Id])]);
    Check(overlap.Collections.Single(group => group.Id == firstTheme.Id).Overview == "Updated overview", "Update a theme overview by stable ID");
    new HistoryStore(folder).UndoAiTopics();
    var editedThemeStore = new HistoryStore(folder);
    Check(editedThemeStore.Collections.Single(group => group.Id == firstTheme.Id).Overview == "First overview",
        "Undo an overview update after reopening the catalog");
    editedThemeStore.SetAiGroupDefinition(firstTheme.Id, "Updated manual definition");
    editedThemeStore.ApplyAiTopics([new("First theme", "Stale proposed overview", [docs.Id], firstTheme.Id,
        OverviewSources: [docs.Id], ExpectedDefinition: firstTheme.Definition)]);
    var editedTheme = new HistoryStore(folder).Collections.Single(group => group.Id == firstTheme.Id);
    Check(editedTheme.Definition == "Updated manual definition" && editedTheme.Overview == "First overview",
        "Preserve a manually edited definition from an outdated AI proposal");
    var now = DateTimeOffset.UtcNow;
    var idle = new Clip { CreatedAt = now.AddHours(-48), CapturedAt = now.AddHours(-48) };
    var values = new ActivityPreferences();
    Check(Math.Abs(ClipActivity.Percentage(idle, values, now) - 50) < .01, "Activity halves after 48 hours");
    var reused = ClipActivity.Record(idle, ActivityKind.Paste, now.AddHours(-24));
    Check(ClipActivity.Percentage(reused, values, now) > 75, "Real pasted use resets age and applies the decaying boost");
}
