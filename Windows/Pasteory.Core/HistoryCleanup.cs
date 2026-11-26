using System.Text;

namespace Pasteory.Core;

public sealed record HistoryCleanupEntry(Guid Id, string Title, DateTimeOffset LastUsedAt, long Bytes, ClipKind Kind);

public sealed class HistoryCleanupPreview
{
    internal HistoryCleanupPreview(DateTimeOffset cutoff, long minimumBytes, List<HistoryCleanupEntry> entries,
        List<Clip> snapshots, Dictionary<string, LocalStorage.FileSize> files)
    {
        Cutoff = cutoff;
        MinimumBytes = minimumBytes;
        Entries = entries.AsReadOnly();
        Snapshots = snapshots;
        Files = files;
    }

    public DateTimeOffset Cutoff { get; }
    public long MinimumBytes { get; }
    public IReadOnlyList<HistoryCleanupEntry> Entries { get; }
    public long ReclaimableBytes => Files.Values.Sum(file => file.ReclaimableBytes);
    internal List<Clip> Snapshots { get; }
    internal Dictionary<string, LocalStorage.FileSize> Files { get; }
}

public sealed record HistoryCleanupResult(int DeletedCount, long ReclaimedBytes, int FailedFiles);

public sealed partial class HistoryStore
{
    public Task<HistoryCleanupPreview> PreviewCleanupAsync(DateTimeOffset cutoff, long minimumBytes,
        CancellationToken cancellation = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(minimumBytes);
        var clips = Clips;
        var rows = catalogRows;
        return Task.Run(() => PreviewCleanup(clips, rows, cutoff, minimumBytes, cancellation), cancellation);
    }

    public HistoryCleanupResult CleanHistory(HistoryCleanupPreview preview)
    {
        var current = PreviewCleanup(Clips, catalogRows, preview.Cutoff, preview.MinimumBytes);
        if (preview.Snapshots.Count != current.Snapshots.Count ||
            !preview.Snapshots.Zip(current.Snapshots).All(pair => ReferenceEquals(pair.First, pair.Second)) ||
            !preview.Entries.SequenceEqual(current.Entries) ||
            preview.Files.Count != current.Files.Count ||
            preview.Files.Any(file => !current.Files.TryGetValue(file.Key, out var size) || size != file.Value))
            throw new IOException("History changed after the preview. Open a new preview to continue.");
        if (current.Entries.Count == 0) return new(0, 0, 0);

        Commit(Remove(current.Entries.Select(entry => entry.Id)), discardOrphans: false);
        long reclaimed = 0;
        int failed = 0;
        foreach (var (path, file) in current.Files)
        {
            if (InspectManagedFile(path) != file) { failed++; continue; }
            try
            {
                File.Delete(path);
                reclaimed += file.ReclaimableBytes;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { failed++; }
        }
        return new(current.Entries.Count, reclaimed, failed);
    }

    private HistoryCleanupPreview PreviewCleanup(IReadOnlyList<Clip> clips, Dictionary<Guid, CatalogRow> rows,
        DateTimeOffset cutoff, long minimumBytes, CancellationToken cancellation = default)
    {
        var selected = new List<Clip>();
        var entries = new List<HistoryCleanupEntry>();
        var candidates = new Dictionary<string, LocalStorage.FileSize>(StringComparer.OrdinalIgnoreCase);
        var sizes = new Dictionary<string, LocalStorage.FileSize?>(StringComparer.OrdinalIgnoreCase);
        var groupMembers = clips.Where(clip => clip.Kind == ClipKind.Aggregate).SelectMany(clip => clip.Members).ToHashSet();
        var ordered = clips.Where(clip => clip.Kind != ClipKind.Aggregate && !clip.Pinned && !clip.Favorite &&
            clip.CollectionIds.Length == 0 && string.IsNullOrWhiteSpace(clip.Group) && !groupMembers.Contains(clip.Id))
            .Select(clip => (Clip: clip, Used: ClipActivity.LastUsed(clip)))
            .Where(item => item.Used < cutoff).OrderBy(item => item.Used).ThenBy(item => item.Clip.Id);
        foreach (var (clip, used) in ordered)
        {
            cancellation.ThrowIfCancellationRequested();
            var packed = rows.GetValueOrDefault(clip.Id)?.Packed;
            long bytes = clip.Files.Sum(path => (long)Encoding.UTF8.GetByteCount(path));
            if (packed is null)
                bytes += Utf8Bytes(clip.Text) + Utf8Bytes(clip.Html) + Utf8Bytes(clip.Rtf);
            var files = StoredPaths(clip, packed).ToArray();
            foreach (string file in files)
            {
                if (!sizes.TryGetValue(file, out var size))
                    sizes[file] = size = InspectManagedFile(file);
                bytes += size?.Length ?? 0;
            }
            if (bytes <= minimumBytes) continue;
            string title = clip.DisplayTitle;
            if (title.Length == 0) title = clip.PlainText ?? "";
            if (title.Length > 160) title = title[..157] + "…";
            entries.Add(new(clip.Id, title, used, bytes, clip.Kind));
            selected.Add(clip);
            foreach (string file in files)
                if (sizes[file] is { } size) candidates[file] = size;
        }

        if (candidates.Count > 0)
        {
            var selectedIds = selected.Select(clip => clip.Id).ToHashSet();
            foreach (var clip in clips)
            {
                cancellation.ThrowIfCancellationRequested();
                if (selectedIds.Contains(clip.Id)) continue;
                foreach (string path in StoredPaths(clip, rows.GetValueOrDefault(clip.Id)?.Packed))
                    candidates.Remove(path);
            }
        }
        return new(cutoff, minimumBytes, entries, selected, candidates);
    }

    private IEnumerable<string> StoredPaths(Clip clip, PackedPayload? packed)
    {
        if (clip.HasImage) yield return ImagePath(clip);
        if (packed is not null) yield return ArchivePath(packed.Hash);
        foreach (var rep in clip.OriginalRepresentations.DistinctBy(rep => rep.Hash))
            yield return RepresentationPath(rep);
    }

    private static long Utf8Bytes(string? value) => value is null ? 0 : Encoding.UTF8.GetByteCount(value);

    private static LocalStorage.FileSize? InspectManagedFile(string path) =>
        LocalStorage.IsOrdinaryDirectory(Path.GetDirectoryName(path)!) ? LocalStorage.Inspect(path) : null;

    private static void DiscardManagedFile(string path)
    {
        if (LocalStorage.IsOrdinaryDirectory(Path.GetDirectoryName(path)!) &&
            LocalStorage.Attributes(path) is { } flags && (flags & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0)
            LocalJson.Discard(path);
    }
}
