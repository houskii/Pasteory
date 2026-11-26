using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;
using Pasteory.Core;
using Pasteory.Windows;

internal static partial class Program
{
    private static void CheckImagePlainText(Clip mixed, byte[] image)
    {
        var withOcr = (mixed with { Note = " Image note [tag] " }).WithImageRecognition("Sample [PDF]", DateTimeOffset.UtcNow);
        var plainCopy = ClipboardFormats.Create(withOcr, true, null);
        Check(plainCopy.GetText() == " Image note [tag] \n\nSample [PDF]" && !plainCopy.ContainsImage(),
            "Plain copy of mixed image content contains the editable note and recognition only");
        var richCopy = ClipboardFormats.Create(withOcr, false, image);
        Check(richCopy.GetText() == mixed.Text && richCopy.ContainsImage(), "Ordinary mixed copy retains the captured image and text");
        var corrected = withOcr with { Note = "Caption\n\n[OCR:User correction]" };
        var withoutSharing = AiTasks.Project(corrected, new AiPreferences { ShareNotes = true })!;
        var withSharing = AiTasks.Project(corrected, new AiPreferences { ShareNotes = true, ShareOcr = true })!;
        Check(withoutSharing.Note == "Caption" && withoutSharing.Text == mixed.Text &&
            withSharing.Text.Contains("User correction", StringComparison.Ordinal) &&
            !withSharing.Text.Contains("Sample [PDF]", StringComparison.Ordinal), "OCR sharing uses current edits and remains separate from sharing notes");
    }

    private const string MarkdownSample = """
        # 剪贴板试读

        保留 **重点**、*斜体* 和 `原文`。

        - [x] 整理灵感
        - [ ] 复核资料

        > 从资料库展开，或切换到原文。

        | 类型 | 状态 |
        | --- | --- |
        | 文字 | 已保存 |

        [参考网页](https://example.com/) [本地路径](file:///C:/Windows/)

        ![示例图片](https://example.com/image.png)
        """;

    private static void CheckMarkdownPreview()
    {
        var id = Guid.NewGuid();
        var first = MarkdownPreview.ParseAsync(id, MarkdownSample);
        Check(ReferenceEquals(first, MarkdownPreview.ParseAsync(id, MarkdownSample)), "Reuse a parsed preview for the same content");
        var parsed = first.GetAwaiter().GetResult();
        Check(MarkdownPreview.LooksFormatted(parsed) && !MarkdownPreview.LooksFormatted(
            MarkdownPreview.ParseAsync(id, "普通文本").GetAwaiter().GetResult()), "Choose source or Markdown based on the parsed content");
        var document = MarkdownPreview.Render(parsed, _ => throw new InvalidOperationException("Rendering opened a link"));
        string displayed = new TextRange(document.ContentStart, document.ContentEnd).Text;
        Check(document.Blocks.OfType<Table>().Single().RowGroups[0].Rows.Count == 2 &&
            document.Blocks.OfType<System.Windows.Documents.List>().Single() is { ListItems.Count: 2, MarkerStyle: TextMarkerStyle.None } &&
            document.Blocks.OfType<Section>().Any() && displayed.Contains("☑") && displayed.Contains("示例图片"),
            "Render tables, quotations, tasks, and image placeholders in the native preview");
        var links = document.Blocks.OfType<Paragraph>().SelectMany(paragraph => paragraph.Inlines.OfType<Hyperlink>()).ToArray();
        Check(links.Length == 1 && links[0].NavigateUri.Scheme == "https" && displayed.Contains("本地路径"),
            "Present safe web links and represent other targets as text");
    }

