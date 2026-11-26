using System;
using System.Buffers.Binary;
using System.Collections.Specialized;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Media.Imaging;
using Pasteory.Core;

namespace Pasteory.Windows;

internal static class ClipboardFormats
{
    internal const string Exclude = "ExcludeClipboardContentFromMonitorProcessing";
    internal const string IncludeInHistory = "CanIncludeInClipboardHistory";
    internal const string UploadToCloud = "CanUploadToCloudClipboard";
    internal const int MaxTextBytes = 10 * 1024 * 1024;
    internal const int MaxImageBytes = 16 * 1024 * 1024;
    private const long MaxPixels = 16_000_000;
    private static readonly (ClipImageFormat Format, string[] Names)[] ImageFormats =
    [
        (ClipImageFormat.Png, ["PNG", "image/png"]),
        (ClipImageFormat.Jpeg, ["JFIF", "JPEG", "image/jpeg"]),
        (ClipImageFormat.Tiff, [DataFormats.Tiff, "image/tiff"]),
        (ClipImageFormat.Gif, ["GIF", "image/gif"]),
        (ClipImageFormat.Bmp, ["BMP", "image/bmp"]),
        (ClipImageFormat.WebP, ["WEBP", "image/webp"]),
        (ClipImageFormat.Heif, ["image/heic", "image/heif"]),
        (ClipImageFormat.Avif, ["image/avif"])
    ];

    internal static (Clip Clip, byte[]? Image)? Read(IDataObject data, string source)
    {
        if (data.GetDataPresent(Exclude, false) || Disallowed(data, IncludeInHistory) ||
            Disallowed(data, UploadToCloud)) return null;

        string[] files = data.GetDataPresent(DataFormats.FileDrop, false) && data.GetData(DataFormats.FileDrop, false) is string[] paths
            ? paths : [];
        if (files.Length > 256 || files.Sum(path => (long)Encoding.UTF8.GetByteCount(path)) > MaxTextBytes) return null;
        string? text = ReadText(data, DataFormats.UnicodeText) ?? ReadText(data, DataFormats.Text);
        string? html = ReadText(data, DataFormats.Html);
        string? rtf = ReadText(data, DataFormats.Rtf);
        bool chat = ChatContext.IsChatApp(source);
        bool shellTransfer = files.Length > 0 && (source.Equals("explorer", StringComparison.OrdinalIgnoreCase) ||
            !chat && data.GetDataPresent("Preferred DropEffect", false));
        var image = shellTransfer ? null : ReadImage(data, allowBitmap: files.Length == 0 || chat);
        if (image is not null)
        {
            bool mixed = !string.IsNullOrEmpty(text) || html is not null || rtf is not null;
            return (new Clip
            {
                Kind = mixed ? ClipKind.Mixed : ClipKind.Image, Source = source, Text = text, Html = html, Rtf = rtf, Files = files,
                ImageHash = Convert.ToHexString(SHA256.HashData(image.Bytes)), ImageSize = image.Bytes.Length,
                ImageFormat = image.Format, ImageWidth = image.Width, ImageHeight = image.Height
            }, image.Bytes);
        }
        if (files.Length > 0)
            return (new Clip { Kind = ClipKind.Files, Source = source, Files = files, Text = text, Html = html, Rtf = rtf }, null);
        if (!string.IsNullOrEmpty(text) || html is not null || rtf is not null)
        {
            var (kind, language) = TextTools.Classify(text);
            return (new Clip { Kind = kind, Source = source, Text = text, Html = html, Rtf = rtf, CodeLanguage = language }, null);
        }
        return null;
    }

