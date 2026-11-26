using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Threading;
using Pasteory.Core;

namespace Pasteory.Windows;

public partial class LibraryPage : UserControl
{
    private readonly App app;
    private readonly ClipResults results;
    private readonly DispatcherTimer searchDelay = new() { Interval = TimeSpan.FromMilliseconds(180) };
    private readonly List<(Button Button, Scope Scope, ClipKind? Kind, Guid? Collection, string Glyph, string Name)> navButtons = [];
    private ClipCollection[] visibleGroups = [];
    private Scope scope = Scope.All;
    private ClipKind? kind;
    private Guid? groupId;
    private Clip? detailsClip;
    private bool composing;
    private bool compact;
    private Point dragOrigin;
    private Guid? dragId;

    internal LibraryPage(App app)
    {
        this.app = app;
        InitializeComponent();
        results = new ClipResults(app, ClipList);
        searchDelay.Tick += (_, _) => { searchDelay.Stop(); Refresh(reset: true); };
        SizeChanged += (_, _) => UpdateColumns();
        PreviewKeyDown += OnKey;
        TextCompositionManager.AddPreviewTextInputStartHandler(Search, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputHandler(Search, (_, _) => composing = false);
        Search.LostKeyboardFocus += (_, _) => composing = false;
        BuildNav();
        Refresh(reset: true);
    }

    private Window Owner => Window.GetWindow(this);

    internal void Reveal(Clip clip)
    {
        Search.Clear();
        searchDelay.Stop();
        scope = clip.ArchivedAt is not null ? Scope.Archive : Scope.All;
        kind = null;
        groupId = null;
        Refresh(reset: true, select: clip.Id);
    }

    internal void Refresh(bool reset = false, Guid? select = null, Guid? focusChildren = null) =>
        _ = RefreshAsync(reset, select, focusChildren);

    private async Task<bool> RefreshAsync(bool reset = false, Guid? select = null, Guid? focusChildren = null)
    {
        if (!visibleGroups.SequenceEqual(app.Collections))
        {
            if (!app.Collections.Any(collection => collection.Id == groupId)) groupId = null;
            BuildNav();
        }
        var selected = navButtons.First(item => item.Scope == scope && item.Kind == kind && item.Collection == groupId);
        foreach (var nav in navButtons)
        {
            bool active = nav.Button == selected.Button;
            nav.Button.SetResourceReference(BackgroundProperty, active ? "AccentGradient" : "TransparentBrush");
            var row = Ui.WithIcon(nav.Glyph, nav.Name, active ? "NavSelectionInk" : "Ink");
            nav.Button.Content = row;
        }
        var collection = app.Collections.FirstOrDefault(group => group.Id == groupId);
        var refresh = results.Refresh(Search.Text, reset, scope, kind, collection, select, focusChildren);
        Heading.Text = selected.Name;
        Subtitle.Text = Search.Text.Trim().Length > 0 ? Labels.Format("Searching in {0}", selected.Name) :
            Labels.Get(scope switch
            {
                Scope.Favorite => "Clips you marked as favorites",
                Scope.Recent => "Clips recently pasted with Pasteory",
                Scope.Archive => "Older clips kept in your archive",
                Scope.Trash => "Deleted clips are kept for 30 days",
                _ => collection is null ? "Saved text, images, links, code and files" :
                    collection.IsAi && collection.Overview.Length > 0 ? collection.Overview :
                    collection.IsSmart ? "Clips matching the rules in this group" : "Clips organized into this group"
            });
        if (!refresh.IsCompleted)
        {
            Count.Text = Labels.Get("Searching…");
            EmptyMessage.Text = "";
            UpdateActions();
        }
        if (!await refresh) return false;
        Count.Text = Labels.Format("{0} results", results.Count);
        EmptyMessage.Text = results.Count == 0 ? Labels.Get(app.Clips.Count == 0 ?
            "Copy something to start your history." : "No clips match.") : "";
        CollectionCount.Text = Labels.Format("{0} items", app.Clips.Count(clip => clip.TrashedAt is null));
        UpdateDetails();
        UpdateActions();
        return true;
    }

    private void BuildNav()
    {
        Navigation.Children.Clear();
        navButtons.Clear();
        visibleGroups = app.Collections.ToArray();
        AddHeading("Library");
        AddNav("All clips", Glyph.Library);
        AddNav("Favorites", Glyph.Favorite, Scope.Favorite);
        AddNav("Recently used", Glyph.Recent, Scope.Recent);
        AddNav("Archive", Glyph.Archive, Scope.Archive);
        AddNav("Trash", Glyph.Trash, Scope.Trash);
        AddHeading("Content types");
        foreach (var clipKind in new[] { ClipKind.Text, ClipKind.Image, ClipKind.Link, ClipKind.Color,
            ClipKind.Code, ClipKind.Files, ClipKind.Mixed })
            AddNav(clipKind.ToString(), Glyph.ForKind(clipKind), filter: clipKind);
        AddHeading("Groups");
        foreach (var group in visibleGroups.Where(group => !group.IsSmart && !group.IsAi)) AddGroup(group);
        AddCreate("New group", Glyph.Add, false);
        AddHeading("Smart groups");
        foreach (var group in visibleGroups.Where(group => group.IsSmart)) AddGroup(group);
        AddCreate("New smart group", Glyph.Smart, true);
        if (visibleGroups.Any(group => group.IsAi))
        {
            AddHeading("AI groups");
            foreach (var group in visibleGroups.Where(group => group.IsAi)) AddGroup(group);
        }
    }

    private void AddGroup(ClipCollection group)
    {
        var button = AddNav(group.Name, group.IsSmart || group.IsAi ? Glyph.Smart : Glyph.Group, collection: group.Id);
        button.ContextMenu = ClipMenus.ForGroup(group, () => EditGroup(group, group.IsSmart), () =>
        {
            if (ClipMenus.Confirm(Owner, "Delete this group? Its clips will stay in the library.")) app.DeleteCollection(group);
        });
        if (group.IsAi)
        {
            ClipMenus.Add(button.ContextMenu, group.Locked ? "Unlock AI group" : "Lock AI group", () => app.ToggleAiGroupLock(group));
            ClipMenus.Add(button.ContextMenu, group.PackPayloads ? "Unpack saved content" : "Compress saved content", () => app.ToggleAiCompression(group));
        }
        button.ToolTip = group.Name;
        button.AllowDrop = true;
        button.PreviewMouseLeftButtonDown += (_, e) => { dragId = group.Id; dragOrigin = e.GetPosition(button); };
        button.PreviewMouseMove += (_, e) =>
        {
            if (dragId != group.Id || e.LeftButton != MouseButtonState.Pressed ||
                (e.GetPosition(button) - dragOrigin).Length < SystemParameters.MinimumHorizontalDragDistance) return;
            dragId = null;
            DragDrop.DoDragDrop(button, new DataObject("Pasteory.Group", group.Id.ToString()), DragDropEffects.Move);
        };
        button.Drop += (_, e) =>
        {
            if (e.Data.GetData("Pasteory.Group") is not string value || !Guid.TryParse(value, out Guid id) ||
                id == group.Id || app.Collections.FirstOrDefault(item => item.Id == id)?.IsSmart != group.IsSmart) return;
            app.MoveCollectionWithinType(id, group.Id);
            e.Handled = true;
        };
    }

    private void AddCreate(string name, string glyph, bool smart)
    {
        var button = Ui.Button(name, () => EditGroup(null, smart), "NavButton");
        button.Content = Ui.WithIcon(glyph, Labels.Get(name), "AccentInk");
        AutomationProperties.SetName(button, Labels.Get(name));
        Navigation.Children.Add(button);
    }

    private void AddHeading(string name)
    {
        var heading = Ui.Text(Labels.Get(name), 11, "Quiet");
        heading.Margin = new Thickness(9, Navigation.Children.Count == 0 ? 0 : 11, 0, 3);
        Navigation.Children.Add(heading);
    }

    private Button AddNav(string name, string glyph, Scope range = Scope.All, ClipKind? filter = null, Guid? collection = null)
    {
        string caption = collection is not null ? name : Labels.Get(name);
        var button = Ui.Button(caption, () =>
        {
            scope = range;
            kind = filter;
            groupId = collection;
            Refresh(reset: true);
        }, "NavButton");
        AutomationProperties.SetName(button, caption);
        navButtons.Add((button, range, filter, collection, glyph, caption));
        Navigation.Children.Add(button);
        return button;
    }

    private void UpdateColumns()
    {
        compact = ActualWidth < 1050;
        DetailsColumn.Width = compact ? new GridLength(0) : new GridLength(336);
        DetailsPane.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        NavigationColumn.Width = new GridLength(ActualWidth < 700 ? 152 : 232);
        UpdateActions();
    }

    private void UpdateActions()
    {
        if (results is null) return;
        DetailsButton.Visibility = compact && results.Selected is not null ? Visibility.Visible : Visibility.Collapsed;
        AggregateButton.Visibility = !results.IsLoading && scope != Scope.Trash && (Search.Text.Trim().Length > 0 && results.Count > 0 ||
            results.HasMultipleSelection) ? Visibility.Visible : Visibility.Collapsed;
        EmptyTrashButton.Visibility = scope == Scope.Trash && results.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ResultActions.Visibility = DetailsButton.Visibility == Visibility.Visible || AggregateButton.Visibility == Visibility.Visible ||
            EmptyTrashButton.Visibility == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        Tools.IsEnabled = results.Selected?.Clip is { TrashedAt: null, PlainText.Length: > 0 };
    }

    private void UpdateDetails()
    {
        var clip = results.Selected?.Clip;
        if (ReferenceEquals(detailsClip, clip) && DetailsHost.Content is not null) return;
        detailsClip = clip;
        DetailsHost.Content = new ClipDetails(app, clip, () => results.Selected is { } row && ToggleAggregation(row));
    }

    private void SelectedChanged(object sender, SelectionChangedEventArgs e)
    {
        if (results is null || results.IsPublishing || results.IsLoading) return;
        UpdateDetails();
        UpdateActions();
    }

    private void SearchChanged(object sender, TextChangedEventArgs e)
    {
        if (SearchHint is null || ClearSearch is null) return;
        SearchHint.Visibility = Search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ClearSearch.Visibility = Search.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (results is null) return;
        searchDelay.Stop();
        searchDelay.Start();
    }

    private void FocusSearch(object sender, MouseButtonEventArgs e) => Search.Focus();
    private void ClearQuery(object sender, RoutedEventArgs e) { Search.Clear(); Search.Focus(); }
    private void UseSelected(object sender, MouseButtonEventArgs e)
    {
        if (results.IsLoading || (e.OriginalSource as FrameworkElement)?.DataContext is not ClipCard row) return;
        if (!ToggleAggregation(row)) _ = app.UseClipAsync(row.Clip, true, false);
    }

    private bool ToggleAggregation(ClipCard row)
    {
        if (row.Clip.Kind != ClipKind.Aggregate) return false;
        results.Expand(row.Clip.Id);
        Refresh(focusChildren: row.Clip.Id);
        return true;
    }

    private void SelectContextRow(object sender, MouseButtonEventArgs e)
    {
        if (results.IsLoading || (e.OriginalSource as FrameworkElement)?.DataContext is not ClipCard row) { ClipList.ContextMenu = null; return; }
        results.Select(row);
        ClipList.ContextMenu = ClipMenus.ForClip(app, row, Owner, () => EditInfo(row.Clip, false), () => EditInfo(row.Clip, true),
            () => EditAggregation(row.Clip), () => { if (!ToggleAggregation(row)) app.OpenClip(row.Clip, Owner); });
        if (app.Collections.FirstOrDefault(group => group.Id == groupId && group.IsAi) is { } topic)
            ClipMenus.Add(ClipList.ContextMenu, "Remove from AI group", () => app.ExcludeFromAiGroup(topic, row.Clip));
    }

    private void ShowTools(object sender, RoutedEventArgs e)
    {
        var menu = ClipMenus.Tools(app, results.Selected?.Clip);
        menu.PlacementTarget = Tools;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    private void ShowDetails(object sender, RoutedEventArgs e)
    {
        if (results.Selected is not { } row) return;
        var window = new Window
        {
            Owner = Owner, Title = Labels.Get("Clip details"), Width = 440, Height = 660,
            MinWidth = 330, MinHeight = 330, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false, Content = new ClipDetails(app, row.Clip, () => ToggleAggregation(row))
        };
        window.PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape) window.Close(); };
        window.ShowDialog();
    }

