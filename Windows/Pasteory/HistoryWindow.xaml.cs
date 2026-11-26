using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Pasteory.Core;
using Forms = System.Windows.Forms;

namespace Pasteory.Windows;

public partial class HistoryWindow : Window
{
    private readonly App app;
    private readonly ClipResults results;
    private readonly DispatcherTimer helpTimer;
    private readonly DispatcherTimer statusTimer;
    private bool refreshing;
    private bool composing;
    private bool multiple;
    private int multiRow = -1;
    private bool originallyPositioned;
    private bool transientMenu;
    private bool accessibilityFocus;
    private int modalDepth;
    private Point groupDragOrigin;
    private Guid? draggingGroup;
    private EditorView? editor;
    private Window? help;
    private string lastStatus = "";
    private Guid? undoAggregationId;
    private IReadOnlyList<Clip>? statsSource;
    private DateTime statsDate;
    private string statsText = "";
    private Guid? currentGroupId;
    private GroupTab[] tabs = [];
    private Guid[] recommendedAi = [];

    internal HistoryWindow(App app)
    {
        this.app = app;
        InitializeComponent();
        results = new ClipResults(app, History, compact: true);
        helpTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        helpTimer.Tick += (_, _) =>
        {
            helpTimer.Stop();
            if (IsActive && Keyboard.Modifiers == ModifierKeys.Control && editor is null && !transientMenu) OpenHelp();
        };
        statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3.5) };
        statusTimer.Tick += (_, _) => { statusTimer.Stop(); lastStatus = ""; undoAggregationId = null; UpdateFooter(); };
        PreviewKeyDown += HandleKeys;
        PreviewKeyUp += (_, e) => { if (e.Key is Key.LeftCtrl or Key.RightCtrl) HideHelp(); };
        TextCompositionManager.AddPreviewTextInputStartHandler(Query, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputHandler(Query, (_, _) => composing = false);
        Query.LostKeyboardFocus += (_, _) => composing = false;
        Closing += HideInsteadOfClose;
        Deactivated += (_, _) =>
        {
            HideHelp();
            Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
            {
                if (!IsActive && IsVisible && !app.Settings.KeepPanelOpen && !transientMenu && !accessibilityFocus && modalDepth == 0)
                    Dismiss(restoreTarget: false);
            }));
        };
    }

    internal void Present(bool keepVisibleForAutomation = false)
    {
        accessibilityFocus = keepVisibleForAutomation;
        bool newPresentation = !IsVisible;
        if (newPresentation)
        {
            refreshing = true;
            Query.Clear();
            composing = false;
            multiple = false;
            History.SelectionMode = SelectionMode.Single;
            results.ResetExpansion();
            recommendedAi = app.Settings.Ai.Enabled ? app.RankedAiGroups().Take(3).Select(group => group.Id).ToArray() : [];
            refreshing = false;
            CloseEditor();
            Width = Math.Clamp(app.Settings.PanelWidth, MinWidth, 670);
            Height = Math.Clamp(app.Settings.PanelHeight, MinHeight, 760);
            PositionNearPointer();
            lastStatus = "";
            undoAggregationId = null;
        }
        Refresh(reset: newPresentation);
        Show();
        Activate();
        FocusManager.SetFocusedElement(this, FocusArea);
        Keyboard.Focus(FocusArea);
        if (newPresentation)
            Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
            {
                if (IsActive && IsVisible && editor is null && !Query.IsKeyboardFocusWithin && !Query.IsMouseOver)
                    Keyboard.Focus(FocusArea);
            }));
    }

    internal void Refresh(bool reset = false, Guid? select = null)
    {
        string display = app.Settings.GroupDisplay;
        var groups = app.Collections.Where(group => display switch
        {
            "AI groups" => group.IsAi,
            "All groups" => true,
            _ => !group.IsAi || group.Id == currentGroupId || recommendedAi.Contains(group.Id)
        });
        var nextTabs = groups.Select(group => new GroupTab(group)).Prepend(new GroupTab(null)).ToArray();
        if (!tabs.SequenceEqual(nextTabs) || tabs.Length == 0) UpdateGroups(nextTabs);
        PanelPin.SetResourceReference(ForegroundProperty, app.Settings.KeepPanelOpen ? "AccentInk" : "Muted");
        var offer = app.Updates?.Available;
        UpdateButton.Visibility = offer is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateButton.ToolTip = offer is null ? null : Labels.Format("Update {0} is available", offer.Version);
        UpdateButton.Background = app.Settings.Theme == "Orange" ? Brushes.PaleTurquoise : Brushes.NavajoWhite;
        UpdateButton.Foreground = app.Settings.Theme == "Orange" ? Brushes.DarkSlateGray : Brushes.SaddleBrown;
        bool sidebar = app.Settings.GroupSidebar && display != "Minimal";
        Sidebar.Visibility = sidebar ? Visibility.Visible : Visibility.Collapsed;
        GroupStrip.Visibility = ScopeBar.Visibility = display == "Minimal" ? Visibility.Collapsed : Visibility.Visible;
        GroupStrip.Margin = new Thickness(9, sidebar ? 1 : 4, 7, 0);
        RefreshResults(reset, select);
    }

    private void UpdateGroups(GroupTab[] next)
    {
        refreshing = true;
        tabs = next;
        Groups.ItemsSource = tabs;
        Groups.SelectedItem = tabs.FirstOrDefault(tab => tab.Id == currentGroupId) ?? tabs[0];
        currentGroupId = (Groups.SelectedItem as GroupTab)?.Id;
        var groupCount = new StackPanel { Orientation = Orientation.Horizontal };
        groupCount.Children.Add(Ui.Icon(Glyph.AllGroups, 12));
        var number = Ui.Text(app.Collections.Count.ToString(), 11, "Muted", strong: true);
        number.FontFamily = new FontFamily("Segoe UI");
        number.Margin = new Thickness(3, 0, 0, 0);
        groupCount.Children.Add(number);
        AllGroups.Content = groupCount;
        SidebarGroups.Children.Clear();
        foreach (var tab in tabs)
        {
            var button = Ui.Button(tab.Name, () => ChangeGroup(tab), "NavButton");
            button.Content = Ui.WithIcon(tab.Glyph, tab.Name);
            if (tab.Collection is { } group)
                button.ContextMenu = ClipMenus.ForGroup(group, () => EditGroup(group, group.IsSmart), () => DeleteGroup(group));
            SidebarGroups.Children.Add(button);
        }
        refreshing = false;
        UpdateScope();
    }

    private void UpdateScope()
    {
        int index = Math.Max(0, Groups.SelectedIndex);
        CurrentGroup.Text = Labels.Format("Current: {0}", tabs.ElementAtOrDefault(index)?.Name ?? Labels.Get("All"));
        GroupPosition.Text = index == 0 ? Labels.Format("{0} groups", tabs.Length - 1) :
            Labels.Format("Group {0} / {1}", index, tabs.Length - 1);
        for (int i = 0; i < SidebarGroups.Children.Count; i++)
            ((Button)SidebarGroups.Children[i]).SetResourceReference(BackgroundProperty, i == index ? "PanelTint" : "TransparentBrush");
    }

    private async void RefreshResults(bool reset, Guid? select = null, Guid? focusChildren = null)
    {
        RefreshSearchHint();
        var refresh = results.Refresh(Query.Text, reset, collection: (Groups.SelectedItem as GroupTab)?.Collection,
            select: select, focusChildren: focusChildren);
        if (!refresh.IsCompleted)
        {
            EmptyMessage.Text = "";
            QuickTools.IsEnabled = false;
        }
        if (!await refresh) return;
        EmptyMessage.Text = results.Count > 0 ? "" : Labels.Get(app.Clips.Count == 0 ?
            "Copy something to start your history." : "No clips match.");
        QuickTools.IsEnabled = results.Selected?.Clip.PlainText is { Length: > 0 };
        UpdateFooter();
    }

    internal void SetStatus(string message)
    {
        lastStatus = message;
        undoAggregationId = null;
        if (Status is null) return;
        statusTimer.Stop();
        statusTimer.Start();
        UpdateFooter();
    }

    internal void OfferAggregationUndo(Guid id)
    {
        if (!IsVisible) return;
        undoAggregationId = id;
        UpdateFooter();
    }

    private void UndoAggregation(object sender, RoutedEventArgs e)
    {
        if (undoAggregationId is { } id) app.UndoAggregation(id);
        undoAggregationId = null;
        UpdateFooter();
    }

    private void UpdateFooter()
    {
        var today = DateTime.Now.Date;
        var clips = app.Clips;
        if (!ReferenceEquals(statsSource, clips) || statsDate != today)
        {
            int totalToday = 0, totalWeek = 0;
            DateTime since = today.AddDays(-6);
            foreach (var clip in clips)
            {
                if (clip.TrashedAt is not null || clip.Kind == ClipKind.Aggregate) continue;
                var copied = clip.CapturedAt.LocalDateTime.Date;
                if (copied >= since) totalWeek++;
                if (copied == today) totalToday++;
            }
            statsSource = clips;
            statsDate = today;
            statsText = Labels.Format("Today {0} · 7 days {1}", totalToday, totalWeek);
        }
        Status.Text = lastStatus.Length > 0 ? lastStatus : multiple
            ? Labels.Format("{0} selected", History.SelectedItems.Count) : statsText;
        Status.ToolTip = Status.Text;
        NavigationHint.Visibility = lastStatus.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        UndoAggregationButton.Visibility = undoAggregationId.HasValue ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (QuickTools is null || results is null) return;
        QuickTools.IsEnabled = results.Selected?.Clip.PlainText is { Length: > 0 };
        if (multiple) UpdateFooter();
    }

    private void QueryChanged(object sender, TextChangedEventArgs e)
    {
        if (refreshing || !IsLoaded) return;
        StopMultiple();
        RefreshResults(reset: true);
    }

    private void RefreshSearchHint()
    {
        SearchHint.Visibility = Query.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ClearSearch.Visibility = Query.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void GroupChanged(object sender, SelectionChangedEventArgs e)
    {
        if (refreshing || !IsLoaded || Groups.SelectedItem is not GroupTab tab) return;
        currentGroupId = tab.Id;
        StopMultiple();
        CloseEditor(focus: false);
        UpdateScope();
        Groups.ScrollIntoView(tab);
        RefreshResults(reset: true);
    }

    private void ChangeGroup(GroupTab tab)
    {
        if (!tabs.Contains(tab))
        {
            currentGroupId = tab.Id;
            UpdateGroups([.. tabs, tab]);
            RefreshResults(reset: true);
        }
        else Groups.SelectedItem = tab;
        Keyboard.Focus(FocusArea);
    }

    private void HandleKeys(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var modifiers = Keyboard.Modifiers;
        if (transientMenu) return;
        if (editor is not null)
        {
            if (key == Key.Escape) { CloseEditor(); e.Handled = true; }
            else if (key == Key.Enter && modifiers == ModifierKeys.None && editor.Submit is not null &&
                Keyboard.FocusedElement is not Button and not ComboBox)
            {
                editor.Submit();
                e.Handled = true;
            }
            return;
        }
        if (key is Key.LeftCtrl or Key.RightCtrl && modifiers == ModifierKeys.Control && !e.IsRepeat)
        {
            helpTimer.Start();
            return;
        }
        HideHelp();
        if (Query.IsKeyboardFocused && (e.Key == Key.ImeProcessed ||
            composing && key is Key.Enter or Key.Up or Key.Down or Key.Left or Key.Right or Key.Escape))
            return;
        if (key == Key.Escape)
        {
            if (multiple) { StopMultiple(); UpdateFooter(); }
            else Dismiss(restoreTarget: true);
        }
        else if (modifiers == ModifierKeys.None && key is Key.Up or Key.Down)
        {
            int step = key == Key.Up ? -1 : 1;
            if (!multiple) results.Move(step);
            else MoveMultiCursor(step);
        }
        else if (modifiers == ModifierKeys.None && key is Key.Left or Key.Right)
        {
            if (!Query.IsKeyboardFocused && tabs.Length > 0)
            {
                int index = (Groups.SelectedIndex + (key == Key.Left ? tabs.Length - 1 : 1)) % tabs.Length;
                ChangeGroup(tabs[index]);
            }
        }
        else if (modifiers == ModifierKeys.Control && key is >= Key.D1 and <= Key.D9)
        {
            int index = key - Key.D1;
            if (results.Rows.Where(row => row.Clip.Kind != ClipKind.Aggregate).Skip(index).FirstOrDefault() is { } row)
                _ = app.UseClipAsync(row.Clip, true, false);
        }
        else if (Query.IsKeyboardFocused && (modifiers == ModifierKeys.None && key != Key.Enter ||
            modifiers == ModifierKeys.Control && key is Key.A or Key.X or Key.V or Key.Z ||
            modifiers == ModifierKeys.Control && key == Key.C && Query.SelectionLength > 0)) return;
        else if (!ExecuteShortcut(key, modifiers)) return;
        e.Handled = true;
    }

    private bool ExecuteShortcut(Key key, ModifierKeys modifiers)
    {
        var match = Shortcuts.Entries.FirstOrDefault(entry => entry.Action != Command.ShowPanel &&
            Shortcuts.Match(app.Settings, entry.Action, key, modifiers));
        if (match.Title is null) return false;
        if (multiple && key == Key.Space && modifiers == ModifierKeys.None &&
            results.Rows.ElementAtOrDefault(multiRow) is { } marked)
        {
            if (History.SelectedItems.Contains(marked)) History.SelectedItems.Remove(marked);
            else History.SelectedItems.Add(marked);
            return true;
        }
        switch (match.Action)
        {
            case Command.Search:
                if (Query.IsKeyboardFocused) Keyboard.Focus(FocusArea); else Query.Focus();
                return true;
            case Command.Library: ShowLibrary(); return true;
            case Command.Settings: ShowSettings(); return true;
            case Command.Close: Dismiss(restoreTarget: true); return true;
            case Command.NewGroup: EditGroup(null, false); return true;
            case Command.Aggregate: Aggregate(); return true;
            case Command.Paste when multiple: Aggregate(); return true;
        }

        if (results.Selected is not { } row) return true;
        var clip = row.Clip;
        switch (match.Action)
        {
            case Command.OpenClip: ActivateRow(row, paste: false); break;
            case Command.Paste: ActivateRow(row, paste: true); break;
            case Command.Copy when clip.Kind != ClipKind.Aggregate: _ = app.UseClipAsync(clip, false, false); break;
            case Command.CopyPlain when clip.Kind != ClipKind.Aggregate: _ = app.UseClipAsync(clip, false, true); break;
            case Command.PastePlain when clip.Kind != ClipKind.Aggregate: _ = app.UseClipAsync(clip, true, true); break;
            case Command.Edit: EditInfo(clip, false); break;
            case Command.AssignGroups: EditInfo(clip, true); break;
            case Command.Favorite: app.ToggleFavorite(clip); break;
            case Command.Pin: app.TogglePin(clip); break;
            case Command.Tools: OpenTools(History.ItemContainerGenerator.ContainerFromItem(row) as FrameworkElement ?? QuickTools); break;
            case Command.Trash:
                if (row.Parent is { } container) app.RemoveMember(container, clip.Id); else app.TrashClip(clip);
                break;
            case Command.Expand when clip.Kind == ClipKind.Aggregate: Expand(row); break;
            case Command.Collapse: Collapse(row); break;
        }
        return true;
    }

    private void ActivateRow(ClipCard row, bool paste)
    {
        if (results.IsLoading) return;
        if (row.Clip.Kind == ClipKind.Aggregate) Expand(row);
        else if (paste) _ = app.UseClipAsync(row.Clip, true, false);
        else
        {
            modalDepth++;
            try { app.OpenClip(row.Clip, this); }
            finally { modalDepth--; }
        }
    }

    private void Expand(ClipCard row)
    {
        results.Expand(row.Clip.Id);
        RefreshResults(reset: false, focusChildren: row.Clip.Id);
    }

    private void Collapse(ClipCard row)
    {
        Guid id = row.Parent ?? row.Clip.Id;
        if (row.Parent is null && row.Clip.Kind != ClipKind.Aggregate) return;
        results.Collapse(id);
        if (row.Parent is not null) app.UpdateClip(id, clip => clip with { LastSelectedMember = row.Clip.Id });
        RefreshResults(reset: false, select: id);
    }

    private void Aggregate()
    {
        if (results.IsLoading) return;
        var clip = results.Selected?.Clip;
        if (clip?.Kind == ClipKind.Aggregate && !multiple && !results.HasMultipleSelection)
        {
            ShowAggregation(clip, clip.Members, clip.Title, clip.AggregationOrigin, true);
            return;
        }
        if (multiple || results.HasMultipleSelection)
        {
            var selected = results.SelectedMembers.ToArray();
            if (selected.Length < 2) SetStatus(Labels.Get("Choose at least two different clips."));
            else ShowAggregation(null, selected, Labels.Get("Aggregation"), "Manual", false);
        }
        else if (!string.IsNullOrWhiteSpace(Query.Text))
            ShowAggregation(null, results.SearchMembers, Query.Text.Trim(), Query.Text, false);
        else if (clip is not null)
        {
            StartMultiple();
            SetStatus(Labels.Get("Select at least two clips, then press Enter."));
        }
    }

    private void ShowAggregation(Clip? clip, System.Collections.Generic.IEnumerable<Guid> members, string title, string? origin,
        bool chooseMembers) =>
        OpenEditor(LibraryEditors.Aggregation(app, clip, members, title, origin, chooseMembers, CloseEditorFromForm, id =>
        {
            StopMultiple();
            Query.Clear();
            ChangeGroup(tabs[0]);
            RefreshResults(reset: true, select: id);
        }));

    private void StopMultiple()
    {
        if (!multiple) return;
        multiple = false;
        multiRow = -1;
        History.SelectionMode = SelectionMode.Single;
    }

    private void StartMultiple()
    {
        multiple = true;
        multiRow = Math.Max(0, History.SelectedIndex);
        History.SelectionMode = SelectionMode.Extended;
        MoveMultiCursor(0);
    }

    private void MoveMultiCursor(int step)
    {
        if (results.Rows.Count == 0) return;
        multiRow = Math.Clamp(multiRow + step, 0, results.Rows.Count - 1);
        var row = results.Rows[multiRow];
        History.ScrollIntoView(row);
        History.UpdateLayout();
        if (History.ItemContainerGenerator.ContainerFromItem(row) is ListBoxItem container) Keyboard.Focus(container);
    }

    private void SelectMultipleRows(object sender, MouseButtonEventArgs e)
    {
        if (!multiple && (Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Shift)) != 0 && RowFrom(e.OriginalSource) is not null)
            StartMultiple();
    }

    private void UseSelected(object sender, MouseButtonEventArgs e)
    {
        if (RowFrom(e.OriginalSource) is { } row) ActivateRow(row, paste: true);
    }

    private void SelectContextRow(object sender, MouseButtonEventArgs e)
    {
        if (RowFrom(e.OriginalSource) is { } row)
        {
            results.Select(row);
            var menu = ClipMenus.ForClip(app, row, this, () => EditInfo(row.Clip, false), () => EditInfo(row.Clip, true),
                () => ShowAggregation(row.Clip, row.Clip.Members, row.Clip.Title, row.Clip.AggregationOrigin, true),
                () => ActivateRow(row, false));
            History.ContextMenu = menu;
            KeepOpenFor(menu);
        }
        else History.ContextMenu = null;
    }

    private void ShowContextMenu(object sender, ContextMenuEventArgs e)
    {
        if (History.ContextMenu is null) e.Handled = true;
    }

    private static ClipCard? RowFrom(object? source) => (source as FrameworkElement)?.DataContext as ClipCard;

    private void KeepOpenFor(ContextMenu menu)
    {
        menu.Opened += (_, _) => transientMenu = true;
        menu.Closed += (_, _) => transientMenu = false;
    }

    private void ShowTools(object sender, RoutedEventArgs e) => OpenTools(QuickTools);
    private void OpenTools(FrameworkElement target)
    {
        if (results.Selected is not { } row) return;
        var menu = ClipMenus.Tools(app, row.Clip);
        menu.PlacementTarget = target;
        menu.Placement = PlacementMode.Bottom;
        KeepOpenFor(menu);
        menu.IsOpen = true;
    }

    private void ShowGroups(object sender, RoutedEventArgs e)
    {
        var body = new DockPanel();
        var actions = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };
        DockPanel.SetDock(actions, Dock.Top);
        var add = Ui.Button("New group", () => EditGroup(null, false));
        add.Margin = new Thickness(0, 0, 6, 0);
        actions.Children.Add(add);
        actions.Children.Add(Ui.Button("New smart group", () => EditGroup(null, true)));
        body.Children.Add(actions);
        var all = app.Collections.Select(collection => new GroupTab(collection)).Prepend(new GroupTab(null)).ToArray();
        var list = new ListBox { ItemsSource = all, SelectedItem = all.FirstOrDefault(item => item.Id == currentGroupId),
            HorizontalContentAlignment = HorizontalAlignment.Stretch };
        list.DisplayMemberPath = nameof(GroupTab.Name);
        AutomationProperties.SetName(list, Labels.Get("All groups"));
        body.Children.Add(list);
        void Go()
        {
            if (list.SelectedItem is GroupTab chosen) ChangeGroup(chosen);
            CloseEditor();
        }
        list.MouseDoubleClick += (_, _) => Go();
        list.PreviewMouseRightButtonDown += (_, args) =>
        {
            if ((args.OriginalSource as FrameworkElement)?.DataContext is GroupTab { Collection: { } collection })
            {
                list.ContextMenu = ClipMenus.ForGroup(collection, () => EditGroup(collection, collection.IsSmart),
                    () => { DeleteGroup(collection); CloseEditor(); });
                KeepOpenFor(list.ContextMenu);
            }
            else list.ContextMenu = null;
        };
        list.PreviewMouseLeftButtonDown += GroupDragStart;
        list.PreviewMouseMove += GroupDragMove;
        list.AllowDrop = true;
        list.DragOver += GroupDragOver;
        list.Drop += GroupDropped;
        var surface = LibraryEditors.Wrap("All groups", body, list, () => { Go(); return true; }, CloseEditorFromForm);
        OpenEditor(surface);
    }

    private void GroupDragStart(object sender, MouseButtonEventArgs e)
    {
        groupDragOrigin = e.GetPosition((IInputElement)sender);
        draggingGroup = ((e.OriginalSource as FrameworkElement)?.DataContext as GroupTab)?.Id;
    }

    private void GroupContextMenu(object sender, MouseButtonEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not GroupTab { Collection: { } group })
        {
            Groups.ContextMenu = null;
            return;
        }
        Groups.ContextMenu = ClipMenus.ForGroup(group, () => EditGroup(group, group.IsSmart), () => DeleteGroup(group));
        KeepOpenFor(Groups.ContextMenu);
    }

    private void GroupDragMove(object sender, MouseEventArgs e)
    {
        if (draggingGroup is not { } id || e.LeftButton != MouseButtonState.Pressed) return;
        var delta = e.GetPosition((IInputElement)sender) - groupDragOrigin;
        if (Math.Abs(delta.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(delta.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        draggingGroup = null;
        DragDrop.DoDragDrop((DependencyObject)sender, new DataObject("Pasteory.Group", id.ToString()), DragDropEffects.Move);
    }

    private void GroupDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent("Pasteory.Group") ? DragDropEffects.Move : DragDropEffects.None;
        e.Handled = true;
    }

    private void GroupDropped(object sender, DragEventArgs e)
    {
        if (e.Data.GetData("Pasteory.Group") is not string value || !Guid.TryParse(value, out var id)) return;
        var target = (e.OriginalSource as FrameworkElement)?.DataContext as GroupTab;
        if (target is { Id: null }) return;
        app.MoveCollection(id, target?.Id);
        if (sender != Groups && editor is not null) ShowGroups(this, new RoutedEventArgs());
        e.Handled = true;
    }

    private void EditInfo(Clip clip, bool groups) => OpenEditor(LibraryEditors.ClipInfo(app, clip, groups, CloseEditorFromForm));
    private void EditGroup(ClipCollection? group, bool smart) =>
        OpenEditor(LibraryEditors.Group(app, group, smart, CloseEditorFromForm,
            id => currentGroupId = id));

    private void DeleteGroup(ClipCollection group)
    {
        modalDepth++;
        try
        {
            if (ClipMenus.Confirm(this, "Delete this group? Its clips will stay in the library.")) app.DeleteCollection(group);
        }
        finally { modalDepth--; }
    }

    private void OpenEditor(EditorView value)
    {
        HideHelp();
        editor = value;
        OverlayContent.Content = value.Content;
        Overlay.Visibility = Visibility.Visible;
        Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() => Keyboard.Focus(value.InitialFocus)));
    }

    private void CloseEditorFromForm()
    {
        CloseEditor();
        var tab = tabs.FirstOrDefault(item => item.Id == currentGroupId);
        if (tab is not null && !Equals(Groups.SelectedItem, tab)) ChangeGroup(tab);
    }

    private void CloseEditor(bool focus = true)
    {
        if (editor is null) return;
        editor = null;
        Overlay.Visibility = Visibility.Collapsed;
        OverlayContent.Content = null;
        if (focus && IsVisible) Keyboard.Focus(FocusArea);
    }

    private void OpenHelp()
    {
        if (help is not null) return;
        var rows = new StackPanel { Margin = new Thickness(12, 10, 12, 12) };
        rows.Children.Add(Ui.Text(Labels.Get("Quick actions"), 14, strong: true));
        foreach (var entry in Shortcuts.Entries)
        {
            string shortcut = Shortcuts.Text(app.Settings, entry.Action);
            if (shortcut.Length == 0) continue;
            var line = new DockPanel { Margin = new Thickness(0, 5, 0, 0) };
            var key = Ui.Text(shortcut, 11, "AccentInk", strong: true);
            DockPanel.SetDock(key, Dock.Right);
            line.Children.Add(key);
            line.Children.Add(Ui.Text(Labels.Get(entry.Title), 11));
            rows.Children.Add(line);
        }
        double workRight = DeviceToDip(new Point(Forms.Screen.FromHandle(new WindowInteropHelper(this).Handle).WorkingArea.Right, 0)).X;
        help = new Window
        {
            Owner = this, Title = Labels.Get("Quick actions"), Width = 260, MaxHeight = ActualHeight,
            SizeToContent = SizeToContent.Height, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false, ShowActivated = false, Focusable = false, Left = Left + ActualWidth + 7 + 260 <= workRight
                ? Left + ActualWidth + 7 : Math.Max(0, Left - 267), Top = Top, Topmost = true,
            Content = new ScrollViewer { Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }
        };
        help.Show();
    }

    private void HideHelp()
    {
        helpTimer.Stop();
        help?.Close();
        help = null;
    }

    internal void Dismiss(bool restoreTarget)
    {
        if (!IsVisible) return;
        CloseEditor(focus: false);
        HideHelp();
        Hide();
        if (restoreTarget) app.RestoreFocus();
    }

    private void HideInsteadOfClose(object? sender, CancelEventArgs e)
    {
        if (app.Exiting) return;
        e.Cancel = true;
        Dismiss(restoreTarget: true);
    }

    private void ShowLibrary() { Dismiss(false); app.OpenSettings(SettingsPage.Library); }
    private void ShowSettings() { Dismiss(false); app.OpenSettings(SettingsPage.General); }
    private void OpenSettings(object sender, RoutedEventArgs e) => ShowSettings();
    private void OpenLibrary(object sender, RoutedEventArgs e) => ShowLibrary();
    private void ShowUpdate(object sender, RoutedEventArgs e)
    {
        modalDepth++;
        try { app.ShowUpdate(this); }
        finally { modalDepth--; }
    }
    private void TogglePinPanel(object sender, RoutedEventArgs e)
    {
        app.SaveSettings(app.Settings with { KeepPanelOpen = !app.Settings.KeepPanelOpen });
        Keyboard.Focus(FocusArea);
    }
    private void SearchClick(object sender, MouseButtonEventArgs e) => Query.Focus();
    private void ClearQuery(object sender, RoutedEventArgs e) { Query.Clear(); Query.Focus(); }
    private void ScrollGroups(object sender, MouseWheelEventArgs e)
    {
        if (FindScroll(Groups) is not { } scroll) return;
        scroll.ScrollToHorizontalOffset(scroll.HorizontalOffset - e.Delta * .45);
        e.Handled = true;
    }
    private static ScrollViewer? FindScroll(DependencyObject root)
    {
        if (root is ScrollViewer scroll) return scroll;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            if (FindScroll(VisualTreeHelper.GetChild(root, index)) is { } found) return found;
        return null;
    }
    private void DragHeader(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || e.OriginalSource is not Grid) return;
        DragMove();
        originallyPositioned = true;
    }

    private void ResizePanel(object sender, DragDeltaEventArgs e)
    {
        Width = Math.Clamp(Width + e.HorizontalChange, MinWidth, 670);
        Height = Math.Clamp(Height + e.VerticalChange, MinHeight, 760);
    }

    private void SavePanelSize(object sender, DragCompletedEventArgs e) =>
        app.SaveSettings(app.Settings with { PanelWidth = Width, PanelHeight = Height });

    private void PositionNearPointer()
    {
        var handle = new WindowInteropHelper(this).EnsureHandle();
        var mouse = Forms.Cursor.Position;
        var work = Forms.Screen.FromPoint(mouse).WorkingArea;
        var monitor = NativeMethods.MonitorFromPoint(new NativeMethods.ScreenPoint(mouse.X, mouse.Y), 2);
        double scale = NativeMethods.GetDpiForMonitor(monitor, 0, out uint monitorDpi, out _) == 0 ? monitorDpi / 96d : 1;
        Height = Math.Min(Height, Math.Max(MinHeight, work.Height / scale));
        if (app.Settings.GroupSidebar && app.Settings.GroupDisplay != "Minimal") Width = Math.Max(Width, 516);
        Width = Math.Min(Width, Math.Max(MinWidth, work.Width / scale));
        int width = (int)Math.Ceiling(Width * scale);
        int height = (int)Math.Ceiling(Height * scale);
        int left = mouse.X - width / 2, top = mouse.Y + (int)(12 * scale);
        if (originallyPositioned && NativeMethods.GetWindowRect(handle, out var previous) != 0)
        {
            left = previous.Left;
            top = previous.Top;
        }
        left = Math.Clamp(left, work.Left, Math.Max(work.Left, work.Right - width));
        top = Math.Clamp(top, work.Top, Math.Max(work.Top, work.Bottom - height));
        // Use physical coordinates for placement, including secondary screens with a different DPI.
        NativeMethods.SetWindowPos(handle, 0, left, top, width, height, 0x0014);
    }

    private Point DeviceToDip(Point point) => PresentationSource.FromVisual(this)?.CompositionTarget is { } composition
        ? composition.TransformFromDevice.Transform(point) : point;

    private sealed record GroupTab(ClipCollection? Collection)
    {
        public Guid? Id => Collection?.Id;
        public string Name => Collection?.Name ?? Labels.Get("All");
        public string Glyph => Collection is null ? Windows.Glyph.Recent :
            Collection.IsSmart || Collection.IsAi ? Windows.Glyph.Smart : Windows.Glyph.Group;
    }
}