    internal static DataObject Create(Clip clip, bool plainText, byte[]? image)
    {
        var data = new DataObject();
        if (plainText)
        {
            if (clip.PlainClipboardText is { Length: > 0 } text) data.SetText(text, TextDataFormat.UnicodeText);
        }
        else
        {
            if (clip.Text is { } text) data.SetText(text, TextDataFormat.UnicodeText);
            if (clip.Html is not null) data.SetText(clip.Html, TextDataFormat.Html);
            if (clip.Rtf is not null) data.SetText(clip.Rtf, TextDataFormat.Rtf);
            if (clip.Files.Length > 0)
            {
                if (clip.Files.All(Path.IsPathFullyQualified))
                {
                    var paths = new StringCollection();
                    paths.AddRange(clip.Files);
                    data.SetFileDropList(paths);
                }
                else if (clip.Text is null && clip.PlainText is { } references)
                    data.SetText(references, TextDataFormat.UnicodeText);
            }
            if (image is not null)
            {
                if (ClipboardImage.ClipboardBitmap(image) is { } bitmap) data.SetImage(bitmap);
                foreach (string format in ImageFormats.First(entry => entry.Format == clip.ImageFormat).Names)
                    data.SetData(format, new MemoryStream(image, writable: false), false);
            }
        }

        data.SetData(Exclude, new MemoryStream(new byte[4], writable: false), false);
        data.SetData(IncludeInHistory, new MemoryStream(new byte[4], writable: false), false);
        data.SetData(UploadToCloud, new MemoryStream(new byte[4], writable: false), false);
        return data;
    }

    internal static string WindowsHtml(string html)
    {
        if (html.StartsWith("Version:", StringComparison.OrdinalIgnoreCase)) return html;
        const string headers = "Version:1.0\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
        const string start = "<html><body><!--StartFragment-->";
        const string end = "<!--EndFragment--></body></html>";
        int offset = string.Format(System.Globalization.CultureInfo.InvariantCulture, headers, 0, 0, 0, 0).Length;
        int startFragment = offset + start.Length;
        int endFragment = startFragment + Encoding.UTF8.GetByteCount(html);
        return string.Format(System.Globalization.CultureInfo.InvariantCulture, headers, offset, endFragment + end.Length,
            startFragment, endFragment) + start + html + end;
    }

    private static string? ReadText(IDataObject data, string format)
    {
        if (!data.GetDataPresent(format, false) || data.GetData(format, false) is not string text)
            return null;
        return text.Length <= MaxTextBytes && Encoding.UTF8.GetByteCount(text) <= MaxTextBytes ? text : null;
    }

    private static bool Disallowed(IDataObject data, string format)
    {
        if (!data.GetDataPresent(format, false)) return false;
        return data.GetData(format, false) switch
        {
            int value => value == 0,
            uint value => value == 0,
            byte[] bytes when bytes.Length >= 4 => BinaryPrimitives.ReadUInt32LittleEndian(bytes) == 0,
            MemoryStream stream when stream.Length >= 4 => BinaryPrimitives.ReadUInt32LittleEndian(stream.ToArray()) == 0,
            _ => true
        };
    }

    private static ClipboardImage? ReadImage(IDataObject data, bool allowBitmap)
    {
        var offered = data.GetFormats(autoConvert: false).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var (format, names) in ImageFormats)
        {
            foreach (string name in names)
            {
                if (!offered.TryGetValue(name, out var actual)) continue;
                byte[]? bytes = data.GetData(actual, false) switch
                {
                    byte[] value when value.Length <= MaxImageBytes => value,
                    MemoryStream stream when stream.Length <= MaxImageBytes => stream.ToArray(),
                    _ => null
                };
                if (bytes is not null && ClipboardImage.Read(bytes, MaxPixels) is { } image && image.Format == format) return image;
            }
        }

        if (!allowBitmap || !data.GetDataPresent(DataFormats.Bitmap) ||
            data.GetData(DataFormats.Bitmap) is not BitmapSource bitmap ||
            !IsAllowedSize(bitmap.PixelWidth, bitmap.PixelHeight)) return null;

        byte[] png = ClipboardImage.EncodePng(bitmap);
        return png.Length <= MaxImageBytes ? new(ClipImageFormat.Png, png, bitmap.PixelWidth, bitmap.PixelHeight) : null;
    }

    private static bool IsAllowedSize(long width, long height) =>
        width > 0 && height > 0 && width <= MaxPixels && height <= MaxPixels / width;
}
