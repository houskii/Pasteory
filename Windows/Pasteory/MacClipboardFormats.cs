using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Pasteory.Core;

namespace Pasteory.Windows;

internal static class MacClipboardFormats
{
    internal sealed record Projection(string? Text, string? Html, string? Rtf, string[] Files, ClipboardImage? Image)
    {
        internal bool IsEmpty => Text is null && Html is null && Rtf is null && Files.Length == 0 && Image is null;
    }

    internal static Projection Project(ClipboardItem item, Func<ClipboardRepresentation, byte[]> read, bool includeImage)
    {
        string? text = null, html = null, rtf = null;
        var files = new List<string>();
        ClipboardImage? image = null;
        foreach (var representation in item.Representations.OrderBy(rep => Priority(rep.Uti)))
        {
            switch (representation.Uti)
            {
                case "public.utf8-plain-text" or "public.plain-text" or "public.text" or "NSStringPboardType" when text is null:
                    text = Encoding.UTF8.GetString(read(representation)).TrimStart('\uFEFF');
                    break;
                case "public.utf16-plain-text" when text is null:
                    var bytes = read(representation);
                    text = (bytes.AsSpan().StartsWith(new byte[] { 0xfe, 0xff }) ? Encoding.BigEndianUnicode : Encoding.Unicode)
                        .GetString(bytes).TrimStart('\uFEFF');
                    break;
                case "public.url" when text is null:
                    text = Encoding.UTF8.GetString(read(representation)).TrimEnd('\0');
                    break;
                case "public.html" when html is null:
                    html = ClipboardFormats.WindowsHtml(Encoding.UTF8.GetString(read(representation)));
                    break;
                case "public.rtf" when rtf is null:
                    rtf = Encoding.Latin1.GetString(read(representation));
                    break;
                case "public.file-url":
                    string file = Encoding.UTF8.GetString(read(representation)).Trim().TrimEnd('\0');
                    if (Uri.TryCreate(file, UriKind.Absolute, out var reference) && reference.IsFile)
                        file = reference.IsUnc || LooksLikeDrive(reference.AbsolutePath) ? reference.LocalPath :
                            Uri.UnescapeDataString(reference.AbsolutePath);
                    if (file.Length > 0) files.Add(file);
                    break;
                case var type when includeImage && image is null && Priority(type) >= 10 && Priority(type) < int.MaxValue:
                    image = ClipboardImage.Read(read(representation), 48_000_000);
                    break;
            }
        }
        return new(text, html, rtf, files.ToArray(), image);
    }

    internal static bool CanProject(ClipboardItem item) => item.Representations.Any(rep => Priority(rep.Uti) < int.MaxValue);

    private static bool LooksLikeDrive(string path) => path is ['/', _, ':', ..] || path is [_, ':', ..];

    private static int Priority(string uti) => uti switch
    {
        "public.utf8-plain-text" or "public.plain-text" or "public.text" or "NSStringPboardType" => 0,
        "public.utf16-plain-text" => 1, "public.url" => 2, "public.html" or "public.rtf" or "public.file-url" => 3,
        "public.png" => 10, "public.jpeg" => 11, "public.heic" or "public.heif" => 12, "public.tiff" => 13,
        "com.compuserve.gif" or "com.microsoft.bmp" or "org.webmproject.webp" or "public.webp" or "public.avif" => 14,
        _ => int.MaxValue
    };
}
