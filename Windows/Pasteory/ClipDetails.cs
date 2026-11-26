using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed class ClipDetails : DockPanel
{
    private readonly App app;
    private readonly Clip? clip;
    private readonly StackPanel cards = new() { Margin = new Thickness(13, 13, 13, 4) };

    internal ClipDetails(App app, Clip? clip, Func<bool> expand)
    {
        this.app = app;
        this.clip = clip;
        var heading = Header(clip);
        SetDock(heading, Dock.Top);
        Children.Add(heading);
        Children.Add(new ScrollViewer { Content = cards, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        if (clip is null)
        {
            Card("Preview").Children.Add(Ui.Text(Labels.Get("Select a clip to preview it."), 12, "Muted"));
            return;
        }
        Preview(expand);
        if (clip.Kind != ClipKind.Aggregate) Sources();
        if (clip.TrashedAt is null)
        {
            Edit();
            Groups();
            if (clip.Kind == ClipKind.Link) Link();
        }
        else
        {
            var body = Card("Trash");
            body.Children.Add(Ui.Text(Labels.Format("Moved to Trash on {0}", clip.TrashedAt.Value.ToLocalTime().ToString("g")), 12, "Muted"));
            body.Children.Add(Ui.Button("Restore", () => app.RestoreClip(clip), "PrimaryButton"));
        }
        Metadata();
    }

    private static Border Header(Clip? clip)
    {
        var layout = new DockPanel();
        if (clip is not null)
        {
            var kind = new Border
            {
                Width = 33, Height = 33, CornerRadius = new CornerRadius(9), HorizontalAlignment = HorizontalAlignment.Right,
                Child = Ui.Icon(Glyph.ForKind(clip.Kind), 15, "AccentInk")
            }.WithBackground("AccentTint");
            ((TextBlock)kind.Child).HorizontalAlignment = HorizontalAlignment.Center;
            ((TextBlock)kind.Child).VerticalAlignment = VerticalAlignment.Center;
            SetDock(kind, Dock.Right);
            layout.Children.Add(kind);
        }
        var headings = new StackPanel();
        headings.Children.Add(Ui.Text(Labels.Get("Clip details"), 17, strong: true));
        if (clip is not null) headings.Children.Add(Ui.Text(Labels.Get(clip.Kind.ToString()), 10, "Muted"));
        layout.Children.Add(headings);
        var border = new Border { Padding = new Thickness(15, 14, 15, 12), Child = layout, BorderThickness = new Thickness(0, 0, 0, 1) };
        border.SetResourceReference(Border.BorderBrushProperty, "Line");
        return border;
    }

    private StackPanel Card(string section)
    {
        var body = new StackPanel();
        var caption = Ui.SectionTitle(section);
        caption.Margin = new Thickness(0, 0, 0, 8);
        body.Children.Add(caption);
        cards.Children.Add(Ui.Section(body));
        return body;
    }

    private void Preview(Func<bool> expand)
    {
        var body = Card("Preview");
        body.MinHeight = 185;
        if (clip!.Kind == ClipKind.Aggregate)
        {
            body.Children.Add(Ui.Text(clip.Title.Length > 0 ? clip.Title : Labels.Get("Aggregation"), 15, strong: true));
            body.Children.Add(Ui.Text(Labels.Format("{0} items", clip.Members.Length), 12, "Muted"));
            if (clip.Note.Length > 0) body.Children.Add(Ui.Text(clip.Note));
            if (clip.TrashedAt is null) body.Children.Add(Ui.Button("Expand aggregation", () => expand()));
            return;
        }
        if (clip.HasImage)
        {
            try
            {
                var image = ClipboardFormats.DecodePreview(app.ReadImage(clip));
                body.Children.Add(new Image { Source = image, MaxHeight = 205, Stretch = Stretch.Uniform,
                    HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 7) });
                int width = clip.ImageWidth > 0 ? clip.ImageWidth : image.PixelWidth;
                int height = clip.ImageHeight > 0 ? clip.ImageHeight : image.PixelHeight;
                body.Children.Add(Ui.Text($"PNG · {width} × {height} · {ClipCard.Bytes(clip.ImageSize)}", 11, "Muted"));
                if (clip.RecognizedText is { Length: > 0 } recognized) body.Children.Add(ContentPreview.TextBoxFor(recognized));
            }
            catch (Exception error) when (App.IsLocalError(error) || error is NotSupportedException or ArgumentException or FileFormatException)
            { body.Children.Add(Ui.Text(Labels.Get("The saved image could not be opened."), 12, "Muted")); }
        }
        foreach (var file in clip.Files)
        {
            var title = Ui.WithIcon(Glyph.Files, Path.GetFileName(file));
            var path = Ui.Text(file, 11, "Muted");
            path.Margin = new Thickness(24, 1, 0, 6);
            body.Children.Add(title);
            body.Children.Add(path);
            if (!file.StartsWith(@"\\", StringComparison.Ordinal) && !File.Exists(file))
                body.Children.Add(Ui.Text(Labels.Get("File unavailable"), 11, "Danger"));
        }
        if (clip.Kind == ClipKind.Color && TextTools.TryColor(clip.Text, out var color))
            body.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(color.A, color.R, color.G, color.B)), Height = 56,
                CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 0, 0, 8)
            });
        if (clip.Text is { } content)
        {
            var field = ContentPreview.TextBoxFor(content, clip.Kind == ClipKind.Code);
            field.MinHeight = clip.HasImage ? 48 : 98;
            field.MaxHeight = 210;
            field.BorderThickness = new Thickness(0);
            field.Padding = new Thickness(6);
            body.Children.Add(field);
            if (clip.IsManual && clip.TrashedAt is null)
            {
                var edit = Ui.Button("Edit original text", () =>
                    LibraryEditors.ShowModal(Window.GetWindow(this), "Edit original text", close =>
                    {
                        var form = new StackPanel();
                        var source = Ui.Field("Text", clip.Text ?? "", 1024 * 1024);
                        source.MinHeight = 165;
                        source.AcceptsReturn = true;
                        source.TextWrapping = TextWrapping.Wrap;
                        source.VerticalContentAlignment = VerticalAlignment.Top;
                        Ui.AddField(form, "Text", source);
                        return LibraryEditors.Wrap("Edit original text", form, source,
                            () => app.EditManualText(clip.Id, source.Text), close) with { Submit = null };
                    }));
                edit.HorizontalAlignment = HorizontalAlignment.Right;
                edit.Margin = new Thickness(0, 6, 0, 0);
                body.Children.Add(edit);
            }
        }
        else if (!clip.HasImage && clip.Files.Length == 0)
            body.Children.Add(Ui.Text(Labels.Get("Rich text")));
    }

    private void Sources()
    {
        var body = Card("Capture source");
        var events = clip!.Captures.Length > 0 ? clip.Captures :
            clip.CopyCount > 0 ? [new CaptureEvent(clip.CapturedAt, clip.Source)] : [];
        foreach (var capture in events.Take(1)) AddCapture(body, capture);
        if (events.Length > 1)
        {
            var older = new StackPanel { Margin = new Thickness(0, 6, 0, 0) };
            var expander = new Expander { Header = Labels.Format("{0} earlier copies", events.Length - 1), Margin = new Thickness(0, 6, 0, 0) };
            expander.SetResourceReference(Control.ForegroundProperty, "Muted");
            foreach (var item in events.Skip(1)) AddCapture(older, item);
            expander.Content = older;
            body.Children.Add(expander);
        }
        else if (events.Length == 0)
            body.Children.Add(Ui.Text(Labels.Get("Created in Pasteory"), 11, "Muted"));
    }

    private static void AddCapture(Panel panel, CaptureEvent capture)
    {
        panel.Children.Add(Ui.Text(Labels.Format("App   {0}", capture.Source), 11, "Muted"));
        panel.Children.Add(Ui.Text(Labels.Format("Captured   {0}", capture.CapturedAt.LocalDateTime.ToString("g")), 11, "Muted"));
        if (!string.IsNullOrWhiteSpace(capture.Context)) panel.Children.Add(Ui.Text(capture.Context, 11));
        if (!string.IsNullOrWhiteSpace(capture.Url)) panel.Children.Add(Ui.Text(capture.Url, 11, "LinkInk"));
        if (capture.Details is { } details)
            foreach (string key in new[] { "repository", "branch", "projectId", "mergeRequestId" })
                if (details.TryGetValue(key, out var value)) panel.Children.Add(Ui.Text(value, 11, "Muted"));
    }

    private void Edit()
    {
        var body = Card("Edit");
        var title = Ui.Field("Title", clip!.Title, 160);
        var note = Ui.Field("Note", clip.Note, 16000);
        note.AcceptsReturn = true;
        note.TextWrapping = TextWrapping.Wrap;
        note.MinHeight = 72;
        note.MaxHeight = 150;
        note.VerticalContentAlignment = VerticalAlignment.Top;
        note.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        Ui.AddField(body, "Title", title);
        Ui.AddField(body, "Note", note);
        var save = Ui.Button("Save", () => app.EditClip(clip.Id, item => item with { Title = title.Text.Trim(), Note = note.Text.Trim() }),
            "PrimaryButton");
        save.Margin = new Thickness(0, 6, 0, 0);
        save.HorizontalAlignment = HorizontalAlignment.Right;
        save.Visibility = Visibility.Collapsed;
        title.TextChanged += (_, _) => save.Visibility = Visibility.Visible;
        note.TextChanged += (_, _) => save.Visibility = Visibility.Visible;
        body.Children.Add(save);

        var priorities = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var priority in Enum.GetValues<ClipPriority>())
        {
            var button = Ui.Button(priority.ToString(), () => app.UpdateClip(clip.Id, item => item with { Priority = priority }),
                clip.Priority == priority ? "PrimaryButton" : null);
            button.Margin = new Thickness(0, 0, 3, 0);
            button.Padding = new Thickness(10, 3, 10, 3);
            button.MinHeight = 23;
            priorities.Children.Add(button);
        }
        Ui.AddField(body, "Priority", priorities);

        var flags = new UniformGrid { Columns = 2, Margin = new Thickness(0, 11, 0, 0) };
        var favorite = Ui.Button(clip.Favorite ? "Remove favorite" : "Favorite", () => app.ToggleFavorite(clip));
        favorite.Margin = new Thickness(0, 0, 4, 0);
        var pinned = Ui.Button(clip.Pinned ? "Unpin" : "Pin", () => app.TogglePin(clip));
        pinned.Margin = new Thickness(4, 0, 0, 0);
        foreach (var button in new[] { favorite, pinned })
        {
            button.SetResourceReference(Control.BackgroundProperty, "AccentTint");
            button.SetResourceReference(Control.ForegroundProperty, "AccentInk");
            flags.Children.Add(button);
        }
        body.Children.Add(flags);
    }

    private void Groups()
    {
        var groups = app.Collections.Where(group => !group.IsSmart && !group.IsAi).ToArray();
        if (groups.Length == 0) return;
        var body = Card("Groups");
        foreach (var group in groups)
        {
            var check = new CheckBox { Content = group.Name, IsChecked = clip!.CollectionIds.Contains(group.Id) };
            check.Click += (_, _) => app.UpdateClip(clip.Id, current => current with
            {
                Group = "", CollectionIds = check.IsChecked == true ? [.. current.CollectionIds.Distinct(), group.Id] :
                    current.CollectionIds.Where(id => id != group.Id).ToArray()
            });
            body.Children.Add(check);
        }
    }

    private void Link()
    {
        var body = Card("Link resolution");
        var details = clip!.LinkDetails;
        if (details is not null)
        {
            if (details.Title is { Length: > 0 }) body.Children.Add(Ui.Text(details.Title, 13, strong: true));
            body.Children.Add(Ui.Text(Labels.Get(details.Status), 11, "Muted"));
            if (details.Quality is { } quality) body.Children.Add(Ui.Text(Labels.Get(quality), 11, "Muted"));
            body.Children.Add(Ui.Text($"{details.Source} · {details.AttemptedAt.ToLocalTime():g}", 11, "Muted"));
        }
        else body.Children.Add(Ui.Text(Labels.Get("Not resolved"), 11, "Muted"));
        var retry = Ui.Button(details is null ? "Resolve title" : "Retry resolution", () => _ = app.ResolveLinkAsync(clip));
        retry.HorizontalAlignment = HorizontalAlignment.Right;
        retry.Margin = new Thickness(0, 8, 0, 0);
        body.Children.Add(retry);
    }

    private void Metadata()
    {
        var body = Card("Metadata");
        if (clip!.Kind == ClipKind.Aggregate)
            body.Children.Add(Ui.Text(clip.AggregationOrigin ?? Labels.Get("Manual"), 11, "Muted"));
        else
        {
            body.Children.Add(Ui.Text(Labels.Format("Copy ×{0} · Paste ×{1}", clip.CopyCount, clip.PasteCount), 11, "Muted"));
            if (clip.LastPastedAt is { } pasted) body.Children.Add(Ui.Text(Labels.Format("Last pasted {0}", pasted.ToLocalTime().ToString("g")), 11, "Muted"));
            if (app.Settings.Ai.Enabled && app.ClipRank(clip) is { } activity)
            {
                var policy = app.Settings.Ai.Activity;
                DateTimeOffset now = DateTimeOffset.Now;
                body.Children.Add(Ui.Text(Labels.Format("Activity {0:F0}% · Top {1}%", activity.Score, activity.Percentile), 12, "AccentInk", true));
                body.Children.Add(Ui.Text(Labels.Get(ClipActivity.Stage(clip, policy, now)), 11, "Muted"));
                if (clip.ArchivedAt is null && !clip.Pinned && !clip.Favorite)
                {
                    double days = (now - ClipActivity.LastUsed(clip)).TotalDays;
                    if (days >= policy.ArchiveDays) body.Children.Add(Ui.Text(Labels.Get("Eligible for archive"), 11, "Muted"));
                    else if (days >= policy.CompressDays) body.Children.Add(Ui.Text(Labels.Get("Eligible for compression"), 11, "Muted"));
                }
            }
        }
    }
}