    private void EmptyTrash(object sender, RoutedEventArgs e)
    {
        if (ClipMenus.Confirm(Owner, "Permanently delete all clips in Trash?")) app.EmptyTrash();
    }

    private void EditInfo(Clip clip, bool groups) => LibraryEditors.ShowModal(Owner, "Edit information",
        close => LibraryEditors.ClipInfo(app, clip, groups, close), 430, 480);

    private void EditGroup(ClipCollection? group, bool smart) => LibraryEditors.ShowModal(Owner, smart ? "Smart groups" : "Groups",
        close => LibraryEditors.Group(app, group, smart, close, id =>
        {
            scope = Scope.All;
            kind = null;
            groupId = id;
            Refresh(reset: true);
        }), smart ? 560 : 380, smart ? 620 : 330);

    private async void AggregateResults(object sender, RoutedEventArgs e)
    {
        if (searchDelay.IsEnabled)
        {
            searchDelay.Stop();
            if (!await RefreshAsync()) return;
        }
        if (results.IsLoading) return;
        Guid[] selected = (results.HasMultipleSelection ? results.SelectedMembers : results.SearchMembers).ToArray();
        if (selected.Length < 2)
        {
            app.Notify("Choose at least two different clips.");
            return;
        }
        ShowAggregate(null, selected, Search.Text.Trim().Length > 0 ? Search.Text.Trim() : Labels.Get("Aggregation"),
            Search.Text.Trim().Length > 0 ? Search.Text.Trim() : "Manual", false);
    }