    private static (DataObject Replay, byte[] Bytes, string[] Files) CheckOriginalImages()
    {
        byte[] jpeg = SampleImage(new JpegBitmapEncoder { QualityLevel = 93 });
        string temporary = Path.Combine(Path.GetTempPath(), "pasteory-qa-image.jpeg");
        string[] paths = [temporary, Path.Combine(Path.GetTempPath(), "pasteory-qa-companion.txt")];
        var source = new DataObject();
        source.SetText("Mixed image with file references");
        source.SetData("JFIF", new MemoryStream(jpeg, writable: false), false);
        var references = new StringCollection();
        references.AddRange(paths);
        source.SetFileDropList(references);
        var captured = ClipboardFormats.Read(source, "Weixin")!.Value;
        Check(captured.Clip is { Kind: ClipKind.Mixed, ImageFormat: ClipImageFormat.Jpeg, ImageWidth: 13, ImageHeight: 7 } &&
            captured.Clip.Files.SequenceEqual(paths) && captured.Image!.SequenceEqual(jpeg),
            "Keep a JPEG and its dimensions when files and text are also present");
        var explorer = ClipboardFormats.Read(source, "explorer")!.Value;
        Check(explorer.Clip.Kind == ClipKind.Files && explorer.Clip.Files.SequenceEqual(paths) && explorer.Image is null,
            "Do not treat an Explorer file icon as a clipboard image");
        var replay = ClipboardFormats.Create(captured.Clip, false, captured.Image);
        Check(ReadClipboardBytes(replay, "JFIF").SequenceEqual(jpeg) && replay.GetFileDropList().Cast<string>().SequenceEqual(paths) &&
            replay.GetImage().PixelWidth == 13 && replay.GetText() == captured.Clip.Text, "Restore the full Windows clipboard selection");

        using var image = new MemoryStream(SampleImage(new TiffBitmapEncoder()), writable: false);
        var tiff = new DataObject(DataFormats.Tiff, image);
        var alternate = ClipboardFormats.Read(tiff, "Editor")!.Value;
        Check(alternate.Clip.ImageFormat == ClipImageFormat.Tiff && alternate.Clip.ImageHeight == 7 &&
            ReadClipboardBytes(ClipboardFormats.Create(alternate.Clip, false, alternate.Image), DataFormats.Tiff).SequenceEqual(image.ToArray()),
            "Restore a TIFF without converting or changing its bytes");

        string root = Directory.CreateTempSubdirectory("Pasteory-original-images-").FullName;
        try
        {
            var library = new HistoryStore(Path.Combine(root, "capture"));
            string backup = Path.Combine(root, "backup.zip");
            Check(library.Capture(captured.Clip, captured.Image), "Keep the original file in managed storage");
            library.ExportBackup(backup);
            var restored = new HistoryStore(Path.Combine(root, "restored"));
            Check(restored.ImportBackup(backup) == 1 && restored.Clips[0].ImageFormat == ClipImageFormat.Jpeg &&
                restored.ReadImage(restored.Clips[0]).SequenceEqual(jpeg), "Round-trip the versioned backup with original encoded bytes");
        }
        finally { Directory.Delete(root, recursive: true); }
        return (replay, jpeg, paths);
    }

    private static byte[] ReadClipboardBytes(IDataObject clipboard, string format) => clipboard.GetData(format, false) switch
    {
        MemoryStream stream => stream.ToArray(), byte[] bytes => bytes, _ => []
    };

