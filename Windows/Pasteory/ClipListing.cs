using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using Pasteory.Core;

namespace Pasteory.Windows;

internal enum Scope { All, Favorite, Recent, Archive, Trash, Ungrouped }

internal sealed record ClipListRow(Clip Clip, Guid? Parent = null, int MemberCount = 0, int? MatchCount = null,
    bool Expanded = false, string? MatchSummary = null);

internal sealed record ClipListing(ClipListRow[] Rows, Guid[] SearchMembers, int Count)
{
    internal static ClipListing Build(IReadOnlyList<Clip> source, string query, IEnumerable<Guid>? resultIds,
        Scope scope, ClipKind? kind, ClipCollection? collection, HashSet<Guid> expanded, HashSet<Guid> collapsed,
        Guid? reveal, CancellationToken cancellation = default, IReadOnlySet<Guid>? aiGroups = null,
        IReadOnlySet<Guid>? deferredOrganization = null)
    {
        bool searching = !string.IsNullOrWhiteSpace(query);
        var candidateIds = resultIds?.ToHashSet();
        var now = DateTimeOffset.Now;
        var available = source.Where(clip => scope == Scope.Trash ? clip.TrashedAt.HasValue : !clip.TrashedAt.HasValue);
        bool InScope(Clip clip) => (scope switch
        {
            Scope.Archive => clip.ArchivedAt.HasValue,
            Scope.Favorite => clip.Favorite,
            Scope.Recent => clip.LastPastedAt.HasValue,
            Scope.Trash => true,
            Scope.Ungrouped => IsUngrouped(clip, aiGroups, deferredOrganization),
            _ => !clip.ArchivedAt.HasValue
        }) && (kind is null || kind == clip.Kind) && (collection is null || (collection.Rules is { } rules
            ? clip.Kind != ClipKind.Aggregate && rules.Matches(clip, now) : clip.CollectionIds.Contains(collection.Id)));

        var matching = available.Where(clip => (candidateIds is null || candidateIds.Contains(clip.Id)) && InScope(clip)).ToArray();
        var searchMembers = searching ? matching.Where(clip => clip.Kind != ClipKind.Aggregate).Select(clip => clip.Id).ToList() : [];
        var nested = new HashSet<Guid>();
        var groups = new List<(ClipListRow Parent, ClipListRow[] Children)>();
        string needle = searching ? HistoryStore.NormalizeSearch(query) : "";
        string[] words = needle.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var parents = scope == Scope.Trash ? [] : available.Where(clip => clip.Kind == ClipKind.Aggregate).ToArray();
        if (parents.Length > 0)
        {
            var byId = available.ToDictionary(clip => clip.Id);
            var matchedIds = matching.Select(clip => clip.Id).ToHashSet();
            foreach (var parent in parents)
            {
                cancellation.ThrowIfCancellationRequested();
                var members = parent.Members.Select(id => byId.GetValueOrDefault(id)).OfType<Clip>().ToArray();
                var matched = members.Where(member => matchedIds.Contains(member.Id)).ToArray();
                bool ownScope = InScope(parent);
                bool selfMatch = matchedIds.Contains(parent.Id);
                if (!selfMatch && matched.Length == 0) continue;
                var visible = searching
                    ? matched.Length > 0 || !expanded.Contains(parent.Id) ? matched : members
                    : ownScope && scope == Scope.All && collection?.IsSmart != true ? members : matched;
                bool open = !collapsed.Contains(parent.Id) && (expanded.Contains(parent.Id) || searching && matched.Length > 0);
                nested.UnionWith((searching ? matched : visible).Select(member => member.Id));
                if (searching && selfMatch) searchMembers.AddRange(members.Select(member => member.Id));
                var children = open ? visible.Select(member => new ClipListRow(member, parent.Id,
                    MatchSummary: searching ? SummarizeMatch(member, words) : null)).ToArray() : [];
                groups.Add((new(parent, MemberCount: members.Length,
                    MatchCount: searching && matched.Length > 0 ? matched.Length : null, Expanded: open), children));
            }
        }
        var root = matching.Where(clip => (scope == Scope.Trash || clip.Kind != ClipKind.Aggregate) &&
            (!nested.Contains(clip.Id) || clip.Id == reveal))
            .Select(clip => (Parent: new ClipListRow(clip), Children: Array.Empty<ClipListRow>()));
        var ordered = root.Concat(groups).Select(result =>
        {
            cancellation.ThrowIfCancellationRequested();
            return (result.Parent, result.Children, Score: searching ? Score(result.Parent.Clip, needle, words) : 0);
        })
        .OrderByDescending(result => result.Parent.Clip.Pinned)
        .ThenByDescending(result => result.Score)
        .ThenBy(result => result.Parent.Clip.Priority == ClipPriority.None ? int.MaxValue : (int)result.Parent.Clip.Priority)
        .ThenByDescending(result => scope == Scope.Recent ? result.Parent.Clip.LastPastedAt : result.Parent.Clip.CapturedAt)
        .ThenBy(result => result.Parent.Clip.Id).ToArray();
        var rows = new List<ClipListRow>(ordered.Length);
        foreach (var result in ordered)
        {
            rows.Add(result.Parent);
            rows.AddRange(result.Children);
        }
        return new(rows.ToArray(), parents.Length > 0 ? searchMembers.Distinct().ToArray() : searchMembers.ToArray(), ordered.Length);
    }

    internal static bool IsUngrouped(Clip clip, IReadOnlySet<Guid>? aiGroups, IReadOnlySet<Guid>? deferredOrganization = null) =>
        clip.TrashedAt is null && clip.ArchivedAt is null && clip.Kind != ClipKind.Aggregate &&
        (deferredOrganization?.Contains(clip.Id) == true || aiGroups is null || !clip.CollectionIds.Any(aiGroups.Contains));

    private static int Score(Clip clip, string query, string[] words)
    {
        int score = Field(clip.DisplayTitle, 8) + Field(clip.Text, 5) + Field(clip.RecognizedImageText, 5) +
            Field(clip.Note, 4) + Field(clip.Source, 2);
        return score + (clip.Favorite ? 5 : 0) + (int)clip.Priority * 2 + Math.Min(5, (int)Math.Log2(Math.Max(1, clip.CopyCount)));

        int Field(string? text, int weight)
        {
            if (string.IsNullOrWhiteSpace(text)) return 0;
            foreach (char character in text)
            {
                if (character <= '\x7f' || character is >= '\u4e00' and <= '\u9fff') continue;
                text = HistoryStore.NormalizeSearch(text);
                break;
            }
            var value = text.AsSpan().Trim();
            int index = value.IndexOf(query.AsSpan(), StringComparison.OrdinalIgnoreCase);
            if (index == 0) return weight * (value.Length == query.Length ? 20 : 10);
            if (index > 0) return weight * 5;
            return words.Length < 2 ? 0 : words.Count(word => text.Contains(word, StringComparison.OrdinalIgnoreCase)) * weight;
        }
    }

    private static string? SummarizeMatch(Clip clip, string[] words)
    {
        if (words.Length == 0) return null;
        if (clip.Title.Length > 0 && ContainsWord(clip.Title))
            return Labels.Format("Title match: {0}", ClipCard.Short(clip.Title, 140, 1));
        if (clip.Note.Length > 0 && ContainsWord(clip.Note))
            return Labels.Format("Note match: {0}", ClipCard.Short(clip.Note, 140, 1));
        return null;

        bool ContainsWord(string value)
        {
            string normalized = HistoryStore.NormalizeSearch(value);
            return words.Any(word => normalized.Contains(word, StringComparison.Ordinal));
        }
    }
}
