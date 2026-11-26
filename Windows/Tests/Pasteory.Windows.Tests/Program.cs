using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Interop;
using System.Windows.Threading;
using Pasteory.Core;
using Pasteory.Windows;

internal static partial class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        int fixture = Array.IndexOf(args, "--prepare-ui");
        if (fixture >= 0)
        {
            PrepareUi(args[fixture + 1]);
            return;
        }
        if (args.Contains("--link-engine"))
        {
            CheckLinkEngine();
            return;
        }
        if (args.Contains("--chat-context"))
        {
            CheckChatContext();
            return;
        }
        if (args.Contains("--file-command"))
        {
            Task.Run(CheckFileCommandAsync).GetAwaiter().GetResult();
            return;
        }
        if (args.Contains("--benchmark-search"))
        {
            BenchmarkSearch();
            return;
        }
        int liveModel = Array.IndexOf(args, "--magpie");
        if (liveModel >= 0)
        {
            System.Threading.Tasks.Task.Run(() => CheckLiveModelAsync(args[liveModel + 1])).GetAwaiter().GetResult();
            return;
        }
        const string content = "Pasteory 剪贴板";
        const string rich = @"{\rtf1\ansi Clipboard}";
        var data = new DataObject();
        data.SetText(content, TextDataFormat.UnicodeText);
        data.SetText(rich, TextDataFormat.Rtf);
        var capture = ClipboardFormats.Read(data, "Notepad");
        Check(capture?.Clip.Text == content && capture?.Clip.Rtf == rich, "Read Unicode and RTF");

        var plain = ClipboardFormats.Create(capture!.Value.Clip, plainText: true, png: null);
        Check(plain.GetText() == content && !plain.GetDataPresent(DataFormats.Rtf, false), "Write plain text only");
        Check(ClipboardFormats.Read(plain, "Pasteory") is null, "Ignore Pasteory writes");
        data.SetData(ClipboardFormats.IncludeInHistory, new MemoryStream(new byte[4]), false);
        Check(ClipboardFormats.Read(data, "Notepad") is null, "Honor opted-out clipboard history");

        var link = new DataObject();
        link.SetText("https://example.com");
        Check(ClipboardFormats.Read(link, "Browser")?.Clip.Kind == ClipKind.Link, "Classify HTTPS links");
        var hsl = new DataObject();
        hsl.SetText("hsla(-240deg, 100%, 50%, .25)");
        Check(ClipboardFormats.Read(hsl, "Notepad")?.Clip.Kind == ClipKind.Color &&
            TextTools.TryColor(hsl.GetText(), out var rgba) && rgba == new TextTools.ColorValue(0, 255, 0, 64, true),
            "Classify and render HSL and alpha");

        var app = new App();
        Check(FileTypes.Catalog.Count == 49 &&
            FileTypes.Catalog.All(type => FileTypes.Image(type) is { PixelWidth: 128, PixelHeight: 128 }),
            "All Mac file icon assets are present in the Windows assembly");
        Check(FileTypes.ForName("package-lock.json").Icon == "lock" &&
            FileTypes.ForName("Archive.TAR.GZ").Icon == "archive" && FileTypes.ForName(".gitignore").Icon == "git" &&
            FileTypes.ForName("build.ps1").Icon == "shell", "Match full names and composite suffixes");
        CheckAggregationSearch();
        CheckLinkTitles();
        string temporary = Path.GetTempFileName();
        var tempReference = FileReference.FromPath(new Uri(temporary).AbsoluteUri);
        try
        {
            Check(tempReference.Inspect() is { Size: 0, Missing: false } &&
                tempReference.Folder == Path.GetDirectoryName(temporary), "Inspect file URL and parent directory");
        }
        finally { File.Delete(temporary); }
        Check(tempReference.Inspect().Missing, "Recheck removed file");

        string[] paths = [Path.Combine(Path.GetTempPath(), "clipboard-file.txt"),
            Path.Combine(Path.GetTempPath(), "clipboard-other.txt")];
        var files = ClipboardFormats.Create(new Clip { Kind = ClipKind.Files, Files = paths },
            plainText: false, png: null);
        Check(files.GetFileDropList().Cast<string>().SequenceEqual(paths), "Write Windows file references");

        var image = new DataObject();
        image.SetImage(BitmapSource.Create(1, 1, 96, 96, PixelFormats.Bgra32, null,
            new byte[] { 0, 0, 255, 255 }, 4));
        var capturedImage = ClipboardFormats.Read(image, "Paint");
        Check(capturedImage?.Clip.Kind == ClipKind.Image && capturedImage?.Image is { Length: > 0 },
            "Read native bitmaps");
        var replay = ClipboardFormats.Create(capturedImage!.Value.Clip, plainText: false,
            png: capturedImage.Value.Image);
        Check(replay.GetImage().PixelWidth == 1 && replay.GetDataPresent("PNG", false), "Write image formats");
        image.SetText("Image caption");
        var mixed = ClipboardFormats.Read(image, "Paint")!.Value;
        var mixedReplay = ClipboardFormats.Create(mixed.Clip, false, mixed.Image);
        Check(mixed.Clip.Kind == ClipKind.Mixed && mixedReplay.GetText() == "Image caption" &&
            mixedReplay.GetImage().PixelHeight == 1, "Preserve both text and image in a mixed copy");

        app.InitializeComponent();
        var panel = new HistoryWindow(app);
        Check(panel.Title == "Pasteory", "Load the native WPF history panel and resources");
        CheckMacBackup();
        CheckAiModel().GetAwaiter().GetResult();
        CheckUpdateSignature();
        if (args.Contains("--ocr")) CheckOcr();
        if (args.Contains("--system-clipboard"))
        {
            IDataObject? previous = Clipboard.GetDataObject();
            Clipboard.SetDataObject(plain, copy: true);
            try
            {
                Check(NativeMethods.OwnsClipboard(), "Find the process owning the real clipboard after flushing");
                Check(Clipboard.GetText() == content, "Read back data from the Windows clipboard");
                Check(Clipboard.GetDataObject() is { } systemData &&
                    ClipboardFormats.Read(systemData, "Pasteory") is null, "Keep the opt-out markers on the real clipboard");
            }
            finally
            {
                RestoreClipboard(previous);
            }
        }
        int pathIndex = Array.IndexOf(args, "--packaged-app");
        if (pathIndex >= 0)
        {
            CheckPackagedApp(args[pathIndex + 1]);
            System.Threading.Tasks.Task.Run(() => CheckChromeBridgeAsync(args[pathIndex + 1])).GetAwaiter().GetResult();
        }
        Console.WriteLine("Windows clipboard format and WPF checks passed.");
    }

    private static void CheckPackagedApp(string executable)
    {
        string directory = Path.Combine(Path.GetTempPath(), "Pasteory-package-" + Guid.NewGuid().ToString("N"));
        string indexPath = Path.Combine(directory, HistoryStore.CatalogFileName);
        string token = "Pasteory preview CI " + Guid.NewGuid().ToString("N");
        IDataObject? previous = Clipboard.GetDataObject();
        var start = new ProcessStartInfo(Path.GetFullPath(executable))
        {
            WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(executable))!
        };
        start.ArgumentList.Add("--data-root");
        start.ArgumentList.Add(directory);
        start.ArgumentList.Add("--tray");
        start.ArgumentList.Add("--no-hotkey");
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start the portable build");
        try
        {
            Check(process.WaitForInputIdle(10000), "Start the portable app message loop");
            for (int retry = 0; retry < 20; retry++)
            {
                Check(!process.HasExited, "The portable app exited during launch");
                Clipboard.SetText(token);
                Thread.Sleep(200);
                if (!File.Exists(indexPath)) continue;
                if (new HistoryStore(directory).SearchIds(token, limit: 1).Count == 1)
                {
                    Console.WriteLine("The portable app captured a real Windows clipboard event and persisted the text.");
                    return;
                }
            }
            throw new InvalidOperationException("The portable app did not write the copied text to history");
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill();
                process.WaitForExit();
            }
            RestoreClipboard(previous);
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    private static void RestoreClipboard(IDataObject? previous)
    {
        if (!NativeMethods.OwnsClipboard()) return;
        if (previous is null) Clipboard.Clear();
        else Clipboard.SetDataObject(previous, copy: true);
    }

    private static void CheckAggregationSearch()
    {
        var collection = new ClipCollection(Guid.NewGuid(), "资料");
        var first = new Clip { Text = "笔记", Note = "项目计划", CollectionIds = [collection.Id] };
        var second = new Clip { Text = "作业", Title = "项目计划" };
        var parent = new Clip { Kind = ClipKind.Aggregate, Title = "浏览记录", Members = [first.Id, second.Id] };
        Clip[] clips = [first, second, parent];
        var listed = ClipListing.Build(clips, "项目计划", [first.Id, second.Id], Scope.All,
            null, collection, [], [], null);
        Check(listed.Count == 1 && listed.Rows.Length == 2 &&
            listed.Rows[0] is { MemberCount: 2, MatchCount: 1, Expanded: true } &&
            listed.Rows[1].Parent == parent.Id && listed.Rows[1].Clip.Id == first.Id && listed.Rows[1].MatchSummary is not null &&
            listed.SearchMembers.SequenceEqual([first.Id]), "Preserve the parent and only matching members in a filtered group");
        var title = ClipListing.Build(clips, "浏览记录", [parent.Id], Scope.All, null, null, [], [], null);
        Check(title.Rows is [{ Expanded: false, MatchCount: null }] && title.SearchMembers.Length == 2,
            "A title-only match stays collapsed and aggregates its member clips");
    }

    private static void CheckLinkTitles()
    {
        var first = new Clip { Kind = ClipKind.Link, Text = "https://code.byted.org/tools/Notes/merge_requests/12" };
        var second = new Clip { Kind = ClipKind.Link, Text = "https://code.byted.org/dev/Clipboard/merge_requests/55?utm_source=test" };
        var firstFallback = LinkTitles.UpdateFallback(first, [])!;
        var secondFallback = LinkTitles.UpdateFallback(second, [])!;
        Check(firstFallback is { FallbackTitle: "Notes MR · !12", FallbackSource: "Built-in fallback", Status: "Not attempted" } &&
            firstFallback.Route == secondFallback.Route && secondFallback.FallbackTitle == "Clipboard MR · !55",
            "Group built-in offline titles by route");
        var rule = new LinkFallbackRule(LinkTitles.RulePattern(firstFallback.Route!), "$2 · request $3");
        Check(LinkTitles.UpdateFallback(second, [rule])?.FallbackTitle == "Clipboard · request 55",
            "Use a rule created from the unresolved route to replace an offline title");
        var secret = new Clip { Kind = ClipKind.Link, Text = "https://example.invalid/docs?token=synthetic-test-value" };
        var secretRule = new LinkFallbackRule(@"example\.invalid/docs\?token=([^&]+)", "$1");
        Check(LinkTitles.UpdateFallback(secret, [secretRule])?.FallbackTitle == "••••", "Redact tokens in title captures");

        var good = new LinkDetails("Resolved", "Reviewed clipboard changes", DateTimeOffset.Now, "Anonymous", "Distinctive");
        var saved = LinkTitles.RecordAttempt(first, good, []);
        var failed = LinkTitles.RecordAttempt(first with { LinkDetails = saved },
            new("Sign-in required", null, good.AttemptedAt.AddMinutes(1), "WebView2"), []);
        Check(failed.Title == good.Title && failed.LastResolvedAt == good.AttemptedAt &&
            failed.Attempts is [{ Status: "Sign-in required" }, { Status: "Resolved" }],
            "Keep the last useful title and record the new failed attempt");
    }

    private static void CheckChatContext()
    {
        var header = new TextBlock { Text = "Pasteory QA 会话（8）" };
        AutomationProperties.SetAutomationId(header, "current_chat_name_label");
        var host = new Window { Width = 290, Height = 95, ShowInTaskbar = false, ShowActivated = false, Content = header };
        var frame = new DispatcherFrame();
        var dispatcher = Dispatcher.CurrentDispatcher;
        host.Show();
        try
        {
            var task = dispatcher.InvokeAsync(async () =>
            {
                var capture = new CaptureEvent(DateTimeOffset.Now, "Weixin");
                return await ChatContext.InspectAsync(new WindowInteropHelper(host).Handle, capture, CancellationToken.None);
            }, DispatcherPriority.ApplicationIdle).Task.Unwrap();
            _ = task.ContinueWith(_ => dispatcher.BeginInvoke(new Action(() => frame.Continue = false)),
                CancellationToken.None, System.Threading.Tasks.TaskContinuationOptions.None, System.Threading.Tasks.TaskScheduler.Default);
            Dispatcher.PushFrame(frame);
            var result = task.GetAwaiter().GetResult();
            Check(result?.Context == "Pasteory QA 会话" && result.Details?["conversationType"] == "group" &&
                result.Details?["participantCount"] == "8", "Read the conversation title and participant count from a window's UIA header");
            Console.WriteLine("Windows UI Automation chat header check passed.");
        }
        finally { host.Close(); }
    }

    private static async Task CheckFileCommandAsync()
    {
        string directory = Directory.CreateTempSubdirectory("Pasteory-file-command-").FullName;
        try
        {
            string file = Path.Combine(directory, "reference with spaces.tar.gz");
            File.WriteAllText(file, "synthetic file");
            var runner = new FileCommandRunner();
            var rule = new FileOpenRule("tar.gz", Command:
                "Get-Content -LiteralPath $file\n[Console]::Error.WriteLine('fixture diagnostic')\nexit 7");
            var result = await runner.RunAsync(directory, rule, file);
            Check(result is { ExitCode: 7 } && runner.Latest("tar.gz") == result, "Record the actual PowerShell command exit status");
            string log = File.ReadAllText(result!.Path);
            Check(log.Contains("synthetic file") && log.Contains("fixture diagnostic"), "Pass the path and capture both output streams");
            Console.WriteLine("PowerShell file command and isolated log check passed.");
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static void BenchmarkSearch()
    {
        foreach (int count in new[] { 10_000, 100_000 })
        {
            string directory = Path.Combine(Path.GetTempPath(), "Pasteory-benchmark-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var clips = Enumerable.Range(0, count).Select(index => new Clip
                {
                    Kind = ClipKind.Code, Text = $"常用命令 swift build 编号 {index}", Title = $"构建记录 {index}",
                    Source = "Terminal", Note = "性能样本", CapturedAt = DateTimeOffset.UnixEpoch.AddSeconds(index)
                }).Reverse().ToArray();
                using (var legacy = File.Create(Path.Combine(directory, "history.json")))
                    JsonSerializer.Serialize(legacy, clips);
                var timer = Stopwatch.StartNew();
                var store = new HistoryStore(directory);
                double migrateMs = timer.Elapsed.TotalMilliseconds;
                Check(store.Clips.Count == count, "Migrate every benchmark row");
                const string query = "常用命令";
                double Measure(Func<int> search, int expected)
                {
                    Check(search() == expected, "Warm the app search path");
                    var samples = new double[20];
                    for (int index = 0; index < samples.Length; index++)
                    {
                        timer.Restart();
                        Check(search() == expected, "Find every expected search result");
                        samples[index] = timer.Elapsed.TotalMilliseconds;
                    }
                    Array.Sort(samples);
                    return samples[18];
                }
                double indexP95 = Measure(() => store.SearchIds(query, limit: 500).Count, 500);
                double appP95 = Measure(() => ClipListing.Build(store.Clips, query, store.SearchIds(query), Scope.All,
                    null, null, [], [], null).Count, count);
                Console.WriteLine($"{count:N0} clips   migration {migrateMs:F0} ms   index p95 {indexP95:F2} ms   library p95 {appP95:F2} ms");
                Check(indexP95 < (count == 10_000 ? 150 : 300), "Meet the Mac indexed search benchmark gate");
            }
            finally { Directory.Delete(directory, recursive: true); }
        }
    }

    private static void PrepareUi(string directory)
    {
        Check(Path.IsPathFullyQualified(directory) && !Directory.Exists(directory), "A new absolute fixture directory");
        Directory.CreateDirectory(directory);
        var store = new HistoryStore(directory);
        var design = store.SaveCollection(null, "设计灵感", null);
        var dev = store.SaveCollection(null, "开发资料", null);
        var snippets = store.SaveCollection(null, "写作片段", null);
        store.SaveCollection(null, "代码收藏", new SmartRules(true, [new(RuleField.Kind, RuleComparison.Equals, "Code")], []));
        DateTimeOffset now = DateTimeOffset.Now;
        var sourceIcons = new Dictionary<string, string>
        {
            ["Notepad"] = Path.Combine(Environment.SystemDirectory, "notepad.exe"),
            ["Paint"] = Path.Combine(Environment.SystemDirectory, "mspaint.exe"),
            ["Explorer"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"),
            ["Terminal"] = Path.Combine(Environment.SystemDirectory, "cmd.exe")
        };
        string chrome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"Google\Chrome\Application\chrome.exe");
        string filename = Path.Combine(directory, "project-notes.md");
        File.WriteAllText(filename, "# Pasteory\r\n\r\nWindows visual fixture.");
        store.Capture(new Clip
        {
            Source = "Notepad", SourcePath = sourceIcons["Notepad"], Text = "为每一次复制，留一个位置。\n留下有用的片段，在需要的时候找到它们。",
            Title = "值得留下的灵感", Note = "留给下个版本的一点想法", Pinned = true, Favorite = true,
            CollectionIds = [design.Id, snippets.Id], CopyCount = 3, PasteCount = 2, CapturedAt = now
        });
        store.Capture(new Clip
        {
            Kind = ClipKind.Link, Source = "Chrome", SourcePath = chrome, Text = "https://github.com/houskii/Pasteory",
            LinkDetails = new("Resolved", "github.com · Pasteory", now, "github.com"), CollectionIds = [dev.Id], CapturedAt = now.AddMinutes(-1)
        });
        store.Capture(new Clip
        {
            Kind = ClipKind.Code, Source = "Terminal", SourcePath = sourceIcons["Terminal"],
            Text = "let ideas = clipboard.history\n    .filter { $0.isFavorite }\n    .sorted { $0.date > $1.date }",
            CodeLanguage = "swift", CollectionIds = [dev.Id], CapturedAt = now.AddMinutes(-2)
        });
        var palette = new DrawingVisual();
        using (var draw = palette.RenderOpen())
        {
            draw.DrawRectangle(Brushes.White, null, new Rect(0, 0, 360, 160));
            draw.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(99, 80, 224)), null, new Rect(0, 2, 68, 156), 14, 14);
            draw.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(2, 187, 214)), null, new Rect(77, 2, 186, 156), 14, 14);
            draw.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(242, 145, 43)), null, new Rect(273, 2, 86, 156), 14, 14);
        }
        var bitmap = new RenderTargetBitmap(360, 160, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(palette);
        using var stream = new MemoryStream();
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(bitmap));
        png.Save(stream);
        byte[] bytes = stream.ToArray();
        store.Capture(new Clip
        {
            Kind = ClipKind.Image, Source = "Paint", SourcePath = sourceIcons["Paint"], CapturedAt = now.AddMinutes(-3),
            ImageSize = bytes.Length, ImageWidth = 360, ImageHeight = 160, RecognizedText = "Pasteory · 配色灵感",
            Title = "主题预览", Note = "保留原图，方便回看",
            ImageHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes))
        }, bytes);
        store.Capture(new Clip { Kind = ClipKind.Files, Source = "Explorer", SourcePath = sourceIcons["Explorer"], Files = [filename], CapturedAt = now.AddMinutes(-4) });
        store.Capture(new Clip { Kind = ClipKind.Color, Source = "Figma", Text = "hsla(265deg, 76%, 54%, .85)",
            CollectionIds = [design.Id], CapturedAt = now.AddMinutes(-5) });
        string archive = Path.Combine(directory, "reference.tar.gz");
        File.WriteAllText(archive, "Synthetic file for native visual QA");
        store.Capture(new Clip { Kind = ClipKind.Files, Source = "Explorer", SourcePath = sourceIcons["Explorer"],
            Files = [archive], CapturedAt = now.AddMinutes(-6) });
        store.Capture(new Clip { Kind = ClipKind.Files, Source = "Explorer", SourcePath = sourceIcons["Explorer"],
            Files = [filename, Path.Combine(directory, "package-lock.json"), archive], CapturedAt = now.AddMinutes(-7) });
        var aggregate = store.SaveAggregation(null, "测试素材", "用于验证匹配成员", store.Clips
            .Where(clip => clip.Kind is ClipKind.Code or ClipKind.Link).Select(clip => clip.Id), "Manual");
        Check(aggregate is not null, "Save fixture aggregation");
        new LocalSettings
        {
            Language = "简体中文", Appearance = "Light", BrowserPath = File.Exists(chrome) ? chrome : null,
            Shortcuts = new Dictionary<string, string> { ["ShowPanel"] = "Ctrl+Alt+Shift+V" }
        }.Save(directory);
        Console.WriteLine("Prepared eight synthetic clips, an aggregation, and four groups.");
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
    }
}
