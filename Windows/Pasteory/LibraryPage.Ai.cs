using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using Pasteory.Core;

namespace Pasteory.Windows;

public partial class LibraryPage
{
    private void OpenAiGroupManager(object sender, RoutedEventArgs e) => ShowAiGroupManager(AiRegroupScope.Recent);

    private void ShowAiActions(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = AiActions, Placement = PlacementMode.Bottom };
        bool ready = app.CanManageAiGroups && app.Settings.Ai.Enabled && app.Ai.CanConnect(app.Settings.Ai);
        ClipMenus.Add(menu, "Analyze recent clips", () => Analyze("recent"), enabled: ready);
        ClipMenus.Add(menu, "Review suggestions", () => (Owner as SettingsWindow)?.ShowReview(), enabled: app.Ai.Review is not null);
        ClipMenus.Add(menu, "Analyze library with existing themes", () => Analyze("full"), enabled: ready);
        menu.Items.Add(new Separator());
        ClipMenus.Add(menu, "Regroup recent clips…", () => ShowAiGroupManager(AiRegroupScope.Recent));
        ClipMenus.Add(menu, "Regroup the whole library…", () => ShowAiGroupManager(AiRegroupScope.Library));
        ClipMenus.Add(menu, "Review existing themes", () => Analyze("manual-review"), enabled: ready);
        if (app.CanUndoAi) ClipMenus.Add(menu, "Undo AI organization", app.UndoAi, enabled: !app.Ai.Running);
        menu.IsOpen = true;

