using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
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
    private readonly DispatcherTimer clearStatus = new() { Interval = TimeSpan.FromSeconds(4) };
    private readonly DispatcherTimer saveSize = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private readonly LibraryPage library;
    private SettingsPage current;
    private static readonly object ShortcutRecorder = new();

    internal SettingsWindow(App app)
    {
        this.app = app;
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
        status.Visibility = Visibility.Collapsed;
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        var root = new Grid();
        var navColumn = new ColumnDefinition { Width = new GridLength(224) };
        root.ColumnDefinitions.Add(navColumn);
        root.ColumnDefinitions.Add(new ColumnDefinition());
        var sidebar = BuildNav();
        var surface = new DockPanel();
        DockPanel.SetDock(status, Dock.Bottom);
        surface.Children.Add(status);
        surface.Children.Add(host);
        Grid.SetColumn(surface, 1);
        root.Children.Add(sidebar);
        root.Children.Add(surface);
        Content = root;
        clearStatus.Tick += (_, _) => { clearStatus.Stop(); status.Visibility = Visibility.Collapsed; };
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
        status.Text = message;
        status.ToolTip = message;
        status.Visibility = Visibility.Visible;
        clearStatus.Stop();
        clearStatus.Start();
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

        AddSection("Content");
        AddNav(SettingsPage.Story, Glyph.Story);
        AddNav(SettingsPage.Library, Glyph.Library);
        AddSection("Basic settings");
        AddNav(SettingsPage.General, Glyph.Settings);
        AddNav(SettingsPage.Privacy, Glyph.Privacy);
        AddSection("Interaction & content");
        AddNav(SettingsPage.Shortcuts, Glyph.Shortcut);
        AddNav(SettingsPage.OpenWith, Glyph.Open);
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
            if (page == SettingsPage.Library) library.Refresh();
            return;
        }
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
            return;
        }
        var layout = new StackPanel { Margin = new Thickness(27, 25, 27, 22), MaxWidth = 920, HorizontalAlignment = HorizontalAlignment.Stretch };
        layout.Children.Add(Ui.Text(PageTitle(page), 25, strong: true));
        var caption = Ui.Text(PageSubtitle(page), 12, "Muted");
        caption.Margin = new Thickness(0, 4, 0, 18);
        layout.Children.Add(caption);
        switch (page)
        {
            case SettingsPage.General: BuildGeneral(layout); break;
            case SettingsPage.Privacy: BuildPrivacy(layout); break;
            case SettingsPage.Shortcuts: BuildShortcuts(layout); break;
            case SettingsPage.OpenWith: BuildOpenWith(layout); break;
            case SettingsPage.Links: BuildLinks(layout); break;
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
        if (key == Key.Escape || Match(Command.Close)) Hide();
        else if (Match(Command.Library)) Select(SettingsPage.Library);
        else if (Match(Command.Settings)) Select(SettingsPage.General);
        else return;
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

    private void Switch(Panel panel, string title, bool enabled, Func<LocalSettings, bool, LocalSettings> update, string? description = null)
    {
        var toggle = new CheckBox { IsChecked = enabled };
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
        Switch(quick, "Show groups in sidebar", app.Settings.GroupSidebar, (settings, value) => settings with { GroupSidebar = value });
        var groups = Picker("Group display", ["Common groups", "All groups", "AI groups", "Minimal"], app.Settings.GroupDisplay);
        groups.SelectionChanged += (_, _) =>
        {
            if (groups.SelectedValue is string selected) app.SaveSettings(app.Settings with { GroupDisplay = selected });
        };
        quick.Children.Add(Row("Group display", groups));

        var runtime = SettingsCard(layout, "Application");
        Switch(runtime, "Start at sign-in", app.Settings.StartAtLogin, (settings, value) => settings with { StartAtLogin = value });
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        var restart = Ui.Button("Restart Pasteory", app.Restart);
        restart.Margin = new Thickness(0, 0, 6, 0);
        actions.Children.Add(restart);
        actions.Children.Add(Ui.Button("Quit", () => app.Shutdown()));
        runtime.Children.Add(Row("Application status", actions, "Pasteory is running in the system tray."));
    }

    private void BuildPrivacy(Panel layout)
    {
        var capture = SettingsCard(layout, "Clipboard capture");
        Switch(capture, "Pause clipboard capture", app.Settings.Paused, (settings, value) => settings with { Paused = value });
        capture.Children.Add(Ui.Text(Labels.Get("Windows clipboard changes are recorded as they happen."), 11, "Muted"));
        Switch(capture, "Recognize image text", app.Settings.RecognizeImages, (settings, value) => settings with { RecognizeImages = value },
            "Recognition runs on this device, and the text is searchable.");
        var sources = SettingsCard(layout, "Source details");
        Switch(sources, "Chrome page context", app.Settings.IncludeBrowserContext, (settings, value) => settings with { IncludeBrowserContext = value },
            "Uses the Pasteory Chrome extension.");
        Switch(sources, "WeChat and Feishu conversation titles", app.Settings.IncludeChatContext, (settings, value) => settings with { IncludeChatContext = value },
            "Saves the active conversation title when the app exposes it.");
        var exclusions = SettingsCard(layout, "Excluded apps");
        var ignored = Ui.Field("Excluded apps", string.Join(Environment.NewLine, app.Settings.IgnoredApps), 4000);
        ignored.AcceptsReturn = true;
        ignored.MinHeight = 105;
        ignored.VerticalContentAlignment = VerticalAlignment.Top;
        ignored.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        Ui.AddField(exclusions, "Excluded process names, one per line (for example KeePassXC)", ignored);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 8, 0, 0) };
        var browse = Ui.Button("Choose app…", () =>
        {
            var picker = AppPicker();
            if (picker.ShowDialog(this) == true) ignored.AppendText(
                (ignored.Text.Length > 0 ? Environment.NewLine : "") + Path.GetFileNameWithoutExtension(picker.FileName));
        });
        browse.Margin = new Thickness(0, 0, 6, 0);
        actions.Children.Add(browse);
        actions.Children.Add(Ui.Button("Save", () =>
        {
            string[] entries = ignored.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(line => line.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? Path.GetFileNameWithoutExtension(line) : line)
                .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (app.SaveSettings(app.Settings with { IgnoredApps = entries })) SetStatus(Labels.Get("Settings saved."));
        }, "PrimaryButton"));
        exclusions.Children.Add(actions);
    }

    private void BuildShortcuts(Panel layout)
    {
        var bindings = SettingsCard(layout, "Keyboard shortcuts");
        var boxes = new Dictionary<Command, TextBox>();
        foreach (var (command, title, _) in Shortcuts.Entries)
        {
            var recorder = Ui.Field(title, Shortcuts.Text(app.Settings, command));
            recorder.IsReadOnly = true;
            recorder.Width = 155;
            recorder.Tag = ShortcutRecorder;
            recorder.ToolTip = Labels.Get("Click and press a shortcut");
            recorder.PreviewKeyDown += (_, e) =>
            {
                var key = e.Key == Key.System ? e.SystemKey : e.Key;
                if (key is Key.Tab or Key.Escape) return;
                var candidate = new Shortcut(key, Keyboard.Modifiers);
                if (Shortcut.TryParse(candidate.ToString(), out var parsed) &&
                    (command != Command.ShowPanel || parsed.Modifiers != ModifierKeys.None)) recorder.Text = parsed.ToString();
                e.Handled = true;
            };
            boxes[command] = recorder;
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            recorder.Margin = new Thickness(0, 0, 6, 0);
            row.Children.Add(recorder);
            row.Children.Add(Ui.IconButton(Glyph.Close, "Disable shortcut", () => recorder.Clear()));
            bindings.Children.Add(Row(title, row));
        }
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 8, 0, 0) };
        var reset = Ui.Button("Restore defaults", () =>
        {
            foreach (var entry in Shortcuts.Entries) boxes[entry.Action].Text = entry.Default;
        });
        reset.Margin = new Thickness(0, 0, 6, 0);
        actions.Children.Add(reset);
        actions.Children.Add(Ui.Button("Save", () =>
        {
            if (boxes.Values.Select(box => box.Text).Where(value => value.Length > 0)
                .GroupBy(value => value, StringComparer.OrdinalIgnoreCase).Any(group => group.Count() > 1))
            {
                SetStatus(Labels.Get("Each shortcut must use a different key combination."));
                return;
            }
            if (app.SaveSettings(app.Settings with { UseAlternateShortcut = false,
                Shortcuts = boxes.ToDictionary(pair => pair.Key.ToString(), pair => pair.Value.Text) }))
                SetStatus(boxes[Command.ShowPanel].Text.Length > 0 && !app.ShortcutAvailable ?
                    Labels.Get("Windows could not register the global shortcut.") : Labels.Get("Settings saved."));
        }, "PrimaryButton"));
        bindings.Children.Add(actions);
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
            var picker = AppPicker();
            if (picker.ShowDialog(this) == true && app.SaveSettings(update(app.Settings, picker.FileName)))
                Select(SettingsPage.OpenWith, rebuild: true);
        });
        choose.Margin = new Thickness(0, 0, 5, 0);
        select.Children.Add(choose);
        if (path is not null)
            select.Children.Add(Ui.IconButton(Glyph.Close, "Remove app", () =>
            {
                if (app.SaveSettings(update(app.Settings, null))) Select(SettingsPage.OpenWith, rebuild: true);
            }));
        panel.Children.Add(Row(title, select, path is null ? title == "Image viewer" ? "Windows default" : "Choose an application" : path));
    }

    private static OpenFileDialog AppPicker() => new()
    {
        Title = Labels.Get("Choose app…"), Filter = $"{Labels.Get("Windows applications")} (*.exe)|*.exe", CheckFileExists = true
    };

    private void EditFileRule(FileOpenRule? existing) => LibraryEditors.ShowModal(this, "File open rules", close =>
    {
        var form = new StackPanel();
        var extension = Ui.Field("File extension", existing?.Extension ?? "", 40);
        var mode = Picker("Open mode", ["Application", "PowerShell command"], existing?.Command is { Length: > 0 } ? "PowerShell command" : "Application");
        var path = Ui.Field("Application", existing?.ApplicationPath ?? "");
        var pathRow = new DockPanel();
        var choose = Ui.Button("Choose app…", () =>
        {
            var picker = AppPicker();
            if (picker.ShowDialog(this) == true) path.Text = picker.FileName;
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

    private void BuildLinks(Panel layout)
    {
        var card = SettingsCard(layout, "Web page titles");
        Switch(card, "Resolve copied links automatically", app.Settings.ResolveLinks,
            (settings, value) => settings with { ResolveLinks = value }, "Public page titles are requested without browser cookies.");
        card.Children.Add(Row("Unresolved links", Ui.Button("Retry", async () =>
        {
            await app.ResolveMatchingLinksAsync();
            SetStatus(Labels.Get("Link resolution finished."));
        })));
        BuildLinkRules(layout);
    }

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
        chrome.Children.Add(Row("Pasteory Web Context", Ui.Button("Prepare Chrome extension", () => app.PrepareChromeExtension()),
            "Load the prepared folder as an unpacked extension in Chrome."));
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
