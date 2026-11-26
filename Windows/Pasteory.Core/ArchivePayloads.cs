using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace Pasteory.Core;

public sealed partial class HistoryStore
{
    private sealed record PackedPayload(string Hash, int Size);
    private sealed record ArchiveText(string? Text, string? Html, string? Rtf);

    public void SetAiGroupCompression(Guid id, bool enabled)
    {
        Commit(Clips.ToList(), Collections.Select(group => group.IsAi && group.Id == id
            ? group with { PackPayloads = enabled } : group).ToList());
    }

    private List<Clip> PackForDisk(List<Clip> clips, List<ClipCollection> groups, Dictionary<Guid, PackedPayload> manifest)
    {
        var compress = groups.Where(group => group.PackPayloads).Select(group => group.Id).ToHashSet();
        return clips.Select(clip =>
        {
            bool eligible = clip.ArchivedAt is not null || clip.CollectionIds.Length > 0 &&
                clip.CollectionIds.All(compress.Contains) && !clip.Pinned && !clip.Favorite && clip.TrashedAt is null;
            if (!eligible || clip.Text is null && clip.Html is null && clip.Rtf is null) return clip;
            byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new ArchiveText(clip.Text, clip.Html, clip.Rtf));
            if (bytes.Length > 128 * 1024 * 1024) return clip;
            string hash = Convert.ToHexString(SHA256.HashData(bytes));
            string path = Path.Combine(archiveDirectory, hash + ".br");
            if (!File.Exists(path))
                LocalJson.WriteFile(path, output =>
                {
                    using var codec = new BrotliStream(output, CompressionLevel.Fastest, leaveOpen: true);
                    codec.Write(bytes);
                });
            manifest[clip.Id] = new(hash, bytes.Length);
            return clip with { Text = null, Html = null, Rtf = null };
        }).ToList();
    }

    private Clip ReadPacked(Clip clip, PackedPayload entry)
    {
        if (entry.Hash is not { Length: 64 } || !entry.Hash.All(char.IsAsciiHexDigit) || entry.Size is < 1 or > 128 * 1024 * 1024)
            throw new JsonException("Invalid archived content reference.");
        using var file = File.OpenRead(Path.Combine(archiveDirectory, entry.Hash + ".br"));
        using var decompressed = new BrotliStream(file, CompressionMode.Decompress);
        byte[] bytes = new byte[entry.Size];
        decompressed.ReadExactly(bytes);
        if (decompressed.ReadByte() >= 0 || !Convert.ToHexString(SHA256.HashData(bytes)).Equals(entry.Hash, StringComparison.OrdinalIgnoreCase))
            throw new JsonException("Archived content checksum mismatch.");
        var content = JsonSerializer.Deserialize<ArchiveText>(bytes) ?? throw new JsonException("Missing archived content.");
        return clip with { Text = content.Text, Html = content.Html, Rtf = content.Rtf };
    }

    private void RemoveOrphanedArchives(HashSet<string> retained)
    {
        try
        {
            if (!Directory.Exists(archiveDirectory)) return;
            foreach (string file in Directory.EnumerateFiles(archiveDirectory, "*.br"))
            {
                string name = Path.GetFileNameWithoutExtension(file);
                if (name.Length == 64 && name.All(char.IsAsciiHexDigit) && !retained.Contains(name)) LocalJson.Discard(file);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
