namespace Pasteory.Core;

public sealed record AiTopicProposal(string Name, string Overview, Guid[] Members, Guid? ExistingGroupId = null,
    string Definition = "", Guid[]? OverviewSources = null, bool CreateOnly = false, string? ExpectedDefinition = null);

public sealed record AiGroupSnapshot(ClipCollection Group, Guid[] Members, int Position)
{
    public static AiGroupSnapshot[] Capture(IReadOnlyList<ClipCollection> groups, IReadOnlyList<Clip> clips, IReadOnlySet<Guid> selected)
    {
        if (selected.Count == 0) return [];
        var members = clips.SelectMany(clip => clip.CollectionIds.Where(selected.Contains).Select(id => (Group: id, clip.Id)))
            .ToLookup(entry => entry.Group, entry => entry.Id);
        return groups.Select((group, position) => (Group: group, Position: position))
            .Where(entry => entry.Group.IsAi && selected.Contains(entry.Group.Id))
            .Select(entry => new AiGroupSnapshot(entry.Group, members[entry.Group.Id].Distinct().Order().ToArray(), entry.Position))
            .ToArray();
    }

    public static bool IsCurrent(IReadOnlyList<ClipCollection> groups, IReadOnlyList<Clip> clips, AiGroupSnapshot[] selection)
        => Matches(Capture(groups, clips, selection.Select(item => item.Group.Id).ToHashSet()), selection);

    internal static bool Matches(AiGroupSnapshot[] current, AiGroupSnapshot[] selection)
    {
        if (current.Length != selection.Length || selection.Select(item => item.Group.Id).Distinct().Count() != selection.Length) return false;
        var byId = current.ToDictionary(item => item.Group.Id);
        return selection.All(item => byId.TryGetValue(item.Group.Id, out var next) &&
            SameGroup(item.Group, next.Group) && item.Members.SequenceEqual(next.Members));
    }

    internal static bool SameGroup(ClipCollection expected, ClipCollection current) =>
        current.Name == expected.Name && current.IsAi && current.Locked == expected.Locked &&
        current.Definition == expected.Definition && current.Overview == expected.Overview && current.Retained == expected.Retained &&
        current.NameIsManual == expected.NameIsManual && current.DefinitionIsManual == expected.DefinitionIsManual &&
        current.DefinitionVersion == expected.DefinitionVersion && current.PackPayloads == expected.PackPayloads &&
        (current.OverviewClips ?? []).SequenceEqual(expected.OverviewClips ?? []) &&
        (current.ExcludedClips ?? []).SequenceEqual(expected.ExcludedClips ?? []);
}

public sealed partial class HistoryStore
{
    public Guid? UndoableAiTask => aiUndo?.TaskId;

