using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed partial class SettingsWindow
{
    private LinkHistorySection linkSection = LinkHistorySection.Pending;
    private LinkHistoryPeriod linkPeriod;
    private LinkHistoryIssue linkIssue;
    private DateTime selectedLinkDay = DateTime.Today;
    private string linkSearch = "";
    private IReadOnlyList<Clip>? linkSnapshot;
    private LinkHistoryEntry[] linkEntries = [];
    private Action<LinkHistoryEntry[]>? updateLinkCounts;
    private LinkHistoryList? linkHistoryList;
    private ComboBox? linkIssuePicker;
    private bool retryingLinks;

    private FrameworkElement BuildLinks(StackPanel header)
    {
        var view = new DockPanel { Margin = header.Margin, MaxWidth = header.MaxWidth };
        header.Margin = new Thickness(0);
        DockPanel.SetDock(header, Dock.Top);
        view.Children.Add(header);
        var summary = SettingsCard(header, "Web page titles");
        Switch(summary, "Resolve copied links automatically", app.Settings.ResolveLinks,
            (settings, value) => settings with { ResolveLinks = value },
            "URL detection and fallback titles work locally. Enable this to request real page titles.");

        var tabs = new TabControl();
        tabs.SetResourceReference(StyleProperty, "SettingsSegmentedTabs");
        AutomationProperties.SetName(tabs, Labels.Get("Link resolution sections"));
        string[] sections = ["All links", "Pending", "Resolved", "Fallback rules", "Connections"];
        foreach (string section in sections) tabs.Items.Add(new TabItem { Header = Labels.Get(section) });
        var sectionHost = new ContentControl
        {
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch
        };

        var counts = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1, Margin = new Thickness(0, 5, 0, 0) };
        var resolved = Metric("Resolved", LinkHistorySection.Resolved, LinkHistoryIssue.All);
        var pending = Metric("Pending links", LinkHistorySection.Pending, LinkHistoryIssue.All);
        var needsLogin = Metric("Sign-in or verification", LinkHistorySection.Pending, LinkHistoryIssue.NeedsLogin);
        var inaccessible = Metric("Cannot access", LinkHistorySection.Pending, LinkHistoryIssue.CannotAccess);
        summary.Children.Add(counts);
        updateLinkCounts = entries =>
        {
            int successes = 0, login = 0, cannotAccess = 0;
            foreach (var entry in entries)
            {
                if (entry.Status == "Resolved") successes++;
                if (entry.NeedsLogin) login++;
                if (entry.CannotAccess) cannotAccess++;
            }
            resolved.Text = successes.ToString("N0");
            pending.Text = (entries.Length - successes).ToString("N0");
            needsLogin.Text = login.ToString("N0");
            inaccessible.Text = cannotAccess.ToString("N0");
        };

        var commands = new WrapPanel { Margin = new Thickness(9, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        AddAction(commands, "Refresh records", () =>
        {
            linkSnapshot = null;
            if (linkSection == LinkHistorySection.Connections) BuildLinkTab(sectionHost);
            else RefreshLinkHistory();
        });
        AddAction(commands, "Add sign-in rule…", async () => await EditSignInAsync(null));
        var toolbar = new WrapPanel();
        toolbar.Children.Add(tabs);
        toolbar.Children.Add(commands);
        DockPanel.SetDock(toolbar, Dock.Top);
        view.Children.Add(toolbar);

        tabs.SelectedIndex = (int)linkSection;
        tabs.SelectionChanged += (_, e) =>
        {
            if (e.Source != tabs || tabs.SelectedIndex < 0) return;
            linkSection = (LinkHistorySection)tabs.SelectedIndex;
            BuildLinkTab(sectionHost);
        };
        BuildLinkTab(sectionHost);
        view.Children.Add(sectionHost);
        return view;

        TextBlock Metric(string title, LinkHistorySection section, LinkHistoryIssue issue)
        {
            var value = Ui.Text("0", 16, "AccentInk", strong: true);
            var label = Ui.Text(Labels.Get(title), 11, "Muted");
            var stack = new StackPanel();
            stack.Children.Add(value);
            stack.Children.Add(label);
            var button = Ui.Button(title, () =>
            {
                linkIssue = issue;
                if (tabs.SelectedIndex != (int)section) tabs.SelectedIndex = (int)section;
                else if (linkIssuePicker is { } picker) picker.SelectedIndex = (int)issue;
            });
            button.Content = stack;
            button.Padding = new Thickness(6, 4, 6, 4);
            button.Margin = new Thickness(0, 0, 5, 0);
            AutomationProperties.SetName(button, Labels.Get(title));
            counts.Children.Add(button);
            return value;
        }
    }

    private void BuildLinkTab(ContentControl sectionHost)
    {
        linkHistoryList = null;
        linkIssuePicker = null;
        linkSessionRows.Clear();
        linkSessionPaused = null;
        if (linkSection is LinkHistorySection.Rules or LinkHistorySection.Connections)
        {
            var settings = new StackPanel { Margin = new Thickness(0, 10, 5, 0) };
            if (linkSection == LinkHistorySection.Rules) BuildLinkRules(settings);
            else BuildLinkConnections(settings);
            sectionHost.Content = new ScrollViewer { Content = settings, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        }
        else sectionHost.Content = BuildLinkRecords();
        RefreshLinkHistory();
    }

    private FrameworkElement BuildLinkRecords()
    {
        var layout = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        var filterBar = new DockPanel { Margin = new Thickness(0, 0, 4, 7) };
        var filters = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(filters, Dock.Left);
        filterBar.Children.Add(filters);
        var period = FilterPicker("Date range", ["All dates", "Today", "Last seven days", "Specific date"], (int)linkPeriod);
        filters.Children.Add(period);
        var day = new DatePicker
        {
            SelectedDate = selectedLinkDay, Width = 118, Margin = new Thickness(0, 0, 7, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = linkPeriod == LinkHistoryPeriod.SelectedDay ? Visibility.Visible : Visibility.Collapsed
        };
        AutomationProperties.SetName(day, Labels.Get("Specific date"));
        filters.Children.Add(day);
        day.SelectedDateChanged += (_, _) =>
        {
            if (day.SelectedDate is not { } date) return;
            selectedLinkDay = date;
            ApplyLinkFilters();
        };
        period.SelectionChanged += (_, _) =>
        {
            linkPeriod = (LinkHistoryPeriod)period.SelectedIndex;
            day.Visibility = linkPeriod == LinkHistoryPeriod.SelectedDay ? Visibility.Visible : Visibility.Collapsed;
            ApplyLinkFilters();
        };
        var issues = FilterPicker("Link status", ["All statuses", "Sign-in or verification", "Cannot access"], (int)linkIssue);
        linkIssuePicker = issues;
        filters.Children.Add(issues);
        issues.SelectionChanged += (_, _) => { linkIssue = (LinkHistoryIssue)issues.SelectedIndex; ApplyLinkFilters(); };

        var search = Ui.Field("Search addresses, titles or apps", linkSearch);
        search.MinWidth = 100;
        search.Height = 32;
        search.ToolTip = Labels.Get("Search addresses, titles or apps");
        var placeholder = Ui.Text(Labels.Get("Search addresses, titles or apps"), 12, "Muted");
        placeholder.VerticalAlignment = VerticalAlignment.Center;
        placeholder.Margin = new Thickness(9, 0, 5, 0);
        placeholder.TextWrapping = TextWrapping.NoWrap;
        placeholder.TextTrimming = TextTrimming.CharacterEllipsis;
        placeholder.IsHitTestVisible = false;
        placeholder.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var searchField = new Grid();
        searchField.Children.Add(search);
        searchField.Children.Add(placeholder);
        filterBar.Children.Add(searchField);
        search.TextChanged += (_, _) =>
        {
            linkSearch = search.Text;
            placeholder.Visibility = linkSearch.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            ApplyLinkFilters();
        };
        DockPanel.SetDock(filterBar, Dock.Top);
        layout.Children.Add(filterBar);

        var noteRow = new DockPanel { Margin = new Thickness(0, 0, 4, 5) };
        if (linkSection == LinkHistorySection.Pending)
        {
            var retry = Ui.Button("Retry pending links", async () =>
            {
                if (retryingLinks) return;
                retryingLinks = true;
                try { SetStatus(Labels.Format("Retried {0} links.", await app.ResolveMatchingLinksAsync())); }
                finally { retryingLinks = false; }
            });
            retry.FontSize = 11;
            retry.MinHeight = 23;
            retry.Padding = new Thickness(8, 2, 8, 2);
            DockPanel.SetDock(retry, Dock.Right);
            noteRow.Children.Add(retry);
        }
        var note = Ui.Text(Labels.Get("Grouped by latest attempt or by date added."), 11, "Muted");
        note.VerticalAlignment = VerticalAlignment.Center;
        noteRow.Children.Add(note);
        DockPanel.SetDock(noteRow, Dock.Top);
        layout.Children.Add(noteRow);
        linkHistoryList = new LinkHistoryList
        {
            Retry = async entry => await app.ResolveLinkAsync(entry.Clip),
            SignIn = async entry => await SignInForLinkAsync(entry),
            More = ShowLinkActions
        };
        layout.Children.Add(linkHistoryList);
        return layout;
    }

    private static ComboBox FilterPicker(string label, string[] values, int selected)
    {
        var picker = new ComboBox
        {
            ItemsSource = values.Select(Labels.Get).ToArray(), SelectedIndex = selected,
            Margin = new Thickness(0, 0, 7, 0), Height = 32, MinWidth = 112,
            VerticalAlignment = VerticalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center
        };
        AutomationProperties.SetName(picker, Labels.Get(label));
        return picker;
    }

    internal void RefreshLinkHistory()
    {
        if (current != SettingsPage.Links || updateLinkCounts is null) return;
        var clips = app.Clips;
        if (!ReferenceEquals(linkSnapshot, clips))
        {
            linkEntries = LinkHistory.Build(clips);
            linkSnapshot = clips;
            updateLinkCounts(linkEntries);
        }
        ApplyLinkFilters();
    }

    private void ApplyLinkFilters() => linkHistoryList?.Show(
        LinkHistory.Filter(linkEntries, linkSection, linkPeriod, DateOnly.FromDateTime(selectedLinkDay), linkIssue,
            linkSearch, DateTimeOffset.Now).ToArray(), entry => app.IsResolvingLink(entry.Key),
        url => app.AllowsLinkRequest(url) && app.MatchLinkSignInRule(url) is not null);

    private void ClearLinkPage()
    {
        linkSnapshot = null;
        linkEntries = [];
        linkHistoryList = null;
        linkIssuePicker = null;
        linkSessionRows.Clear();
        linkSessionPaused = null;
        updateLinkCounts = null;
    }

    private void ShowLinkActions(FrameworkElement source, LinkHistoryEntry entry)
    {
        var menu = new ContextMenu { PlacementTarget = source, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        ClipMenus.Add(menu, "Open web page", () => app.OpenLinkPage(entry.Clip, entry.Url));
        ClipMenus.Add(menu, "Configure fallback title…", () => EditRouteFallback(null, entry));
        ClipMenus.Add(menu, "Configure sign-in…", async () => await EditSignInAsync(null, entry));
        menu.IsOpen = true;
    }
}
