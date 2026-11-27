using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed partial class SettingsWindow
{
    private void BuildAi(Panel layout)
    {
        var tabs = new TabControl { Margin = new Thickness(0, 0, 0, 13) };
        tabs.SetResourceReference(StyleProperty, "SettingsSegmentedTabs");
        AutomationProperties.SetName(tabs, Labels.Get("AI settings"));
        var analysis = new StackPanel { Margin = new Thickness(0, 11, 0, 0) };
        var life = new StackPanel { Margin = new Thickness(0, 11, 0, 0) };
        var usage = new StackPanel { Margin = new Thickness(0, 11, 0, 0) };
        var tasks = new StackPanel { Margin = new Thickness(0, 11, 0, 0) };
        tabs.Items.Add(new TabItem { Header = Labels.Get("Model & analysis"), Content = analysis });
        tabs.Items.Add(new TabItem { Header = Labels.Get("Lifecycle and compression"), Content = life });
        tabs.Items.Add(new TabItem { Header = Labels.Get("Token usage"), Content = usage });
        tabs.Items.Add(new TabItem { Header = Labels.Get("Tasks"), Content = tasks });
        tabs.SelectedIndex = Math.Clamp(app.Settings.LastAiTab, 0, 3);
        tabs.SelectionChanged += (_, e) =>
        {
            if (e.Source == tabs && tabs.SelectedIndex >= 0 && app.Settings.LastAiTab != tabs.SelectedIndex)
                app.SaveSettings(app.Settings with { LastAiTab = tabs.SelectedIndex });
        };
        layout.Children.Add(tabs);
        BuildModel(analysis);
        BuildAiPolicy(analysis);
        BuildActivityPreferences(life, app.Settings.Ai.Activity);
        BuildAiUsage(usage);
        BuildTaskStatus(tasks, false);
        BuildAiHistory(tasks);
    }

    private void BuildModel(Panel layout)
    {
        var preferences = app.Settings.Ai;
        var master = SettingsCard(layout, "AI analysis");
        master.Children.Add(Ui.Text(Labels.Get("AI requests send eligible clips to the model you configure."), 11, "Muted"));
        var enable = new CheckBox { IsChecked = preferences.Enabled };
        enable.SetResourceReference(StyleProperty, "SettingsSwitch");
        AutomationProperties.SetName(enable, Labels.Get("Enable AI analysis"));
        enable.Click += (_, _) =>
        {
            bool next = enable.IsChecked == true;
            if (!app.SaveSettings(app.Settings with { Ai = app.Settings.Ai with { Enabled = next } }))
                enable.IsChecked = !next;
            else if (!next) app.Ai.Pause();
            UpdateStoryNav();
        };
        master.Children.Add(Row("Enable AI analysis", enable));

        var connect = SettingsCard(layout, "Model connection");
        var endpoint = Ui.Field("Base URL", preferences.Endpoint, 1000);
        string[] presets = ["Magpie", "Ollama", "Custom"];
        var provider = Picker("Provider", presets, preferences.Endpoint.Contains(":3425", StringComparison.Ordinal) ? "Magpie" :
            preferences.Endpoint.Contains(":11434", StringComparison.Ordinal) ? "Ollama" : "Custom");
        provider.SelectionChanged += (_, _) =>
        {
            if ((string?)provider.SelectedValue == "Magpie") endpoint.Text = "http://127.0.0.1:3425/v1";
            if ((string?)provider.SelectedValue == "Ollama") endpoint.Text = "http://127.0.0.1:11434/v1";
        };
        connect.Children.Add(Row("Provider", provider));
        Ui.AddField(connect, "Base URL", endpoint);
        var secret = new PasswordBox { MaxLength = 600, MinHeight = 29, Padding = new Thickness(8, 4, 8, 4) };
        AutomationProperties.SetName(secret, Labels.Get("API key"));
        Ui.AddField(connect, "API key", secret);
        var keyHint = Ui.Text(Labels.Get("The API key is encrypted for this Windows user."), 11, "Muted");
        connect.Children.Add(keyHint);
        var models = new ComboBox { IsEditable = true, Text = preferences.Model, MinHeight = 30 };
        AutomationProperties.SetName(models, Labels.Get("Model"));
        Ui.AddField(connect, "Model", models);
        var none = new[] { "auto" };
        var reasoning = Picker("Reasoning", preferences.Reasoning == "auto" ? none : ["auto", preferences.Reasoning],
            preferences.Reasoning);
        connect.Children.Add(Row("Reasoning", reasoning));
        AiModelClient.Model[] catalog = [];
        models.SelectionChanged += (_, _) =>
        {
            string? id = models.SelectedItem as string;
            var levels = catalog.FirstOrDefault(item => item.Id == id)?.Reasoning ?? [];
            reasoning.ItemsSource = new[] { "auto" }.Concat(levels).Distinct().Select(item => new { Value = item, Name = Labels.Get(item) }).ToArray();
            reasoning.SelectedValue = "auto";
        };
        AiPreferences Draft() => app.Settings.Ai with
        {
            Endpoint = endpoint.Text.Trim().TrimEnd('/'),
            Model = models.Text.Trim(),
            Reasoning = (string?)reasoning.SelectedValue ?? "auto"
        };
        var buttons = new WrapPanel { Margin = new Thickness(0, 10, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
        AddAction(buttons, "Fetch models", async () =>
        {
            try
            {
                string typed = models.Text;
                catalog = await app.Ai.ModelsAsync(endpoint.Text, secret.Password.Trim(), app.AppToken);
                models.ItemsSource = catalog.Select(item => item.Id).ToArray();
                models.Text = typed;
                if (catalog.Length == 1 && typed.Length == 0) models.SelectedIndex = 0;
                SetStatus(Labels.Format("{0} models returned.", catalog.Length));
            }
            catch (Exception error) when (AiTasks.Expected(error) || error is OperationCanceledException) { SetStatus(Labels.Get(error.Message)); }
        });
        AddAction(buttons, "Test connection", async () =>
        {
            try
            {
                await app.Ai.TestAsync(Draft(), secret.Password.Trim(), app.AppToken);
                SetStatus(Labels.Get("Model connection succeeded."));
            }
            catch (Exception error) when (AiTasks.Expected(error) || error is OperationCanceledException)
            { SetStatus(Labels.Get(error.Message)); }
        });
        AddAction(buttons, "Clear saved key", () =>
        {
            try
            {
                if (ClipMenus.Confirm(this, "Clear the saved API key?"))
                {
                    app.Ai.Credentials.Set(Draft().Endpoint, "");
                    secret.Clear();
                    SetStatus(Labels.Get("Saved key cleared."));
                }
            }
            catch (Exception error) when (AiTasks.Expected(error)) { SetStatus(Labels.Get(error.Message)); }
        });
        buttons.Children.Add(Ui.Button("Save", () =>
        {
            var next = Draft();
            if (!AiModelClient.TryEndpoint(next.Endpoint, out _))
            {
                SetStatus(Labels.Get("Use an HTTPS API endpoint or a loopback HTTP endpoint."));
                return;
            }
            try
            {
                string key = secret.Password.Trim();
                if (key.Length > 0) app.Ai.Credentials.Set(next.Endpoint, key);
                if (!app.SaveSettings(app.Settings with { Ai = next })) return;
                secret.Clear();
                SetStatus(Labels.Get("Settings saved."));
            }
            catch (Exception error) when (AiTasks.Expected(error)) { SetStatus(Labels.Get(error.Message)); }
        }, "PrimaryButton"));
        connect.Children.Add(buttons);

        var story = SettingsCard(layout, "Story");
        var summarize = new CheckBox { IsChecked = preferences.Story };
        summarize.SetResourceReference(StyleProperty, "SettingsSwitch");
        AutomationProperties.SetName(summarize, Labels.Get("Enable Story"));
        summarize.Click += (_, _) =>
        {
            bool next = summarize.IsChecked == true;
            if (!app.SaveSettings(app.Settings with { Ai = app.Settings.Ai with { Story = next } }))
                summarize.IsChecked = !next;
            UpdateStoryNav();
        };
        story.Children.Add(Row("Enable Story", summarize, "Make a recap from eligible clips in the last seven days."));

        var share = SettingsCard(layout, "Shared content");
        Switch(share, "Share notes", preferences.ShareNotes, (settings, flag) => settings with { Ai = settings.Ai with { ShareNotes = flag } });
        Switch(share, "Share source app names", preferences.ShareSource, (settings, flag) => settings with { Ai = settings.Ai with { ShareSource = flag } });
        Switch(share, "Share locally recognized image text", preferences.ShareOcr, (settings, flag) => settings with { Ai = settings.Ai with { ShareOcr = flag } });
        Switch(share, "Allow linked images and files", preferences.ShareResources,
            (settings, flag) => settings with { Ai = settings.Ai with { ShareResources = flag } },
            "The configured model can request supported resources already referenced by a task.");
        var prompt = Ui.Field("Organization preferences", preferences.Prompt, 4000);
        prompt.AcceptsReturn = true;
        prompt.MinHeight = 55;
        prompt.TextWrapping = TextWrapping.Wrap;
        prompt.VerticalContentAlignment = VerticalAlignment.Top;
        Ui.AddField(share, "Organization preferences", prompt);
        var promptActions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 6, 0, 0) };
        var restorePrompt = Ui.Button("Use default prompt", prompt.Clear);
        restorePrompt.Margin = new Thickness(0, 0, 6, 0);
        promptActions.Children.Add(restorePrompt);
        var savePrompt = Ui.Button("Save preferences", () => app.SaveSettings(app.Settings with { Ai = app.Settings.Ai with { Prompt = prompt.Text } }));
        promptActions.Children.Add(savePrompt);
        share.Children.Add(promptActions);
    }

    private void BuildAiPolicy(Panel layout)
    {
        var prefs = app.Settings.Ai;
        var automatic = SettingsCard(layout, "Organization policy");
        Switch(automatic, "Organize newly copied content", prefs.AutoOrganize,
            (settings, flag) => settings with { Ai = settings.Ai with { AutoOrganize = flag } });
        Switch(automatic, "Organize while idle", prefs.IdleOrganize,
            (settings, flag) => settings with { Ai = settings.Ai with { IdleOrganize = flag } },
            "Runs in the chosen hours after five minutes of inactivity.");
        Switch(automatic, "Review low-activity themes every seven days", prefs.WeeklyThemeReview,
            (settings, flag) => settings with { Ai = settings.Ai with { WeeklyThemeReview = flag } });
        var limit = Ui.Field("Recent clip limit", prefs.RecentLimit.ToString(CultureInfo.InvariantCulture), 4);
        var themes = Picker("Target theme count", ["6", "7", "8"], Math.Clamp(prefs.TargetGroupCount, 6, 8).ToString(CultureInfo.InvariantCulture));
        var rounds = Ui.Field("Model rounds per run", prefs.TaskRounds.ToString(CultureInfo.InvariantCulture), 3);
        var starts = Enumerable.Range(0, 23).Select(hour => $"{hour:D2}:00").ToArray();
        var ends = Enumerable.Range(1, 23).Select(hour => $"{hour:D2}:00").ToArray();
        var start = Picker("Idle start", starts, $"{Math.Clamp(prefs.IdleStartHour, 0, 22):D2}:00");
        var end = Picker("Idle end", ends, $"{Math.Clamp(prefs.IdleEndHour, 1, 23):D2}:00");
        var mode = Picker("Application mode", ["Review before applying", "Automatically add to existing AI groups"],
            prefs.AppendExistingAiGroups ? "Automatically add to existing AI groups" : "Review before applying");
        limit.Width = rounds.Width = 104;
        automatic.Children.Add(Row("Idle start", start));
        automatic.Children.Add(Row("Idle end", end));
        automatic.Children.Add(Row("Application mode", mode));
        automatic.Children.Add(Row("Recent clip limit", limit));
        automatic.Children.Add(Row("Target theme count", themes));
        automatic.Children.Add(Row("Model rounds per run", rounds));
        automatic.Children.Add(Row("Manual organization", Ui.Button("Save", () =>
        {
            if (!int.TryParse(limit.Text, out int value) || value is < 1 or > 1000)
            {
                SetStatus(Labels.Get("Enter a limit between 1 and 1000."));
                return;
            }
            if (!int.TryParse(rounds.Text, out int roundLimit) || roundLimit is < 1 or > 500)
            {
                SetStatus(Labels.Get("Enter a model round limit between 1 and 500."));
                return;
            }
            int target = int.Parse((string?)themes.SelectedValue ?? "7", CultureInfo.InvariantCulture);
            int from = Array.IndexOf(starts, (string?)start.SelectedValue);
            int through = Array.IndexOf(ends, (string?)end.SelectedValue) + 1;
            if (from < 0 || through <= from)
            {
                SetStatus(Labels.Get("The idle end must be after the start."));
                return;
            }
            app.SaveSettings(app.Settings with
            {
                Ai = app.Settings.Ai with
                {
                    RecentLimit = value, TargetGroupCount = target, TaskRounds = roundLimit, IdleStartHour = from, IdleEndHour = through,
                    AppendExistingAiGroups = (string?)mode.SelectedValue == "Automatically add to existing AI groups"
                }
            });
            SetStatus(Labels.Get("Settings saved."));
        }, "PrimaryButton")));
    }

    private void BuildActivityPreferences(Panel layout, ActivityPreferences activity)
    {
        var card = SettingsCard(layout, "Activity calculation");
        Switch(card, "Enable content lifecycle", app.Settings.Ai.LifecycleEnabled,
            (settings, flag) => settings with { Ai = settings.Ai with { LifecycleEnabled = flag } });
        var presets = Picker("Lifecycle preset", ["Aggressive", "Standard", "Conservative"], activity.RetainDays switch
        { <= 3 => "Aggressive", >= 14 => "Conservative", _ => "Standard" });
        card.Children.Add(Row("Lifecycle preset", presets));
        TextBox Numeric(string label, double value)
        {
            var input = Ui.Field(label, value.ToString(CultureInfo.CurrentCulture), 12);
            input.Width = 105;
            card.Children.Add(Row(label, input));
            return input;
        }
        var retain = Numeric("Retention threshold (days)", activity.RetainDays);
        var compress = Numeric("Compression threshold (days)", activity.CompressDays);
        var archive = Numeric("Archive threshold (days)", activity.ArchiveDays);
        var halfLife = Numeric("Activity half-life (hours)", activity.HalfLifeHours);
        var copy = Numeric("Copy boost", activity.CopyBoost);
        var paste = Numeric("Paste boost", activity.PasteBoost);
        var top = Numeric("Highest-ranked members", activity.TopMembers);
        var weight = Numeric("Highest-ranked weight", activity.TopWeight);
        presets.SelectionChanged += (_, _) =>
        {
            var thresholds = (string?)presets.SelectedValue switch
            { "Aggressive" => (3, 7, 30), "Conservative" => (14, 30, 120), _ => (7, 14, 60) };
            retain.Text = thresholds.Item1.ToString(CultureInfo.CurrentCulture);
            compress.Text = thresholds.Item2.ToString(CultureInfo.CurrentCulture);
            archive.Text = thresholds.Item3.ToString(CultureInfo.CurrentCulture);
        };
        card.Children.Add(Row("Activity calculation", Ui.Button("Save", () =>
        {
            if (!int.TryParse(retain.Text, out int a) || !int.TryParse(compress.Text, out int b) ||
                !int.TryParse(archive.Text, out int c) || a < 1 || b < a || c < b || c > 3650 ||
                !double.TryParse(halfLife.Text, out double hours) || !double.IsFinite(hours) || hours is < 1 or > 8760 ||
                !double.TryParse(copy.Text, out double copied) || !double.IsFinite(copied) || copied is < 0 or > 3 ||
                !double.TryParse(paste.Text, out double pasted) || !double.IsFinite(pasted) || pasted is < 0 or > 3 ||
                !int.TryParse(top.Text, out int members) || members is < 1 or > 100 ||
                !double.TryParse(weight.Text, out double portion) || !double.IsFinite(portion) || portion is < 0 or > 1)
            { SetStatus(Labels.Get("Enter valid lifecycle parameters.")); return; }
            app.SaveSettings(app.Settings with { Ai = app.Settings.Ai with
            {
                Activity = new ActivityPreferences(hours, copied, pasted, members, portion, a, b, c)
            } });
            SetStatus(Labels.Get("Settings saved."));
        }, "PrimaryButton")));

        var compression = SettingsCard(layout, "Lossless compression");
        Switch(compression, "Automatically compress eligible content", app.Settings.Ai.AutomaticCompression,
            (settings, flag) => settings with { Ai = settings.Ai with { AutomaticCompression = flag } },
            "Uses the saved compression threshold and content activity. Favorites and pins are excluded.");
        var compressNow = Ui.Button("Compress eligible content", async () => await app.CompressEligibleContentAsync(manual: true));
        compressNow.HorizontalAlignment = HorizontalAlignment.Right;
        compressNow.Margin = new Thickness(0, 8, 0, 0);
        compression.Children.Add(compressNow);
    }

    private void BuildAiUsage(Panel layout)
    {
        var card = SettingsCard(layout, "Daily budget");
        card.Children.Add(Ui.Text(Labels.Format("{0:N0} tokens used today", app.Ai.TodayTokens), 17, "AccentInk", strong: true));
        var budget = Ui.Field("Daily token limit", app.Settings.Ai.DailyTokens.ToString(CultureInfo.InvariantCulture), 9);
        var nightly = Ui.Field("Nightly token limit", app.Settings.Ai.NightlyTokens.ToString(CultureInfo.InvariantCulture), 8);
        var count = Ui.Field("Daily automatic tasks", app.Settings.Ai.DailyAutomaticTasks.ToString(CultureInfo.InvariantCulture), 4);
        var input = Ui.Field("Input tokens per request", app.Settings.Ai.MaxInputTokens.ToString(CultureInfo.InvariantCulture), 6);
        var output = Ui.Field("Output tokens per request", app.Settings.Ai.MaxOutputTokens.ToString(CultureInfo.InvariantCulture), 5);
        budget.Width = count.Width = nightly.Width = input.Width = output.Width = 124;
        card.Children.Add(Row("Daily token limit", budget));
        card.Children.Add(Row("Nightly token limit", nightly));
        card.Children.Add(Row("Daily automatic tasks", count));
        card.Children.Add(Row("Input tokens per request", input, "The request estimate includes the prompt, recent tool turns and tool definitions."));
        card.Children.Add(Row("Output tokens per request", output));
        card.Children.Add(Row("Token usage", Ui.Button("Save", () =>
        {
            if (!int.TryParse(budget.Text, out int tokens) || tokens is < 1000 or > 50_000_000 ||
                !int.TryParse(nightly.Text, out int night) || night is < 1000 or > 10_000_000 ||
                !int.TryParse(count.Text, out int jobs) || jobs is < 0 or > 1000)
            {
                SetStatus(Labels.Get("Enter a valid token budget and automatic task limit."));
                return;
            }
            if (!int.TryParse(input.Text, out int maxInput) || maxInput is < 1_000 or > 128_000 ||
                !int.TryParse(output.Text, out int maxOutput) || maxOutput is < 256 or > 16_384)
            {
                SetStatus(Labels.Get("Use 1,000–128,000 input tokens and 256–16,384 output tokens per request."));
                return;
            }
            app.SaveSettings(app.Settings with { Ai = app.Settings.Ai with
            {
                DailyTokens = tokens, NightlyTokens = night, DailyAutomaticTasks = jobs, MaxInputTokens = maxInput, MaxOutputTokens = maxOutput
            } });
        }, "PrimaryButton")));

        var chart = SettingsCard(layout, "Last 7 days");
        var days = Enumerable.Range(0, 7).Select(i => DateTime.Now.Date.AddDays(-i)).Select(date =>
            (Date: date, Used: app.Ai.Usage.Where(call => call.At.ToLocalTime().Date == date).Sum(call => call.Tokens))).ToArray();
        long maximum = Math.Max(1, days.Max(day => day.Used));
        foreach (var day in days)
        {
            var row = new DockPanel { Margin = new Thickness(0, 4, 0, 2) };
            var label = Ui.Text(day.Date.ToString("MM-dd"), 11, "Muted");
            label.Width = 52;
            DockPanel.SetDock(label, Dock.Left);
            row.Children.Add(label);
            var total = Ui.Text(day.Used.ToString("N0", CultureInfo.CurrentCulture), 11, "Muted");
            total.MinWidth = 56;
            total.HorizontalAlignment = HorizontalAlignment.Right;
            DockPanel.SetDock(total, Dock.Right);
            row.Children.Add(total);
            var width = new Grid { Height = 8, VerticalAlignment = VerticalAlignment.Center };
            width.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(day.Used, GridUnitType.Star) });
            width.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(maximum - day.Used, GridUnitType.Star) });
            width.Children.Add(new Border { CornerRadius = new CornerRadius(4) }.WithBackground("Accent"));
            row.Children.Add(width);
            chart.Children.Add(row);
        }
        var recent = new StackPanel();
        SettingsCard(layout, "Recent calls").Children.Add(recent);
        void Refresh()
        {
            recent.Children.Clear();
            foreach (var group in app.Ai.Usage.OrderByDescending(call => call.At).GroupBy(call => call.Task).Take(18))
            {
                var summary = new Expander
                {
                    Header = $"{Labels.Get(group.First().Kind)} · {group.First().Model} · {group.Sum(call => call.Tokens):N0}",
                    Margin = new Thickness(0, 6, 0, 0)
                };
                summary.SetResourceReference(ForegroundProperty, "Ink");
                var calls = new StackPanel { Margin = new Thickness(12, 4, 0, 3) };
                foreach (var call in group)
                    calls.Children.Add(Ui.Text(Labels.Format("{0:g} · input {1:N0} · output {2:N0} · cache {3:N0} · reasoning {4:N0}",
                        call.At.ToLocalTime(), call.Input, call.Output, call.Cached, call.Reasoning) +
                        $" · {Labels.Get(call.Estimated ? "Estimated" : "Reported")} · {Labels.Get(call.Outcome)}", 11, "Muted"));
                calls.Children.Add(Ui.Button("Open task files", () => OpenAiTask(group.Key)));
                summary.Content = calls;
                recent.Children.Add(summary);
            }
        }
        recent.Loaded += (_, _) => { app.Ai.Changed += Refresh; Refresh(); };
        recent.Unloaded += (_, _) => app.Ai.Changed -= Refresh;
    }

    private void OpenAiTask(Guid id)
    {
        string path = app.Ai.DirectoryFor(id);
        try
        {
            if (!Directory.Exists(path)) path = app.Ai.Folder;
            Directory.CreateDirectory(path);
            App.OpenInShell(path);
        }
        catch (Exception error) when (AiTasks.Expected(error)) { SetStatus(Labels.Get(error.Message)); }
    }

    private void BuildAiHistory(Panel layout)
    {
        var list = new StackPanel();
        SettingsCard(layout, "Task history").Children.Add(list);
        void Refresh()
        {
            list.Children.Clear();
            var tasks = app.Ai.RecentHistory();
            if (tasks.Length == 0) list.Children.Add(Ui.Text(Labels.Get("No AI tasks yet."), 12, "Muted"));
            foreach (var item in tasks)
            {
                var open = Ui.Button("Open task files", () => OpenAiTask(item.Id));
                list.Children.Add(Row(Labels.Get(item.Trigger), open,
                    Labels.Format("{0:g} · {1} clips · {2}", item.Started.ToLocalTime(), item.Total, Labels.Get(item.Status))));
            }
        }
        list.Loaded += (_, _) => { app.Ai.Changed += Refresh; Refresh(); };
        list.Unloaded += (_, _) => app.Ai.Changed -= Refresh;
    }

    private void BuildTaskStatus(Panel layout, bool story)
    {
        var card = SettingsCard(layout, story ? "Story generation" : "Organization tasks");
        var caption = Ui.Text("", 12, "Muted");
        caption.Margin = new Thickness(0, 8, 0, 7);
        card.Children.Add(caption);
        var progressBar = new ProgressBar { Height = 4, Margin = new Thickness(0, 0, 0, 8) };
        progressBar.SetResourceReference(ForegroundProperty, "Accent");
        card.Children.Add(progressBar);
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        var primary = Ui.Button(story ? "Generate Story" : "Analyze recent clips", async () =>
            await app.RunAiAsync(story, story ? "story" : "recent"), "PrimaryButton");
        primary.Margin = new Thickness(0, 0, 6, 0);
        actions.Children.Add(primary);
        var full = Ui.Button("Organize all clips", async () => await app.RunAiAsync(false, "full"));
        if (!story) actions.Children.Add(full);
        var groupReview = Ui.Button("Review existing themes", async () => await app.RunAiAsync(false, "manual-review"));
        groupReview.Margin = new Thickness(5, 0, 0, 0);
        if (!story) actions.Children.Add(groupReview);
        var pause = Ui.Button("Pause", app.Ai.Pause);
        var resume = Ui.Button("Resume last task", async () => await app.RunAiAsync(story, "", resume: true));
        var abandon = Ui.Button("Abandon task", () =>
        {
            if (!ClipMenus.Confirm(this, "Abandon this paused task?")) return;
            try { app.Ai.Abandon(story); }
            catch (Exception error) when (AiTasks.Expected(error)) { SetStatus(Labels.Get(error.Message)); }
        });
        var review = Ui.Button("Review suggestions", ShowReview, "PrimaryButton");
        var undo = Ui.Button("Undo AI organization", () => { app.UndoAi(); Select(SettingsPage.Ai, rebuild: true); });
        var files = Ui.Button("Open task files", () =>
        {
            if (app.Ai.Job(story) is { } job) OpenAiTask(job.Id);
        });
        foreach (var button in new[] { pause, resume, abandon, review, undo, files })
        {
            button.Margin = new Thickness(0, 0, 6, 3);
            actions.Children.Add(button);
        }
        card.Children.Add(actions);

        void Refresh()
        {
            var job = app.Ai.Job(story);
            bool running = app.Ai.Running;
            bool ready = !running && app.Settings.Ai.Enabled && app.Ai.CanConnect(app.Settings.Ai);
            bool canStart = ready && (story || app.Ai.Review is null && job?.Status != "Paused");
            primary.IsEnabled = full.IsEnabled = groupReview.IsEnabled = canStart;
            resume.IsEnabled = ready;
            caption.Text = job is null ? Labels.Get(canStart ? "Ready" : "Configure and enable AI analysis to begin.") :
                Labels.Get(job.Status) + $"  ·  {job.Cursor} / {job.Total}" + (job.Error is { Length: > 0 } error ? "  ·  " + Labels.Get(error) : "");
            progressBar.Visibility = job is { Total: > 0, Status: "Running" or "Paused" } ? Visibility.Visible : Visibility.Collapsed;
            progressBar.Maximum = Math.Max(1, job?.Total ?? 0);
            progressBar.Value = job?.Cursor ?? 0;
            progressBar.IsIndeterminate = running && job?.Status == "Running" && job.Cursor == 0;
            pause.Visibility = running && app.Ai.ActiveJob?.Kind == (story ? "story" : "organization") ? Visibility.Visible : Visibility.Collapsed;
            resume.Visibility = abandon.Visibility = !running && job?.Status == "Paused" ? Visibility.Visible : Visibility.Collapsed;
            files.Visibility = job is { Total: > 0 } ? Visibility.Visible : Visibility.Collapsed;
            review.Visibility = !story && app.Ai.Review is not null ? Visibility.Visible : Visibility.Collapsed;
            undo.Visibility = !story && app.CanUndoAi ? Visibility.Visible : Visibility.Collapsed;
        }
        card.Loaded += (_, _) => { app.Ai.Changed += Refresh; Refresh(); };
        card.Unloaded += (_, _) => app.Ai.Changed -= Refresh;
        Refresh();
    }

    internal void ShowReview()
    {
        if (app.Ai.Review is not { } review) return;
        LibraryEditors.ShowModal(this, "Review suggestions", close =>
        {
            var body = new StackPanel();
            var clips = app.Clips.ToDictionary(clip => clip.Id);
            bool regroup = review.Replacing is not null;
            if (review.Replacing is { Length: > 0 } replacing)
            {
                var summary = SettingsCard(body, "AI groups to replace");
                foreach (var item in replacing) summary.Children.Add(Ui.Text(item.Group.Name, 12));
                int outside = replacing.SelectMany(item => item.Members).Distinct().Count(id => !review.Versions.ContainsKey(id));
                if (outside > 0) summary.Children.Add(Ui.Text(Labels.Format("{0} clips outside the analysis scope will leave the replaced groups.", outside),
                    11, "Muted"));
            }
            body.Children.Add(Ui.Text(Labels.Format("{0} topics · {1} clips · {2} unassigned", review.Proposal.Groups.Length,
                review.Proposal.Groups.SelectMany(group => group.Members).Distinct().Count(), review.Proposal.Unassigned.Length), 12, "Muted"));
            var checks = new List<CheckBox>();
            foreach (var topic in review.Proposal.Groups)
            {
                var card = SettingsCard(body, topic.Name);
                var check = new CheckBox { Content = Labels.Format("Organize {0} clips", topic.Members.Length), IsChecked = true, Tag = topic.Name,
                    IsEnabled = !regroup };
                checks.Add(check);
                card.Children.Add(check);
                if (topic.Definition.Length > 0) card.Children.Add(Ui.Text(topic.Definition, 12));
                if (topic.Overview.Length > 0) card.Children.Add(Ui.Text(topic.Overview, 12, "Muted"));
                var sources = new Expander { Header = Labels.Get("Clips"), Margin = new Thickness(0, 8, 0, 0) };
                sources.Expanded += (_, _) =>
                {
                    if (sources.Content is not null) return;
                    var entries = new StackPanel { Margin = new Thickness(12, 5, 0, 0) };
                    foreach (Guid id in topic.Members)
                        entries.Children.Add(Ui.Text("• " + ClipLabel(id), 12, "Muted"));
                    sources.Content = entries;
                };
                card.Children.Add(sources);
            }
            if (review.Proposal.Unassigned.Length > 0)
            {
                var unassigned = new Expander { Header = Labels.Get("Unassigned clips"), Margin = new Thickness(0, 8, 0, 5) };
                unassigned.Expanded += (_, _) =>
                {
                    if (unassigned.Content is not null) return;
                    var entries = new StackPanel { Margin = new Thickness(12, 5, 0, 0) };
                    foreach (var item in review.Proposal.Unassigned)
                        entries.Children.Add(Ui.Text($"{ClipLabel(item.Id)} · {Labels.Get(item.Reason)}", 12, "Muted"));
                    unassigned.Content = entries;
                };
                body.Children.Add(unassigned);
            }
            var discard = Ui.Button("Discard proposal", () =>
            {
                if (!ClipMenus.Confirm(Window.GetWindow(body) ?? this, "Discard these AI suggestions?")) return;
                try { app.Ai.ClearReview(); close(); }
                catch (Exception error) when (AiTasks.Expected(error)) { SetStatus(Labels.Get(error.Message)); }
            });
            discard.HorizontalAlignment = HorizontalAlignment.Left;
            discard.Margin = new Thickness(0, 5, 0, 0);
            body.Children.Add(discard);
            var errorMessage = Ui.Text("", 12, "Danger");
            body.Children.Add(errorMessage);
            IInputElement focus = regroup ? discard : (IInputElement?)checks.FirstOrDefault() ?? body;
            var editor = LibraryEditors.Wrap("Review suggestions", body, focus,
                () =>
                {
                    app.ApplyAiPlan(review, checks.Where(check => check.IsChecked == true).Select(check => (string)check.Tag),
                        error => errorMessage.Text = Labels.Get(error));
                    return app.Ai.Review is null;
                }, close, regroup ? "Apply regrouping" : "Apply selected groups");
            return regroup ? editor with { Submit = null } : editor;

            string ClipLabel(Guid id) => clips.TryGetValue(id, out var clip) ?
                ClipCard.Short(clip.DisplayTitle.Length > 0 ? clip.DisplayTitle : clip.PlainText ?? Labels.Get(clip.Kind.ToString()), 95, 1) :
                Labels.Get("Source no longer matches");
        }, 640, 670);
    }

    private void BuildStory(Panel layout)
    {
        var content = new StackPanel();
        layout.Children.Add(content);
        Guid? latestId = null, selectedId = null;
        void Refresh()
        {
            if (current != SettingsPage.Story) return;
            content.Children.Clear();
            if (app.Ai.Stories.FirstOrDefault() is not { } recap)
            {
                content.Children.Add(Ui.Section(Ui.Text(Labels.Get("Your first Story will appear here."), 15, "Muted")));
                return;
            }
            if (latestId != recap.Id) selectedId = latestId = recap.Id;
            var pick = new ComboBox
            {
                ItemsSource = app.Ai.Stories.ToArray(), SelectedItem = app.Ai.Stories.FirstOrDefault(item => item.Id == selectedId) ?? recap,
                DisplayMemberPath = nameof(SavedStory.GeneratedAt),
                MinWidth = 170, Margin = new Thickness(0, 0, 0, 9), HorizontalAlignment = HorizontalAlignment.Right
            };
            AutomationProperties.SetName(pick, Labels.Get("Past Stories"));
            if (app.Ai.Stories.Count > 1) content.Children.Add(pick);
            var cards = new StackPanel();
            content.Children.Add(cards);
            pick.SelectionChanged += (_, _) =>
            {
                if (pick.SelectedItem is not SavedStory selected) return;
                selectedId = selected.Id;
                ShowRecap(cards, selected);
            };
            ShowRecap(cards, pick.SelectedItem as SavedStory ?? recap);
        }
        content.Loaded += (_, _) => { app.Ai.Changed += Refresh; Refresh(); };
        content.Unloaded += (_, _) => app.Ai.Changed -= Refresh;
        Refresh();
        BuildTaskStatus(layout, true);
    }

    private void ShowRecap(Panel layout, SavedStory recap)
    {
        layout.Children.Clear();
        var cover = new StackPanel();
        cover.Children.Add(Ui.Text($"{recap.From:yyyy-MM-dd}  –  {recap.Through:yyyy-MM-dd}", 11, "AccentInk", strong: true));
        var headline = Ui.Text(recap.Story.Title, 26, strong: true);
        headline.Margin = new Thickness(0, 5, 0, 12);
        cover.Children.Add(headline);
        cover.Children.Add(Ui.Text(recap.Story.Summary, 14));
        if (recap.SourceCount > 0)
            cover.Children.Add(Ui.Text(Labels.Format("Based on {0} clips · generated {1:g}", recap.SourceCount, recap.GeneratedAt.ToLocalTime()),
                11, "Muted"));
        var encouragement = Ui.Text(recap.Story.Encouragement, 13, "AccentInk", strong: true);
        encouragement.Margin = new Thickness(0, 13, 0, 3);
        cover.Children.Add(encouragement);
        layout.Children.Add(Ui.Section(cover));
        AddSections("Recent work", recap.Story.Work);
        AddSections("Observations", recap.Story.Observations);
        var record = Ui.Button("View this generation record", () => OpenAiTask(recap.Id));
        record.Margin = new Thickness(0, 8, 0, 0);
        record.HorizontalAlignment = HorizontalAlignment.Left;
        layout.Children.Add(record);
        void AddSections(string label, IEnumerable<StorySection> summaries)
        {
            var sections = summaries.ToArray();
            if (sections.Length == 0) return;
            var card = SettingsCard(layout, label);
            foreach (var section in sections)
            {
                var heading = Ui.Text(section.Title, 15, strong: true);
                heading.Margin = new Thickness(0, 10, 0, 3);
                card.Children.Add(heading);
                card.Children.Add(Ui.Text(section.Detail));
                var references = new StackPanel();
                foreach (var reference in section.References)
                {
                    var clip = app.Clips.FirstOrDefault(item => item.Id == reference.ClipId && item.TrashedAt is null);
                    var current = clip is null ? null : AiTasks.Project(clip, app.Settings.Ai);
                    bool available = current is not null && (recap.Versions?.TryGetValue(reference.ClipId, out var version) != true ||
                        version == current.Version) && new[] { current.Text, current.Title, current.Note }
                        .Any(value => value.Contains(reference.Quote, StringComparison.Ordinal));
                    var action = Ui.Button(available ? "View source clip" : "Source no longer matches", () =>
                    {
                        if (clip is null) return;
                        Select(SettingsPage.Library);
                        library.Reveal(clip);
                    });
                    action.IsEnabled = available;
                    references.Children.Add(Ui.Text(reference.Quote, 12, "Muted"));
                    references.Children.Add(action);
                }
                var list = new Expander { Header = Labels.Get("Source excerpts"), Content = references, Margin = new Thickness(0, 4, 0, 2) };
                list.SetResourceReference(ForegroundProperty, "Muted");
                card.Children.Add(list);
            }
        }
    }
}
