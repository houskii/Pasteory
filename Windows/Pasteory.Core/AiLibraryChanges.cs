namespace Pasteory.Core;

public sealed record AiTopicProposal(string Name, string Overview, Guid[] Members, Guid? ExistingGroupId = null,
    string Definition = "", Guid[]? OverviewSources = null, bool CreateOnly = false, string? ExpectedDefinition = null);

public sealed partial class HistoryStore
{
    public Guid? UndoableAiTask => aiUndo?.TaskId;

    public int ApplyAiTopics(IEnumerable<AiTopicProposal> proposals, Guid? taskId = null)
    {
        if (taskId is not null && aiUndo?.TaskId == taskId) return 0;
        var topics = proposals.ToArray();
        var allowed = Clips.Where(clip => !clip.ExcludeFromAi && clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate)
            .ToDictionary(clip => clip.Id);
        if (topics.Length > 8 || topics.Any(topic => topic.Members.Distinct().Count() != topic.Members.Length ||
            topic.Members.Any(id => !allowed.ContainsKey(id))))
            throw new ArgumentException("The proposal contains invalid memberships.");

        var groups = Collections.ToList();
        var addedByClip = new Dictionary<Guid, List<Guid>>();
        var created = new List<ClipCollection>();
        var overviews = new List<AiOverviewEdit>();
        var touched = new HashSet<Guid>();
        foreach (var topic in topics)
        {
            if (topic.Members.Length == 0) continue;
            string name = topic.Name.Trim();
            var previous = topic.ExistingGroupId is { } groupId ? groups.FirstOrDefault(group => group.Id == groupId) :
                groups.FirstOrDefault(group => group.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
            if (previous is { IsAi: false } or { Locked: true } || name.Length is < 1 or > 80 ||
                topic.ExistingGroupId is not null && previous is null || topic.CreateOnly && previous is not null ||
                topic.ExpectedDefinition is { } expected && previous?.Definition != expected) continue;
            bool updateOverview = topic.OverviewSources is { Length: > 0 } &&
                topic.OverviewSources.All(id => topic.Members.Contains(id) && previous?.ExcludedClips?.Contains(id) != true);
            if (previous is null)
            {
                if (topic.Members.Length < 3 || groups.Count(group => group.IsAi) >= 8) continue;
                previous = new ClipCollection(Guid.NewGuid(), name, IsAi: true,
                    Overview: updateOverview || topic.OverviewSources is null ? topic.Overview : "",
                    Definition: topic.Definition, OverviewClips: updateOverview ? topic.OverviewSources : null);
                groups.Add(previous);
                created.Add(previous);
            }
            if (!touched.Add(previous.Id)) throw new ArgumentException("The proposal repeats an AI group.");
            if (updateOverview && (previous.Overview != topic.Overview ||
                !(previous.OverviewClips ?? []).SequenceEqual(topic.OverviewSources!)))
            {
                var updated = previous with { Overview = topic.Overview, OverviewClips = topic.OverviewSources };
                groups[groups.IndexOf(previous)] = updated;
                overviews.Add(new(previous, updated));
            }
            foreach (var id in topic.Members)
            {
                if (!allowed[id].CollectionIds.Contains(previous.Id) && previous.ExcludedClips?.Contains(id) != true)
                {
                    if (!addedByClip.TryGetValue(id, out var memberships)) addedByClip[id] = memberships = [];
                    memberships.Add(previous.Id);
                }
            }
        }
        if (addedByClip.Count == 0 && created.Count == 0 && overviews.Count == 0) return 0;
        var undo = new AiUndoRecord(created.ToArray(), [], addedByClip.ToDictionary(entry => entry.Key,
            entry => entry.Value.ToArray()), overviews.ToArray(), taskId);
        var next = Clips.Select(clip => addedByClip.TryGetValue(clip.Id, out var memberships) ?
            clip with { CollectionIds = [.. clip.CollectionIds, .. memberships] } : clip).ToList();
        Commit(next, groups, replaceAiUndo: true, nextUndo: undo);
        return addedByClip.Count;
    }

    public void UndoAiTopics()
    {
        if (aiUndo is not { } undo) return;
        var groups = undo.Created.Select(group => group.Id).ToHashSet();
        var added = undo.Memberships ?? undo.Added.ToDictionary(entry => entry.Key, entry => new[] { entry.Value });
        var overviews = (undo.Overviews ?? []).ToDictionary(edit => edit.After.Id);
        bool Matches(ClipCollection expected) => Collections.FirstOrDefault(item => item.Id == expected.Id) is { } current &&
            current.Name == expected.Name && current.IsAi && current.Locked == expected.Locked &&
            current.Definition == expected.Definition && current.Overview == expected.Overview &&
            (current.OverviewClips ?? []).SequenceEqual(expected.OverviewClips ?? []) &&
            (current.ExcludedClips ?? []).SequenceEqual(expected.ExcludedClips ?? []) &&
            current.PackPayloads == expected.PackPayloads;
        if (undo.Created.Any(created => !Matches(created)) || overviews.Values.Any(edit => !Matches(edit.After)) ||
            Clips.Any(clip => clip.CollectionIds.Any(group => groups.Contains(group) &&
                (!added.TryGetValue(clip.Id, out var memberships) || !memberships.Contains(group)))) ||
            added.Any(entry => !Clips.Any(clip => clip.Id == entry.Key && entry.Value.All(clip.CollectionIds.Contains))))
            throw new ArgumentException("Memberships changed after organization. Undo was cancelled.");
        var next = Clips.Select(clip => added.TryGetValue(clip.Id, out var memberships) ?
            clip with { CollectionIds = clip.CollectionIds.Except(memberships).ToArray() } : clip).ToList();
        Commit(next, Collections.Where(group => !groups.Contains(group.Id)).Select(group =>
            overviews.TryGetValue(group.Id, out var edit) ? edit.Before : group).ToList(), replaceAiUndo: true);
    }

    public void SetAiGroupLocked(Guid id, bool locked) => Commit(Clips.ToList(), Collections.Select(group => group.IsAi && group.Id == id
        ? group with { Locked = locked } : group).ToList());

    public void SetAiGroupDefinition(Guid id, string definition)
    {
        definition = definition.Trim();
        if (definition.Length is < 1 or > 2000) throw new ArgumentException("Enter an AI group definition up to 2000 characters.");
        var current = Collections.SingleOrDefault(group => group.Id == id && group.IsAi);
        if (current is null || current.Definition == definition) return;
        Commit(Clips.ToList(), Collections.Select(group => group.Id == id ? group with { Definition = definition } : group).ToList());
    }

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

    private sealed record AiOverviewEdit(ClipCollection Before, ClipCollection After);
    private sealed record AiUndoRecord(ClipCollection[] Created, Dictionary<Guid, Guid> Added,
        Dictionary<Guid, Guid[]>? Memberships = null, AiOverviewEdit[]? Overviews = null, Guid? TaskId = null);
}
