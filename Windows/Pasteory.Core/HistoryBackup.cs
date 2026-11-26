using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace Pasteory.Core;

public sealed partial class HistoryStore
{
    private const int MaxImageBytes = 64 * 1024 * 1024;

    public void ExportBackup(string destination)
    {
        LocalJson.WriteFile(destination, file =>
        {
            using var zip = new ZipArchive(file, ZipArchiveMode.Create, leaveOpen: true);
            int version = Clips.Any(clip => clip.HasImage && clip.ImageFormat != ClipImageFormat.Png) ? 3 : 2;
            using (var index = zip.CreateEntry("pasteory-history.json").Open())
                JsonSerializer.Serialize(index, new LibraryState(Clips.ToList(), Collections.ToList(), Version: version));
            foreach (var clip in Clips.Where(clip => clip.HasImage))
            {
                using var image = File.OpenRead(ImagePath(clip));
                using var exported = zip.CreateEntry($"images/{clip.ImageFileName}", CompressionLevel.NoCompression).Open();
                image.CopyTo(exported);
            }
        });
    }

    public int ImportBackup(string source)
    {
        using var zip = ZipFile.OpenRead(source);
        var entry = zip.GetEntry("pasteory-history.json") ?? throw new InvalidDataException("Missing backup catalog.");
        using var index = entry.Open();
        var state = JsonSerializer.Deserialize<LibraryState>(index) ?? throw new InvalidDataException("Missing backup catalog.");
        if (state.Version is not (2 or 3) || state.Clips.Any(clip => !Enum.IsDefined(clip.ImageFormat) ||
                state.Version == 2 && clip.ImageFormat != ClipImageFormat.Png) ||
            state.Clips.Select(clip => clip.Id).Distinct().Count() != state.Clips.Count ||
            state.Collections.Select(group => group.Id).Distinct().Count() != state.Collections.Count)
            throw new InvalidDataException("Unsupported or invalid backup.");

        return ImportClips(state.Clips, state.Collections, clip =>
        {
            var entry = zip.GetEntry($"images/{clip.ImageFileName}");
            if (entry is null || entry.Length is < 1 or > MaxImageBytes || entry.Length != clip.ImageSize)
                throw new InvalidDataException("Missing or invalid image in backup.");
            using var payload = entry.Open();
            var image = new byte[(int)entry.Length];
            payload.ReadExactly(image);
            if (clip.ImageHash is { Length: 64 } hash &&
                !Convert.ToHexString(SHA256.HashData(image)).Equals(hash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Image checksum mismatch.");
            return image;
        });
    }

    public int ImportClips(IReadOnlyList<Clip> imported, IReadOnlyList<ClipCollection> importedGroups, Func<Clip, byte[]> readImage)
    {
        var groups = Collections.ToList();
        var validGroupIds = groups.Select(group => group.Id).ToHashSet();
        foreach (var group in importedGroups)
        {
            if (validGroupIds.Contains(group.Id)) continue;
            if (string.IsNullOrWhiteSpace(group.Name) || group.Rules is { } rules && !rules.IsValid())
                throw new InvalidDataException("Invalid group in backup.");
            string name = group.Name[..Math.Min(group.Name.Length, 70)];
            var baseName = name;
            for (int suffix = 2; groups.Any(item => item.Name.Equals(name, StringComparison.OrdinalIgnoreCase)); suffix++)
                name = $"{baseName} ({suffix})";
            groups.Add(group with { Name = name });
            validGroupIds.Add(group.Id);
        }

        var clips = Clips.ToList();
        var byId = Clips.ToDictionary(clip => clip.Id);
        var mapping = new Dictionary<Guid, Guid>();
        var written = new List<string>();
        int added = 0;
        try
        {
            foreach (var item in imported.OrderBy(clip => clip.Kind == ClipKind.Aggregate))
            {
                if (byId.ContainsKey(item.Id)) { mapping[item.Id] = item.Id; continue; }
                if (item.Kind != ClipKind.Aggregate && item.TrashedAt is null &&
                    clips.FirstOrDefault(clip => clip.TrashedAt is null && clip.SameContent(item)) is { } duplicate)
                {
                    mapping[item.Id] = duplicate.Id;
                    var merged = duplicate with { CollectionIds = duplicate.CollectionIds
                        .Concat(item.CollectionIds.Where(validGroupIds.Contains)).Distinct().ToArray() };
                    clips[clips.IndexOf(duplicate)] = merged;
                    byId[duplicate.Id] = merged;
                    continue;
                }
                var clip = item with
                {
                    CollectionIds = item.CollectionIds.Where(validGroupIds.Contains).Distinct().ToArray(),
                    Members = item.Members.Where(mapping.ContainsKey).Select(id => mapping[id]).Distinct().ToArray(),
                    LastSelectedMember = item.LastSelectedMember is { } selected && mapping.TryGetValue(selected, out var mapped) ? mapped : null
                };
                if (clip.HasImage)
                {
                    byte[] image = readImage(item);
                    string path = ImagePath(clip);
                    LocalJson.WriteFile(path, file => file.Write(image));
                    written.Add(path);
                }
                mapping[item.Id] = clip.Id;
                byId.Add(clip.Id, clip);
                clips.Add(clip);
                added++;
            }
            Commit(clips.OrderByDescending(clip => clip.CapturedAt).ToList(), groups);
        }
        catch
        {
            foreach (string path in written) LocalJson.Discard(path);
            throw;
        }
        return added;
    }
}
