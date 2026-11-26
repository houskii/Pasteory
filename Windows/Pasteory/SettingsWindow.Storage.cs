using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
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
        async Task Calculate()
        {
            sizes.Children.Clear();
            sizes.Children.Add(Ui.Text(Labels.Get("Calculating…"), 11, "Muted"));
            try
            {
                var totals = await Task.Run(() => DiskTotals(app.DataDirectory));
                if (app.Exiting) return;
                sizes.Children.Clear();
                foreach (var (label, bytes) in totals)
                    sizes.Children.Add(Row(label, Ui.Text(ClipCard.Bytes(bytes), 11, "Muted")));
                sizes.Children.Add(Row("Total", Ui.Text(ClipCard.Bytes(totals.Sum(item => item.Bytes)), 13, strong: true)));
            }
            catch (Exception error) when (App.IsLocalError(error))
            { sizes.Children.Clear(); sizes.Children.Add(Ui.Text(error.Message, 11, "Danger")); }
        }
        storage.Children.Add(Row("Data folder", Ui.Button("Recalculate", async () => await Calculate()), app.DataDirectory));
        storage.Children.Add(sizes);
        _ = Calculate();

        var archive = SettingsCard(layout, "Automatic archive");
        var daysOptions = new Dictionary<string, int> { ["Off"] = 0, ["7 days"] = 7, ["30 days"] = 30, ["90 days"] = 90, ["1 year"] = 365 };
        var days = Picker("Archive after", daysOptions.Keys,
            daysOptions.FirstOrDefault(entry => entry.Value == app.Settings.ArchiveAfterDays).Key ?? "30 days");
        days.SelectionChanged += (_, _) =>
        {
            if (days.SelectedValue is string option) app.SaveSettings(app.Settings with { ArchiveAfterDays = daysOptions[option] });
        };
        archive.Children.Add(Row("Archive after", days));
        archive.Children.Add(Row("Archived clips", Ui.Button("Run archive now", async () =>
        {
            app.RunArchiveNow();
            ShowContentStats(graph, (string?)periods.SelectedValue ?? "7 days");
            await Calculate();
        }), app.Clips.Count(clip => clip.ArchivedAt is not null && clip.TrashedAt is null).ToString()));

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

    private void ShowContentStats(StackPanel graph, string period)
    {
        graph.Children.Clear();
        int days = period == "1 day" ? 1 : period == "30 days" ? 30 : 7;
        var today = DateTime.Now.Date;
        var clips = app.Clips.Where(clip => clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate).ToArray();
        var rows = period == "Total" ? new[] { (Label: Labels.Get("Total"), Clips: clips) }
            : Enumerable.Range(0, days).Select(day => (Label: today.AddDays(-day).ToString("MM-dd"),
                Clips: clips.Where(clip => clip.CapturedAt.LocalDateTime.Date == today.AddDays(-day)).ToArray())).ToArray();
        int max = Math.Max(1, rows.Max(row => row.Clips.Length));
        var bars = new StackPanel();
        foreach (var (label, items) in rows)
        {
            var row = new Grid { Margin = new Thickness(0, 2, 0, 2) };
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

    private static (string Label, long Bytes)[] DiskTotals(string root)
    {
        long Size(string subdirectory)
        {
            string folder = Path.Combine(root, subdirectory);
            return Directory.Exists(folder) ? Directory.EnumerateFiles(folder, "*", new EnumerationOptions
            {
                RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint
            }).Sum(file => new FileInfo(file).Exists ? new FileInfo(file).Length : 0) : 0;
        }
        long FileSize(string name) => new FileInfo(Path.Combine(root, name)) is { Exists: true } file ? file.Length : 0;
        long database = FileSize(HistoryStore.CatalogFileName) + FileSize(HistoryStore.CatalogFileName + "-wal") +
            FileSize(HistoryStore.CatalogFileName + "-shm");
        return [("Database", database), ("Images & attachments", Size("images")),
            ("Archive", Size("archives")), ("AI task history", Size("AITasks")),
            ("File command logs", Size("logs")), ("Other", Size("cache") + FileSize("history.json"))];
    }
}