    private void EditAggregation(Clip clip) => ShowAggregate(clip, clip.Members, clip.Title, clip.AggregationOrigin, true);
    private void ShowAggregate(Clip? existing, IEnumerable<Guid> members, string title, string? origin, bool chooseMembers) =>
        LibraryEditors.ShowModal(Owner, "Aggregate clips", close =>
            LibraryEditors.Aggregation(app, existing, members, title, origin, chooseMembers, close, id =>
            {
                Search.Clear();
                searchDelay.Stop();
                scope = Scope.All;
                kind = null;
                groupId = null;
                Refresh(reset: true, select: id);
            }));

    private void CreateText(object sender, RoutedEventArgs e) => LibraryEditors.ShowModal(Owner, "New text clip", close =>
    {
        var form = new StackPanel();
        var title = Ui.Field("Title", "", 160);
        var body = Ui.Field("Text", "", 1024 * 1024);
        body.MinHeight = 150;
        body.AcceptsReturn = true;
        body.TextWrapping = TextWrapping.Wrap;
        body.VerticalContentAlignment = VerticalAlignment.Top;
        Ui.AddField(form, "Title", title);
        Ui.AddField(form, "Text", body);
        var view = LibraryEditors.Wrap("New text clip", form, body, () =>
        {
            if (app.SaveManual(body.Text, title.Text) is not { } saved) return false;
            Search.Clear();
            searchDelay.Stop();
            scope = Scope.All;
            kind = null;
            groupId = null;
            Refresh(reset: true, select: saved.Id);
            return true;
        }, close);
        return view with { Submit = null };
    });

