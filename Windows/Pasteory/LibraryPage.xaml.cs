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
    private readonly Dictionary<string, (Scope Scope, ClipKind? Kind, Guid? Group, string Query, ClipViewPosition Position)> profilePositions = [];
    private ClipCollection[] visibleGroups = [];
    private string currentProfile = "";
    private bool showUngrouped;
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
        results.MarkingChanged += UpdateActions;
        searchDelay.Tick += (_, _) => { searchDelay.Stop(); Refresh(reset: true); };
        SizeChanged += (_, _) => UpdateColumns();
        TextCompositionManager.AddPreviewTextInputStartHandler(Search, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputHandler(Search, (_, _) => composing = false);
        Search.LostKeyboardFocus += (_, _) => composing = false;
        Refresh(reset: true);
    }

    private Window Owner => Window.GetWindow(this);

    internal void FocusResults()
    {
        _ = Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
        {
            if (IsVisible && !IsKeyboardFocusWithin) ClipList.Focus();
        }));
    }

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
        var display = app.Settings.GroupDisplay;
        bool viewChanged = currentProfile != display;
        ClipViewPosition? restored = null;
        if (viewChanged)
        {
            if (currentProfile.Length > 0)
                profilePositions[currentProfile] = (scope, kind, groupId, Search.Text, results.Position);
            currentProfile = display;
            if (profilePositions.TryGetValue(display, out var position))
                (scope, kind, groupId, Search.Text, restored) = position;
            else
            {
                scope = Scope.All;
                kind = null;
                groupId = null;
                Search.Clear();
            }
            searchDelay.Stop();
            reset = true;
        }
        bool hasThemes = app.Collections.Any(group => group.IsAi);
        ClipCollection[] ranked = hasThemes ? app.RankedAiGroups().ToArray() : [];
        var shown = GroupNavigation.Visible(display, app.Collections, ranked, library: true, groupId);
        if (groupId is { } selectedGroup && !shown.Any(group => group.Id == selectedGroup))
        {
            groupId = null;
            scope = Scope.All;
            kind = null;
            reset = true;
        }
        bool filter = app.Settings.Ai.Enabled || scope == Scope.Ungrouped || display == "AI groups" || hasThemes;
        if (viewChanged || filter != showUngrouped || !visibleGroups.SequenceEqual(shown))
        {
            showUngrouped = filter;
            visibleGroups = shown;
            BuildNav();
        }
        var selected = navButtons.First(item => item.Scope == scope && item.Kind == kind && item.Collection == groupId);
        foreach (var nav in navButtons)
        {
            bool active = nav.Button == selected.Button;
            nav.Button.SetResourceReference(BackgroundProperty, active ? "AccentGradient" : "TransparentBrush");
            int position = nav.Collection is { } collectionId ? Array.FindIndex(visibleGroups, group => group.Id == collectionId) + 1 :
                nav.Scope == Scope.All && nav.Kind is null ? 0 : -1;
            string hint = GroupNavigation.Hint(app.Settings, position);
            bool ai = nav.Collection is not null && position > 0 && visibleGroups[position - 1].IsAi;
            var row = GroupNavigation.Row(nav.Glyph, nav.Name, hint, active ? "NavSelectionInk" : "Ink", ai);
            nav.Button.Content = row;
            nav.Button.ToolTip = hint.Length > 0 ? $"{nav.Name} · {hint}" : nav.Name;
        }
        var collection = app.Collections.FirstOrDefault(group => group.Id == groupId);
        var refresh = results.Refresh(Search.Text, reset, scope, kind, collection, select, focusChildren, restored);
        Heading.Text = selected.Name;
        RefreshThemeOverview(collection);
        Subtitle.Text = Search.Text.Trim().Length > 0 ? Labels.Format("Searching in {0}", selected.Name) :
            Labels.Get(scope switch
            {
                Scope.Favorite => "Clips you marked as favorites",
                Scope.Recent => "Clips recently pasted with Pasteory",
                Scope.Archive => "Older clips kept in your archive",
                Scope.Trash => "Deleted clips are kept for 30 days",
                Scope.Ungrouped => "Clips outside AI themes, including clips in manual groups",
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

    private ClipCollection? shownTheme;

    private void RefreshThemeOverview(ClipCollection? collection)
    {
        var theme = collection is { IsAi: true } ? collection : null;
        if (theme is not null && ReferenceEquals(shownTheme, theme)) return;
        if (shownTheme?.Id != theme?.Id) ThemeOverview.IsExpanded = false;
        shownTheme = theme;
        ThemeOverviewBody.Children.Clear();
        ThemeOverview.Visibility = theme is null ? Visibility.Collapsed : Visibility.Visible;
        if (theme is null) return;
        if (theme.Definition.Length > 0)
        {
            ThemeOverviewBody.Children.Add(Ui.SectionTitle("Theme definition"));
            ThemeOverviewBody.Children.Add(Ui.Text(theme.Definition, 12));
        }
        if (theme.Overview.Length > 0)
        {
            ThemeOverviewBody.Children.Add(Ui.Text(theme.Overview, 12, "Muted"));
            if (theme.OverviewClips is { Length: > 0 } sources)
            {
                var names = new WrapPanel { Margin = new Thickness(0, 5, 0, 0) };
                foreach (Guid id in sources.Take(8))
                {
                    var action = Ui.Button("View source clip", () =>
                    {
                        if (app.Clips.FirstOrDefault(item => item.Id == id && item.TrashedAt is null) is { } clip) Reveal(clip);
                    });
                    action.Margin = new Thickness(0, 3, 5, 3);
                    names.Children.Add(action);
                }
                ThemeOverviewBody.Children.Add(names);
            }
        }
        var edit = Ui.Button("Edit theme definition", () => ShowThemeDefinitionEditor(theme));
        edit.HorizontalAlignment = HorizontalAlignment.Left;
        edit.Margin = new Thickness(0, 6, 0, 0);
        ThemeOverviewBody.Children.Add(edit);
    }

    private void ShowThemeDefinitionEditor(ClipCollection group) => LibraryEditors.ShowModal(Owner, "Edit theme definition", close =>
    {
        var body = new StackPanel();
        var value = Ui.Field("Theme definition", group.Definition, 2000);
        value.AcceptsReturn = true;
        value.MinHeight = 130;
        value.TextWrapping = TextWrapping.Wrap;
        value.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        Ui.AddField(body, "Theme definition", value);
        return LibraryEditors.Wrap("Edit theme definition", body, value, () => app.EditAiGroupDefinition(group, value.Text), close);
    }, 520, 350);

    private void BuildNav()
    {
        Navigation.Children.Clear();
        navButtons.Clear();
        AddHeading("Library");
        var profiles = new UniformGrid { Rows = 1, Margin = new Thickness(0, 5, 0, 8) };
        foreach (string profile in GroupNavigation.Profiles)
        {
            var button = Ui.Button(GroupNavigation.ProfileTitle(profile), () => app.SetGroupProfile(profile),
                app.Settings.GroupDisplay == profile ? "PrimaryButton" : null);
            button.FontSize = 10.5;
            button.Padding = new Thickness(2);
            button.MinHeight = 25;
            button.Margin = new Thickness(0, 0, 3, 0);
            button.ToolTip = Labels.Get(profile);
            profiles.Children.Add(button);
        }
        Navigation.Children.Add(profiles);
        AddNav("All clips", Glyph.Library);
        if (showUngrouped) AddNav("Ungrouped", Glyph.Group, Scope.Ungrouped);
        AddNav("Favorites", Glyph.Favorite, Scope.Favorite);
        AddNav("Recently used", Glyph.Recent, Scope.Recent);
        AddNav("Archive", Glyph.Archive, Scope.Archive);
        AddNav("Trash", Glyph.Trash, Scope.Trash);
        AddHeading("Content types");
        foreach (var clipKind in new[] { ClipKind.Text, ClipKind.Image, ClipKind.Link, ClipKind.Color,
            ClipKind.Code, ClipKind.Files, ClipKind.Mixed })
            AddNav(clipKind.ToString(), Glyph.ForKind(clipKind), filter: clipKind);
        if (visibleGroups.Any(group => group.IsAi))
        {
            AddHeading(currentProfile == "Common groups" ? "Recommended AI groups" : "AI groups");
            foreach (var group in visibleGroups.Where(group => group.IsAi)) AddGroup(group);
        }
        if (currentProfile is "AI groups" or "Minimal") return;
        AddHeading("Groups");
        foreach (var group in visibleGroups.Where(group => !group.IsSmart && !group.IsAi)) AddGroup(group);
        AddCreate("New group", Glyph.Add, false);
        AddHeading("Smart groups");
        foreach (var group in visibleGroups.Where(group => group.IsSmart)) AddGroup(group);
        AddCreate("New smart group", Glyph.Smart, true);
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
            ClipMenus.Add(button.ContextMenu, "Edit theme definition", () => ShowThemeDefinitionEditor(group));
            ClipMenus.Add(button.ContextMenu, "Review existing theme", async () => await app.ReviewThemeAsync(group));
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
                id == group.Id || app.Collections.FirstOrDefault(item => item.Id == id) is not { } moved ||
                moved.IsSmart != group.IsSmart || moved.IsAi != group.IsAi) return;
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
        SelectionBar.Visibility = results.IsMarking ? Visibility.Visible : Visibility.Collapsed;
        MarkStatus.Text = Labels.Format("{0} selected", results.MarkedCount);
        AggregateSelectionButton.IsEnabled = !results.IsLoading && results.MarkedCount >= 2;
        AggregateButton.Visibility = scope != Scope.Trash && !results.IsMarking && Search.Text.Trim().Length > 0 ?
            Visibility.Visible : Visibility.Collapsed;
        AggregateButton.IsEnabled = !searchDelay.IsEnabled && !results.IsLoading && results.SearchMembers.Count >= 2;
        AggregateButton.ToolTip = AggregateButton.IsEnabled ? null : Labels.Get("Choose at least two different clips.");
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
        results.EndMarking(restore: false);
        searchDelay.Stop();
        searchDelay.Start();
        UpdateActions();
    }

    private void FocusSearch(object sender, MouseButtonEventArgs e) => Search.Focus();
    private void ClearQuery(object sender, RoutedEventArgs e) { Search.Clear(); Search.Focus(); }
    internal bool TryCancelMarking() => results.EndMarking(restore: true);
    internal bool IsComposingSearch => Search.IsKeyboardFocused && composing;

    private void CancelMarking(object sender, RoutedEventArgs e)
    {
        TryCancelMarking();
        ClipList.Focus();
    }

    private void SelectMultipleRows(object sender, MouseButtonEventArgs e)
    {
        var modifiers = Keyboard.Modifiers;
        if (scope == Scope.Trash || searchDelay.IsEnabled ||
            (e.OriginalSource as FrameworkElement)?.DataContext is not ClipCard row ||
            !results.MarkClick(row, modifiers.HasFlag(ModifierKeys.Control), modifiers.HasFlag(ModifierKeys.Shift))) return;
        ClipList.Focus();
        e.Handled = true;
    }

    private void UseSelected(object sender, MouseButtonEventArgs e)
    {
        if (searchDelay.IsEnabled || results.IsLoading || results.IsMarking ||
            (e.OriginalSource as FrameworkElement)?.DataContext is not ClipCard row) return;
        if (!ToggleAggregation(row)) _ = app.UseClipAsync(row.Clip, true, false);
    }

    private bool ToggleAggregation(ClipCard row)
    {
        if (row.Clip.Kind != ClipKind.Aggregate) return false;
        results.Expand(row.Clip.Id);
        Refresh(focusChildren: row.Clip.Id);
        return true;
    }

    private void Collapse(ClipCard row)
    {
        Guid parent = row.Parent ?? row.Clip.Id;
        results.Collapse(parent);
        if (results.LastChild(parent) is { } child && app.Clips.FirstOrDefault(clip => clip.Id == parent)?.LastSelectedMember != child)
            app.UpdateClip(parent, item => item with { LastSelectedMember = child });
        Refresh(select: parent);
    }

    private void SelectContextRow(object sender, MouseButtonEventArgs e)
    {
        if (results.IsLoading || (e.OriginalSource as FrameworkElement)?.DataContext is not ClipCard row) { ClipList.ContextMenu = null; return; }
        results.Select(row);
        ClipList.ContextMenu = ClipMenus.ForClip(app, row, Owner, () => EditInfo(row.Clip, false), () => EditInfo(row.Clip, true),
            () => EditAggregation(row.Clip), () => { if (!ToggleAggregation(row)) app.OpenClip(row.Clip, Owner); }, () => Collapse(row));
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
            if (app.Settings.GroupDisplay is "Minimal" or "AI groups" && group?.IsAi != true)
                app.SetGroupProfile("Common groups");
            scope = Scope.All;
            kind = null;
            groupId = id;
            Refresh(reset: true);
        }), smart ? 560 : 380, smart ? 620 : 330);

    private void AggregateResults(object sender, RoutedEventArgs e) => _ = AggregateAsync(fromButton: true);

    private async Task AggregateAsync(bool fromButton)
    {
        if (scope == Scope.Trash) return;
        if (searchDelay.IsEnabled)
        {
            searchDelay.Stop();
            if (!await RefreshAsync(reset: true)) return;
        }
        if (results.IsLoading) return;
        if (results.IsMarking)
        {
            var selected = results.SelectedMembers.ToArray();
            if (selected.Length < 2) app.Notify("Choose at least two different clips.");
            else ShowAggregate(null, selected, Labels.Get("New aggregation"), null, false);
            return;
        }
        if (!fromButton && results.Selected?.Clip is { Kind: ClipKind.Aggregate } parent)
        {
            EditAggregation(parent);
            return;
        }
        string query = Search.Text.Trim();
        if (query.Length > 0)
        {
            if (results.SearchMembers.Count < 2) app.Notify("Choose at least two different clips.");
            else ShowAggregate(null, results.SearchMembers, LibraryEditors.SearchAggregationTitle(query), query, true);
        }
        else if (results.StartMarking()) ClipList.Focus();
    }

    private void EditAggregation(Clip clip) => ShowAggregate(clip, clip.Members, clip.Title, clip.AggregationOrigin, clip.AggregationFromSearch);
    private void ShowAggregate(Clip? existing, IEnumerable<Guid> members, string title, string? origin, bool search) =>
        LibraryEditors.ShowModal(Owner, existing is null ? "Aggregate clips" : "Edit aggregation", close =>
            LibraryEditors.Aggregation(app, existing, members, title, origin, search, compact: false, close, id =>
            {
                results.EndMarking(restore: false);
                Search.Clear();
                searchDelay.Stop();
                scope = Scope.All;
                kind = null;
                groupId = null;
                Refresh(reset: true, select: id);
            }), 520, 470);

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

    internal void HandleKey(KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var modifiers = Keyboard.Modifiers;
        bool searchFocused = Search.IsKeyboardFocused;
        if (searchFocused && (e.Key == Key.ImeProcessed || composing && key is Key.Enter or Key.Up or Key.Down or Key.Left or Key.Right))
            return;
        bool Match(Command command) => Shortcuts.Match(app.Settings, command, key, modifiers);
        if (Match(Command.Search))
        {
            if (Search.IsKeyboardFocused) ClipList.Focus(); else Search.Focus();
        }
        else if (!searchFocused && Keyboard.FocusedElement is TextBoxBase or PasswordBox or ComboBox)
            return;
        else if (!composing && GroupNavigation.Match(app.Settings, key, modifiers) is { } groupAction)
        {
            if (groupAction.Profile is { } profile) app.SetGroupProfile(profile);
            else if (groupAction.Position <= visibleGroups.Length)
            {
                scope = Scope.All;
                kind = null;
                groupId = groupAction.Position == 0 ? null : visibleGroups[groupAction.Position - 1].Id;
                Refresh(reset: true);
            }
        }
        else if ((searchFocused || results.IsMarking) && modifiers == ModifierKeys.None && key is Key.Up or Key.Down)
        {
            if (!searchDelay.IsEnabled) results.Move(key == Key.Up ? -1 : 1);
        }
        else if (results.IsMarking && !searchFocused && modifiers == ModifierKeys.None && key == Key.Space)
            results.ToggleCurrentMark();
        else if (results.IsMarking && modifiers == ModifierKeys.None && key == Key.Enter)
            _ = AggregateAsync(fromButton: false);
        else if (Match(Command.NewGroup)) EditGroup(null, false);
        else if (Match(Command.Aggregate))
            _ = AggregateAsync(fromButton: false);
        else if (results.IsMarking) return;
        else if (searchFocused && (modifiers == ModifierKeys.None && key != Key.Enter ||
            modifiers == ModifierKeys.Control && (key is Key.A or Key.X or Key.V or Key.Z || key == Key.C && Search.SelectionLength > 0)))
            return;
        else if (!searchDelay.IsEnabled && results.Selected is { } row && scope != Scope.Trash)
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
                Collapse(row);
            }
            else if (Match(Command.Paste) || Match(Command.Copy) ||
                Match(Command.PastePlain) || Match(Command.CopyPlain) || Match(Command.OpenClip))
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
