using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed partial class SettingsWindow
{
    private void BuildPrivacy(Panel layout)
    {
        var capture = SettingsCard(layout, "Clipboard capture");
        var intervals = new (int Milliseconds, string Title)[] { (0, "Immediately"), (100, "0.1 seconds"), (500, "0.5 seconds"), (1000, "1 second") };
        var frequency = new TabControl();
        frequency.SetResourceReference(StyleProperty, "SettingsSegmentedTabs");
        AutomationProperties.SetName(frequency, Labels.Get("Clipboard detection interval"));
        foreach (var interval in intervals)
            frequency.Items.Add(new TabItem { Header = Labels.Get(interval.Title) });
        frequency.SelectedIndex = Array.FindIndex(intervals, interval => interval.Milliseconds == app.Settings.CaptureInterval());
        frequency.SelectionChanged += (_, e) =>
        {
            if (e.Source != frequency || frequency.SelectedIndex < 0) return;
            int value = intervals[frequency.SelectedIndex].Milliseconds;
            if (app.Settings.CaptureInterval() != value && !app.SaveSettings(app.Settings with { CaptureIntervalMilliseconds = value }))
                frequency.SelectedIndex = Array.FindIndex(intervals, interval => interval.Milliseconds == app.Settings.CaptureInterval());
        };
        capture.Children.Add(Row("Clipboard detection interval", frequency,
            "Save the latest change at the selected interval. Opening the quick panel checks immediately."));
        Switch(capture, "Pause clipboard capture", app.Settings.Paused, (settings, value) => settings with { Paused = value },
            "Capture pauses while Windows is locked or asleep.");

        var recognition = SettingsCard(layout, "Image text recognition");
        Switch(recognition, "Recognize image text", app.Settings.RecognizeImages,
            (settings, value) => settings with { RecognizeImages = value },
            "Recognition runs on this device and appends [OCR:…] to the note. You can edit the result, search it or copy it as plain text.");

        var protections = SettingsCard(layout, "Default protections");
        protections.Children.Add(Ui.Text(Labels.Get("Known password managers are excluded automatically."), 12));
        protections.Children.Add(Ui.Text(Labels.Get("Pasteory honors Windows clipboard privacy markers."), 12));
        protections.Children.Add(Ui.Text(Labels.Format("Format limits are {0} MiB for text and {1} MiB for images.",
            ClipboardFormats.MaxTextBytes / (1024 * 1024), ClipboardFormats.MaxImageBytes / (1024 * 1024)), 12));

        var sources = SettingsCard(layout, "Source details");
        var browser = Ui.SectionTitle("Browser");
        browser.Margin = new Thickness(0, 9, 0, 0);
        sources.Children.Add(browser);
        bool chromeExcluded = app.Settings.ShouldIgnore("chrome");
        Switch(sources, "Google Chrome", app.Settings.SourceContextEnabled(SourceCaptureApplication.Chrome),
            (settings, value) => settings with { IncludeBrowserContext = value },
            chromeExcluded ? "This app is excluded from clipboard capture." : "Page address, title, selection, and surrounding content.",
            available: !chromeExcluded);
        if (!chromeExcluded)
            sources.Children.Add(Ui.Text(Labels.Get("Manage which sites share context from the Pasteory Chrome extension."), 11, "Muted"));

        var communication = Ui.SectionTitle("Communication");
        communication.Margin = new Thickness(0, 12, 0, 0);
        sources.Children.Add(communication);
        AddChatSource(sources, "WeChat", SourceCaptureApplication.WeChat, ["Weixin", "WeChat"],
            (settings, value) => settings with { IncludeWeChatContext = value });
        AddChatSource(sources, "Feishu", SourceCaptureApplication.Feishu, ["Feishu", "Lark"],
            (settings, value) => settings with { IncludeFeishuContext = value });
        sources.Children.Add(Ui.Text(Labels.Get("Source preferences apply to new copies."), 11, "Muted"));

        var exclusions = SettingsCard(layout, "Excluded apps");
        if (app.Settings.IgnoredApps.Length == 0)
            exclusions.Children.Add(Ui.Text(Labels.Get("No custom app exclusions."), 12, "Muted"));
        foreach (string entry in app.Settings.IgnoredApps)
        {
            var identity = app.Settings.IgnoredAppIdentities.GetValueOrDefault(entry.ToUpperInvariant());
            string? executable = identity?.Path ?? app.Clips.FirstOrDefault(clip =>
                clip.Source.Equals(entry, StringComparison.OrdinalIgnoreCase) && clip.SourcePath is not null)?.SourcePath;
            var remove = Ui.Button("Remove", () => SaveExclusions(app.Settings.IgnoredApps
                .Where(name => !name.Equals(entry, StringComparison.OrdinalIgnoreCase)).ToArray()));
            AutomationProperties.SetName(remove, Labels.Format("Remove app exclusion for {0}", identity?.Name ?? entry));
            exclusions.Children.Add(Row(identity?.Name ?? entry, remove, executable, app.SourceIcon(executable)));
        }
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0)
        };
        AddAction(actions, "Edit process names…", EditExcludedProcesses);
        var choose = Ui.Button("Choose app…", () =>
        {
            var application = ApplicationPicker.Choose(app, this, "Choose an app to exclude",
                choice => app.Settings.ShouldIgnore(choice.ProcessName));
            if (application is null || app.Settings.ShouldIgnore(application.ProcessName)) return;
            SaveExclusions([.. app.Settings.IgnoredApps, application.ProcessName], application);
        }, "PrimaryButton");
        actions.Children.Add(choose);
        exclusions.Children.Add(actions);
    }

    private void AddChatSource(Panel sources, string title, SourceCaptureApplication source, string[] processNames,
        Func<LocalSettings, bool, LocalSettings> update)
    {
        var blocked = processNames.Where(app.Settings.ShouldIgnore).ToArray();
        bool excluded = blocked.Length == processNames.Length;
        string detail = excluded ? "This app is excluded from clipboard capture." :
            "Save the active conversation title and type when available.";
        Switch(sources, title, app.Settings.SourceContextEnabled(source), update, detail, available: !excluded);
        if (!excluded && blocked.Length > 0)
            sources.Children.Add(Ui.Text(Labels.Format("Excluded processes {0}", string.Join(", ", blocked)), 11, "WarningInk"));
    }

    private bool SaveExclusions(string[] exclusions, DesktopApplication? selected = null)
    {
        var names = exclusions.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var identities = app.Settings.IgnoredAppIdentities.Where(entry => names.Contains(entry.Key))
            .ToDictionary(entry => entry.Key, entry => entry.Value, StringComparer.OrdinalIgnoreCase);
        if (selected is not null)
            identities[selected.ProcessName.ToUpperInvariant()] = new(selected.Name, selected.Path);
        if (!app.SaveSettings(app.Settings with { IgnoredApps = exclusions, IgnoredAppIdentities = identities })) return false;
        Select(SettingsPage.Privacy, rebuild: true);
        SetStatus(Labels.Get("Settings saved."));
        return true;
    }

    private void EditExcludedProcesses() => LibraryEditors.ShowModal(this, "Edit process names…", close =>
    {
        var form = new StackPanel();
        var ignored = Ui.Field("Excluded apps", string.Join(Environment.NewLine, app.Settings.IgnoredApps), 4000);
        ignored.AcceptsReturn = true;
        ignored.MinHeight = 132;
        ignored.VerticalContentAlignment = VerticalAlignment.Top;
        ignored.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        Ui.AddField(form, "Excluded process names, one per line (for example KeePassXC)", ignored);
        return LibraryEditors.Wrap("Edit process names…", form, ignored, () =>
        {
            string[] entries = ignored.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(name => name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? Path.GetFileNameWithoutExtension(name) : name)
                .Where(name => !string.IsNullOrWhiteSpace(name)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            return SaveExclusions(entries);
        }, close) with { Submit = null };
    }, 526, 380);
}
