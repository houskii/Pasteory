using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed partial class SettingsWindow
{
    private static readonly (ClipKind Kind, Color Color)[] StatColors =
    [
        (ClipKind.Text, Color.FromRgb(78, 99, 244)), (ClipKind.Image, Color.FromRgb(27, 166, 187)),
        (ClipKind.Link, Color.FromRgb(44, 138, 231)), (ClipKind.Color, Color.FromRgb(221, 123, 40)),
        (ClipKind.Code, Color.FromRgb(139, 65, 229)), (ClipKind.Files, Color.FromRgb(47, 167, 115)),
        (ClipKind.Mixed, Color.FromRgb(202, 79, 153))
    ];

    private void BuildStorage(Panel layout)
    {
        var stats = SettingsCard(layout, "Content statistics");
        var periods = Picker("Content statistics", ["1 day", "7 days", "30 days", "Total"], "7 days");
        var graph = new StackPanel { Margin = new Thickness(0, 6, 0, 4) };
        stats.Children.Add(Row("Range", periods));
        stats.Children.Add(graph);
        periods.SelectionChanged += (_, _) => ShowContentStats(graph, (string?)periods.SelectedValue ?? "7 days");
        ShowContentStats(graph, "7 days");

        var storage = SettingsCard(layout, "Local storage");
        var sizes = new StackPanel { Margin = new Thickness(0, 5, 0, 0) };
        int calculation = 0;
        async Task Calculate()
        {
            int request = ++calculation;
            sizes.Children.Clear();
            sizes.Children.Add(Ui.Text(Labels.Get("Calculating…"), 11, "Muted"));
            try
            {
                var (totals, volume) = await Task.Run(() => DiskTotals(app.DataDirectory));
                if (app.Exiting || request != calculation) return;
                sizes.Children.Clear();
                foreach (var (label, bytes) in totals)
                    sizes.Children.Add(Row(label, Ui.Text(ClipCard.Bytes(bytes), 11, "Muted")));
                long total = totals.Sum(item => item.Bytes);
                string estimate = volume is { } capacity
                    ? Labels.Format("{0:P3} of the data volume", (double)total / capacity) : "";
                sizes.Children.Add(Row("Total", Ui.Text(ClipCard.Bytes(total), 13, strong: true), estimate.Length > 0 ? estimate : null));
            }
            catch (Exception error) when (App.IsLocalError(error))
            {
                if (request != calculation) return;
                sizes.Children.Clear();
                sizes.Children.Add(Ui.Text(error.Message, 11, "Danger"));
            }
        }
        storage.Children.Add(Row("Data folder", Ui.Button("Recalculate", async () => await Calculate()), app.DataDirectory));
        storage.Children.Add(sizes);
        _ = Calculate();
        BuildWebCache(layout, Calculate);

        var archiveCount = Ui.Text("", 11, "Muted");
        void RefreshArchiveCount() => archiveCount.Text = app.Clips.Count(clip => clip.ArchivedAt is not null && clip.TrashedAt is null).ToString();
        BuildHistoryCleanup(layout, async () =>
        {
            RefreshArchiveCount();
            ShowContentStats(graph, (string?)periods.SelectedValue ?? "7 days");
            await Calculate();
        });

        var archive = SettingsCard(layout, "Automatic archive");
        RefreshArchiveCount();
        var daysOptions = new Dictionary<string, int> { ["Off"] = 0, ["7 days"] = 7, ["30 days"] = 30, ["90 days"] = 90, ["1 year"] = 365 };
        var days = Picker("Archive after", daysOptions.Keys,
            daysOptions.FirstOrDefault(entry => entry.Value == app.Settings.ArchiveAfterDays).Key ?? "30 days");
        days.SelectionChanged += (_, _) =>
        {
            if (days.SelectedValue is string option) app.SaveSettings(app.Settings with { ArchiveAfterDays = daysOptions[option] });
        };
        archive.Children.Add(Row("Archive after", days));
        var archiveActions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        archiveCount.VerticalAlignment = VerticalAlignment.Center;
        archiveCount.Margin = new Thickness(0, 0, 8, 0);
        archiveActions.Children.Add(archiveCount);
        archiveActions.Children.Add(Ui.Button("Run archive now", async () =>
        {
            app.RunArchiveNow();
            RefreshArchiveCount();
            ShowContentStats(graph, (string?)periods.SelectedValue ?? "7 days");
            await Calculate();
        }));
        archive.Children.Add(Row("Archived clips", archiveActions, "Favorites, pins, and regular groups stay available. The active history target is 10,000 items."));

        var backup = SettingsCard(layout, "Backup");
        var controls = new WrapPanel();
        var export = Ui.Button("Export backup…", () =>
        {
            var dialog = new SaveFileDialog
            {
                Title = Labels.Get("Export backup…"), FileName = $"Pasteory-{DateTime.Now:yyyy-MM-dd}.zip",
                Filter = Labels.Get("Windows backup") + " (*.zip)|*.zip", AddExtension = true
            };
            if (dialog.ShowDialog(this) == true) app.ExportBackup(dialog.FileName);
        });
        export.Margin = new Thickness(0, 0, 6, 0);
        controls.Children.Add(export);
        controls.Children.Add(Ui.Button("Import backup…", () =>
        {
            var dialog = new OpenFileDialog { Title = Labels.Get("Import backup…"), Filter = Labels.Get("Windows backup") + " (*.zip)|*.zip" };
            if (dialog.ShowDialog(this) == true)
            {
                app.ImportBackup(dialog.FileName);
                Select(SettingsPage.Storage, rebuild: true);
            }
        }));
        backup.Children.Add(Row("Windows backup", controls));
        backup.Children.Add(Row("Mac backup", Ui.Button("Import Mac backup…", () =>
        {
            var dialog = new OpenFolderDialog { Title = Labels.Get("Import Mac backup…") };
            if (dialog.ShowDialog(this) == true)
            {
                app.ImportMacBackup(dialog.FolderName);
                Select(SettingsPage.Storage, rebuild: true);
            }
        })));
    }

    private void BuildWebCache(Panel layout, Func<Task> refreshStorage)
    {
        var cache = SettingsCard(layout, "Web cache");
        Switch(cache, "Automatically clear web cache", app.Settings.AutomaticWebCacheCleanup,
            (settings, enabled) => settings with { AutomaticWebCacheCleanup = enabled },
            "Pasteory clears its web cache after browsing and link resolution finish, once it reaches 100 MB or a day has passed.");
        var lastCleared = Ui.Text("", 11, "Muted");
        cache.Children.Add(Row("Last cache cleanup", lastCleared));
        var clear = Ui.Button("Clear web cache", app.RequestWebCacheCleanup);
        clear.HorizontalAlignment = HorizontalAlignment.Right;
        cache.Children.Add(clear);
        DateTimeOffset? observed = app.Settings.LastWebCacheCleanup;
        void Update()
        {
            var date = app.Settings.LastWebCacheCleanup;
            lastCleared.Text = date?.LocalDateTime.ToString("g") ?? Labels.Get("Never cleared");
            clear.Content = Labels.Get(app.IsClearingWebCache ? "Clearing web cache…" :
                app.WebCacheWaiting ? "Waiting for web activity to finish…" : "Clear web cache");
            clear.IsEnabled = !app.IsClearingWebCache && !app.WebCacheWaiting;
            if (date != observed)
            {
                observed = date;
                _ = refreshStorage();
            }
        }
        cache.Loaded += (_, _) => { app.WebCacheChanged += Update; Update(); };
        cache.Unloaded += (_, _) => app.WebCacheChanged -= Update;
        Update();
    }

    private void BuildHistoryCleanup(Panel layout, Func<Task> onChanged)
    {
        var cleanup = SettingsCard(layout, "Clean history");
        var criteria = new UniformGrid { Columns = 2, Margin = new Thickness(0, 8, 0, 0) };
        var days = Ui.Field("Last used before (days ago)", "30", 5);
        var size = Ui.Field("Item size greater than (MB)", "1", 18);
        var ageField = new StackPanel { Margin = new Thickness(0, 0, 7, 0) };
        var sizeField = new StackPanel { Margin = new Thickness(7, 0, 0, 0) };
        Ui.AddField(ageField, "Last used before (days ago)", days);
        Ui.AddField(sizeField, "Item size greater than (MB)", size);
        criteria.Children.Add(ageField);
        criteria.Children.Add(sizeField);
        cleanup.Children.Add(criteria);
        cleanup.Children.Add(Ui.Text(Labels.Get("Both conditions must match. Favorites, pins, grouped clips, and aggregation members are protected."), 11, "Muted"));

        (DateTimeOffset Cutoff, long Bytes)? SelectedCriteria()
        {
            if (!int.TryParse(days.Text, out int age) || age is < 0 or > 36_500 ||
                !decimal.TryParse(size.Text.Trim(), NumberStyles.AllowDecimalPoint, CultureInfo.CurrentCulture, out decimal megabytes) ||
                megabytes is < 0 or > 1_000_000) return null;
            return (new DateTimeOffset(DateTime.Now.AddDays(-age)), (long)(megabytes * 1_000_000m));
        }

        var preview = Ui.Button("Preview cleanup…", async () =>
        {
            if (SelectedCriteria() is not { } selection) return;
            criteria.IsEnabled = false;
            try
            {
                var planned = await app.PreviewCleanupAsync(selection.Cutoff, selection.Bytes);
                if (app.Exiting || !criteria.IsLoaded || !ShowCleanupPreview(planned)) return;
                if (app.CleanHistory(planned) is not { } result) return;
                string status = Labels.Format("Deleted {0} history items and freed {1}.", result.DeletedCount, ClipCard.Bytes(result.ReclaimedBytes));
                if (result.FailedFiles > 0) status += " " + Labels.Format("{0} stored files could not be removed.", result.FailedFiles);
                SetStatus(status);
                await onChanged();
            }
            catch (OperationCanceledException) when (app.Exiting) { }
            catch (Exception error) when (App.IsLocalError(error)) { SetStatus(Labels.Get(error.Message)); }
            finally { criteria.IsEnabled = true; }
        }, "PrimaryButton");
        preview.HorizontalAlignment = HorizontalAlignment.Right;
        preview.Margin = new Thickness(0, 8, 0, 0);
        void UpdateEnabled() => preview.IsEnabled = criteria.IsEnabled && SelectedCriteria() is not null;
        criteria.IsEnabledChanged += (_, _) => UpdateEnabled();
        days.TextChanged += (_, _) => UpdateEnabled();
        size.TextChanged += (_, _) => UpdateEnabled();
        cleanup.Children.Add(preview);
    }

    private bool ShowCleanupPreview(HistoryCleanupPreview preview)
    {
        var dialog = new Window
        {
            Title = Labels.Get("History cleanup preview"), Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Width = 525, Height = preview.Entries.Count == 0 ? 190 : 460, MinWidth = 380, MinHeight = 180, ShowInTaskbar = false
        };
        var frame = new DockPanel { Margin = new Thickness(18) };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(actions, Dock.Bottom);
        var cancel = Ui.Button(preview.Entries.Count > 0 ? "Cancel" : "Close", dialog.Close);
        cancel.IsCancel = true;
        actions.Children.Add(cancel);
        if (preview.Entries.Count > 0)
        {
            var delete = Ui.Button(Labels.Format("Permanently delete {0} items", preview.Entries.Count), () => dialog.DialogResult = true);
            delete.Margin = new Thickness(7, 0, 0, 0);
            delete.SetResourceReference(Control.ForegroundProperty, "Danger");
            actions.Children.Add(delete);
        }
        frame.Children.Add(actions);
        var heading = new StackPanel { Margin = new Thickness(0, 0, 0, 9) };
        DockPanel.SetDock(heading, Dock.Top);
        heading.Children.Add(Ui.Text(Labels.Get("History cleanup preview"), 18, strong: true));
        heading.Children.Add(Ui.Text(preview.Entries.Count == 0 ? Labels.Get("No history meets these conditions.") :
            Labels.Format("{0} items match. Estimated attachment and archive space: {1}.",
                preview.Entries.Count, ClipCard.Bytes(preview.ReclaimableBytes)), 12, "Muted"));
        frame.Children.Add(heading);
        if (preview.Entries.Count > 0)
        {
            var message = Ui.Text(Labels.Get("This permanently deletes the listed history and its unshared attachments and archives."), 11, "Muted");
            message.Margin = new Thickness(0, 8, 0, 8);
            DockPanel.SetDock(message, Dock.Bottom);
            frame.Children.Add(message);
            var columns = new GridView();
            columns.Columns.Add(new GridViewColumn { Header = Labels.Get("Content"), DisplayMemberBinding = new Binding("Title"), Width = 220 });
            columns.Columns.Add(new GridViewColumn { Header = Labels.Get("Last used"), DisplayMemberBinding = new Binding("Used"), Width = 130 });
            columns.Columns.Add(new GridViewColumn { Header = Labels.Get("Size"), DisplayMemberBinding = new Binding("Size"), Width = 95 });
            var items = new ListView
            {
                View = columns, ItemsSource = preview.Entries.Select(entry =>
                    new
                    {
                        Title = entry.Title.Length > 0 ? entry.Title : Labels.Get(entry.Kind.ToString()),
                        Used = entry.LastUsedAt.LocalDateTime.ToString("g"), Size = ClipCard.Bytes(entry.Bytes)
                    })
            };
            VirtualizingPanel.SetVirtualizationMode(items, VirtualizationMode.Recycling);
            frame.Children.Add(items);
        }
        else frame.Children.Add(new Grid());
        dialog.Content = frame;
        dialog.Loaded += (_, _) => Keyboard.Focus(cancel);
        return dialog.ShowDialog() == true;
    }

    private void ShowContentStats(StackPanel graph, string period)
    {
        graph.Children.Clear();
        int days = period == "1 day" ? 1 : period == "30 days" ? 30 : 7;
        var today = DateTime.Now.Date;
        var clips = app.Clips.Where(clip => clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate).ToArray();
        var daily = clips.ToLookup(clip => clip.CapturedAt.LocalDateTime.Date);
        var rows = period == "Total" ? new[] { (Label: Labels.Get("Total"), Clips: clips) }
            : Enumerable.Range(0, days).Select(day => (Label: today.AddDays(-day).ToString("MM-dd"),
                Clips: daily[today.AddDays(-day)].ToArray())).ToArray();
        int max = Math.Max(1, rows.Max(row => row.Clips.Length));
        var bars = new StackPanel();
        foreach (var (label, items) in rows)
        {
            var row = new Grid { Height = 21 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(66) });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(38) });
            row.Children.Add(Ui.Text(label, 11, "Muted"));
            var bar = new Grid { Height = 10, VerticalAlignment = VerticalAlignment.Center };
            foreach (var (kind, color) in StatColors)
            {
                int count = items.Count(item => item.Kind == kind);
                if (count == 0) continue;
                bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(count, GridUnitType.Star) });
                var segment = new Border { Background = new SolidColorBrush(color), ToolTip = $"{Labels.Get(kind.ToString())} · {count}" };
                Grid.SetColumn(segment, bar.ColumnDefinitions.Count - 1);
                bar.Children.Add(segment);
            }
            if (items.Length < max)
            {
                bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(max - items.Length, GridUnitType.Star) });
                var remainder = new Border().WithBackground("SoftSurface");
                Grid.SetColumn(remainder, bar.ColumnDefinitions.Count - 1);
                bar.Children.Add(remainder);
            }
            Grid.SetColumn(bar, 1);
            row.Children.Add(bar);
            var number = Ui.Text(items.Length.ToString(), 11, "Muted");
            number.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(number, 2);
            row.Children.Add(number);
            bars.Children.Add(row);
        }
        graph.Children.Add(new ScrollViewer { Content = bars, MaxHeight = 147, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        var legend = new WrapPanel { Margin = new Thickness(0, 9, 0, 0) };
        var visible = rows.SelectMany(row => row.Clips).ToArray();
        foreach (var (kind, color) in StatColors)
        {
            int count = visible.Count(clip => clip.Kind == kind);
            var key = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 13, 5) };
            key.Children.Add(new Border { Background = new SolidColorBrush(color), Width = 8, Height = 8,
                CornerRadius = new CornerRadius(2), Margin = new Thickness(0, 0, 5, 0) });
            var ratio = visible.Length == 0 ? 0 : (double)count / visible.Length;
            key.Children.Add(Ui.Text($"{Labels.Get(kind.ToString())}  {count}  {ratio:P0}", 11, "Muted"));
            legend.Children.Add(key);
        }
        graph.Children.Add(legend);
    }

    private static ((string Label, long Bytes)[] Categories, long? Volume) DiskTotals(string root)
    {
        var space = new Dictionary<string, long>
        {
            ["Database"] = 0, ["Images & attachments"] = 0, ["Archive"] = 0, ["Backup"] = 0,
            ["File command logs"] = 0, ["AI task history"] = 0, ["WebView2 site data"] = 0, ["Other"] = 0
        };
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint
        };
        foreach (string path in Directory.EnumerateFiles(root, "*", options))
        {
            string[] location = Path.GetRelativePath(root, path).Split(Path.DirectorySeparatorChar, 2);
            string category = location[0].ToLowerInvariant() switch
            {
                HistoryStore.CatalogFileName or HistoryStore.CatalogFileName + "-wal" or HistoryStore.CatalogFileName + "-shm" => "Database",
                "history.json" or "backups" => "Backup", "images" => "Images & attachments", "archives" => "Archive",
                "logs" => "File command logs", "aitasks" => "AI task history", "web-sessions" => "WebView2 site data", _ => "Other"
            };
            space[category] += LocalStorage.AllocatedBytes(path);
        }
        return (space.Select(category => (category.Key, category.Value)).ToArray(), LocalStorage.VolumeCapacity(root));
    }
}
