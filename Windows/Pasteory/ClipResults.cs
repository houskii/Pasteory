using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Controls;
using System.Windows.Threading;
using Pasteory.Core;

namespace Pasteory.Windows;

internal readonly record struct ClipViewPosition(Guid? Clip, Guid? Parent, int Loaded, double? Offset);

internal sealed class ClipResults
{
    private const int PageSize = 100;
    private readonly App app;
    private readonly ListBox list;
    private readonly bool compact;
    private readonly HashSet<Guid> expanded = [];
    private readonly HashSet<Guid> collapsedForSearch = [];
    private readonly Dictionary<Guid, Guid> lastChildren = [];
    private readonly HashSet<Guid> marks = [];
    private (Guid Id, Guid? Parent)? selectionBeforeMarking;
    private (Guid Id, Guid? Parent)? markAnchor;
    private CancellationTokenSource? pending;
    private string previousQuery = "";
    private ClipListing listing = new([], [], 0);
    private ObservableCollection<ClipCard> page = [];
    private bool pageQueued;
    private ScrollViewer? scroll;

    internal ClipResults(App app, ListBox list, bool compact = false)
    {
        this.app = app;
        this.list = list;
        this.compact = compact;
        list.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler(OnScroll));
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is ClipCard { Parent: { } parent } child)
                lastChildren[parent] = child.Clip.Id;
        };
    }

    internal ClipCard? Selected => IsLoading ? null : list.SelectedItem as ClipCard;
    internal IReadOnlyList<ClipCard> Rows => IsLoading ? [] : page;
    internal int Count => listing.Count;
    internal bool IsLoading => pending is not null;
    internal bool IsPublishing { get; private set; }
    internal bool IsMarking { get; private set; }
    internal int MarkedCount => marks.Count;
    internal IEnumerable<Guid> SelectedMembers => IsLoading ? [] : listing.Rows.Where(row => marks.Contains(row.Clip.Id))
        .Select(row => row.Clip.Id).Distinct();
    internal IReadOnlyList<Guid> SearchMembers => IsLoading ? [] : listing.SearchMembers;
    internal event Action? MarkingChanged;
    internal ClipViewPosition Position => new((list.SelectedItem as ClipCard)?.Clip.Id, (list.SelectedItem as ClipCard)?.Parent,
        page.Count, scroll?.VerticalOffset);

    internal async Task<bool> Refresh(string input, bool reset, Scope scope = Scope.All, ClipKind? kind = null,
        ClipCollection? collection = null, Guid? select = null, Guid? focusChildren = null, ClipViewPosition? position = null,
        IReadOnlySet<Guid>? deferredOrganization = null)
    {
        string query = input.Trim();
        if (previousQuery != query)
        {
            collapsedForSearch.Clear();
            reset = true;
        }
        previousQuery = query;
        if (reset) EndMarking(restore: false);
        pending?.Cancel();
        using var request = new CancellationTokenSource();
        pending = request;
        var source = app.Clips;
        var collections = app.Collections;
        var open = new HashSet<Guid>(expanded);
        var closed = new HashSet<Guid>(collapsedForSearch);
        var current = list.SelectedItem as ClipCard;
        Guid? clipId = select ?? position?.Clip ?? (reset ? null : current?.Clip.Id);
        Guid? parentId = select is not null ? null : position?.Parent ?? (reset ? null : current?.Parent);
        Guid? reveal = parentId is null ? clipId : null;
        double? offset = position?.Offset ?? (reset || select is not null || focusChildren is not null ? null : scroll?.VerticalOffset);
        var aiGroups = scope == Scope.Ungrouped ? collections.Where(group => group.IsAi).Select(group => group.Id).ToHashSet() : null;

        ClipListing Load() => ClipListing.Build(source, query, query.Length == 0 ? null : app.SearchClipIds(query, request.Token),
            scope, kind, collection, open, closed, reveal, request.Token, aiGroups, deferredOrganization);

        ClipListing next;
        try
        {
            next = query.Length > 0 || source.Count > 3000 || collection?.IsSmart == true
                ? await Task.Run(Load, request.Token) : Load();
            if (request.IsCancellationRequested || !ReferenceEquals(source, app.Clips) ||
                !ReferenceEquals(collections, app.Collections)) return false;
        }
        catch (OperationCanceledException) { return false; }
        catch (Exception error) when (error is IOException or InvalidDataException)
        {
            if (!request.IsCancellationRequested) app.Notify(error.Message);
            next = new([], [], 0);
            if (request.IsCancellationRequested) return false;
        }
        finally
        {
            if (ReferenceEquals(pending, request)) pending = null;
        }

        Publish(next, reset, clipId, parentId, focusChildren, offset, position?.Loaded);
        return true;
    }

    private void Publish(ClipListing next, bool reset, Guid? clipId, Guid? parentId, Guid? focusChildren,
        double? offset, int? loaded)
    {
        listing = next;
        int index = clipId is { } id ? FindRow((id, parentId)) : -1;
        if (focusChildren is { } group)
        {
            Guid? last = lastChildren.TryGetValue(group, out Guid childId) ? childId :
                next.Rows.FirstOrDefault(row => row.Clip.Id == group)?.Clip.LastSelectedMember;
            int child = Array.FindIndex(next.Rows, row => row.Parent == group && row.Clip.Id == last);
            if (child < 0) child = Array.FindIndex(next.Rows, row => row.Parent == group);
            if (child >= 0) index = child;
        }
        if (index < 0) index = 0;
        if (IsMarking)
        {
            var visible = next.Rows.Select(row => row.Clip.Id).ToHashSet();
            marks.IntersectWith(visible);
        }
        int count = Math.Max(loaded ?? (reset ? PageSize : page.Count), ((index / PageSize) + 1) * PageSize);
        page = new ObservableCollection<ClipCard>(next.Rows.Take(count).Select(CreateCard));
        IsPublishing = true;
        try
        {
            list.ItemsSource = page;
            list.SelectedItem = page.ElementAtOrDefault(index);
            if (offset is { } restore && scroll is not null)
            {
                var observed = page;
                _ = list.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
                {
                    if (ReferenceEquals(observed, page)) scroll.ScrollToVerticalOffset(restore);
                }));
            }
            else if (list.SelectedItem is ClipCard selected) list.ScrollIntoView(selected);
        }
        finally { IsPublishing = false; }
    }

    private ClipCard CreateCard(ClipListRow row)
    {
        var card = new ClipCard(app, row, compact);
        card.SetMarking(IsMarking, marks.Contains(row.Clip.Id));
        return card;
    }

    private void OnScroll(object sender, ScrollChangedEventArgs e)
    {
        if (e.OriginalSource is ScrollViewer viewer) scroll = viewer;
        if (pageQueued || page.Count >= listing.Rows.Length || page.Count == 0 ||
            e.ExtentHeight - e.ViewportHeight - e.VerticalOffset > e.ViewportHeight * .5) return;
        var observed = page;
        pageQueued = true;
        _ = list.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
        {
            pageQueued = false;
            if (ReferenceEquals(observed, page) && !IsLoading) AppendPage();
        }));
    }

    private void AppendPage()
    {
        int end = Math.Min(listing.Rows.Length, page.Count + PageSize);
        for (int index = page.Count; index < end; index++) page.Add(CreateCard(listing.Rows[index]));
    }

    internal void Move(int amount)
    {
        if (IsLoading || page.Count == 0) return;
        int index = Math.Clamp(list.SelectedIndex + amount, 0, listing.Rows.Length - 1);
        if (index >= page.Count) AppendPage();
        Select(page[index]);
    }

    internal void Select(ClipCard row)
    {
        if (IsLoading) return;
        list.SelectedItem = row;
        list.ScrollIntoView(row);
    }

    internal bool StartMarking()
    {
        if (IsMarking || Selected is not { CanMark: true } row) return false;
        BeginMarking();
        markAnchor = row.Key;
        marks.Add(row.Clip.Id);
        PublishMarks();
        return true;
    }

    internal bool MarkClick(ClipCard row, bool control, bool shift)
    {
        if (IsLoading || !IsMarking && (!row.CanMark || !control && !shift)) return false;
        if (!IsMarking) BeginMarking();
        if (row.CanMark)
        {
            int first = shift && (markAnchor ?? selectionBeforeMarking) is { } anchor ? FindRow(anchor) : -1;
            int last = first >= 0 ? FindRow(row.Key) : -1;
            if (first >= 0 && last >= 0)
            {
                for (int index = Math.Min(first, last); index <= Math.Max(first, last); index++)
                {
                    var clip = listing.Rows[index].Clip;
                    if (clip.Kind != ClipKind.Aggregate && clip.TrashedAt is null) marks.Add(clip.Id);
                }
            }
            else ToggleMark(row.Clip.Id);
            markAnchor = row.Key;
        }
        Select(row);
        PublishMarks();
        return true;
    }

    internal void ToggleCurrentMark()
    {
        if (!IsMarking || Selected is not { CanMark: true } row) return;
        ToggleMark(row.Clip.Id);
        markAnchor = row.Key;
        PublishMarks();
    }

    internal bool EndMarking(bool restore)
    {
        if (!IsMarking) return false;
        IsMarking = false;
        marks.Clear();
        var previous = selectionBeforeMarking;
        selectionBeforeMarking = markAnchor = null;
        if (restore && !IsLoading && previous is { } key)
        {
            int index = FindRow(key);
            if (index >= 0)
            {
                while (index >= page.Count) AppendPage();
                Select(page[index]);
            }
        }
        PublishMarks();
        return true;
    }

    private void BeginMarking()
    {
        selectionBeforeMarking = Selected?.Key;
        IsMarking = true;
    }

    private int FindRow((Guid Id, Guid? Parent) key)
    {
        int index = Array.FindIndex(listing.Rows, row => row.Clip.Id == key.Id && row.Parent == key.Parent);
        return index >= 0 ? index : Array.FindIndex(listing.Rows, row => row.Clip.Id == key.Id);
    }

    private void ToggleMark(Guid id)
    {
        if (!marks.Add(id)) marks.Remove(id);
    }

    private void PublishMarks()
    {
        foreach (var row in page) row.SetMarking(IsMarking, marks.Contains(row.Clip.Id));
        MarkingChanged?.Invoke();
    }

    internal Guid? LastChild(Guid parent) => lastChildren.TryGetValue(parent, out Guid id) ? id : null;

    internal void Expand(Guid parent)
    {
        expanded.Add(parent);
        collapsedForSearch.Remove(parent);
    }

    internal void Collapse(Guid parent)
    {
        expanded.Remove(parent);
        if (previousQuery.Length > 0) collapsedForSearch.Add(parent);
    }

    internal void ResetExpansion()
    {
        expanded.Clear();
        collapsedForSearch.Clear();
    }
}