    private void OnKey(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var modifiers = Keyboard.Modifiers;
        if (Search.IsKeyboardFocused && (e.Key == Key.ImeProcessed || composing && key is Key.Enter or Key.Up or Key.Down))
            return;
        bool Match(Command command) => Shortcuts.Match(app.Settings, command, key, modifiers);
        if (Match(Command.Search))
        {
            if (Search.IsKeyboardFocused) ClipList.Focus(); else Search.Focus();
        }
        else if (Search.IsKeyboardFocused && modifiers == ModifierKeys.None && key is Key.Up or Key.Down)
            results.Move(key == Key.Up ? -1 : 1);
        else if (Match(Command.NewGroup)) EditGroup(null, false);
        else if (Match(Command.Aggregate))
        {
            if (!results.HasMultipleSelection && results.Selected?.Clip is { Kind: ClipKind.Aggregate } clip) EditAggregation(clip);
            else if (results.HasMultipleSelection || Search.Text.Trim().Length > 0) AggregateResults(this, new RoutedEventArgs());
            else if (results.Selected is { } selected) ShowAggregate(null, [selected.Clip.Id], Labels.Get("Aggregation"), "Manual", true);
        }
        else if (results.Selected is { } row && scope != Scope.Trash)
        {
            if (Match(Command.Edit)) EditInfo(row.Clip, false);
            else if (Match(Command.AssignGroups)) EditInfo(row.Clip, true);
            else if (Match(Command.Favorite)) app.ToggleFavorite(row.Clip);
            else if (Match(Command.Pin)) app.TogglePin(row.Clip);
            else if (Match(Command.Tools)) ShowTools(this, new RoutedEventArgs());
            else if (Match(Command.Trash))
            {
                if (row.Parent is { } parent) app.RemoveMember(parent, row.Clip.Id); else app.TrashClip(row.Clip);
            }
            else if (Match(Command.Expand) && row.Clip.Kind == ClipKind.Aggregate) ToggleAggregation(row);
            else if (Match(Command.Collapse) && (row.Parent is not null || row.Clip.Kind == ClipKind.Aggregate))
            {
                Guid parent = row.Parent ?? row.Clip.Id;
                results.Collapse(parent);
                if (row.Parent is not null) app.UpdateClip(parent, item => item with { LastSelectedMember = row.Clip.Id });
                Refresh(select: parent);
            }
            else if (Keyboard.FocusedElement is not TextBox && (Match(Command.Paste) || Match(Command.Copy) ||
                Match(Command.PastePlain) || Match(Command.CopyPlain) || Match(Command.OpenClip)))
            {
                if (!ToggleAggregation(row))
                {
                    if (Match(Command.OpenClip)) app.OpenClip(row.Clip, Owner);
                    else _ = app.UseClipAsync(row.Clip, Match(Command.Paste) || Match(Command.PastePlain),
                        Match(Command.PastePlain) || Match(Command.CopyPlain));
                }
            }
            else return;
        }
        else return;
        e.Handled = true;
    }
}
