namespace Pasteory.Core;

public sealed class HistoryStore
{
    private const long MaxIndexBytes = 12 * 1024 * 1024;
    private readonly string indexPath;
    private readonly string imageDirectory;
    private readonly int maxClips;
    private readonly long maxBytes;

    public IReadOnlyList<Clip> Clips { get; private set; }

    public HistoryStore(string dataDirectory, int maxClips = 200, long maxBytes = 96 * 1024 * 1024)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxClips);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxBytes);
        this.maxClips = maxClips;
        this.maxBytes = maxBytes;
        indexPath = Path.Combine(dataDirectory, "history.json");
        imageDirectory = Path.Combine(dataDirectory, "images");
        Clips = (LocalJson.Read<Clip[]>(indexPath) ?? []).ToList().AsReadOnly();
        RemoveOrphanedImages();
    }

    public bool Capture(Clip clip, byte[]? png = null)
    {
        if (clip.Kind == ClipKind.Image && (png is null || png.Length != clip.ImageSize))
            throw new ArgumentException("Image bytes do not match the clip.", nameof(png));

        var duplicate = Clips.FirstOrDefault(existing => existing.SameContent(clip));
        var next = Clips.Where(existing => existing.Id != duplicate?.Id).ToList();
        next.Insert(0, duplicate is null ? clip : duplicate with
        {
            Source = clip.Source,
            CapturedAt = clip.CapturedAt
        });

        long size = next.Sum(item => item.Size);
        long indexSize = size - next.Sum(item => (long)item.ImageSize);
        for (int index = next.Count - 1; index > 0 && OverLimit(); index--)
        {
            if (next[index].Pinned || next[index].Favorite) continue;
            size -= next[index].Size;
            indexSize -= next[index].IndexSize;
            next.RemoveAt(index);
        }
        if (OverLimit()) return false;

        bool OverLimit() => next.Count > maxClips || size > maxBytes || indexSize > MaxIndexBytes;

        string? newImage = null;
        if (png is not null)
        {
            string path = ImagePath(next[0].Id);
            if (!File.Exists(path))
            {
                LocalJson.WriteFile(path, stream => stream.Write(png));
                if (duplicate is null) newImage = path;
            }
        }
        try { Commit(next); }
        catch
        {
            if (newImage is not null) LocalJson.Discard(newImage);
            throw;
        }
        return true;
    }

    public bool Edit(Clip clip, string title, string note, string group, bool pinned, bool favorite)
    {
        var next = Clips.Select(existing => existing.Id == clip.Id
            ? existing with { Title = title, Note = note, Group = group, Pinned = pinned, Favorite = favorite }
            : existing).ToList();
        if (next.Sum(item => item.Size) > maxBytes || next.Sum(item => item.IndexSize) > MaxIndexBytes)
            return false;
        Commit(next);
        return true;
    }

    public void Delete(Clip clip) => Commit(Clips.Where(existing => existing.Id != clip.Id).ToList());

    public void ClearUnprotected() => Commit(Clips.Where(clip => clip.Favorite || clip.Pinned).ToList());

    public byte[] ReadImage(Clip clip) => File.ReadAllBytes(ImagePath(clip.Id));

    private string ImagePath(Guid id) => Path.Combine(imageDirectory, id.ToString("N") + ".png");

    private void Commit(List<Clip> next)
    {
        LocalJson.Write(indexPath, next);
        var retained = next.Select(clip => clip.Id).ToHashSet();
        foreach (var clip in Clips)
        {
            if (clip.Kind == ClipKind.Image && !retained.Contains(clip.Id))
                LocalJson.Discard(ImagePath(clip.Id));
        }
        Clips = next.AsReadOnly();
    }

    private void RemoveOrphanedImages()
    {
        if (!Directory.Exists(imageDirectory)) return;
        var retained = Clips.Where(clip => clip.Kind == ClipKind.Image)
            .Select(clip => clip.Id).ToHashSet();
        foreach (string path in Directory.EnumerateFiles(imageDirectory, "*.png"))
        {
            if (Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "N", out var id) && !retained.Contains(id))
                LocalJson.Discard(path);
        }
    }
}