    private static byte[] SampleImage(BitmapEncoder encoder, int width = 13, int height = 7)
    {
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr24, null,
            Enumerable.Repeat((byte)140, width * height * 3).ToArray(), width * 3);
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    private static void CheckMacBackup()
    {
        string root = Directory.CreateTempSubdirectory("Pasteory-MacBackup-QA-").FullName;
        try
        {
            string backup = Directory.CreateDirectory(Path.Combine(root, "backup")).FullName;
            Guid id = Guid.NewGuid(), group = Guid.NewGuid();
            const string text = "归档中的 Mac 剪贴板原文";
            byte[] raw = Encoding.UTF8.GetBytes(text);
            byte[] compressed = new byte[12 + raw.Length];
            "bvx-"u8.CopyTo(compressed);
            BinaryPrimitives.WriteInt32LittleEndian(compressed.AsSpan(4), raw.Length);
            raw.CopyTo(compressed, 8);
            "bvx$"u8.CopyTo(compressed.AsSpan(8 + raw.Length));
            var manifest = new Dictionary<string, string>();
            void Add(string path, byte[] content)
            {
                string file = Path.Combine(backup, path);
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                File.WriteAllBytes(file, content);
                manifest[path] = Convert.ToHexString(SHA256.HashData(content)).ToLowerInvariant();
            }
            Add("data/Archives/clip.lzfse", compressed);
            var alternate = Encoding.UTF8.GetBytes("Second Mac clipboard item");
            var opaque = new byte[] { 0, 128, 255, 7 };
            Guid firstItem = Guid.NewGuid(), secondItem = Guid.NewGuid();
            var clip = new
            {
                id, createdAt = DateTimeOffset.UtcNow, updatedAt = DateTimeOffset.UtcNow, lastCopiedAt = DateTimeOffset.UtcNow,
                primaryKind = "text", isArchived = true, source = new { appName = "Notes", confidence = "high" },
                collectionIDs = new[] { group }, copyCount = 3, title = "Archived", note = "Kept", aiAnalysisExcluded = true,
                items = new[]
                {
                    new { id = firstItem, order = 0, representations = new object[]
                    {
                        new { uti = "public.utf8-plain-text", storage = new
                        {
                            type = "archived", relativePath = "clip.lzfse", checksum = Convert.ToHexString(SHA256.HashData(raw)), size = raw.Length
                        } }
                    } },
                    new { id = secondItem, order = 1, representations = new object[]
                    {
                        new { uti = "public.utf8-plain-text", storage = new { type = "inline", data = alternate } },
                        new { uti = "example.fixture.bin", storage = new { type = "inline", data = opaque } }
                    } }
                }
            };
            byte[] jpeg = SampleImage(new JpegBitmapEncoder());
            Guid pictureId = Guid.NewGuid(), referenceId = Guid.NewGuid(), pendingId = Guid.NewGuid(), staleId = Guid.NewGuid();
            var recognizedAt = DateTimeOffset.FromUnixTimeSeconds(DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            string pictureHash = Convert.ToHexString(SHA256.HashData(jpeg));
            object ImageClip(Guid clipId, string kind, bool pending = false, bool stale = false) => new
            {
                id = clipId, createdAt = DateTimeOffset.UtcNow, primaryKind = kind,
                source = new { appName = "Finder" },
                contentHash = pictureHash,
                note = kind == "image" ? "Image caption\n\n[OCR:Corrected Mac OCR]" : "",
                localOCR = kind == "image" ? new
                {
                    version = 1, contentHash = stale ? "previous-content" : pictureHash, text = "Raw Mac OCR", recognizedAt,
                    method = "visionFast", appendedNote = "[OCR:Raw Mac OCR]"
                } : null,
                localOCRRequest = pending || stale ? new { contentHash = stale ? "previous-content" : pictureHash, method = "visionFast" } : null,
                items = new[]
                {
                    new
                    {
                        order = 0, representations = new[]
                        {
                            new { uti = "public.jpeg", storage = new { type = "inline", data = jpeg } },
                            new { uti = "public.file-url", storage = new
                                { type = "inline", data = Encoding.UTF8.GetBytes(stale ? "file:///Users/qa/previous.jpeg" : "file:///Users/qa/picture.jpeg") } }
                        }
                    }
                }
            };
            object[] entries = [clip, ImageClip(pictureId, "image"), ImageClip(referenceId, "file"),
                ImageClip(pendingId, "mixed", pending: true), ImageClip(staleId, "image", stale: true)];
            Add("clips.jsonl", Encoding.UTF8.GetBytes(string.Join("\n", entries.Select(item => JsonSerializer.Serialize(item)))));
            Add("collections.json", JsonSerializer.SerializeToUtf8Bytes(new[]
            {
                new { id = group, name = "Mac group", kind = "normal", sortOrder = 0 }
            }));
            File.WriteAllBytes(Path.Combine(backup, "manifest.json"),
                JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 5, fileChecksums = manifest }));
            var store = new HistoryStore(Path.Combine(root, "history"));
            Check(new MacBackupReader(backup).Import(store).Count == entries.Length, "Import Mac v5 archived and inline items");
            var archived = store.Clips.Single(item => item.Id == id);
            Check(archived.Text == text + Environment.NewLine + Encoding.UTF8.GetString(alternate) &&
                archived.ArchivedAt is not null && archived.CollectionIds.SequenceEqual([group]) && archived.ExcludeFromAi &&
                archived.CopyCount == 3, "Import all Mac text items and retain the AI sharing opt-out");
            var originalItems = archived.OriginalItems!;
            Check(originalItems.Select(item => item.Id).SequenceEqual([firstItem, secondItem]) &&
                store.ReadRepresentation(originalItems[1].Representations[1]).SequenceEqual(opaque) &&
                MacClipboardFormats.Project(originalItems[1], store.ReadRepresentation, true).Text == Encoding.UTF8.GetString(alternate),
                "Preserve original item order, supported copy formats and opaque bytes");
            var picture = store.Clips.Single(item => item.Id == pictureId);
            var reference = store.Clips.Single(item => item.Id == referenceId);
            Check(picture is { ImageFormat: ClipImageFormat.Jpeg, ImageWidth: 13, ImageHeight: 7 } &&
                store.ReadImage(picture).SequenceEqual(jpeg) && reference.Kind == ClipKind.Files &&
                !reference.HasImage && reference.Files.Length == 1, "Keep Mac image bytes and leave file references as files");
            Check(picture.OcrInNote && picture.OcrMode == ImageOcrMode.Fast && picture.RecognizedAt == recognizedAt && picture.RecognizedImageText == "Corrected Mac OCR" &&
                picture.PlainClipboardText == "Image caption\n\nCorrected Mac OCR", "Import the Mac editable OCR block and recognition timestamp");
            Check(store.Clips.Single(item => item.Id == pendingId) is { OcrPending: true, OcrMode: ImageOcrMode.Fast } &&
                store.Clips.Single(item => item.Id == staleId) is { OcrPending: false, RecognizedImageText: null, Note.Length: > 0 },
                "Keep the mode of pending Mac OCR and reject stale requests and results while preserving notes");
            string zip = Path.Combine(root, "windows.zip");
            store.ExportBackup(zip);
            var restored = new HistoryStore(Path.Combine(root, "restored"));
            Check(restored.ImportBackup(zip) == entries.Length && restored.ImportBackup(zip) == 0, "Windows restores multi-item backups idempotently");
            var restoredClip = restored.Clips.Single(item => item.Id == id);
            Check(restored.ReadRepresentation(restoredClip.OriginalItems![1].Representations[1]).SequenceEqual(opaque),
                "Windows ZIP restoration retains opaque Mac clipboard data");

            string exported = Path.Combine(root, "exported-for-mac");
            var ai = new AiTasks(root);
            Guid recapId = Guid.NewGuid();
            ai.ImportArchive(new([], [new(recapId, DateTimeOffset.UtcNow, DateOnly.FromDateTime(DateTime.Now.AddDays(-7)),
                DateOnly.FromDateTime(DateTime.Now), new("Saved Story", "A test recap", "Keep going", [], []), 3)],
                [new(recapId, DateTimeOffset.UtcNow, "test model", "story", 100, 50, 5, 10, false)]));
            var native = new Clip { Text = "Windows 备份", Html = ClipboardFormats.WindowsHtml("<b>Windows 备份</b>"), Source = "Notepad" };
            Check(restored.Capture(native), "Add Windows clipboard content to the cross-platform backup");
            var route = new LinkFallbackRule("*.example.com/issues/{id}", "Ticket {{path.id}} · {{query.view}}",
                new(Guid.NewGuid(), "Ticket", "*.example.com", "/issues/{id}", ["view"]));
            new MacBackupWriter(restored, ai, [route]).Export(exported);
            var returned = new HistoryStore(Path.Combine(root, "returned"));
            var exportedArchive = new MacBackupReader(exported).Import(returned);
            Check(exportedArchive.Count == entries.Length + 1 && exportedArchive.Ai.Stories.Single().Id == recapId &&
                exportedArchive.Ai.Usage.Single().Output == 50 &&
                returned.Clips.Single(item => item.Id == native.Id).Html == native.Html,
                "Reimport the Mac v5 export with Windows rich text, saved Story and usage");
            var returnedClip = returned.Clips.Single(item => item.Id == id);
            Check(returnedClip.ExcludeFromAi && returned.ReadRepresentation(returnedClip.OriginalItems![1].Representations[1]).SequenceEqual(opaque),
                "Cross-platform backup round trips preserve per-clip AI privacy and exact clipboard bytes");
            var returnedImage = returned.Clips.Single(item => item.Id == pictureId);
            Check(returnedImage.OcrInNote && returnedImage.RecognizedAt == recognizedAt && returnedImage.RecognizedImageText == "Corrected Mac OCR" &&
                returnedImage.RecognizedText == "Raw Mac OCR" && returnedImage.OcrMode == ImageOcrMode.Fast &&
                returned.Clips.Single(item => item.Id == pendingId) is { OcrPending: true, OcrMode: ImageOcrMode.Fast },
                "Round-trip completed and pending OCR metadata in Mac v5 format");
            var ticket = new Clip { Kind = ClipKind.Link, Text = "https://test.example.com/issues/42?view=summary" };
            Check(exportedArchive.Fallbacks.Single().Route?.Id == route.Route!.Id &&
                LinkTitles.UpdateFallback(ticket, exportedArchive.Fallbacks)?.FallbackTitle == "Ticket 42 · summary",
                "Restore Mac route rules and expand both path and query variables on Windows");

            File.AppendAllText(Path.Combine(backup, "clips.jsonl"), "\n");
            try
            {
                new MacBackupReader(backup).Import(store);
                throw new InvalidOperationException("Expected Mac backup checksum rejection");
            }
            catch (InvalidDataException) { }
            Check(store.Clips.Count == entries.Length, "Reject altered Mac backup without changing existing clips");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static async Task CheckAiModel()
    {
        string root = Directory.CreateTempSubdirectory("Pasteory-AI-QA-").FullName;
        try
        {
            var clips = new[] { "alpha task", "beta task", "gamma task" }.Select(text => new Clip { Text = text }).ToArray();
            using var fake = new MockAiResponses(clips);
            using var transport = new HttpClient(fake);
            var tasks = new AiTasks(root, new AiModelClient(transport));
            var settings = new AiPreferences { Endpoint = "http://127.0.0.1:3425/v1", Model = "synthetic-model", Enabled = true };
            const string testSecret = "only-a-test-value";
            tasks.Credentials.Set(settings.Endpoint, testSecret);
            Check(tasks.Credentials.Read(settings.Endpoint) == testSecret && tasks.Credentials.Read("https://other.example/v1") == "",
                "Keep model credentials scoped and encrypted");
            Check((await tasks.ModelsAsync(settings.Endpoint, "", CancellationToken.None)).Single().Id == settings.Model,
                "Read model catalog from compatible endpoint");
            await tasks.AnalyzeAsync(settings, clips, [], false, "recent", false, CancellationToken.None);
            Check(tasks.Review?.Proposal.Groups.Single().Members.Length == 3 && tasks.TodayTokens == 280,
                "Validate organization results and record token usage");
            tasks.ClearReview();
            await tasks.AnalyzeAsync(settings, clips, [], true, "story", false, CancellationToken.None);
            Check(tasks.Stories.Single().Story.Work.Single().References.Single().Quote == "alpha task",
                "Keep exact Story citations and discard unsupported observations");
            var reopened = new AiTasks(root);
            Check(reopened.Stories.Count == 1 && reopened.Usage.Count == 3, "Persist Story and usage across sessions");
            Check(reopened.RecentHistory().Any(job => job.Status == "Discarded") &&
                reopened.RecentHistory().Any(job => job.Status == "Complete"), "Reopen independent Story and organization history");
            Check(!AiModelClient.TryEndpoint("http://example.com/v1", out _) &&
                AiTasks.Project(new Clip { Text = "-----BEGIN PRIVATE KEY-----" }, settings) is null,
                "Filter visible credentials and reject unencrypted nonlocal APIs");
            string textFile = Path.Combine(root, "referenced.txt");
            File.WriteAllText(textFile, "Synthetic file excerpt.");
            var fileClip = new Clip { Kind = ClipKind.Files, Files = [textFile] };
            var resources = AiTaskResources.Build(root, [fileClip]);
            var tool = new AiModelClient.ToolCall("local-test", "read_local_resource",
                JsonSerializer.Serialize(new { id = fileClip.Id, index = 0, offset = 0 }), default);
            var source = AiTasks.Project(fileClip, settings)!;
            Check(new AiReadingTools([source]).ResourceReply(tool, true).Content.Contains("disabled", StringComparison.Ordinal) &&
                new AiReadingTools([source], resources).ResourceReply(tool, true).Content.Contains("Synthetic file excerpt.", StringComparison.Ordinal),
                "Read linked file content only when explicitly made available to the task");
            File.AppendAllText(textFile, "Changed after preparation.");
            Check(new AiReadingTools([source], resources).ResourceReply(tool, true).Content.Contains("changed", StringComparison.Ordinal),
                "Reject a source file that changed during the task");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static async Task CheckLiveModelAsync(string model)
    {
        string root = Directory.CreateTempSubdirectory("Pasteory-Magpie-QA-").FullName;
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(80));
        try
        {
            var samples = new[]
            {
                "Synthetic Pasteory QA project: added the Windows quick panel keyboard flow.",
                "Synthetic Pasteory QA project: verified search, title editing and clipboard paste.",
                "Synthetic Pasteory QA project: packaged x64 and Arm64 sample builds.",
                "Synthetic Pasteory QA project: plan the next group editor test."
            };
            var clips = samples.Select(text => new Clip { Text = text }).ToArray();
            var task = new AiTasks(root);
            var prefs = new AiPreferences { Model = model, Enabled = true, DailyTokens = 30000 };
            var catalog = await task.ModelsAsync(prefs.Endpoint, "", stop.Token);
            Check(catalog.Any(item => item.Id == model), "Local Magpie advertises the selected model");
            await task.AnalyzeAsync(prefs, clips, [], false, "recent", true, stop.Token);
            var plan = task.Review ?? throw new InvalidOperationException(
                "Live organization did not finish: " + (task.ActiveJob?.Error ?? task.ActiveJob?.Status));
            Check(plan.Proposal.Groups.Sum(group => group.Members.Length) + plan.Proposal.Unassigned.Length == clips.Length,
                "Live organization accounted for each synthetic clip");
            await task.AnalyzeAsync(prefs, clips, [], true, "story", true, stop.Token);
            var recap = task.Stories.FirstOrDefault() ?? throw new InvalidOperationException(
                "Live Story did not finish: " + (task.ActiveJob?.Error ?? task.ActiveJob?.Status));
            Check(recap.Story.Work.Concat(recap.Story.Observations).SelectMany(section => section.References).Any(),
                "The live Story returned source references checked against the synthetic clips");
            Console.WriteLine($"Local Magpie completed organization and Story for {clips.Length} synthetic clips with {task.Usage.Count} model calls.");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static async Task CheckAiRecovery()
    {
        string root = Directory.CreateTempSubdirectory("Pasteory-AI-Recovery-").FullName;
        try
        {
            var clips = Enumerable.Range(0, 25).Select(index => new Clip { Text = $"Synthetic clip {index} " +
                (index == 3 ? new string('x', 62_000) + " complete ending" : "") }).ToArray();
            var settings = new AiPreferences { Enabled = true, Model = "synthetic-model", TaskRounds = 1, RecentLimit = 2 };
            using var transport = new HttpClient(new MockAiResponses(clips, wide: true));
            var first = new AiTasks(root, new AiModelClient(transport));
            first.Credentials.Set(settings.Endpoint, "only-a-test-value");
            first.ObserveClips(settings, [], clips);
            Check(first.DueIncremental(settings, clips, DateTimeOffset.UtcNow)?.Count == clips.Length,
                "Queue all newly copied contents independently of the recent limit");
            await first.AnalyzeAsync(settings, clips, [], false, "full", false, CancellationToken.None);
            var paused = first.Job(false)!;
            Check(paused is { Status: "Paused", Cursor: 25 } && paused.Error!.Contains("round limit"),
                "Retain the staged classification when the round budget pauses a task");
            string path = first.DirectoryFor(paused.Id);
            Check(File.ReadAllText(Path.Combine(path, "items.json")).Contains(" complete ending") &&
                File.Exists(Path.Combine(path, "plan.schema.json")) && File.Exists(Path.Combine(path, "agent-state.json")),
                "Save complete text and restartable task files");

            var reopened = new AiTasks(root, new AiModelClient(transport));
            await reopened.ResumeAsync(settings with { Model = "replacement-model" },
                clips, [], false, false, CancellationToken.None);
            Check(reopened.Review?.Id == paused.Id && reopened.Review.Proposal.Groups.Single().Members.Length == 3 &&
                reopened.Review.Proposal.Unassigned.Length == 22 &&
                reopened.Usage.Any(call => call.Model == "replacement-model"),
                "Resume the original task and its staged decisions under current model settings");
            reopened.ClearReview(applied: true);
            Check(new AiTasks(root).RecentHistory().Single().Status == "Applied" &&
                File.ReadAllLines(Path.Combine(path, "execution.jsonl")).Length == 2,
                "Preserve applied history and both model calls after restart");
            Check(reopened.DueIncremental(settings, clips, DateTimeOffset.UtcNow) is null,
                "Remove analyzed versions from the new-content queue");
            var changed = clips.Select((clip, index) => index == 0 ? clip with { Text = "Updated synthetic content" } : clip).ToArray();
            await reopened.AnalyzeAsync(settings with { NightlyTokens = 1000 }, changed, [], false, "idle", false, CancellationToken.None);
            Check(reopened.Job(false)?.Error == "Nightly token budget reached." && reopened.Usage.Count == 2,
                "Enforce a separate nightly budget before a model request");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private sealed class MockAiResponses(Clip[] clips, bool wide = false) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Check(request.Headers.Authorization?.Parameter == "only-a-test-value", "Use the scoped model key");
            string json;
            if (request.RequestUri?.AbsolutePath == "/v1/models")
                json = """{"data":[{"id":"synthetic-model","reasoning_levels":["low","high"]}]}""";
            else
            {
                string body = await request.Content!.ReadAsStringAsync(cancellationToken);
                using var sent = JsonDocument.Parse(body);
                var messages = sent.RootElement.GetProperty("messages");
                string args = messages[1].GetProperty("content").GetString()!;
                JsonElement input = JsonSerializer.Deserialize<JsonElement>(args);
                bool story = input.GetProperty("task").GetString() == "story";
                Guid taskId = input.GetProperty("taskId").GetGuid();
                var replies = messages.EnumerateArray().Where(message => message.GetProperty("role").GetString() == "tool").ToArray();
                var assignments = clips.Select((_, index) => new AiAssignment(AiTaskWorkspace.ItemKey(index),
                    index < 3 ? ["topic"] : [], index < 3 ? null : "Unrelated")).ToArray();
                if (!story && replies.Length == 0)
                {
                    Check(sent.RootElement.GetProperty("tools").GetArrayLength() == 4, "Expose only scoped reading and staging tools");
                    var tools = wide ? new[]
                    {
                        Tool("call_page", "clips_list", new { offset = 16, limit = 6 }),
                        Tool("call_stage", "stage_assignments", new { assignments })
                    } : [Tool("call_test", "clips_get", new { id = clips[0].Id, offset = 0, maxChars = 40 })];
                    json = JsonSerializer.Serialize(new
                    {
                        choices = new[] { new { message = new
                        {
                            content = (string?)null, tool_calls = tools
                        } } },
                        usage = new { prompt_tokens = 100, completion_tokens = 40 }
                    });
                    return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
                }
                if (!story) Check(replies[0].GetProperty("content").GetString()!.Contains(wide ? "\"i17\"" : "alpha task"),
                    "Retain the requested clipboard page as part of the task conversation");
                string response = story ? JsonSerializer.Serialize(new AiStoryResult(taskId,
                        new StoryDraft("Weekly story", "Three sample tasks", "Keep going",
                            [new("Alpha", "First task", [new(clips[0].Id, "alpha task")])],
                            [new("Unsupported", "Missing evidence", [new(clips[0].Id, "invented text")])])), AiFile.Json)
                    : JsonSerializer.Serialize(new AiOrganizationResult(taskId,
                        [new("topic", "Test project", "Fictional clips", null, "Test summary", ["i1"])], wide ? [] : assignments),
                        AiFile.Json);
                json = JsonSerializer.Serialize(new
                {
                    choices = new[] { new { message = new { content = response } } },
                    usage = new { prompt_tokens = 100, completion_tokens = 40, prompt_tokens_details = new { cached_tokens = 12 } }
                });
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }

        private static object Tool(string id, string name, object args) => new
        {
            id, type = "function", function = new { name, arguments = JsonSerializer.Serialize(args) }
        };
    }

    private static void CheckUpdateSignature()
    {
        var privateKey = new Ed25519PrivateKeyParameters(new SecureRandom());
        var offer = new UpdateOffer("0.1.58", "x64",
            "https://github.com/houskii/Pasteory/releases/download/windows-v0.1.58/Pasteory-win-x64.zip",
            new string('0', 64), 1000, "Synthetic release notes.");
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new UpdateIndex(1, [offer]), AiFile.Json);
        var signer = new Ed25519Signer();
        signer.Init(true, privateKey);
        signer.BlockUpdate(bytes, 0, bytes.Length);
        var signature = new SignedUpdateIndex(Convert.ToBase64String(bytes), Convert.ToBase64String(signer.GenerateSignature()));
        byte[] key = privateKey.GeneratePublicKey().GetEncoded();
        Check(WindowsUpdates.Verify(signature, key).Releases.Single() == offer, "Verify signed Windows version index");
        bytes[20] ^= 1;
        try
        {
            WindowsUpdates.Verify(signature with { Payload = Convert.ToBase64String(bytes) }, key);
            throw new InvalidOperationException("Expected an invalid update signature to be rejected");
        }
        catch (InvalidDataException) { }
    }

    private static byte[] OcrSampleImage(string label = "PASTEORY LOCAL OCR")
    {
        var visual = new DrawingVisual();
        using (var draw = visual.RenderOpen())
        {
            draw.DrawRectangle(Brushes.White, null, new Rect(0, 0, 1920, 288));
            var text = new FormattedText(label, CultureInfo.GetCultureInfo("en-US"),
                FlowDirection.LeftToRight, new Typeface("Segoe UI"), 56, Brushes.Black, 1);
            draw.DrawText(text, new Point(24, 48));
        }
        var bitmap = new RenderTargetBitmap(1920, 288, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var bytes = new MemoryStream();
        encoder.Save(bytes);
        return bytes.ToArray();
    }

    private static void CheckOcr()
    {
        using var trace = new System.Diagnostics.TextWriterTraceListener(Console.Out);
        System.Diagnostics.Trace.Listeners.Add(trace);
        try
        {
            byte[] sample = OcrSampleImage();
            using var accurate = ImageOcr.DecodeAsync(sample, ImageOcrMode.Accurate, CancellationToken.None).GetAwaiter().GetResult();
            using var fast = ImageOcr.DecodeAsync(sample, ImageOcrMode.Fast, CancellationToken.None).GetAwaiter().GetResult();
            Check(accurate.PixelWidth == 1920 && accurate.PixelHeight == 288 && fast.PixelWidth == 1280 && fast.PixelHeight == 192,
                $"OCR uses distinct working resolutions. Accurate {accurate.PixelWidth}×{accurate.PixelHeight}, fast {fast.PixelWidth}×{fast.PixelHeight}.");
            Console.WriteLine("Windows OCR languages: " + string.Join(", ",
                global::Windows.Media.Ocr.OcrEngine.AvailableRecognizerLanguages.Select(language => language.LanguageTag)));
            foreach (var mode in Enum.GetValues<ImageOcrMode>())
            {
                string result = ImageOcr.ReadAsync(sample, "English", mode, CancellationToken.None).GetAwaiter().GetResult();
                Check(result.Contains("PASTEORY", StringComparison.OrdinalIgnoreCase), $"Recognize synthetic text in {mode} mode. Observed: {result}");
            }
        }
        finally
        {
            System.Diagnostics.Trace.Flush();
            System.Diagnostics.Trace.Listeners.Remove(trace);
        }
    }

    private static void CheckPackagedOcr(string executable)
    {
        string root = Directory.CreateTempSubdirectory("Pasteory-OCR-QA-").FullName;
        try
        {
            byte[] image = OcrSampleImage(), second = OcrSampleImage("SECOND IMAGE"), rejected = OcrSampleImage("SKIP THIS VERSION");
            byte[] damaged = new byte[image.Length];
            var broken = new Clip
            {
                Kind = ClipKind.Image, ImageSize = image.Length, ImageHash = Convert.ToHexString(SHA256.HashData(image)),
                ImageWidth = 1920, ImageHeight = 288, OcrPending = true, Note = "Saved caption"
            };
            var store = new HistoryStore(root);
            Check(store.Capture(broken, damaged), "Seed an unreadable OCR job saved by an earlier version");
            var inputs = new Dictionary<Guid, byte[]>();
            ClipboardRepresentation Input(string uti, byte[] data)
            {
                var id = Guid.NewGuid();
                inputs.Add(id, data);
                return new(id, uti, Convert.ToHexString(SHA256.HashData(data)), data.Length);
            }

            var imported = new Clip
            {
                Kind = ClipKind.Mixed, OcrPending = true, OcrMode = ImageOcrMode.Fast, Note = "Imported caption",
                OriginalItems =
                [
                    new(Guid.NewGuid(), 1, [Input("public.png", second), Input("public.tiff", rejected)]),
                    new(Guid.NewGuid(), 0, [Input("public.png", damaged), Input("public.tiff", image)])
                ]
            };
            Check(store.ImportClips([imported], [], _ => throw new InvalidOperationException(), rep => inputs[rep.Id]) == 1,
                "Seed a Mac OCR job with two ordered items and alternate representations");
            new LocalSettings { Language = "English", RecognizeImages = true, OcrMode = ImageOcrMode.Fast }.Save(root);
            WaitForJob(imported.Id, (snapshot, current) =>
            {
                var text = current.RecognizedImageText ?? "";
                Check(current is { OcrInNote: true, OcrMode: ImageOcrMode.Fast } &&
                    text.Split('\n') is [var first, var next] && first.Contains("PASTEORY", StringComparison.OrdinalIgnoreCase) &&
                    next.Contains("SECOND IMAGE", StringComparison.OrdinalIgnoreCase) &&
                    snapshot.Clips.Single(item => item.Id == broken.Id) is { OcrPending: true, RecognizedText: null },
                    $"Recognize one representation per original item in order and keep the unreadable job. Text: {text}");
            });

            File.WriteAllBytes(Path.Combine(root, "images", broken.ImageFileName), image);
            WaitForJob(broken.Id, (snapshot, current) =>
            {
                Check(current is { OcrInNote: true, OcrMode: ImageOcrMode.Accurate } &&
                    current.Note.StartsWith("Saved caption\n\n[OCR:", StringComparison.Ordinal) &&
                    current.RecognizedImageText?.Contains("PASTEORY", StringComparison.OrdinalIgnoreCase) == true &&
                    snapshot.SearchIds("local ocr").Contains(broken.Id), "Resume a recovered legacy job and index its editable text");
            });
            Console.WriteLine("The portable app recognized multi-item images, retained an unreadable job and indexed it after recovery.");
        }
        finally { Directory.Delete(root, recursive: true); }

        void WaitForJob(Guid id, Action<HistoryStore, Clip> verify)
        {
            var start = new ProcessStartInfo(Path.GetFullPath(executable)) { UseShellExecute = false, CreateNoWindow = true };
            foreach (string arg in new[] { "--data-root", root, "--no-hotkey", "--no-capture", "--tray" }) start.ArgumentList.Add(arg);
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not launch the OCR fixture.");
            try
            {
                var timeout = Stopwatch.StartNew();
                while (timeout.Elapsed < TimeSpan.FromSeconds(12))
                {
                    Check(!process.HasExited, "The packaged app stays running while processing an OCR job");
                    var store = new HistoryStore(root);
                    var current = store.Clips.Single(item => item.Id == id);
                    if (!current.OcrPending)
                    {
                        verify(store, current);
                        return;
                    }
                    Thread.Sleep(150);
                }
                throw new InvalidOperationException("The packaged image recognition did not finish.");
            }
            finally
            {
                if (!process.HasExited) { process.Kill(); process.WaitForExit(3000); }
            }
        }
    }
}
