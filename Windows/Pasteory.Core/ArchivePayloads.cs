using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace Pasteory.Core;

public sealed partial class HistoryStore
{
    private sealed record PackedPayload(string Hash, int Size);
    private sealed record ArchiveText(string? Text, string? Html, string? Rtf);
    private string ArchivePath(string hash) => Path.Combine(archiveDirectory, hash + ".br");

    public void SetAiGroupCompression(Guid id, bool enabled)
    {
        Commit(Clips.ToList(), Collections.Select(group => group.IsAi && group.Id == id
            ? group with { PackPayloads = enabled } : group).ToList());
    }

    private PackedPayload? PackForDisk(Clip clip, HashSet<Guid> compress, CatalogRow? previous)
    {
        bool eligible = clip.ArchivedAt is not null || clip.CollectionIds.Length > 0 &&
            clip.CollectionIds.All(compress.Contains) && !clip.Pinned && !clip.Favorite && clip.TrashedAt is null;
        if (!eligible || clip.Text is null && clip.Html is null && clip.Rtf is null) return null;
        if (previous is { Packed: { } packed } &&
            clip.Text == previous.Clip.Text && clip.Html == previous.Clip.Html && clip.Rtf == previous.Clip.Rtf)
            return packed;
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new ArchiveText(clip.Text, clip.Html, clip.Rtf));
        if (bytes.Length > 128 * 1024 * 1024) return null;
        string hash = Convert.ToHexString(SHA256.HashData(bytes));
        string path = ArchivePath(hash);
        if (!File.Exists(path))
            LocalJson.WriteFile(path, output =>
            {
                using var codec = new BrotliStream(output, CompressionLevel.Fastest, leaveOpen: true);
                codec.Write(bytes);
            });
        return new(hash, bytes.Length);
    }

    private Clip ReadPacked(Clip clip, PackedPayload entry)
    {
        if (entry.Hash is not { Length: 64 } || !entry.Hash.All(char.IsAsciiHexDigit) || entry.Size is < 1 or > 128 * 1024 * 1024)
            throw new JsonException("Invalid archived content reference.");
        using var file = File.OpenRead(ArchivePath(entry.Hash));
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
            if (!LocalStorage.IsOrdinaryDirectory(archiveDirectory)) return;
            foreach (string file in Directory.EnumerateFiles(archiveDirectory, "*.br"))
            {
                string name = Path.GetFileNameWithoutExtension(file);
                if (name.Length == 64 && name.All(char.IsAsciiHexDigit) && !retained.Contains(name)) DiscardManagedFile(file);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
