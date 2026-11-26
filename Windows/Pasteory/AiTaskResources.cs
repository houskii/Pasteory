using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed record AiResource(string Name, string Path, string MimeType, long Length, DateTime LastWriteUtc);
internal sealed record AiResourceMessage(string role, object[] content);
internal sealed record AiResourceReply(string Content, AiResourceMessage? Attachment = null);

internal static class AiTaskResources
{
    private const int MaxTextBytes = 512 * 1024;
    private const int MaxBinaryBytes = 4 * 1024 * 1024;
    private static readonly HashSet<string> TextTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        ".txt", ".md", ".csv", ".tsv", ".json", ".xml", ".yml", ".yaml", ".ini", ".toml", ".log", ".cs", ".py",
        ".js", ".ts", ".swift", ".java", ".kt", ".cpp", ".c", ".h", ".css", ".html", ".sql", ".rs", ".go", ".sh", ".ps1"
    };

    internal static readonly object Definition = new
    {
        type = "function",
        function = new
        {
            name = "read_local_resource",
            description = "Read a resource already referenced by this task. Resource indexes start at zero. Text uses character offsets. One optional image or PDF may be provided per batch.",
            parameters = new
            {
                type = "object",
                properties = new { id = new { type = "string" }, index = new { type = "integer" }, offset = new { type = "integer" } },
                required = new[] { "id", "index", "offset" }
            }
        }
    };

    internal static Dictionary<Guid, AiResource[]> Build(string root, IEnumerable<Clip> clips)
    {
        var result = new Dictionary<Guid, AiResource[]>();
        foreach (var clip in clips)
        {
            var files = clip.Files.Select(path => Describe(path)).OfType<AiResource>().Take(20).ToList();
            if (clip.HasImage && Describe(Path.Combine(root, "images", clip.ImageFileName), "Clipboard image." + clip.ImageExtension) is { } image)
                files.Insert(0, image);
            if (files.Count > 0) result.Add(clip.Id, files.ToArray());
        }
        return result;
    }

    private static AiResource? Describe(string path, string? name = null)
    {
        if (!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal) ||
            path.IndexOf(':', 2) >= 0) return null;
        try
        {
            var file = new FileInfo(path);
            string ext = file.Extension.ToLowerInvariant();
            string? mime = ext switch
            {
                ".png" => "image/png", ".jpg" or ".jpeg" => "image/jpeg", ".webp" => "image/webp", ".gif" => "image/gif",
                ".tif" or ".tiff" => "image/tiff", ".bmp" => "image/bmp", ".heic" or ".heif" => "image/heic", ".avif" => "image/avif",
                ".pdf" => "application/pdf", _ => TextTypes.Contains(ext) ? "text/plain" : null
            };
            if (mime is null || !file.Exists || file.Length > (mime == "text/plain" ? MaxTextBytes : MaxBinaryBytes) ||
                (file.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Offline)) != 0) return null;
            return new AiResource(name ?? file.Name, file.FullName, mime, file.Length, file.LastWriteTimeUtc);
        }
        catch (Exception error) when (App.IsLocalError(error) || error is ArgumentException or NotSupportedException) { return null; }
    }

    internal static AiResourceReply Read(AiResource file, int offset, bool allowAttachment)
    {
        var current = Describe(file.Path, file.Name);
        if (current != file) return Error("The file changed after this task was prepared");
        using var stream = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length != file.Length) return Error("The file changed after this task was prepared");
        if (file.MimeType == "text/plain")
        {
            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            string body = reader.ReadToEnd();
            if (body.Contains('\0') || AiTasks.MightBeSecret(body)) return Error("The resource contains unsupported or sensitive content");
            int start = Math.Clamp(offset, 0, body.Length);
            int length = Math.Min(4000, body.Length - start);
            return new AiResourceReply(JsonSerializer.Serialize(new
            {
                file.Name, offset = start, text = body.Substring(start, length),
                nextOffset = start + length < body.Length ? (int?)(start + length) : null
            }));
        }
        if (!allowAttachment) return Error("This batch already contains a binary resource");
        var bytes = new byte[(int)file.Length];
        stream.ReadExactly(bytes);
        string mime = file.MimeType;
        if (mime is "image/tiff" or "image/bmp" or "image/heic" or "image/avif")
        {
            try
            {
                var (width, height) = ClipboardImage.Dimensions(bytes);
                if (width <= 0 || height <= 0 || (long)width * height > 48_000_000)
                    return Error("The image format is unavailable or its dimensions exceed the resource limit");
                bytes = ClipboardImage.EncodePng(ClipboardImage.Preview(bytes, 900, width, height));
                if (bytes.Length > MaxBinaryBytes) return Error("The converted image exceeds the resource limit");
                mime = "image/png";
            }
            catch (Exception error) when (ClipboardImage.DecoderFailure(error)) { return Error("The image encoding is unavailable"); }
        }
        string encoded = $"data:{mime};base64,{Convert.ToBase64String(bytes)}";
        object item = file.MimeType == "application/pdf" ? new { type = "file", file = new { filename = file.Name, file_data = encoded } } :
            new { type = "image_url", image_url = new { url = encoded, detail = "low" } };
        var message = new AiResourceMessage("user", [new { type = "text", text = "Requested Pasteory resource: " + file.Name }, item]);
        return new AiResourceReply(JsonSerializer.Serialize(new { file.Name, MimeType = mime, attached = true }), message);
    }

    private static AiResourceReply Error(string text) => new(JsonSerializer.Serialize(new { error = text }));
}
