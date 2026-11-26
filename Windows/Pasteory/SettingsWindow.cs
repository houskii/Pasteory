using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Pasteory.Core;

namespace Pasteory.Windows;

internal enum SettingsPage { Story, Library, General, Privacy, Shortcuts, OpenWith, Links, Ai, Storage, Advanced, About }

internal sealed partial class SettingsWindow : Window
{
    private readonly App app;
    private readonly ContentControl host = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly StackPanel nav = new();
    private readonly Dictionary<SettingsPage, (Button Button, string Glyph)> buttons = [];
    private readonly TextBlock status = Ui.Text("", 11, "Muted");
    private readonly DockPanel feedback = new() { Visibility = Visibility.Collapsed };
    private readonly Button undoAggregation;
    private readonly DispatcherTimer clearStatus = new();
    private readonly DispatcherTimer saveSize = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private readonly LibraryPage library;
    private SettingsPage current;
    private Guid? undoAggregationId;
    private bool rebuildingSearchIndex;
    private static readonly object ShortcutRecorder = new();

    internal SettingsWindow(App app)
    {
        this.app = app;
        SetResourceReference(StyleProperty, typeof(Window));
        Title = Labels.Get("Pasteory Settings");
        Width = Math.Clamp(app.Settings.SettingsWidth, 700, SystemParameters.WorkArea.Width);
        Height = Math.Clamp(app.Settings.SettingsHeight, 520, SystemParameters.WorkArea.Height);
        MinWidth = Math.Min(960, SystemParameters.WorkArea.Width);
        MinHeight = Math.Min(620, SystemParameters.WorkArea.Height);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/Pasteory.ico"));
        library = new LibraryPage(app);
        status.TextTrimming = TextTrimming.CharacterEllipsis;
        status.TextWrapping = TextWrapping.NoWrap;
        status.Margin = new Thickness(12, 6, 12, 7);
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        undoAggregation = Ui.Button("Undo", () =>
        {
            if (undoAggregationId is { } id) app.UndoAggregation(id);
            ClearAggregationUndo();
        });
        undoAggregation.Margin = new Thickness(0, 2, 12, 3);
        undoAggregation.Padding = new Thickness(8, 1, 8, 1);
        undoAggregation.MinHeight = 22;
        undoAggregation.Visibility = Visibility.Collapsed;
        DockPanel.SetDock(undoAggregation, Dock.Right);
        feedback.Children.Add(undoAggregation);
        feedback.Children.Add(status);
        var root = new Grid();
        var navColumn = new ColumnDefinition { Width = new GridLength(224) };
        root.ColumnDefinitions.Add(navColumn);
        root.ColumnDefinitions.Add(new ColumnDefinition());
        var sidebar = BuildNav();
        var surface = new DockPanel();
        DockPanel.SetDock(feedback, Dock.Bottom);
        surface.Children.Add(feedback);
        surface.Children.Add(host);
        Grid.SetColumn(surface, 1);
        root.Children.Add(sidebar);
        root.Children.Add(surface);
        Content = root;
        clearStatus.Tick += (_, _) => { clearStatus.Stop(); feedback.Visibility = Visibility.Collapsed; ClearAggregationUndo(); };
        saveSize.Tick += (_, _) =>
        {
            saveSize.Stop();
            if (!app.Exiting && WindowState == WindowState.Normal)
                app.SaveSettings(app.Settings with { SettingsWidth = Width, SettingsHeight = Height });
        };
        SizeChanged += (_, _) =>
        {
            navColumn.Width = new GridLength(ActualWidth < 880 ? 166 : 224);
            if (IsLoaded && WindowState == WindowState.Normal) { saveSize.Stop(); saveSize.Start(); }
        };
        Closing += (_, e) =>
        {
            if (app.Exiting) return;
            e.Cancel = true;
            Hide();
        };
        PreviewKeyDown += OnWindowKey;
    }

    internal void Present(SettingsPage? requested)
    {
        if (requested is null && IsActive)
        {
            Activate();
            return;
        }
        var next = requested ?? (Enum.TryParse(app.Settings.LastSettingsPage, out SettingsPage page) ? page : SettingsPage.General);
        bool storyEnabled = app.Settings.Ai.Enabled && app.Settings.Ai.Story;
        bool newOpening = !IsVisible || !IsActive;
        bool preferStory = requested is null && newOpening && storyEnabled;
        if (preferStory && app.Ai.Stories.FirstOrDefault() is { } latest)
        {
            int seen = app.Settings.SeenStory == latest.Id ? app.Settings.StoryOpenings : 0;
            preferStory = seen < 3;
            if (preferStory) app.SaveSettings(app.Settings with { SeenStory = latest.Id, StoryOpenings = seen + 1 });
        }
        UpdateStoryNav();
        Select(preferStory ? SettingsPage.Story : next, remember: !preferStory);
        Show();
        Activate();
    }

    internal void SetStatus(string message)
    {
        ClearAggregationUndo();
        status.Text = message;
        status.ToolTip = message;
        feedback.Visibility = Visibility.Visible;
        clearStatus.Stop();
        clearStatus.Interval = TimeSpan.FromSeconds(4);
        clearStatus.Start();
    }