    public int ApplyAiTopics(IEnumerable<AiTopicProposal> proposals, Guid? taskId = null, AiGroupSnapshot[]? replacing = null)
    {
        if (taskId is not null && aiUndo?.TaskId == taskId) return 0;
        var topics = proposals.ToArray();
        var allowed = Clips.Where(clip => !clip.ExcludeFromAi && clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate)
            .ToDictionary(clip => clip.Id);
        if (topics.Length > 8 || topics.Any(topic => topic.Members.Distinct().Count() != topic.Members.Length ||
            topic.Members.Any(id => !allowed.ContainsKey(id))))
            throw new ArgumentException("The proposal contains invalid memberships.");

        var removedIds = (replacing ?? []).Select(item => item.Group.Id).ToHashSet();
        var removed = AiGroupSnapshot.Capture(Collections, Clips, removedIds);
        if (replacing is not null && !AiGroupSnapshot.Matches(removed, replacing))
            throw new ArgumentException("The selected AI groups changed. Refresh the selection and try again.");
        var groups = Collections.Where(group => !removedIds.Contains(group.Id)).ToList();
        var addedByClip = new Dictionary<Guid, List<Guid>>();
        var created = new List<ClipCollection>();
        var overviews = new List<AiOverviewEdit>();
        var touched = new HashSet<Guid>();
        foreach (var topic in topics)
        {
            string name = topic.Name.Trim();
            var previous = topic.ExistingGroupId is { } groupId ? groups.FirstOrDefault(group => group.Id == groupId) :
                groups.FirstOrDefault(group => group.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
            if (topic.Members.Length == 0 || previous is null && topic.Members.Length < 3 ||
                previous is { IsAi: false } or { Locked: true } || name.Length is < 1 or > 80 ||
                topic.ExistingGroupId is not null && previous is null || topic.CreateOnly && previous is not null ||
                topic.ExpectedDefinition is { } expected && previous?.Definition != expected ||
                previous is null && groups.Count(group => group.IsAi) >= 8 ||
                replacing is not null && previous is not null && (previous.Name != name ||
                    previous.ExcludedClips?.Any(topic.Members.Contains) == true))
            {
                if (replacing is not null) throw new ArgumentException("A proposed AI group changed. Generate a new regrouping plan.");
                continue;
            }
            bool updateOverview = topic.OverviewSources is { Length: > 0 } &&
                topic.OverviewSources.All(id => topic.Members.Contains(id) && previous?.ExcludedClips?.Contains(id) != true);
            if (previous is null)
            {
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
        if (addedByClip.Count == 0 && created.Count == 0 && overviews.Count == 0 && removed.Length == 0) return 0;
        var undo = new AiUndoRecord(created.ToArray(), [], addedByClip.ToDictionary(entry => entry.Key,
            entry => entry.Value.ToArray()), overviews.ToArray(), taskId, removed);
        var next = Clips.Select(clip => addedByClip.ContainsKey(clip.Id) || clip.CollectionIds.Any(removedIds.Contains)
            ? clip with { CollectionIds = [.. clip.CollectionIds.Where(id => !removedIds.Contains(id)), .. addedByClip.GetValueOrDefault(clip.Id, [])] }
            : clip).ToList();
        Commit(next, groups, replaceAiUndo: true, nextUndo: undo);
        return addedByClip.Count;
    }

    public void UndoAiTopics()
    {
        if (aiUndo is not { } undo) return;
        var groups = undo.Created.Select(group => group.Id).ToHashSet();
        var added = undo.Memberships ?? undo.Added.ToDictionary(entry => entry.Key, entry => new[] { entry.Value });
        var overviews = (undo.Overviews ?? []).ToDictionary(edit => edit.After.Id);
        var removed = undo.RemovedGroups ?? [];
        var remaining = Collections.Where(group => !groups.Contains(group.Id)).ToList();
        var clipsById = Clips.ToDictionary(clip => clip.Id);
        bool Matches(ClipCollection expected) => Collections.FirstOrDefault(item => item.Id == expected.Id) is { } current &&
            AiGroupSnapshot.SameGroup(expected, current);
        if (undo.Created.Any(created => !Matches(created)) || overviews.Values.Any(edit => !Matches(edit.After)) ||
            removed.Any(item => item.Members.Any(id => !clipsById.ContainsKey(id)) || remaining.Any(group =>
                group.Id == item.Group.Id || group.Name.Equals(item.Group.Name, StringComparison.OrdinalIgnoreCase))) ||
            Clips.Any(clip => clip.CollectionIds.Any(group => groups.Contains(group) &&
                (!added.TryGetValue(clip.Id, out var memberships) || !memberships.Contains(group)))) ||
            added.Any(entry => !clipsById.TryGetValue(entry.Key, out var clip) || !entry.Value.All(clip.CollectionIds.Contains)))
            throw new ArgumentException("Memberships changed after organization. Undo was cancelled.");
        var restore = removed.SelectMany(item => item.Members.Select(id => (ClipId: id, item.Group.Id)))
            .ToLookup(item => item.ClipId, item => item.Id);
        var next = Clips.Select(clip => added.ContainsKey(clip.Id) || restore.Contains(clip.Id)
            ? clip with { CollectionIds = [.. clip.CollectionIds.Except(added.GetValueOrDefault(clip.Id, [])), .. restore[clip.Id]] }
            : clip).ToList();
        var restoredGroups = remaining.Select(group => overviews.TryGetValue(group.Id, out var edit) ? edit.Before : group).ToList();
        foreach (var item in removed.OrderBy(item => item.Position))
            restoredGroups.Insert(Math.Clamp(item.Position, 0, restoredGroups.Count), item.Group);
        Commit(next, restoredGroups, replaceAiUndo: true);
    }

    public void SetAiGroupLocked(Guid id, bool locked) => Commit(Clips.ToList(), Collections.Select(group => group.IsAi && group.Id == id
        ? group with { Locked = locked } : group).ToList());

    public void SetAiGroupDefinition(Guid id, string definition)
    {
        definition = definition.Trim();
        if (definition.Length is < 1 or > 2000) throw new ArgumentException("Enter an AI group definition up to 2000 characters.");
        var current = Collections.SingleOrDefault(group => group.Id == id && group.IsAi);
        if (current is not null) UpdateAiGroup(current, current.Name, definition, current.Retained);
    }

    public void UpdateAiGroup(ClipCollection opened, string name, string definition, bool retained)
    {
        var current = Collections.FirstOrDefault(group => group.Id == opened.Id && group.IsAi);
        if (current is null || current.DefinitionVersion != opened.DefinitionVersion || current.Name != opened.Name ||
            current.Definition != opened.Definition || current.Retained != opened.Retained)
            throw new ArgumentException("This AI group changed while editing. Reopen it and try again.");
        name = name.Trim();
        definition = definition.Trim();
        if (name != current.Name && (name.Length is < 1 or > 40 || Collections.Any(group =>
            group.Id != current.Id && group.Name.Equals(name, StringComparison.OrdinalIgnoreCase))))
            throw new ArgumentException("Use a unique AI group name of up to 40 characters.");
        if (definition != current.Definition && definition.Length is < 1 or > 2000)
            throw new ArgumentException("Enter an AI group definition up to 2000 characters.");
        if (name == current.Name && definition == current.Definition && retained == current.Retained) return;
        var updated = current with
        {
            Name = name, Definition = definition, Retained = retained, DefinitionVersion = current.DefinitionVersion + 1,
            NameIsManual = current.NameIsManual || current.Name != name,
            DefinitionIsManual = current.DefinitionIsManual || current.Definition != definition
        };
        Commit(Clips.ToList(), Collections.Select(group => group.Id == current.Id ? updated : group).ToList());
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
        Dictionary<Guid, Guid[]>? Memberships = null, AiOverviewEdit[]? Overviews = null, Guid? TaskId = null,
        AiGroupSnapshot[]? RemovedGroups = null);
}
