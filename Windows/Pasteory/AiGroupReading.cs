using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed class AiGroupReading
{
    private sealed record Visit(HashSet<Guid> Members, DateTimeOffset? OpenedAt = null);
    private readonly string path;
    private Dictionary<Guid, Visit> viewed;
    private IReadOnlyList<Clip>? clips;
    private IReadOnlyList<ClipCollection>? groups;
    private Dictionary<Guid, HashSet<Guid>> members = [];

    internal AiGroupReading(string root, IReadOnlyList<Clip> clips, IReadOnlyList<ClipCollection> groups)
    {
        path = Path.Combine(root, "ai-group-reading.json");
        Update(clips, groups);
        Dictionary<Guid, Visit>? saved = null;
        try { saved = AiFile.Load<Dictionary<Guid, Visit>>(path); }
        catch (Exception error) when (AiTasks.Expected(error)) { Trace.TraceWarning(error.Message); }
        viewed = saved ?? members.ToDictionary(entry => entry.Key, entry => new Visit(entry.Value));
        if (saved is null)
        {
            try { AiFile.Save(path, viewed); }
            catch (Exception error) when (AiTasks.Expected(error)) { Trace.TraceWarning(error.Message); }
        }
    }

    internal void Update(IReadOnlyList<Clip> currentClips, IReadOnlyList<ClipCollection> currentGroups)
    {
        if (ReferenceEquals(clips, currentClips) && ReferenceEquals(groups, currentGroups)) return;
        clips = currentClips;
        groups = currentGroups;
        var next = currentGroups.Where(group => group.IsAi).ToDictionary(group => group.Id, _ => new HashSet<Guid>());
        foreach (var clip in currentClips.Where(clip => clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate))
            foreach (Guid group in clip.CollectionIds)
                if (next.TryGetValue(group, out var groupMembers)) groupMembers.Add(clip.Id);
        members = next;
    }

    internal int Unread(Guid id) => members.TryGetValue(id, out var current) ?
        current.Count(clip => viewed.GetValueOrDefault(id)?.Members.Contains(clip) != true) : 0;

    internal bool Open(Guid id, DateTimeOffset now)
    {
        if (!members.TryGetValue(id, out var current)) return false;
        bool changed = Unread(id) > 0;
        var next = new Dictionary<Guid, Visit>(viewed) { [id] = new(current, now) };
        AiFile.Save(path, next);
        viewed = next;
        return changed;
    }

    internal bool OpenedSince(Guid id, DateTimeOffset cutoff) => viewed.GetValueOrDefault(id)?.OpenedAt >= cutoff;
}
