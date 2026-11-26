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

internal sealed class ClipResults
{
    private const int PageSize = 100;
    private readonly App app;
    private readonly ListBox list;
    private readonly bool compact;
    private readonly HashSet<Guid> expanded = [];
    private readonly HashSet<Guid> collapsedForSearch = [];
    private CancellationTokenSource? pending;
    private string previousQuery = "";
    private ClipListing listing = new([], [], 0);
    private ObservableCollection<ClipCard> page = [];
    private bool pageQueued;

    internal ClipResults(App app, ListBox list, bool compact = false)
    {
        this.app = app;
        this.list = list;
        this.compact = compact;
        list.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler(OnScroll));
    }

    internal ClipCard? Selected => IsLoading ? null : list.SelectedItem as ClipCard;
    internal IReadOnlyList<ClipCard> Rows => IsLoading ? [] : page;
    internal int Count => listing.Count;
    internal bool IsLoading => pending is not null;
    internal bool IsPublishing { get; private set; }
    internal bool HasMultipleSelection => !IsLoading && list.SelectedItems.Count > 1;
    internal IEnumerable<Guid> SelectedMembers => IsLoading ? [] : list.SelectedItems.OfType<ClipCard>()
        .SelectMany(row => row.Clip.Kind == ClipKind.Aggregate ? row.Clip.Members : [row.Clip.Id]).Distinct();
    internal IReadOnlyList<Guid> SearchMembers => IsLoading ? [] : listing.SearchMembers;

    internal async Task<bool> Refresh(string input, bool reset, Scope scope = Scope.All, ClipKind? kind = null,
        ClipCollection? collection = null, Guid? select = null, Guid? focusChildren = null)
    {
        string query = input.Trim();
        if (previousQuery != query) collapsedForSearch.Clear();
        previousQuery = query;
        pending?.Cancel();
        using var request = new CancellationTokenSource();
        pending = request;
        var source = app.Clips;
        var collections = app.Collections;
        var open = new HashSet<Guid>(expanded);
        var closed = new HashSet<Guid>(collapsedForSearch);
        var current = list.SelectedItem as ClipCard;
        var previousSelected = reset || select is not null || list.SelectionMode == SelectionMode.Single ? null :
            list.SelectedItems.OfType<ClipCard>().Select(row => (row.Clip.Id, row.Parent)).ToHashSet();
        Guid? clipId = select ?? (reset ? null : current?.Clip.Id);
        Guid? parentId = select is not null || reset ? null : current?.Parent;

        ClipListing Load() => ClipListing.Build(source, query, query.Length == 0 ? null : app.SearchClipIds(query, request.Token),
            scope, kind, collection, open, closed, select, request.Token);

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

        Publish(next, reset, clipId, parentId, previousSelected, focusChildren);
        return true;
    }

    private void Publish(ClipListing next, bool reset, Guid? clipId, Guid? parentId,
        HashSet<(Guid, Guid?)>? previousSelected, Guid? focusChildren)
    {
        listing = next;
        int index = Array.FindIndex(next.Rows, row => row.Clip.Id == clipId && row.Parent == parentId);
        if (index < 0) index = Array.FindIndex(next.Rows, row => row.Clip.Id == clipId);
        if (focusChildren is { } group)
        {
            Guid? last = next.Rows.FirstOrDefault(row => row.Clip.Id == group)?.Clip.LastSelectedMember;
            int child = Array.FindIndex(next.Rows, row => row.Parent == group && row.Clip.Id == last);
            if (child < 0) child = Array.FindIndex(next.Rows, row => row.Parent == group);
            if (child >= 0) index = child;
        }
        if (index < 0) index = 0;
        int count = Math.Max(reset ? PageSize : page.Count, ((index / PageSize) + 1) * PageSize);
        page = new ObservableCollection<ClipCard>(next.Rows.Take(count).Select(CreateCard));
        IsPublishing = true;
        try
        {
            list.ItemsSource = page;
            list.SelectedItem = page.ElementAtOrDefault(index);
            if (previousSelected is { Count: > 1 })
                foreach (var row in page.Where(row => previousSelected.Contains((row.Clip.Id, row.Parent))))
                    if (!list.SelectedItems.Contains(row)) list.SelectedItems.Add(row);
            if (list.SelectedItem is ClipCard selected) list.ScrollIntoView(selected);
        }
        finally { IsPublishing = false; }
    }

    private ClipCard CreateCard(ClipListRow row) => new(app, row, compact);

    private void OnScroll(object sender, ScrollChangedEventArgs e)
    {
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
