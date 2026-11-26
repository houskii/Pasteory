using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Controls;
using Pasteory.Core;

namespace Pasteory.Windows;

internal enum Scope { All, Favorite, Recent, Archive, Trash }

internal sealed class ClipResults(App app, ListBox list)
{
    private readonly HashSet<Guid> expanded = [];
    private readonly HashSet<Guid> collapsedForSearch = [];
    private string previousQuery = "";
    private ClipCard[] rows = [];
    internal ClipCard? Selected => list.SelectedItem as ClipCard;
    internal IReadOnlyList<ClipCard> Rows => rows;
    internal int Count { get; private set; }
    internal bool HasMultipleSelection => list.SelectedItems.Count > 1;
    internal IEnumerable<Guid> SelectedMembers => list.SelectedItems.OfType<ClipCard>()
        .SelectMany(row => row.Clip.Kind == ClipKind.Aggregate ? row.Clip.Members : [row.Clip.Id]).Distinct();

    internal void Refresh(string query, bool reset, Scope scope = Scope.All, ClipKind? kind = null,
        ClipCollection? collection = null, Guid? select = null)
    {
        if (previousQuery != query) collapsedForSearch.Clear();
        previousQuery = query;
        var current = Selected;
        var previousSelected = reset || select is not null || list.SelectionMode == SelectionMode.Single ? null :
            list.SelectedItems.OfType<ClipCard>().Select(row => (row.Clip.Id, row.Parent)).ToHashSet();
        Guid? clipId = select ?? (reset ? null : current?.Clip.Id);
        Guid? parentId = select is not null || reset ? null : current?.Parent;
        var now = DateTimeOffset.Now;
        var collections = app.Collections.ToDictionary(group => group.Id, group => group.Name);
        var available = app.Clips.Where(clip => scope == Scope.Trash ? clip.TrashedAt is not null : clip.TrashedAt is null)
            .ToDictionary(clip => clip.Id);
        bool InScope(Clip clip) => scope switch
        {
            Scope.Archive => clip.ArchivedAt is not null,
            Scope.Favorite => clip.Favorite,
            Scope.Recent => clip.LastPastedAt is not null,
            Scope.Trash => true,
            _ => clip.ArchivedAt is null
        };
        bool InCollection(Clip clip) => collection is null || (collection.Rules is { } rules
            ? clip.Kind != ClipKind.Aggregate && rules.Matches(clip, now) : clip.CollectionIds.Contains(collection.Id));
        bool IsMatch(Clip clip) => clip.Matches(query, clip.CollectionIds.Where(collections.ContainsKey).Select(id => collections[id]));

        var ordered = available.Values.Where(clip => InScope(clip) && InCollection(clip) && (kind is null || kind == clip.Kind))
            .OrderByDescending(clip => clip.Pinned)
            .ThenBy(clip => clip.Priority == ClipPriority.None ? int.MaxValue : (int)clip.Priority)
            .ThenByDescending(clip => scope == Scope.Recent ? clip.LastPastedAt : clip.CapturedAt).ToArray();
        var next = new List<ClipCard>();
        var nested = new HashSet<Guid>();
        bool searching = !string.IsNullOrWhiteSpace(query);

        foreach (var clip in ordered)
        {
            bool selfMatch = IsMatch(clip);
            if (clip.Kind != ClipKind.Aggregate || scope == Scope.Trash)
            {
                if (selfMatch) next.Add(new ClipCard(app, clip, clip.Members.Length, false, null, null));
                continue;
            }

            var members = clip.Members.Where(available.ContainsKey).Select(id => available[id]).ToArray();
            var matching = searching ? members.Where(IsMatch).ToArray() : members;
            if (!selfMatch && matching.Length == 0) continue;
            bool isExpanded = expanded.Contains(clip.Id) || searching && matching.Length > 0 && !selfMatch &&
                !collapsedForSearch.Contains(clip.Id);
            var visibleMembers = searching && !selfMatch ? matching : members;
            nested.UnionWith(visibleMembers.Select(member => member.Id));
            next.Add(new ClipCard(app, clip, members.Length, isExpanded, searching && !selfMatch ? matching.Length : null, null));
            if (isExpanded)
                next.AddRange(visibleMembers.Select(member => new ClipCard(app, member, 0, false, null, clip.Id)));
        }

        rows = next.Where(row => row.Parent is not null || row.Clip.Id == select || !nested.Contains(row.Clip.Id)).ToArray();
        Count = rows.Count(row => !row.IsChild);
        var matches = rows.FirstOrDefault(row => row.Clip.Id == clipId && row.Parent == parentId);
        matches ??= rows.FirstOrDefault(row => row.Clip.Id == clipId) ?? rows.FirstOrDefault();
        list.ItemsSource = rows;
        list.SelectedItem = matches;
        if (previousSelected is { Count: > 1 })
            foreach (var row in rows.Where(row => previousSelected.Contains((row.Clip.Id, row.Parent))))
                if (!list.SelectedItems.Contains(row)) list.SelectedItems.Add(row);
        if ((reset || select is not null) && matches is not null) list.ScrollIntoView(matches);
    }

    internal void Move(int amount)
    {
        if (rows.Length == 0) return;
        int index = Math.Clamp(list.SelectedIndex + amount, 0, rows.Length - 1);
        Select(rows[index]);
    }

    internal void Select(ClipCard row)
    {
        list.SelectedItem = row;
        list.ScrollIntoView(row);
    }

    internal void Expand(Guid parent)
    {
        expanded.Add(parent);
        collapsedForSearch.Remove(parent);
    }

    internal void Collapse(Guid parent)
    {
        expanded.Remove(parent);
        collapsedForSearch.Add(parent);
    }

    internal void ResetExpansion()
    {
        expanded.Clear();
        collapsedForSearch.Clear();
    }

    internal IEnumerable<Guid> SearchMembers(string query)
    {
        var collections = app.Collections.ToDictionary(group => group.Id, group => group.Name);
        var lookup = app.Clips.Where(clip => clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate)
            .ToDictionary(clip => clip.Id);
        return rows.SelectMany(row => row.Clip.Kind != ClipKind.Aggregate ? [row.Clip.Id]
            : row.Clip.Members.Where(id => lookup.TryGetValue(id, out var clip) &&
                (row.Clip.Matches(query) || clip.Matches(query, clip.CollectionIds.Where(collections.ContainsKey)
                    .Select(groupId => collections[groupId]))))).Distinct();
    }
}
