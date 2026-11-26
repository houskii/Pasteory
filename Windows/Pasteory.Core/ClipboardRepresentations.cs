using System.Security.Cryptography;

namespace Pasteory.Core;

public sealed partial class HistoryStore
{
    public const int MaximumRepresentationBytes = 64 * 1024 * 1024;

    public byte[] ReadRepresentation(ClipboardRepresentation representation)
    {
        string path = RepresentationPath(representation);
        if (InspectManagedFile(path) is not { } file || file.Length != representation.Size)
            throw new InvalidDataException("An original clipboard representation is missing or damaged.");
        using var stream = File.OpenRead(path);
        return ReadRepresentation(stream, representation);
    }

    private string RepresentationPath(ClipboardRepresentation representation) =>
        Path.Combine(representationDirectory, RepresentationFileName(representation));

    private static string RepresentationFileName(ClipboardRepresentation representation)
    {
        if (representation.Hash is not { Length: 64 } || !representation.Hash.All(char.IsAsciiHexDigit) ||
            representation.Size is < 0 or > MaximumRepresentationBytes)
            throw new InvalidDataException("Invalid clipboard representation reference.");
        return representation.Hash.ToUpperInvariant() + ".bin";
    }

    private static byte[] ReadRepresentation(Stream stream, ClipboardRepresentation representation)
    {
        var bytes = new byte[representation.Size];
        stream.ReadExactly(bytes);
        if (stream.ReadByte() >= 0 || !MatchesRepresentation(bytes, representation))
            throw new InvalidDataException("Clipboard representation checksum mismatch.");
        return bytes;
    }

    private static bool MatchesRepresentation(byte[] bytes, ClipboardRepresentation representation) =>
        bytes.Length == representation.Size &&
        Convert.ToHexString(SHA256.HashData(bytes)).Equals(representation.Hash, StringComparison.OrdinalIgnoreCase);

    private void RemoveOrphanedRepresentations(IEnumerable<Clip> clips)
    {
        if (!LocalStorage.IsOrdinaryDirectory(representationDirectory)) return;
        var retained = clips.SelectMany(clip => clip.OriginalRepresentations).Select(RepresentationFileName)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (string path in Directory.EnumerateFiles(representationDirectory, "*.bin"))
            {
                string name = Path.GetFileNameWithoutExtension(path);
                if (name is { Length: 64 } && name.All(char.IsAsciiHexDigit) && !retained.Contains(Path.GetFileName(path)))
                    DiscardManagedFile(path);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
