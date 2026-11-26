using System.Text.Json;

namespace Pasteory.Core;

public sealed partial class HistoryStore
{
    private const long MaxActiveIndexBytes = 12 * 1024 * 1024;
    public const string CatalogFileName = "history.sqlite3";
    private readonly string catalogPath;
    private readonly string imageDirectory;
    private readonly string archiveDirectory;
    private readonly string representationDirectory;
    private readonly int maxClips;
    private readonly long maxBytes;
    private readonly bool archiveOverflow;

    public IReadOnlyList<Clip> Clips { get; private set; }
    public IReadOnlyList<ClipCollection> Collections { get; private set; }
    private AiUndoRecord? aiUndo;
    public bool CanUndoAi => aiUndo is not null;

    public HistoryStore(string dataDirectory, int maxClips = 200, long maxBytes = 96 * 1024 * 1024,
        bool archiveOverflow = false)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxClips);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxBytes);
        this.maxClips = maxClips;
        this.maxBytes = maxBytes;
        this.archiveOverflow = archiveOverflow;
        catalogPath = Path.Combine(dataDirectory, CatalogFileName);
        imageDirectory = Path.Combine(dataDirectory, "images");
        archiveDirectory = Path.Combine(dataDirectory, "archives");
        representationDirectory = Path.Combine(dataDirectory, "representations");
        string legacyPath = Path.Combine(dataDirectory, "history.json");
        var state = File.Exists(catalogPath) ? ReadCatalog() : ReadLegacyState(legacyPath);
        if (!File.Exists(catalogPath) && File.Exists(legacyPath))
            WriteCatalog(state.Clips, state.Collections, state.AiUndo, state.Payloads ?? [], []);
        Collections = state.Collections.AsReadOnly();
        Clips = state.Clips.AsReadOnly();
        aiUndo = state.AiUndo;
        RemoveOrphanedImages();
        RemoveOrphanedRepresentations(Clips);
        RemoveOrphanedArchives((state.Payloads ?? []).Values.Select(payload => payload.Hash).ToHashSet(StringComparer.OrdinalIgnoreCase));
    }

    private LibraryState ReadLegacyState(string indexPath)
    {
        if (!File.Exists(indexPath)) return new([], []);
        using var stream = File.OpenRead(indexPath);
        using var document = JsonDocument.Parse(stream);
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            var state = document.RootElement.Deserialize<LibraryState>();
            if (state is not { Version: 2, Clips: not null, Collections: not null })
                throw new JsonException("Unsupported history format.");
            if (state.Payloads is { Count: > 0 } packed)
                state = state with { Clips = state.Clips.Select(clip => packed.TryGetValue(clip.Id, out var entry) ?
                    ReadPacked(clip, entry) : clip).ToList() };
            return state with { Clips = state.Clips.Select(WithCurrentColorKind).ToList() };
        }

        var clips = document.RootElement.Deserialize<List<Clip>>() ?? throw new JsonException("Missing clipboard history.");
        clips = clips.Select(WithCurrentColorKind).ToList();
        var groups = clips.Select(clip => clip.Group).Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(name => name, StringComparer.CurrentCultureIgnoreCase)
            .ToDictionary(name => name, name => new ClipCollection(Guid.NewGuid(), name), StringComparer.OrdinalIgnoreCase);
        return new(clips.Select(clip => groups.TryGetValue(clip.Group, out var group)
            ? clip with { CollectionIds = [group.Id] } : clip).ToList(), groups.Values.ToList());
    }

    private static Clip WithCurrentColorKind(Clip clip) =>
        clip.Kind == ClipKind.Text && TextTools.TryColor(clip.Text, out _) ? clip with { Kind = ClipKind.Color } : clip;

    public bool Capture(Clip clip, byte[]? png = null) => Capture(clip, png, out _);

    public bool Capture(Clip clip, byte[]? png, out Clip? saved)
    {
        saved = null;
        if (clip.HasImage && (png is null || png.Length != clip.ImageSize))
            throw new ArgumentException("Image bytes do not match the clip.", nameof(png));

        var duplicate = Clips.FirstOrDefault(existing => existing.TrashedAt is null && existing.SameContent(clip));
        if (duplicate is null && Clips.Any(existing => existing.Id == clip.Id)) clip = clip with { Id = Guid.NewGuid() };
        var next = Clips.Where(existing => existing.Id != duplicate?.Id).ToList();
        Clip updated = MergeCapture(duplicate, clip);
        next.Insert(0, updated);

        var active = next.Where(IsActiveContent).ToList();
        var protectedGroups = RegularGroups();
        int count = active.Count;
        long size = active.Sum(item => item.Size);
        long indexSize = active.Sum(item => item.IndexSize);
        if (OverLimit())
        {
            var indices = Enumerable.Range(1, next.Count - 1).Reverse();
            if (archiveOverflow)
                indices = indices.OrderBy(index => next[index].CreatedAt ?? next[index].CapturedAt).ToArray();
            foreach (int index in indices)
            {
                var candidate = next[index];
                if (!IsActiveContent(candidate) || ProtectedFromArchive(candidate, protectedGroups)) continue;
                count--;
                size -= candidate.Size;
                indexSize -= candidate.IndexSize;
                if (archiveOverflow) next[index] = candidate with { ArchivedAt = DateTimeOffset.UtcNow };
                else next.RemoveAt(index);
                if (!OverLimit()) break;
            }
        }
        if (OverLimit()) return false;

        bool OverLimit() => count > maxClips || size > maxBytes || indexSize > MaxActiveIndexBytes;
        string? newImage = null;
        if (png is not null)
        {
            string path = ImagePath(updated);
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
        saved = updated;
        return true;
    }

    private static bool IsActiveContent(Clip clip) =>
        clip.ArchivedAt is null && clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate;

    private HashSet<Guid> RegularGroups() => Collections.Where(group => !group.IsSmart && !group.IsAi).Select(group => group.Id).ToHashSet();

    private static bool ProtectedFromArchive(Clip clip, HashSet<Guid> groups) =>
        clip.Pinned || clip.Favorite || clip.CollectionIds.Any(groups.Contains);

    private static Clip MergeCapture(Clip? existing, Clip latest)
    {
        var events = latest.CopyCount == 0 || latest.Captures.Length > 0 ? latest.Captures
            : [new CaptureEvent(latest.CapturedAt, latest.Source)];
        if (existing is null) return latest with { CreatedAt = latest.CreatedAt ?? latest.CapturedAt, Captures = events };

        var previous = existing.Captures.Length > 0 || existing.CopyCount == 0 ? existing.Captures
            : [new CaptureEvent(existing.CapturedAt, existing.Source)];
        // A tool result can add provenance to existing content without counting as a system copy.
        if (latest.CopyCount == 0)
        {
            var added = latest.Conversions.Except(existing.Conversions).ToArray();
            return added.Length == 0 ? existing : existing with
            {
                Conversions = [.. existing.Conversions, .. added],
                Note = existing.Note.Length == 0 ? latest.Note : existing.Note + Environment.NewLine + latest.Note
            };
        }

        if (latest.CapturedAt < existing.CapturedAt)
            return ClipActivity.Record(existing, ActivityKind.Copy, latest.CapturedAt) with
            {
                CopyCount = (int)Math.Min(int.MaxValue, (long)existing.CopyCount + latest.CopyCount),
                Captures = [.. events.Concat(previous).OrderByDescending(item => item.CapturedAt).Take(100)]
            };

        var used = ClipActivity.Record(existing, ActivityKind.Copy, latest.CapturedAt);
        return latest with
        {
            Id = existing.Id,
            CreatedAt = existing.CreatedAt ?? existing.CapturedAt,
            LastPastedAt = existing.LastPastedAt,
            CopyCount = (int)Math.Min(int.MaxValue, (long)existing.CopyCount + latest.CopyCount),
            PasteCount = existing.PasteCount,
            Title = existing.Title,
            Note = existing.Note,
            Pinned = existing.Pinned,
            Favorite = existing.Favorite,
            Priority = existing.Priority,
            CollectionIds = existing.CollectionIds,
            ExcludeFromAi = existing.ExcludeFromAi,
            IsManual = existing.IsManual,
            Uses = used.Uses,
            Group = existing.Group,
            Captures = [.. events.Concat(previous).Take(100)],
            Conversions = existing.Conversions,
            RecognizedText = existing.RecognizedText ?? latest.RecognizedText,
            RecognizedAt = existing.RecognizedAt ?? latest.RecognizedAt,
            OcrInNote = existing.OcrInNote,
            OcrPending = existing.RecognizedText is null && latest.RecognizedText is null && existing.OcrPending,
            OcrMode = existing.RecognizedText is not null || latest.RecognizedText is null ? existing.OcrMode : latest.OcrMode,
            LinkDetails = latest.LinkDetails is { Status: "Not attempted" } fallback && existing.LinkDetails is { } known
                ? known with { FallbackTitle = fallback.FallbackTitle, FallbackSource = fallback.FallbackSource, Route = fallback.Route }
                : latest.LinkDetails ?? existing.LinkDetails
        };
    }

    public bool Edit(Clip clip, string title, string note, string group, bool pinned, bool favorite)
    {
        var groups = Collections.ToList();
        var match = groups.FirstOrDefault(item => !item.IsSmart && item.Name.Equals(group, StringComparison.OrdinalIgnoreCase));
        if (group.Length > 0 && match is null)
        {
            match = new ClipCollection(Guid.NewGuid(), group);
            groups.Add(match);
        }
        return EditInternal(clip.Id, existing => existing with
        {
            Title = title, Note = note, Group = group, Pinned = pinned, Favorite = favorite,
            CollectionIds = match is null ? [] : [match.Id]
        }, groups);
    }

    public bool Update(Guid id, Func<Clip, Clip> change) => EditInternal(id, change);

    public bool UpdateManualText(Guid id, string text, Func<Clip, LinkDetails?>? linkDetails = null)
    {
        var previous = Clips.FirstOrDefault(clip => clip.Id == id && clip.IsManual && clip.TrashedAt is null);
        if (previous is null || string.IsNullOrWhiteSpace(text)) return false;
        var (kind, language) = TextTools.Classify(text);
        var next = ClipActivity.Record(previous, ActivityKind.Edit, DateTimeOffset.UtcNow) with
        {
            Text = text, Kind = kind, CodeLanguage = language, LinkDetails = text == previous.Text ? previous.LinkDetails : null
        };
        if (kind == ClipKind.Link && linkDetails is not null) next = next with { LinkDetails = linkDetails(next) };
        if (Clips.Any(clip => clip.Id != id && clip.TrashedAt is null && clip.SameContent(next)))
            throw new ArgumentException("This content is already in the library.");
        return Update(id, _ => next);
    }

    private bool EditInternal(Guid id, Func<Clip, Clip> change, List<ClipCollection>? groups = null)
    {
        var old = Clips.FirstOrDefault(clip => clip.Id == id);
        if (old is null) return false;
        var updated = change(old);
        long additional = updated.IndexSize - old.IndexSize;
        if (IsActiveContent(updated) && additional > 0 && Clips.Where(IsActiveContent).Sum(item => item.IndexSize) + additional
            > Math.Min(MaxActiveIndexBytes, maxBytes)) return false;
        Commit(Clips.Select(existing => existing.Id == id ? updated : existing).ToList(), groups);
        return true;
    }

    public void RecordPaste(Guid id) => Update(id, clip =>
    {
        var now = DateTimeOffset.UtcNow;
        return ClipActivity.Record(clip, ActivityKind.Paste, now) with
        {
            PasteCount = clip.PasteCount < int.MaxValue ? clip.PasteCount + 1 : clip.PasteCount,
            LastPastedAt = now
        };
    });

    public void FavoriteMembers(IEnumerable<Guid> ids)
    {
        var members = ids.ToHashSet();
        Commit(Clips.Select(clip => members.Contains(clip.Id) && clip.TrashedAt is null
            ? clip with { Favorite = true } : clip).ToList());
    }

    public void Trash(Guid id) => Update(id, clip => clip with { TrashedAt = DateTimeOffset.UtcNow });
    public void Restore(Guid id) => Update(id, clip => clip with { TrashedAt = null });
    public void SetArchived(Guid id, bool archived) =>
        Update(id, clip => clip with { ArchivedAt = archived ? DateTimeOffset.UtcNow : null });
    public void Delete(Clip clip) => Commit(Remove([clip.Id]));
    public void ClearUnprotected() => Commit(Remove(Clips.Where(clip => !clip.Favorite && !clip.Pinned).Select(clip => clip.Id)));
    public void EmptyTrash() => Commit(Remove(Clips.Where(clip => clip.TrashedAt is not null).Select(clip => clip.Id)));

    public void RunMaintenance(DateTimeOffset now, int archiveAfterDays)
    {
        var expiredIds = Clips.Where(clip => clip.TrashedAt <= now.AddDays(-30)).Select(clip => clip.Id).ToArray();
        var next = Remove(expiredIds);
        DateTimeOffset cutoff = now.AddDays(-Math.Clamp(archiveAfterDays, 0, 3650));
        bool changed = expiredIds.Length > 0;
        int overflow = archiveOverflow ? Math.Max(0, next.Count(IsActiveContent) - maxClips) : 0;
        if (archiveAfterDays > 0 || overflow > 0)
        {
            var protectedGroups = RegularGroups();
            var candidates = Enumerable.Range(0, next.Count)
                .Where(index => IsActiveContent(next[index]) && !ProtectedFromArchive(next[index], protectedGroups))
                .OrderBy(index => next[index].CreatedAt ?? next[index].CapturedAt).ToArray();
            foreach (int index in candidates)
            {
                var clip = next[index];
                if (overflow <= 0 && (archiveAfterDays <= 0 || (clip.CreatedAt ?? clip.CapturedAt) >= cutoff)) break;
                next[index] = clip with { ArchivedAt = now };
                overflow--;
                changed = true;
            }
        }
        if (changed) Commit(next);
    }

    private List<Clip> Remove(IEnumerable<Guid> ids)
    {
        var removed = ids.ToHashSet();
        return Clips.Where(clip => !removed.Contains(clip.Id)).Select(clip =>
            clip.Members.Any(removed.Contains) ? clip with { Members = clip.Members.Where(id => !removed.Contains(id)).ToArray() } : clip)
            .ToList();
    }

    public ClipCollection SaveCollection(Guid? id, string name, SmartRules? rules)
    {
        name = name.Trim();
        if (name.Length is < 1 or > 80 || rules is not null && !rules.IsValid() ||
            Collections.Any(group => group.Id != id && group.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("Use a unique group name and valid rules.");
        var next = Collections.ToList();
        int position = next.FindIndex(group => group.Id == id);
        var group = position >= 0 ? next[position] with { Name = name, Rules = rules } :
            new ClipCollection(id ?? Guid.NewGuid(), name, rules);
        if (position < 0) next.Add(group); else next[position] = group;
        Commit(Clips.Select(clip => clip.CollectionIds.Contains(group.Id) && clip.Group.Length > 0
            ? clip with { Group = name } : clip).ToList(), next);
        return group;
    }

    public void DeleteCollection(Guid id) => Commit(Clips.Select(clip => clip.CollectionIds.Contains(id)
        ? clip with { CollectionIds = clip.CollectionIds.Where(groupId => groupId != id).ToArray(), Group = "" } : clip)
        .ToList(), Collections.Where(group => group.Id != id).ToList());

    public void MoveCollection(Guid id, Guid? before)
    {
        if (id == before || Collections.FirstOrDefault(group => group.Id == id) is not { } group) return;
        var next = Collections.Where(item => item.Id != id).ToList();
        int position = next.FindIndex(item => item.Id == before);
        next.Insert(position < 0 ? next.Count : position, group);
        Commit(Clips.ToList(), next);
    }

    public void MoveCollectionWithinType(Guid id, Guid before)
    {
        var group = Collections.FirstOrDefault(item => item.Id == id);
        if (group is null || id == before) return;
        bool SameType(ClipCollection item) => item.IsSmart == group.IsSmart && item.IsAi == group.IsAi;
        var matching = Collections.Where(item => SameType(item) && item.Id != id).ToList();
        int position = matching.FindIndex(item => item.Id == before);
        if (position < 0) return;
        matching.Insert(position, group);
        var ordered = new Queue<ClipCollection>(matching);
        Commit(Clips.ToList(), Collections.Select(item => SameType(item) ? ordered.Dequeue() : item).ToList());
    }

    public Clip SaveAggregation(Guid? id, string title, string note, IEnumerable<Guid> members, string? origin, bool fromSearch = false)
    {
        title = title.Trim();
        if (title.Length == 0) throw new ArgumentException("Enter a title for the aggregation.");
        var candidates = Clips.Where(clip => clip.Kind != ClipKind.Aggregate && clip.TrashedAt is null)
            .Select(clip => clip.Id).ToHashSet();
        Guid[] memberIds = members.Where(candidates.Contains).Distinct().ToArray();
        if (memberIds.Length < 2) throw new ArgumentException("Choose at least two different clips.");
        var previous = Clips.FirstOrDefault(clip => clip.Id == id && clip.Kind == ClipKind.Aggregate && clip.TrashedAt is null);
        if (id is not null && previous is null) throw new ArgumentException("This aggregation is no longer available.");
        var now = DateTimeOffset.UtcNow;
        var aggregate = (previous ?? new Clip { Kind = ClipKind.Aggregate, CopyCount = 0 }) with
        {
            Title = title, Note = note, Members = memberIds, AggregationOrigin = origin, AggregationFromSearch = fromSearch,
            CreatedAt = previous?.CreatedAt ?? previous?.CapturedAt ?? now, AggregationUpdatedAt = now,
            LastSelectedMember = previous?.LastSelectedMember is { } child && memberIds.Contains(child) ? child : null
        };
        Commit(Clips.Where(clip => clip.Id != aggregate.Id).Prepend(aggregate).ToList());
        return aggregate;
    }

    public bool RemoveAggregationMember(Guid parentId, Guid memberId)
    {
        var parent = Clips.FirstOrDefault(clip => clip.Id == parentId && clip.Kind == ClipKind.Aggregate && clip.TrashedAt is null);
        if (parent is null || !parent.Members.Contains(memberId)) return false;
        Guid[] members = parent.Members.Where(id => id != memberId).ToArray();
        if (members.Length < 2)
        {
            Commit(Clips.Where(clip => clip.Id != parentId).ToList());
            return true;
        }
        Update(parentId, clip => clip with
        {
            Members = members, LastSelectedMember = clip.LastSelectedMember == memberId ? null : clip.LastSelectedMember,
            AggregationUpdatedAt = DateTimeOffset.UtcNow
        });
        return false;
    }

    public byte[] ReadImage(Clip clip) => File.ReadAllBytes(ImagePath(clip));

    public void UpdateLinkDetails(Func<Clip, LinkDetails?> update)
    {
        bool changed = false;
        var next = Clips.Select(clip =>
        {
            if (clip.Kind != ClipKind.Link || clip.TrashedAt is not null) return clip;
            var details = update(clip);
            if (details == clip.LinkDetails) return clip;
            changed = true;
            return clip with { LinkDetails = details };
        }).ToList();
        if (changed) Commit(next);
    }

    private string ImagePath(Clip clip) => Path.Combine(imageDirectory, clip.ImageFileName);

    private void Commit(List<Clip> next, List<ClipCollection>? groups = null, bool replaceAiUndo = false,
        AiUndoRecord? nextUndo = null, bool discardOrphans = true)
    {
        var collections = groups ?? Collections.ToList();
        var undo = replaceAiUndo ? nextUndo : aiUndo;
        var packed = WriteCatalog(next, collections, undo, null, Collections);
        if (discardOrphans)
        {
            var retained = next.Where(clip => clip.HasImage).Select(clip => clip.ImageFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var clip in Clips)
                if (clip.HasImage && !retained.Contains(clip.ImageFileName)) DiscardManagedFile(ImagePath(clip));
            if (!Clips.Where(clip => clip.OriginalItems is not null).Select(clip => clip.OriginalItems)
                .SequenceEqual(next.Where(clip => clip.OriginalItems is not null).Select(clip => clip.OriginalItems)))
                RemoveOrphanedRepresentations(next);
            RemoveOrphanedArchives(packed.Values.Select(payload => payload.Hash).ToHashSet(StringComparer.OrdinalIgnoreCase));
        }
        Clips = next.AsReadOnly();
        Collections = collections.AsReadOnly();
        aiUndo = undo;
    }

    private void RemoveOrphanedImages()
    {
        if (!LocalStorage.IsOrdinaryDirectory(imageDirectory)) return;
        var retained = Clips.Where(clip => clip.HasImage).Select(clip => clip.ImageFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (string path in Directory.EnumerateFiles(imageDirectory))
        {
            string extension = Path.GetExtension(path).ToLowerInvariant();
            if (extension is ".png" or ".jpeg" or ".tiff" or ".gif" or ".bmp" or ".webp" or ".heic" or ".avif" &&
                Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "N", out _) && !retained.Contains(Path.GetFileName(path)))
                DiscardManagedFile(path);
        }
    }

    private sealed record LibraryState(List<Clip> Clips, List<ClipCollection> Collections, int Version = 2,
        AiUndoRecord? AiUndo = null, Dictionary<Guid, PackedPayload>? Payloads = null);
}
