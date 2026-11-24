using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Pasteory.Core;
using Pasteory.Windows;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
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

        var app = new App();
        app.InitializeComponent();
        var panel = new HistoryWindow(app);
        Check(panel.Title == "Pasteory", "Load the native WPF history panel and resources");
        if (args.Contains("--system-clipboard"))
        {
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
                if (NativeMethods.OwnsClipboard()) Clipboard.Clear();
            }
        }
        Console.WriteLine("Windows clipboard format and WPF checks passed.");
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
    }
}
