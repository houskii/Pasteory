namespace Pasteory.Core;

public sealed record AiTopicProposal(string Name, string Overview, Guid[] Members);

public sealed partial class HistoryStore
{
    public int ApplyAiTopics(IEnumerable<AiTopicProposal> proposals)
    {
        var topics = proposals.ToArray();
        var allowed = Clips.Where(clip => !clip.ExcludeFromAi && clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate)
            .ToDictionary(clip => clip.Id);
        if (topics.Length > 8 || topics.SelectMany(topic => topic.Members).GroupBy(id => id).Any(grouping => grouping.Count() > 1) ||
            topics.SelectMany(topic => topic.Members).Any(id => !allowed.ContainsKey(id)))
            throw new ArgumentException("The proposal contains invalid memberships.");

        var groups = Collections.ToList();
        var addedByClip = new Dictionary<Guid, Guid>();
        var created = new List<ClipCollection>();
        foreach (var topic in topics)
        {
            string name = topic.Name.Trim();
            var previous = groups.FirstOrDefault(group => group.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
            if (previous is { IsAi: false } || previous?.Locked == true || name.Length is < 1 or > 80) continue;
            if (previous is null)
            {
                if (topic.Members.Length < 3 || groups.Count(group => group.IsAi) >= 8) continue;
                previous = new ClipCollection(Guid.NewGuid(), name, IsAi: true, Overview: topic.Overview);
                groups.Add(previous);
                created.Add(previous);
            }
            foreach (var id in topic.Members)
            {
                if (!allowed[id].CollectionIds.Contains(previous.Id) && previous.ExcludedClips?.Contains(id) != true)
                    addedByClip.Add(id, previous.Id);
            }
        }
        if (addedByClip.Count == 0 && created.Count == 0) return 0;
        var undo = new AiUndoRecord(created.ToArray(), addedByClip);
        var next = Clips.Select(clip => addedByClip.TryGetValue(clip.Id, out var group) ?
            clip with { CollectionIds = [.. clip.CollectionIds, group] } : clip).ToList();
        Commit(next, groups, replaceAiUndo: true, nextUndo: undo);
        return addedByClip.Count;
    }

    public void UndoAiTopics()
    {
        if (aiUndo is not { } undo) return;
        var groups = undo.Created.Select(group => group.Id).ToHashSet();
        if (undo.Created.Any(created => Collections.FirstOrDefault(item => item.Id == created.Id) is not { } current ||
            current.Name != created.Name || current.Locked || current.Overview != created.Overview) ||
            Clips.Any(clip => clip.CollectionIds.Any(group => groups.Contains(group) &&
                (!undo.Added.TryGetValue(clip.Id, out var added) || added != group))) ||
            undo.Added.Any(entry => !Clips.Any(clip => clip.Id == entry.Key && clip.CollectionIds.Contains(entry.Value))))
            throw new ArgumentException("Memberships changed after organization. Undo was cancelled.");
        var next = Clips.Select(clip => undo.Added.TryGetValue(clip.Id, out var group) ?
            clip with { CollectionIds = clip.CollectionIds.Where(id => id != group).ToArray() } : clip).ToList();
        Commit(next, Collections.Where(group => !groups.Contains(group.Id)).ToList(), replaceAiUndo: true);
    }

    public void SetAiGroupLocked(Guid id, bool locked) => Commit(Clips.ToList(), Collections.Select(group => group.IsAi && group.Id == id
        ? group with { Locked = locked } : group).ToList());

    public void RemoveFromAiTopic(Guid groupId, Guid clipId)
    {
        var group = Collections.FirstOrDefault(item => item.Id == groupId && item.IsAi);
        if (group is null) return;
        var next = Clips.Select(clip => clip.Id == clipId ?
            clip with { CollectionIds = clip.CollectionIds.Where(id => id != groupId).ToArray() } : clip).ToList();
        var groups = Collections.Select(item => item.Id != groupId ? item : item with
        { ExcludedClips = (item.ExcludedClips ?? []).Append(clipId).Distinct().ToArray() }).ToList();
        Commit(next, groups);
    }

    private sealed record AiUndoRecord(ClipCollection[] Created, Dictionary<Guid, Guid> Added);
}
