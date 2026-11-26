using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
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

        var app = new App();
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
        string indexPath = Path.Combine(directory, "history.json");
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
                using var stream = new FileStream(indexPath, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream);
                if (reader.ReadToEnd().Contains(token, StringComparison.Ordinal))
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
            ImageSize = bytes.Length, ImageWidth = 360, ImageHeight = 160,
            ImageHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes))
        }, bytes);
        store.Capture(new Clip { Kind = ClipKind.Files, Source = "Explorer", SourcePath = sourceIcons["Explorer"], Files = [filename], CapturedAt = now.AddMinutes(-4) });
        store.Capture(new Clip { Kind = ClipKind.Color, Source = "Figma", Text = "#7C3AED", CollectionIds = [design.Id], CapturedAt = now.AddMinutes(-5) });
        new LocalSettings
        {
            Language = "简体中文", Appearance = "Light", BrowserPath = File.Exists(chrome) ? chrome : null,
            Shortcuts = new Dictionary<string, string> { ["ShowPanel"] = "Ctrl+Alt+Shift+V" }
        }.Save(directory);
        Console.WriteLine("Prepared six synthetic clips and four groups.");
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
    }
}