        void Analyze(string trigger)
        {
            if (app.OpenAiTaskPage()) _ = app.RunAiAsync(story: false, trigger);
        }
    }

    private void ShowAiGroupEditor(ClipCollection group, Window? owner = null, Action? changed = null) =>
        LibraryEditors.ShowModal(owner ?? Owner, "Edit AI group", close => LibraryEditors.AiGroup(app, group, close, changed), 500, 490);

    private void ShowAiGroupManager(AiRegroupScope initialScope, Guid? initialGroup = null) =>
        LibraryEditors.ShowModal(Owner, "Manage AI groups", close => BuildAiGroupManager(close, initialScope, initialGroup), 800, 720);

    private EditorView BuildAiGroupManager(Action close, AiRegroupScope initialScope, Guid? initialGroup)
    {
        var layout = new DockPanel { Margin = new Thickness(22) };
        KeyboardNavigation.SetTabNavigation(layout, KeyboardNavigationMode.Cycle);
        var heading = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var dismiss = Ui.Button("Close", close);
        DockPanel.SetDock(dismiss, Dock.Right);
        heading.Children.Add(dismiss);
        var title = Ui.Text(Labels.Get("Manage AI groups"), 22, strong: true);
        title.VerticalAlignment = VerticalAlignment.Center;
        heading.Children.Add(title);
        DockPanel.SetDock(heading, Dock.Top);
        layout.Children.Add(heading);

        var body = new StackPanel();
        var totals = Ui.Text("", 12, "Muted");
        totals.Margin = new Thickness(0, 0, 0, 7);
        body.Children.Add(totals);

        int recent = Math.Clamp(app.Settings.Ai.RecentLimit, 1, 1000);
        var scopes = new TabControl { Margin = new Thickness(0, 0, 0, 7) };
        scopes.SetResourceReference(StyleProperty, "SettingsSegmentedTabs");
        AutomationProperties.SetName(scopes, Labels.Get("Regrouping scope"));
        AddScope(AiRegroupScope.Recent, Labels.Format("Recent {0} eligible clips", recent));
        AddScope(AiRegroupScope.Selected, Labels.Get("Members of selected groups"));
        AddScope(AiRegroupScope.Library, Labels.Get("Entire library"));
        scopes.SelectedIndex = (int)initialScope;
        body.Children.Add(scopes);

        var selected = initialGroup is { } preselected ? new HashSet<Guid> { preselected } : [];
        var rows = new Dictionary<Guid, CheckBox>();
        AiGroupActivity[] groups = [];
        var selection = Ui.Text("", 12);
        var selectAll = Ui.Button("Select all AI groups");
        var scopeSummary = new DockPanel { Margin = new Thickness(0, 3, 0, 8) };
        DockPanel.SetDock(selectAll, Dock.Right);
        scopeSummary.Children.Add(selectAll);
        selection.VerticalAlignment = VerticalAlignment.Center;
        selection.Margin = new Thickness(0, 0, 8, 0);
        scopeSummary.Children.Add(selection);
        body.Children.Add(scopeSummary);
        var items = new StackPanel();
        body.Children.Add(new ScrollViewer { Content = items, MaxHeight = 270, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });

        var disclosure = new Expander { Header = Labels.Get("Review AI prompt and sharing scope"), Margin = new Thickness(0, 8, 0, 4) };
        var details = new StackPanel { Margin = new Thickness(8, 7, 0, 0) };
        var sharing = Ui.Text("", 11, "Muted");
        details.Children.Add(sharing);
        var prompt = Ui.Field("Regrouping prompt", "", 16000);
        prompt.IsReadOnly = true;
        prompt.Height = 107;
        prompt.Margin = new Thickness(0, 6, 0, 0);
        prompt.AcceptsReturn = true;
        prompt.TextWrapping = TextWrapping.Wrap;
        prompt.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        prompt.VerticalContentAlignment = VerticalAlignment.Top;
        details.Children.Add(prompt);
        disclosure.Content = details;
        body.Children.Add(disclosure);

        var actions = new WrapPanel { Margin = new Thickness(0, 9, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
        var clear = Ui.Button("Clear selected AI groups…");
        clear.SetResourceReference(Control.ForegroundProperty, "Danger");
        var undo = Ui.Button("Undo AI organization");
        var generate = Ui.Button("Generate regrouping plan", style: "PrimaryButton");
        var pending = Ui.Button("Review suggestions", () =>
        {
            close();
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (app.Ai.Review is not null) (Owner as SettingsWindow)?.ShowReview();
                else app.OpenAiTaskPage();
            }));
        });
        foreach (var button in new[] { undo, clear, generate })
        {
            button.Margin = new Thickness(0, 0, 6, 4);
            actions.Children.Add(button);
        }
        DockPanel.SetDock(actions, Dock.Bottom);
        layout.Children.Add(actions);
        layout.Children.Add(new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        var message = Ui.Text("", 11, "Muted");
        message.Margin = new Thickness(0, 6, 0, 0);
        body.Children.Add(message);
        var operationError = Ui.Text("", 12, "Danger");
        body.Children.Add(operationError);
        pending.HorizontalAlignment = HorizontalAlignment.Left;
        pending.Margin = new Thickness(0, 8, 0, 0);
        body.Children.Add(pending);
        var previewIds = new HashSet<Guid>();
        AiGroupSnapshot[] previewGroups = [];

        void AddScope(AiRegroupScope mode, string caption)
        {
            var tab = new TabItem
            {
                Header = new TextBlock { Text = caption, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap },
                Tag = mode
            };
            AutomationProperties.SetName(tab, caption);
            scopes.Items.Add(tab);
        }

        void SelectAll()
        {
            if (selected.Count == groups.Length) selected.Clear();
            else selected.UnionWith(groups.Select(item => item.Group.Id));
            Refresh();
        }

        AiRegroupScope Mode() => (AiRegroupScope)((TabItem)scopes.SelectedItem).Tag;
        AiGroupSnapshot[] Snapshots() => AiGroupSnapshot.Capture(app.Collections, app.Clips, Mode() == AiRegroupScope.Selected
            ? selected : app.Collections.Where(group => group.IsAi).Select(group => group.Id).ToHashSet());

        void ReloadGroups()
        {
            groups = app.ScoreAiGroups();
            selected.IntersectWith(groups.Select(item => item.Group.Id));
            rows.Clear();
            items.Children.Clear();
            if (groups.Length == 0) items.Children.Add(Ui.Text(Labels.Get("No AI groups yet."), 12, "Muted"));
            foreach (var activity in groups)
            {
                var group = activity.Group;
                var row = new StackPanel();
                var rowHeader = new DockPanel();
                var edit = Ui.Button("Edit theme definition", () => ShowAiGroupEditor(group, Window.GetWindow(body), ReloadGroups));
                AutomationProperties.SetName(edit, Labels.Format("Edit theme definition for {0}", group.Name));
                DockPanel.SetDock(edit, Dock.Right);
                rowHeader.Children.Add(edit);
                var count = Ui.Text(Labels.Format("{0} items", activity.Members), 11, "Muted");
                count.Margin = new Thickness(0, 0, 9, 0);
                count.VerticalAlignment = VerticalAlignment.Center;
                DockPanel.SetDock(count, Dock.Right);
                rowHeader.Children.Add(count);
                var caption = Ui.Text(group.Name, 13, strong: true);
                caption.TextWrapping = TextWrapping.NoWrap;
                caption.TextTrimming = TextTrimming.CharacterEllipsis;
                var check = new CheckBox { Content = caption, VerticalAlignment = VerticalAlignment.Center, ToolTip = group.Name };
                AutomationProperties.SetName(check, group.Name);
                check.Click += (_, _) =>
                {
                    if (check.IsChecked == true) selected.Add(group.Id); else selected.Remove(group.Id);
                    Refresh();
                };
                rows.Add(group.Id, check);
                rowHeader.Children.Add(check);
                row.Children.Add(rowHeader);
                if (group.Retained || group.NameIsManual || group.DefinitionIsManual)
                    row.Children.Add(Ui.Text(Labels.Get("Has manual settings"), 11, "AccentInk"));
                if (!string.IsNullOrWhiteSpace(group.Definition)) row.Children.Add(Ui.Text(ClipCard.Short(group.Definition, 275, 3), 12, "Muted"));
                items.Children.Add(Ui.Section(row));
            }
            Refresh();
        }

        void Refresh()
        {
            var prefs = app.Settings.Ai;
            var groupIds = groups.Select(item => item.Group.Id).ToHashSet();
            var library = app.Clips.Where(clip => clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate).ToArray();
            int grouped = library.Count(clip => clip.CollectionIds.Any(groupIds.Contains));
            totals.Text = Labels.Format("{0} library clips · {1} in AI groups · {2} outside AI groups", library.Length, grouped, library.Length - grouped);
            var snapshots = Snapshots();
            var memberIds = snapshots.SelectMany(item => item.Members).ToHashSet();
            var input = AiTasks.RegroupInput(app.Clips, prefs, Mode(), memberIds);
            previewIds = input.EligibleIds;
            previewGroups = snapshots;
            int outside = library.Count(clip => memberIds.Contains(clip.Id) && !input.EligibleIds.Contains(clip.Id));
            bool groupScope = Mode() == AiRegroupScope.Selected;
            bool manageable = app.CanManageAiGroups;
            bool configured = prefs.Enabled && app.Ai.CanConnect(prefs);
            scopes.IsEnabled = !app.Ai.Running;
            selection.Text = groupScope ? Labels.Format("Selected {0} of {1} AI groups · {2} unique clips", snapshots.Length, groups.Length,
                library.Count(clip => memberIds.Contains(clip.Id))) : Labels.Format("{0} existing AI groups in the replacement scope", snapshots.Length);
            selectAll.Content = Labels.Get(!groupScope ? "All AI groups included" :
                selected.Count == groups.Length && groups.Length > 0 ? "Clear AI group selection" : "Select all AI groups");
            selectAll.IsEnabled = groupScope && groups.Length > 0 && !app.Ai.Running;
            foreach (var pair in rows)
            {
                pair.Value.IsChecked = !groupScope || selected.Contains(pair.Key);
                pair.Value.IsEnabled = groupScope && !app.Ai.Running;
            }
            message.Text = Labels.Format("{0} clips will be analyzed · {1} ineligible clips excluded", input.EligibleIds.Count, input.ExcludedCount);
            if (outside > 0) message.Text += "\n" + Labels.Format("{0} clips outside the analysis scope will leave the replaced groups.", outside);
            if (!configured) message.Text += "\n" + Labels.Get("Configure and enable AI analysis to begin.");
            sharing.Text = Labels.Format("Model {0} · notes {1} · source apps {2} · local OCR {3} · linked resources {4}",
                prefs.Model.Length == 0 ? Labels.Get("Not configured") : prefs.Model, OnOff(prefs.ShareNotes), OnOff(prefs.ShareSource),
                OnOff(prefs.ShareOcr), OnOff(prefs.ShareResources));
            prompt.Text = AiTasks.BuildOrganizationPrompt(prefs, Labels.Chinese, regroup: true);
            clear.IsEnabled = manageable && groupScope && snapshots.Length > 0;
            undo.Visibility = app.CanUndoAi ? Visibility.Visible : Visibility.Collapsed;
            undo.IsEnabled = !app.Ai.Running;
            bool hasReview = app.Ai.Review is not null;
            pending.Content = Labels.Get(hasReview ? "Review suggestions" : "Open saved AI task");
            pending.Visibility = hasReview || app.Ai.Job(false)?.Status == "Paused" ? Visibility.Visible : Visibility.Collapsed;
            generate.Content = Labels.Get(Mode() == AiRegroupScope.Library ? "Generate full library regrouping plan" : "Generate regrouping plan");
            generate.IsEnabled = manageable && configured && input.EligibleIds.Count > 0;
        }

        void Clear()
        {
            var snapshots = Snapshots();
            if (snapshots.Length == 0 || Mode() != AiRegroupScope.Selected) return;
            int distinctMembers = snapshots.SelectMany(item => item.Members).Distinct().Count();
            string question = Labels.Format("Clear {0} selected AI groups and their memberships for {1} clips? This change can be undone.",
                snapshots.Length, distinctMembers);
            if (ClipMenus.Confirm(Window.GetWindow(body) ?? Owner, question) &&
                app.ClearAiGroups(snapshots, error => operationError.Text = Labels.Get(error)))
            {
                operationError.Text = "";
                selected.Clear();
                ReloadGroups();
            }
        }

        void Generate()
        {
            if (!app.CanManageAiGroups || !app.Settings.Ai.Enabled || !app.Ai.CanConnect(app.Settings.Ai)) return;
            var scope = Mode();
            var snapshots = Snapshots();
            var input = AiTasks.RegroupInput(app.Clips, app.Settings.Ai, scope, snapshots.SelectMany(item => item.Members).ToHashSet());
            if (snapshots.Length != previewGroups.Length || !previewIds.SetEquals(input.EligibleIds) ||
                !AiGroupSnapshot.IsCurrent(app.Collections, app.Clips, previewGroups))
            {
                ReloadGroups();
                message.Text += "\n" + Labels.Get("The preview was refreshed. Check the scope before generating.");
                return;
            }
            if (input.EligibleIds.Count == 0) return;
            close();
            Dispatcher.BeginInvoke(new Action(() => _ = app.RegroupAiAsync(scope, snapshots, input.EligibleIds)));
        }

        static string OnOff(bool enabled) => Labels.Get(enabled ? "On" : "Off");
        selectAll.Click += (_, _) => SelectAll();
        clear.Click += (_, _) => Clear();
        undo.Click += (_, _) => { app.UndoAi(); ReloadGroups(); };
        generate.Click += (_, _) => Generate();
        scopes.SelectionChanged += (_, args) => { if (args.Source == scopes) Refresh(); };
        body.Loaded += (_, _) => app.Ai.Changed += ReloadGroups;
        body.Unloaded += (_, _) => app.Ai.Changed -= ReloadGroups;
        ReloadGroups();
        return new EditorView(new Border { Child = layout }.WithBackground("Surface"), scopes);
    }
}
