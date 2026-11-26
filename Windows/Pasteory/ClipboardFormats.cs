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
    private const string Png = "PNG";
    private const int MaxTextBytes = 1024 * 1024;
    private const int MaxImageBytes = 16 * 1024 * 1024;
    private const long MaxPixels = 16_000_000;

    internal static (Clip Clip, byte[]? Image)? Read(IDataObject data, string source)
    {
        if (data.GetDataPresent(Exclude, false) || Disallowed(data, IncludeInHistory) ||
            Disallowed(data, UploadToCloud)) return null;

        if (data.GetDataPresent(DataFormats.FileDrop, false) &&
            data.GetData(DataFormats.FileDrop, false) is string[] files && files.Length > 0)
        {
            if (files.Length > 256 || files.Sum(path => (long)Encoding.UTF8.GetByteCount(path)) > MaxTextBytes)
                return null;
            return (new Clip { Kind = ClipKind.Files, Source = source, Files = files }, null);
        }

        string? text = ReadText(data, DataFormats.UnicodeText) ?? ReadText(data, DataFormats.Text);
        string? html = ReadText(data, DataFormats.Html);
        string? rtf = ReadText(data, DataFormats.Rtf);
        var image = ReadImage(data);
        if (image is not null)
        {
            using var stream = new MemoryStream(image, writable: false);
            var frame = BitmapFrame.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
            bool mixed = !string.IsNullOrEmpty(text) || html is not null || rtf is not null;
            return (new Clip
            {
                Kind = mixed ? ClipKind.Mixed : ClipKind.Image, Source = source, Text = text, Html = html, Rtf = rtf,
                ImageHash = Convert.ToHexString(SHA256.HashData(image)), ImageSize = image.Length,
                ImageWidth = frame.PixelWidth, ImageHeight = frame.PixelHeight
            }, image);
        }
        if (!string.IsNullOrEmpty(text) || html is not null || rtf is not null)
        {
            var (kind, language) = TextTools.Classify(text);
            return (new Clip { Kind = kind, Source = source, Text = text, Html = html, Rtf = rtf, CodeLanguage = language }, null);
        }
        return null;
    }

    internal static DataObject Create(Clip clip, bool plainText, byte[]? png)
    {
        var data = new DataObject();
        if (plainText)
        {
            if (clip.PlainText is { } text) data.SetText(text, TextDataFormat.UnicodeText);
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
            if (png is not null)
            {
                using var stream = new MemoryStream(png, writable: false);
                data.SetImage(BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad));
                data.SetData(Png, new MemoryStream(png, writable: false), false);
            }
        }

        data.SetData(Exclude, new MemoryStream(new byte[4], writable: false), false);
        data.SetData(IncludeInHistory, new MemoryStream(new byte[4], writable: false), false);
        data.SetData(UploadToCloud, new MemoryStream(new byte[4], writable: false), false);
        return data;
    }

    internal static (int Width, int Height) PngDimensions(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 24 || bytes[0] != 137 || !bytes.Slice(1, 7).SequenceEqual("PNG\r\n\x1a\n"u8) ||
            !bytes.Slice(12, 4).SequenceEqual("IHDR"u8)) return (0, 0);
        return (Math.Max(0, BinaryPrimitives.ReadInt32BigEndian(bytes[16..])),
            Math.Max(0, BinaryPrimitives.ReadInt32BigEndian(bytes[20..])));
    }

    internal static BitmapSource DecodePreview(byte[] png, int maximumDimension = 500)
    {
        using var stream = new MemoryStream(png, writable: false);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        var (width, height) = PngDimensions(png);
        if (width >= height && width > maximumDimension) image.DecodePixelWidth = maximumDimension;
        else if (height > maximumDimension) image.DecodePixelHeight = maximumDimension;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
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

    private static byte[]? ReadImage(IDataObject data)
    {
        if (data.GetDataPresent(Png, false))
        {
            byte[]? png = data.GetData(Png, false) switch
            {
                byte[] bytes => bytes,
                MemoryStream stream when stream.Length <= MaxImageBytes => stream.ToArray(),
                _ => null
            };
            if (png is { Length: >= 24 and <= MaxImageBytes })
            {
                var (width, height) = PngDimensions(png);
                if (IsAllowedSize(width, height)) return png;
            }
        }

        if (!data.GetDataPresent(DataFormats.Bitmap) ||
            data.GetData(DataFormats.Bitmap) is not BitmapSource bitmap ||
            !IsAllowedSize(bitmap.PixelWidth, bitmap.PixelHeight)) return null;

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.Length <= MaxImageBytes ? output.ToArray() : null;
    }

    private static bool IsAllowedSize(long width, long height) =>
        width > 0 && height > 0 && width <= MaxPixels && height <= MaxPixels / width;
}