    internal void OfferAggregationUndo(Guid id)
    {
        if (!IsVisible || current != SettingsPage.Library) return;
        undoAggregationId = id;
        undoAggregation.Visibility = Visibility.Visible;
        clearStatus.Stop();
        clearStatus.Interval = TimeSpan.FromSeconds(12);
        clearStatus.Start();
    }

    private void ClearAggregationUndo()
    {
        undoAggregationId = null;
        undoAggregation.Visibility = Visibility.Collapsed;
    }

    internal void RefreshLibrary()
    {
        if (current == SettingsPage.Library) library.Refresh();
    }

    private Border BuildNav()
    {
        var stack = new DockPanel();
        var brand = new DockPanel { Margin = new Thickness(16, 16, 10, 17) };
        var icon = new Image { Source = Icon, Width = 39, Height = 39, Margin = new Thickness(0, 0, 10, 0) };
        DockPanel.SetDock(icon, Dock.Left);
        brand.Children.Add(icon);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(Ui.Text("Pasteory", 16, strong: true));
        titles.Children.Add(Ui.Text(Labels.Get("Settings"), 10, "Muted"));
        brand.Children.Add(titles);
        DockPanel.SetDock(brand, Dock.Top);
        stack.Children.Add(brand);
        stack.Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = nav });
        nav.Margin = new Thickness(10, 0, 10, 12);

        AddNav(SettingsPage.Story, Glyph.Story);
        AddNav(SettingsPage.Library, Glyph.Library);
        AddSection("App settings");
        AddNav(SettingsPage.General, Glyph.Settings);
        AddNav(SettingsPage.Shortcuts, Glyph.Shortcut);
        AddNav(SettingsPage.OpenWith, Glyph.Open);
        AddSection("Capture & processing");
        AddNav(SettingsPage.Privacy, Glyph.Privacy);
        AddNav(SettingsPage.Links, Glyph.Link);
        AddNav(SettingsPage.Ai, Glyph.Smart);
        AddSection("Data & support");
        AddNav(SettingsPage.Storage, Glyph.Storage);
        AddNav(SettingsPage.Advanced, Glyph.Diagnostic);
        AddNav(SettingsPage.About, Glyph.Info);
        var pane = new Border { Child = stack, BorderThickness = new Thickness(0, 0, 1, 0) }.WithBackground("Nav");
        pane.SetResourceReference(Border.BorderBrushProperty, "Line");
        return pane;
    }

    private void UpdateStoryNav() => buttons[SettingsPage.Story].Button.Visibility =
        app.Settings.Ai is { Enabled: true, Story: true } ? Visibility.Visible : Visibility.Collapsed;

    private void AddSection(string name)
    {
        var label = Ui.Text(Labels.Get(name), 10.5, "Quiet");
        label.Margin = new Thickness(9, nav.Children.Count == 0 ? 4 : 12, 0, 4);
        nav.Children.Add(label);
    }

    private void AddNav(SettingsPage page, string glyph)
    {
        var button = Ui.Button(PageTitle(page), () => Select(page), "NavButton");
        AutomationProperties.SetName(button, PageTitle(page));
        nav.Children.Add(button);
        buttons.Add(page, (button, glyph));
    }

    private void Select(SettingsPage page, bool rebuild = false, bool remember = true)
    {
        if (!buttons.ContainsKey(page)) page = SettingsPage.General;
        if (page == SettingsPage.Story && app.Settings.Ai is not { Enabled: true, Story: true }) page = SettingsPage.Library;
        UpdateStoryNav();
        if (host.Content is not null && current == page && !rebuild)
        {
            if (page == SettingsPage.Library)
            {
                library.Refresh();
                library.FocusResults();
            }
            if (page == SettingsPage.Links) RefreshLinkHistory();
            return;
        }
        if (current == SettingsPage.Links) ClearLinkPage();
        current = page;
        foreach (var (key, item) in buttons)
        {
            bool selected = key == page;
            item.Button.Content = Ui.WithIcon(item.Glyph, PageTitle(key), selected ? "AccentInk" : "Ink");
            item.Button.SetResourceReference(BackgroundProperty, selected ? "AccentTint" : "TransparentBrush");
        }
        if (remember && app.Settings.LastSettingsPage != page.ToString())
            app.SaveSettings(app.Settings with { LastSettingsPage = page.ToString() });
        if (page == SettingsPage.Library)
        {
            host.Content = library;
            library.Refresh();
            library.FocusResults();
            return;
        }
        var layout = new StackPanel { Margin = new Thickness(27, 25, 27, 22), MaxWidth = 920, HorizontalAlignment = HorizontalAlignment.Stretch };
        layout.Children.Add(Ui.Text(PageTitle(page), 25, strong: true));
        var caption = Ui.Text(PageSubtitle(page), 12, "Muted");
        caption.Margin = new Thickness(0, 4, 0, 18);
        layout.Children.Add(caption);
        if (page == SettingsPage.Links)
        {
            host.Content = BuildLinks(layout);
            return;
        }
        switch (page)
        {
            case SettingsPage.General: BuildGeneral(layout); break;
            case SettingsPage.Privacy: BuildPrivacy(layout); break;
            case SettingsPage.Shortcuts: BuildShortcuts(layout); break;
            case SettingsPage.OpenWith: BuildOpenWith(layout); break;
            case SettingsPage.Storage: BuildStorage(layout); break;
            case SettingsPage.Advanced: BuildAdvanced(layout); break;
            case SettingsPage.About: BuildAbout(layout); break;
            case SettingsPage.Ai: BuildAi(layout); break;
            case SettingsPage.Story: BuildStory(layout); break;
        }
        host.Content = new ScrollViewer { Content = layout, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private void OnWindowKey(object sender, KeyEventArgs e)
    {
        if (Keyboard.FocusedElement is FrameworkElement { Tag: { } tag } && ReferenceEquals(tag, ShortcutRecorder)) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        bool Match(Command command) => Shortcuts.Match(app.Settings, command, key, Keyboard.Modifiers);
        if (key == Key.Escape)
        {
            if (current == SettingsPage.Library && library.IsComposingSearch) return;
            if (current != SettingsPage.Library || !library.TryCancelMarking()) Hide();
        }
        else if (Match(Command.Close)) Hide();
        else if (Match(Command.Library)) Select(SettingsPage.Library);
        else if (Match(Command.Settings)) Select(SettingsPage.General);
        else
        {
            if (current == SettingsPage.Library) library.HandleKey(e);
            return;
        }
        e.Handled = true;
    }

    private static string PageTitle(SettingsPage page) => Labels.Get(page switch
    {
        SettingsPage.Privacy => "Capture & privacy", SettingsPage.OpenWith => "Open With",
        SettingsPage.Links => "Link resolution", SettingsPage.Ai => "AI Organization",
        SettingsPage.Storage => "Storage & cleanup", SettingsPage.Advanced => "Advanced diagnostics", _ => page.ToString()
    });

    private static string PageSubtitle(SettingsPage page) => Labels.Get(page switch
    {
        SettingsPage.General => "Appearance, startup and application status",
        SettingsPage.Privacy => "Clipboard capture, image recognition, source details and excluded apps",
        SettingsPage.Shortcuts => "Quick panel and clip actions",
        SettingsPage.OpenWith => "Choose your browser, editor and file rules",
        SettingsPage.Links => "Page titles, fallback rules and sign-in sessions",
        SettingsPage.Storage => "Content statistics, local storage, archive and backup",
        SettingsPage.Advanced => "Permissions, integrations and search",
        SettingsPage.About => "Version and product information",
        SettingsPage.Ai => "Models, topic groups, tasks and usage",
        SettingsPage.Story => "Look back at the last seven days and see your progress", _ => ""
    });

    private StackPanel SettingsCard(Panel layout, string name)
    {
        var fields = new StackPanel();
        fields.Children.Add(Ui.SectionTitle(name));
        layout.Children.Add(Ui.Section(fields));
        return fields;
    }

    private static FrameworkElement Row(string title, FrameworkElement field, string? description = null, ImageSource? icon = null)
    {
        var row = new Grid { Margin = new Thickness(0, 8, 0, 6) };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) };
        label.Children.Add(Ui.Text(Labels.Get(title), 13));
        if (description is not null) label.Children.Add(Ui.Text(Labels.Get(description), 11, "Muted"));
        if (icon is null) row.Children.Add(label);
        else
        {
            var heading = new DockPanel { VerticalAlignment = VerticalAlignment.Center };
            var image = new Image { Source = icon, Width = 33, Height = 33, Margin = new Thickness(0, 0, 6, 0) };
            DockPanel.SetDock(image, Dock.Left);
            heading.Children.Add(image);
            heading.Children.Add(label);
            row.Children.Add(heading);
        }
        field.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(field, 1);
        row.Children.Add(field);
        return row;
    }

    private void Switch(Panel panel, string title, bool enabled, Func<LocalSettings, bool, LocalSettings> update,
        string? description = null, bool available = true)
    {
        var toggle = new CheckBox { IsChecked = enabled, IsEnabled = available };
        toggle.SetResourceReference(StyleProperty, "SettingsSwitch");
        AutomationProperties.SetName(toggle, Labels.Get(title));
        toggle.Click += (_, _) =>
        {
            bool next = toggle.IsChecked == true;
            if (!app.SaveSettings(update(app.Settings, next))) toggle.IsChecked = !next;
        };
        panel.Children.Add(Row(title, toggle, description));
    }

    private static ComboBox Picker(string label, IEnumerable<string> options, string selected)
    {
        var picker = new ComboBox
        {
            ItemsSource = options.Select(value => new { Value = value, Name = Labels.Get(value) }).ToArray(),
            DisplayMemberPath = "Name", SelectedValuePath = "Value", SelectedValue = selected, MinHeight = 27, MinWidth = 115
        };
        picker.SetResourceReference(StyleProperty, "SettingsPicker");
        AutomationProperties.SetName(picker, Labels.Get(label));
        return picker;
    }

    private void BuildGeneral(Panel layout)
    {
        var appearance = SettingsCard(layout, "Appearance");
        var colors = new WrapPanel();
        foreach (var color in Theme.Colors)
        {
            var selected = color.Equals(app.Settings.Theme, StringComparison.Ordinal);
            var swatch = Ui.Button("", () =>
            {
                if (app.SaveSettings(app.Settings with { Theme = color }))
                    foreach (Button item in colors.Children) item.Content = Equals(item.Tag, color) ? "✓" : "";
            });
            swatch.Content = selected ? "✓" : "";
            swatch.Tag = color;
            swatch.Width = 27;
            swatch.Height = 27;
            swatch.MinHeight = 0;
            swatch.Margin = new Thickness(4, 0, 0, 0);
            swatch.Padding = new Thickness(0);
            swatch.Background = Theme.Swatch(color);
            swatch.Foreground = System.Windows.Media.Brushes.White;
            swatch.ToolTip = Labels.Get(color);
            AutomationProperties.SetName(swatch, Labels.Get(color));
            colors.Children.Add(swatch);
        }
        appearance.Children.Add(Row("Theme color", colors));
        var display = Picker("Appearance", ["System", "Light", "Dark"], app.Settings.Appearance);
        display.SelectionChanged += (_, _) =>
        {
            if (display.SelectedValue is string mode) app.SaveSettings(app.Settings with { Appearance = mode });
        };
        appearance.Children.Add(Row("Appearance", display));
        var language = Picker("Language", ["System", "English", "简体中文"], app.Settings.Language);
        language.SelectionChanged += (_, _) =>
        {
            if (language.SelectedValue is string value && app.SaveSettings(app.Settings with { Language = value }))
                SetStatus(Labels.Get("Restart Pasteory to apply the language."));
        };
        appearance.Children.Add(Row("Language", language));

        var quick = SettingsCard(layout, "Quick panel");
        Switch(quick, "Keep panel open", app.Settings.KeepPanelOpen, (settings, value) => settings with { KeepPanelOpen = value });
        var placement = Picker("Group placement", ["Top", "Left", "Right"], GroupNavigation.Placement(app.Settings));
        placement.SelectionChanged += (_, _) =>
        {
            if (placement.SelectedValue is string side)
                app.SaveSettings(app.Settings with { QuickGroupPlacement = side, GroupSidebar = side != "Top" });
        };
        quick.Children.Add(Row("Group placement", placement));
        var groups = Picker("Group display", GroupNavigation.Profiles, app.Settings.GroupDisplay);
        groups.SelectionChanged += (_, _) =>
        {
            if (groups.SelectedValue is string selected) app.SetGroupProfile(selected);
        };
        quick.Children.Add(Row("Group display", groups));
        Switch(quick, "Recommend AI groups in Common view", app.Settings.RecommendAiGroups,
            (settings, value) => settings with { RecommendAiGroups = value });
        var recommended = Picker("AI recommendation count", Enumerable.Range(1, 8).Select(count => count.ToString()),
            GroupNavigation.RecommendationCount(app.Settings).ToString());
        recommended.SelectionChanged += (_, _) =>
        {
            if (recommended.SelectedValue is string value && int.TryParse(value, out int count) &&
                !app.SaveSettings(app.Settings with { Ai = app.Settings.Ai with { RecommendedGroupCount = count } }))
                recommended.SelectedValue = GroupNavigation.RecommendationCount(app.Settings).ToString();
        };
        quick.Children.Add(Row("AI recommendation count", recommended));
        quick.Children.Add(Row("Group sidebar width", GroupWidthSlider()));
        Switch(quick, "Compact group rows", app.Settings.CompactGroupRows, (settings, value) => settings with { CompactGroupRows = value });

        var runtime = SettingsCard(layout, "Application");
        Switch(runtime, "Start at sign-in", app.Settings.StartAtLogin, (settings, value) => settings with { StartAtLogin = value });
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        var restart = Ui.Button("Restart Pasteory", app.Restart);
        restart.Margin = new Thickness(0, 0, 6, 0);
        actions.Children.Add(restart);
        actions.Children.Add(Ui.Button("Quit", () => app.Shutdown()));
        runtime.Children.Add(Row("Application status", actions, "Pasteory is running in the system tray."));
    }

    private FrameworkElement GroupWidthSlider()
    {
        var slider = new Slider
        {
            Minimum = GroupNavigation.MinSidebarWidth, Maximum = GroupNavigation.MaxSidebarWidth,
            Value = GroupNavigation.SidebarWidth(app.Settings), TickFrequency = 1, IsSnapToTickEnabled = true,
            SmallChange = 1, LargeChange = 10, Width = 140, VerticalAlignment = VerticalAlignment.Center
        };
        AutomationProperties.SetName(slider, Labels.Get("Group sidebar width"));
        var value = Ui.Text(slider.Value.ToString("0"), 12, "Muted");
        value.MinWidth = 34;
        value.TextAlignment = TextAlignment.Right;
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(slider);
        row.Children.Add(value);
        void SaveWidth()
        {
            if (slider.Value != GroupNavigation.SidebarWidth(app.Settings) &&
                !app.SaveSettings(app.Settings with { GroupSidebarWidth = slider.Value }))
                slider.Value = GroupNavigation.SidebarWidth(app.Settings);
        }
        slider.ValueChanged += (_, _) =>
        {
            value.Text = slider.Value.ToString("0");
            if (!slider.IsMouseCaptureWithin) SaveWidth();
        };
        slider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, args) =>
        {
            if (args.Canceled) slider.Value = GroupNavigation.SidebarWidth(app.Settings);
            else SaveWidth();
        }));
        slider.PreviewMouseLeftButtonUp += (_, _) => SaveWidth();
        return row;
    }

    private void BuildShortcuts(Panel layout)
    {
        var boxes = new Dictionary<string, (TextBox Box, string Default)>();
        foreach (var section in Shortcuts.Sections)
        {
            var card = SettingsCard(layout, section.Title);
            foreach (var command in section.Actions)
            {
                var entry = Shortcuts.Entries.First(item => item.Action == command);
                AddRecorder(card, command.ToString(), entry.Title, Shortcuts.Text(app.Settings, command), entry.Default,
                    requireModifier: command == Command.ShowPanel);
            }
        }
        var positions = SettingsCard(layout, "Switch groups by position");
        foreach (var action in GroupNavigation.Positions)
            AddRecorder(positions, action.Setting, action.Title, GroupNavigation.Text(app.Settings, action), action.Default, requireModifier: true);
        var views = SettingsCard(layout, "Switch group views");
        foreach (var action in GroupNavigation.Views)
            AddRecorder(views, action.Setting, action.Title, GroupNavigation.Text(app.Settings, action), action.Default, requireModifier: true);
        var fixedKeys = SettingsCard(layout, "Fixed navigation keys");
        fixedKeys.Children.Add(Row("Choose content / switch groups", Ui.Text("↑↓ / ←→", 12, "Muted")));
        fixedKeys.Children.Add(Row("Quick paste the first nine clips", Ui.Text(Labels.Get("Ctrl+1–9"), 12, "Muted")));
        fixedKeys.Children.Add(Row("Close the current layer", Ui.Text("Esc", 12, "Muted")));

        void AddRecorder(Panel card, string keyName, string title, string value, string resetTo, bool requireModifier)
        {
            if (Shortcut.TryParse(value, out var existing)) value = existing.ToString();
            if (Shortcut.TryParse(resetTo, out var baseline)) resetTo = baseline.ToString();
            var recorder = Ui.Field(title, value);
            recorder.IsReadOnly = true;
            recorder.Width = 155;
            recorder.Tag = ShortcutRecorder;
            recorder.ToolTip = Labels.Get("Click and press a shortcut");
            recorder.PreviewKeyDown += (_, e) =>
            {
                var key = e.Key == Key.System ? e.SystemKey : e.Key;
                if (key is Key.Tab or Key.Escape) return;
                var candidate = new Shortcut(key, Keyboard.Modifiers);
                if (candidate.Modifiers == ModifierKeys.Control && candidate.Key is >= Key.D1 and <= Key.D9)
                {
                    SetStatus(Labels.Get("Ctrl+1–9 are reserved for quick paste."));
                    e.Handled = true;
                    return;
                }
                if (Shortcut.TryParse(candidate.ToString(), out var parsed) &&
                    (!requireModifier || parsed.Modifiers != ModifierKeys.None)) recorder.Text = parsed.ToString();
                e.Handled = true;
            };
            boxes[keyName] = (recorder, resetTo);
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            recorder.Margin = new Thickness(0, 0, 6, 0);
            row.Children.Add(recorder);
            row.Children.Add(Ui.IconButton(Glyph.Close, "Disable shortcut", () => recorder.Clear()));
            card.Children.Add(Row(title, row));
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 8, 0, 0) };
        var reset = Ui.Button("Restore defaults", () =>
        {
            foreach (var entry in boxes.Values) entry.Box.Text = entry.Default;
        });
        reset.Margin = new Thickness(0, 0, 6, 0);
        actions.Children.Add(reset);
        actions.Children.Add(Ui.Button("Save", () =>
        {
            if (boxes.Values.Select(entry => entry.Box.Text).Where(value => value.Length > 0)
                .GroupBy(value => value, StringComparer.OrdinalIgnoreCase).Any(group => group.Count() > 1))
            {
                SetStatus(Labels.Get("Each shortcut must use a different key combination."));
                return;
            }
            var saved = new Dictionary<string, string>(app.Settings.Shortcuts);
            foreach (var (key, entry) in boxes) saved[key] = entry.Box.Text;
            if (app.SaveSettings(app.Settings with { UseAlternateShortcut = false, Shortcuts = saved }))
                SetStatus(boxes[nameof(Command.ShowPanel)].Box.Text.Length > 0 && !app.ShortcutAvailable ?
                    Labels.Get("Windows could not register the global shortcut.") : Labels.Get("Settings saved."));
        }, "PrimaryButton"));
        layout.Children.Add(actions);
    }

    private void BuildOpenWith(Panel layout)
    {
        var apps = SettingsCard(layout, "Applications");
        AppPath(apps, "Browser", app.Settings.BrowserPath, (settings, value) => settings with { BrowserPath = value });
        AppPath(apps, "Image viewer", app.Settings.ImageViewerPath, (settings, value) => settings with { ImageViewerPath = value });
        AppPath(apps, "Code editor", app.Settings.CodeEditorPath, (settings, value) => settings with { CodeEditorPath = value });
        var files = SettingsCard(layout, "File open rules");
        foreach (var rule in app.Settings.FileRules.OrderBy(item => item.Extension, StringComparer.OrdinalIgnoreCase))
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            var edit = Ui.Button("Edit", () => EditFileRule(rule));
            edit.Margin = new Thickness(0, 0, 5, 0);
            actions.Children.Add(edit);
            if (!string.IsNullOrWhiteSpace(rule.Command) && !rule.ShowTerminal)
            {
                var log = Ui.Button("Command output", () => ViewCommandLog(rule));
                log.Margin = new Thickness(0, 0, 5, 0);
                void Update(string suffix)
                {
                    if (!rule.Extension.Equals(suffix, StringComparison.OrdinalIgnoreCase)) return;
                    var run = app.FileCommands.Latest(suffix);
                    log.Content = Labels.Get("Command output") + (run is null ? "" : " · " + CommandStatus(run));
                    log.ToolTip = run?.Error;
                }
                Update(rule.Extension);
                log.Loaded += (_, _) => app.FileCommands.Changed += Update;
                log.Unloaded += (_, _) => app.FileCommands.Changed -= Update;
                actions.Children.Add(log);
            }
            actions.Children.Add(Ui.IconButton(Glyph.Close, "Remove file rule", () =>
            {
                if (app.SaveSettings(app.Settings with { FileRules = app.Settings.FileRules.Where(item => item != rule).ToArray() }))
                    Select(SettingsPage.OpenWith, rebuild: true);
            }));
            var type = FileTypes.ForSuffix(rule.Extension);
            files.Children.Add(Row("." + rule.Extension, actions, type.Name + " · " +
                (rule.Command is { Length: > 0 } ? Labels.Get("PowerShell command") : rule.ApplicationPath), FileTypes.Image(type)));
        }
        files.Children.Add(Row("Match by file extension", Ui.Button("Add rule", () => EditFileRule(null), "PrimaryButton")));
    }

    private void AppPath(Panel panel, string title, string? path, Func<LocalSettings, string?, LocalSettings> update)
    {
        var select = new StackPanel { Orientation = Orientation.Horizontal };
        var choose = Ui.Button("Choose app…", () =>
        {
            if (ApplicationPicker.Choose(app, this, "Choose app…", choice => choice.Path.Equals(path, StringComparison.OrdinalIgnoreCase)) is { } selected &&
                app.SaveSettings(update(app.Settings, selected.Path)))
                Select(SettingsPage.OpenWith, rebuild: true);
        });
        choose.Margin = new Thickness(0, 0, 5, 0);
        select.Children.Add(choose);
        if (path is not null)
            select.Children.Add(Ui.IconButton(Glyph.Close, "Remove app", () =>
            {
                if (app.SaveSettings(update(app.Settings, null))) Select(SettingsPage.OpenWith, rebuild: true);
            }));
        panel.Children.Add(Row(title, select, path is null ? title == "Image viewer" ? "Windows default" : "Choose an application" : path,
            app.SourceIcon(path)));
    }

    private void EditFileRule(FileOpenRule? existing) => LibraryEditors.ShowModal(this, "File open rules", close =>
    {
        var form = new StackPanel();
        var extension = Ui.Field("File extension", existing?.Extension ?? "", 40);
        var mode = Picker("Open mode", ["Application", "PowerShell command"], existing?.Command is { Length: > 0 } ? "PowerShell command" : "Application");
        var path = Ui.Field("Application", existing?.ApplicationPath ?? "");
        var pathRow = new DockPanel();
        var choose = Ui.Button("Choose app…", () =>
        {
            var owner = GetWindow(path) ?? this;
            if (ApplicationPicker.Choose(app, owner, "Choose app…", choice => choice.Path.Equals(path.Text, StringComparison.OrdinalIgnoreCase)) is { } selected)
                path.Text = selected.Path;
        });
        DockPanel.SetDock(choose, Dock.Right);
        choose.Margin = new Thickness(5, 0, 0, 0);
        pathRow.Children.Add(choose);
        pathRow.Children.Add(path);
        var script = Ui.Field("PowerShell command", existing?.Command ?? "", 8000);
        script.AcceptsReturn = true;
        script.MinHeight = 84;
        script.TextWrapping = TextWrapping.Wrap;
        var terminal = new CheckBox { Content = Labels.Get("Show terminal"), IsChecked = existing?.ShowTerminal ?? true };
        var scriptPanel = new StackPanel();
        scriptPanel.Children.Add(script);
        scriptPanel.Children.Add(Ui.Text(Labels.Get("$file is the full file path. The working directory is its containing folder."), 11, "Muted"));
        scriptPanel.Children.Add(terminal);
        void Toggle()
        {
            bool command = (string?)mode.SelectedValue == "PowerShell command";
            pathRow.Visibility = command ? Visibility.Collapsed : Visibility.Visible;
            scriptPanel.Visibility = command ? Visibility.Visible : Visibility.Collapsed;
        }
        var suffixEntry = new DockPanel();
        var (catalog, search) = FileExtensionPicker(extension);
        var presets = Ui.Button("Preset file extensions", () =>
        {
            catalog.Visibility = catalog.IsVisible ? Visibility.Collapsed : Visibility.Visible;
            if (catalog.IsVisible) _ = Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
            {
                if (!catalog.IsVisible) return;
                search.BringIntoView();
                Keyboard.Focus(search);
            }));
        });
        DockPanel.SetDock(presets, Dock.Right);
        presets.Margin = new Thickness(6, 0, 0, 0);
        suffixEntry.Children.Add(presets);
        suffixEntry.Children.Add(extension);
        Ui.AddField(form, "File extension", suffixEntry);
        form.Children.Add(catalog);
        Ui.AddField(form, "Open mode", mode);
        form.Children.Add(pathRow);
        form.Children.Add(scriptPanel);
        mode.SelectionChanged += (_, _) => Toggle();
        Toggle();
        return LibraryEditors.Wrap("File open rules", form, extension, () =>
        {
            string suffix = extension.Text.Trim().TrimStart('.').ToLowerInvariant();
            bool command = (string?)mode.SelectedValue == "PowerShell command";
            if (suffix.Length == 0 || suffix.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not ('.' or '-' or '_')) ||
                (command ? string.IsNullOrWhiteSpace(script.Text) : !File.Exists(path.Text) || !path.Text.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)))
            {
                MessageBox.Show(this, Labels.Get("Enter a file extension and a valid open action."), "Pasteory");
                return false;
            }
            var rule = new FileOpenRule(suffix, command ? null : path.Text, command ? script.Text : null, terminal.IsChecked == true);
            if (!app.SaveSettings(app.Settings with
            {
                FileRules = [.. app.Settings.FileRules.Where(item => item != existing && item.Extension != suffix), rule]
            })) return false;
            Select(SettingsPage.OpenWith, rebuild: true);
            return true;
        }, close) with { Submit = null };
    });

    private static (StackPanel Panel, TextBox Search) FileExtensionPicker(TextBox destination)
    {
        var panel = new StackPanel { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 6) };
        var filter = Ui.Field("Search extensions or types", "");
        var choices = new ListBox { MaxHeight = 178, Margin = new Thickness(0, 3, 0, 0) };
        AutomationProperties.SetName(choices, Labels.Get("Preset file extensions"));
        Ui.AddField(panel, "Search extensions or types", filter);
        panel.Children.Add(choices);

        void Populate()
        {
            string query = filter.Text.Trim();
            choices.Items.Clear();
            foreach (string suffix in FileTypes.Suffixes)
            {
                var type = FileTypes.ForSuffix(suffix);
                if (!("." + suffix).Contains(query, StringComparison.OrdinalIgnoreCase) &&
                    !type.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)) continue;
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                row.Children.Add(Ui.Text("." + suffix, 13, strong: true));
                row.Children.Add(new Image { Source = FileTypes.Image(type), Width = 28, Height = 28, Margin = new Thickness(8, 0, 5, 0) });
                row.Children.Add(Ui.Text(type.Name, 11, "Muted"));
                var item = new ListBoxItem { Content = row, Tag = suffix };
                AutomationProperties.SetName(item, $".{suffix} · {type.Name}");
                choices.Items.Add(item);
            }
        }

        filter.TextChanged += (_, _) => Populate();
        void Choose()
        {
            if (choices.SelectedItem is not ListBoxItem { Tag: string suffix }) return;
            destination.Text = suffix;
            choices.SelectedIndex = -1;
            panel.Visibility = Visibility.Collapsed;
            destination.Focus();
        }
        choices.MouseDoubleClick += (_, _) => Choose();
        choices.PreviewKeyDown += (_, args) =>
        {
            if (args.Key != Key.Enter) return;
            args.Handled = true;
            Choose();
        };
        var use = Ui.Button("Use extension", Choose);
        use.HorizontalAlignment = HorizontalAlignment.Right;
        use.IsEnabled = false;
        use.Margin = new Thickness(0, 4, 0, 0);
        choices.SelectionChanged += (_, _) => use.IsEnabled = choices.SelectedItem is not null;
        panel.Children.Add(use);
        panel.IsVisibleChanged += (_, _) => { if (panel.IsVisible) Populate(); };
        return (panel, filter);
    }

    private void ViewCommandLog(FileOpenRule rule)
    {
        var dialog = new Window { Owner = this, Title = Labels.Get("Command output"), Width = 590, Height = 400,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false };
        var view = ContentPreview.TextBoxFor("", true);
        var rows = new DockPanel { Margin = new Thickness(12) };
        var label = Ui.Text("", 12, "Muted");
        DockPanel.SetDock(label, Dock.Top);
        rows.Children.Add(label);
        rows.Children.Add(view);
        dialog.Content = rows;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        void Refresh()
        {
            if (app.FileCommands.Latest(rule.Extension) is not { } run)
            {
                label.Text = Labels.Get("No command has run for this rule.");
                return;
            }
            label.Text = run.Error ?? CommandStatus(run);
            try
            {
                if (File.Exists(run.Path))
                {
                    using var file = new FileStream(run.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    using var reader = new StreamReader(file);
                    string next = reader.ReadToEnd();
                    if (view.Text != next) view.Text = next;
                }
            }
            catch (Exception error) when (App.IsLocalError(error)) { }
        }
        timer.Tick += (_, _) => Refresh();
        dialog.Closed += (_, _) => timer.Stop();
        Refresh();
        timer.Start();
        dialog.ShowDialog();
    }

    private static string CommandStatus(FileCommandRunner.Run run) => run.Error is not null ? Labels.Get("Failed") :
        run.ExitCode is null ? Labels.Get("Running…") : run.ExitCode is 0 ? Labels.Get("Completed") :
        Labels.Format("Exit code {0}", run.ExitCode);

    private void BuildAdvanced(Panel layout)
    {
        var diagnostics = SettingsCard(layout, "Runtime status");
        diagnostics.Children.Add(Row("Clipboard listener", Ui.Text(Labels.Get(app.CaptureAvailable ? "Active" : "Inactive"), 12, "Muted")));
        diagnostics.Children.Add(Row("Global shortcut", Ui.Text(Labels.Get(app.ShortcutAvailable ? "Active" : "Inactive"), 12, "Muted")));
        diagnostics.Children.Add(Row("Data folder", Ui.Button("Open data folder", app.OpenDataFolder), app.DataDirectory));
        diagnostics.Children.Add(Row("File command logs", Ui.Button("Open folder", () =>
        {
            string folder = FileCommandRunner.LogFolder(app.DataDirectory);
            Directory.CreateDirectory(folder);
            App.OpenInShell(folder);
        })));
        var chrome = SettingsCard(layout, "Chrome extension");
        AddChromeConnectionStatus(chrome);
        chrome.Children.Add(Row("Manage browser connection", Ui.Button("Open link resolution settings", OpenLinkConnections)));
        var search = SettingsCard(layout, "Search index");
        var rebuild = Ui.Button("Rebuild search index", async () =>
        {
            if (rebuildingSearchIndex) return;
            rebuildingSearchIndex = true;
            Select(SettingsPage.Advanced, rebuild: true);
            SetStatus(Labels.Get("Rebuilding search index…"));
            try
            {
                await app.RebuildSearchIndexAsync();
                if (!app.Exiting) SetStatus(Labels.Get("Search index rebuilt."));
            }
            catch (OperationCanceledException) when (app.Exiting) { }
            catch (IOException error) { SetStatus(Labels.Get(error.Message)); }
            finally
            {
                rebuildingSearchIndex = false;
                if (!app.Exiting && current == SettingsPage.Advanced) Select(SettingsPage.Advanced, rebuild: true);
            }
        });
        rebuild.IsEnabled = !rebuildingSearchIndex;
        search.Children.Add(Row("Find saved clipboard content", rebuild, "Rebuild the index using the saved clipboard records."));
    }

    private void BuildAbout(Panel layout)
    {
        var card = SettingsCard(layout, "Pasteory for Windows");
        var brand = new DockPanel { Margin = new Thickness(0, 12, 0, 9) };
        var icon = new Image { Source = Icon, Height = 58, Width = 58, Margin = new Thickness(0, 0, 12, 0) };
        DockPanel.SetDock(icon, Dock.Left);
        brand.Children.Add(icon);
        var title = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(Ui.Text("Pasteory", 19, strong: true));
        title.Children.Add(Ui.Text(Labels.Format("Version {0}", Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.1.57"), 12, "Muted"));
        brand.Children.Add(title);
        card.Children.Add(brand);
        card.Children.Add(Ui.Text(Labels.Get("Pasteory learns from what you copied."), 13));
        card.Children.Add(Row("Source code", Ui.Button("Open GitHub", () => App.OpenInShell("https://github.com/houskii/Pasteory"))));
        var updater = SettingsCard(layout, "Updates");
        Switch(updater, "Automatically check for updates daily", app.Settings.CheckUpdatesDaily,
            (settings, value) => settings with { CheckUpdatesDaily = value });
        updater.Children.Add(Row("Last update check", Ui.Button("Check for updates…", async () =>
        {
            await app.CheckUpdatesAsync(manual: true, this);
            if (!app.Exiting) Select(SettingsPage.About, rebuild: true);
        }), app.Settings.LastUpdateCheck?.ToLocalTime().ToString("g") ?? "Not checked yet"));
        if (app.Updates.Available is { } offer) updater.Children.Add(Row(Labels.Format("Update {0} is available", offer.Version),
            Ui.Button("View update", () => app.ShowUpdate(this))));
    }
}
