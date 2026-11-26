using System;
using System.Buffers.Binary;
using System.Collections.Generic;
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
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;
using Pasteory.Core;
using Pasteory.Windows;

internal static partial class Program
{
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
            var clip = new
            {
                id, createdAt = DateTimeOffset.UtcNow, updatedAt = DateTimeOffset.UtcNow, lastCopiedAt = DateTimeOffset.UtcNow,
                primaryKind = "text", isArchived = true, source = new { appName = "Notes", confidence = "high" },
                collectionIDs = new[] { group }, copyCount = 3, title = "Archived", note = "Kept",
                items = new[] { new { order = 0, representations = new[] { new { uti = "public.utf8-plain-text", storage = new
                {
                    type = "archived", relativePath = "clip.lzfse", checksum = Convert.ToHexString(SHA256.HashData(raw)), size = raw.Length
                } } } } }
            };
            Add("clips.jsonl", JsonSerializer.SerializeToUtf8Bytes(clip));
            Add("collections.json", JsonSerializer.SerializeToUtf8Bytes(new[]
            {
                new { id = group, name = "Mac group", kind = "normal", sortOrder = 0 }
            }));
            File.WriteAllBytes(Path.Combine(backup, "manifest.json"),
                JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 5, fileChecksums = manifest }));
            var store = new HistoryStore(Path.Combine(root, "history"));
            Check(new MacBackupReader(backup).Import(store).Count == 1 && store.Clips.Single().Text == text &&
                store.Clips[0].ArchivedAt is not null && store.Clips[0].CollectionIds.SequenceEqual([group]) &&
                store.Clips[0].CopyCount == 3, "Import Mac v5 archive and its metadata");
            File.AppendAllText(Path.Combine(backup, "clips.jsonl"), "\n");
            try
            {
                new MacBackupReader(backup).Import(store);
                throw new InvalidOperationException("Expected Mac backup checksum rejection");
            }
            catch (InvalidDataException) { }
            Check(store.Clips.Count == 1, "Reject altered Mac backup without changing existing clips");
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

    private sealed class MockAiResponses(Clip[] clips) : HttpMessageHandler
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
                if (!story && messages.GetArrayLength() == 2)
                {
                    Check(sent.RootElement.GetProperty("tools").GetArrayLength() == 2, "Expose only bounded reading tools");
                    json = JsonSerializer.Serialize(new
                    {
                        choices = new[] { new { message = new
                        {
                            content = (string?)null, tool_calls = new[] { new
                            {
                                id = "call_test", type = "function", function = new
                                {
                                    name = "clips_get", arguments = JsonSerializer.Serialize(new { id = clips[0].Id, offset = 0, maxChars = 40 })
                                }
                            } }
                        } } },
                        usage = new { prompt_tokens = 100, completion_tokens = 40 }
                    });
                    return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
                }
                if (!story) Check(messages[messages.GetArrayLength() - 1].GetProperty("content").GetString()!.Contains("alpha task"),
                    "Return only the requested clipboard excerpt");
                string response = story ? JsonSerializer.Serialize(new StoryDraft("Weekly story", "Three sample tasks", "Keep going",
                        [new("Alpha", "First task", [new(clips[0].Id, "alpha task")])],
                        [new("Unsupported", "Missing evidence", [new(clips[0].Id, "invented text")])]), AiFile.Json)
                    : JsonSerializer.Serialize(new AiProposal([new("Test project", "Fictional clips", clips.Select(clip => clip.Id).ToArray())], []),
                        AiFile.Json);
                json = JsonSerializer.Serialize(new
                {
                    choices = new[] { new { message = new { content = response } } },
                    usage = new { prompt_tokens = 100, completion_tokens = 40, prompt_tokens_details = new { cached_tokens = 12 } }
                });
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }
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

    private static void CheckOcr()
    {
        var visual = new DrawingVisual();
        using (var draw = visual.RenderOpen())
        {
            draw.DrawRectangle(Brushes.White, null, new Rect(0, 0, 800, 190));
            var text = new FormattedText("PASTEORY LOCAL OCR", CultureInfo.GetCultureInfo("en-US"),
                FlowDirection.LeftToRight, new Typeface("Segoe UI"), 56, Brushes.Black, 1);
            draw.DrawText(text, new Point(24, 48));
        }
        var bitmap = new RenderTargetBitmap(800, 190, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var bytes = new MemoryStream();
        encoder.Save(bytes);
        using var trace = new System.Diagnostics.TextWriterTraceListener(Console.Out);
        System.Diagnostics.Trace.Listeners.Add(trace);
        string? result = ImageOcr.ReadAsync(bytes.ToArray(), "English", CancellationToken.None).GetAwaiter().GetResult();
        System.Diagnostics.Trace.Flush();
        System.Diagnostics.Trace.Listeners.Remove(trace);
        Console.WriteLine("Windows OCR languages: " + string.Join(", ",
            global::Windows.Media.Ocr.OcrEngine.AvailableRecognizerLanguages.Select(language => language.LanguageTag)));
        Check(result?.Contains("PASTEORY", StringComparison.OrdinalIgnoreCase) == true,
            $"Recognize synthetic text with Windows OCR. Observed: {result ?? "(none)"}");
    }
}
