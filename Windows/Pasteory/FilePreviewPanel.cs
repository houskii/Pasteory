using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Pasteory.Core;

namespace Pasteory.Windows;

internal readonly record struct FileReference(string Path, string Name, string Folder, long? Size = null, bool Missing = false)
{
    internal static FileReference FromPath(string reference)
    {
        string path = reference;
        if (reference.StartsWith("file://", StringComparison.OrdinalIgnoreCase) &&
            Uri.TryCreate(reference, UriKind.Absolute, out var url) && url.IsFile)
            path = url.LocalPath;

        string trimmed = path.TrimEnd('/', '\\');
        int separator = Math.Max(trimmed.LastIndexOf('/'), trimmed.LastIndexOf('\\'));
        string name = trimmed[(separator + 1)..];
        string folder = separator <= 0 || (separator == 2 && trimmed[1] == ':')
            ? trimmed[..(separator + 1)] : trimmed[..separator];
        return new(path, name.Length > 0 ? name : reference, folder);
    }

    internal FileReference Inspect()
    {
        if (!System.IO.Path.IsPathFullyQualified(Path)) return this with { Missing = true };
        // A clipboard reference can point to a network share. Resolve those when the user opens the files.
        if (Path.StartsWith(@"\\", StringComparison.Ordinal) || Path.StartsWith("//", StringComparison.Ordinal)) return this;
        try
        {
            var attributes = File.GetAttributes(Path);
            if ((attributes & (FileAttributes.Directory | FileAttributes.Offline)) != 0) return this;
            return this with { Size = new FileInfo(Path).Length };
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException or ArgumentException)
        {
            return this with { Missing = true };
        }
        catch (Exception error) when (App.IsLocalError(error)) { return this; }
    }

    internal string Summary(bool compact)
    {
        string folder = compact && Folder.Length > 35 ? Folder[..14] + "…" + Folder[^19..] : Folder;
        string location = Size is { } size ? string.Join(" · ", new[] { folder, ClipCard.Bytes(size) }.Where(value => value.Length > 0)) : folder;
        return Missing ? string.Join(" · ", new[] { Labels.Get("File deleted"), location }.Where(value => value.Length > 0)) : location;
    }
}

public sealed class FilePreviewPanel : ContentControl
{
    private Window? owner;
    private FileReference[] displayed = [];
    private object? presented;
    private int refreshId;

    public FilePreviewPanel()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        Loaded += (_, _) =>
        {
            owner = Window.GetWindow(this);
            if (owner is not null) owner.Activated += OnActivated;
            Reload();
        };
        Unloaded += (_, _) =>
        {
            refreshId++;
            if (owner is not null) owner.Activated -= OnActivated;
            owner = null;
        };
        DataContextChanged += (_, _) => Reload();
        IsVisibleChanged += (_, _) => { if (IsVisible && IsLoaded) Reload(); };
    }

    private void OnActivated(object? sender, EventArgs e)
    {
        if (IsVisible) Reload();
    }

    private async void Reload()
    {
        int request = ++refreshId;
        var card = DataContext as ClipCard;
        var clip = DataContext as Clip ?? (card?.IsFile == true ? card.Clip : null);
        if (clip is null || clip.Files.Length == 0)
        {
            displayed = [];
            presented = null;
            Content = null;
            return;
        }

        var paths = clip.Files.Select(FileReference.FromPath).ToArray();
        if (!displayed.Select(file => file.Path).SequenceEqual(paths.Select(file => file.Path)))
            Render(card, paths);
        else if (!ReferenceEquals(presented, DataContext))
            Render(card, displayed);
        presented = DataContext;
        if (!IsLoaded || !IsVisible) return;
        var inspected = await Task.Run(() => paths.Select(file => file.Inspect()).ToArray());
        if (request == refreshId && !displayed.SequenceEqual(inspected)) Render(card, inspected);
    }

    private void Render(ClipCard? card, FileReference[] files)
    {
        displayed = files;
        if (card is not null)
        {
            card.SetFileMissing(files.All(file => file.Missing));
            Content = Compact(files, card.ContentImageWidth);
        }
        else
        {
            var list = new StackPanel();
            foreach (var file in files)
            {
                list.Children.Add(FileRow(file));
            }
            Content = list;
        }
    }

    private static DockPanel Compact(FileReference[] files, double iconWidth)
    {
        var row = new DockPanel();
        row.Children.Add(IconStack(files, iconWidth));
        if (files.Length == 1)
        {
            row.Children.Add(FileLabels(files[0], compact: true));
            return row;
        }

        var body = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        body.Children.Add(Ui.Text(Labels.Format("{0} files", files.Length), 13, strong: true));
        var names = new TextBlock { FontSize = 10.5, TextTrimming = TextTrimming.CharacterEllipsis };
        names.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        var visible = files.Take(3).ToArray();
        for (int index = 0; index < visible.Length; index++)
        {
            if (index > 0) names.Inlines.Add(" · ");
            var name = new System.Windows.Documents.Run(visible[index].Name);
            if (visible[index].Missing) name.TextDecorations = TextDecorations.Strikethrough;
            names.Inlines.Add(name);
        }
        if (files.Length > visible.Length) names.Inlines.Add(" · …");
        body.Children.Add(names);
        int missing = files.Count(file => file.Missing);
        if (missing > 0)
            body.Children.Add(Trimmed(Labels.Format("{0} files deleted", missing), 10.5, "Muted"));
        row.Children.Add(body);
        return row;
    }

    private static Grid IconStack(FileReference[] files, double width)
    {
        var stack = new Grid { Width = width, Height = width, Margin = new Thickness(0, 0, 6, 0) };
        DockPanel.SetDock(stack, Dock.Left);
        if (files.Length == 1)
        {
            stack.Children.Add(Icon(files[0], width));
            return stack;
        }

        for (int index = 0; index < Math.Min(files.Length, 3); index++)
        {
            var image = Icon(files[index], 38);
            image.HorizontalAlignment = HorizontalAlignment.Left;
            image.VerticalAlignment = VerticalAlignment.Top;
            image.Margin = new Thickness(index * 5, 7 - index * 3, 0, 0);
            stack.Children.Add(image);
        }
        var count = Ui.Text(files.Length.ToString(CultureInfo.CurrentCulture), 9, strong: true);
        count.Foreground = Brushes.White;
        var badge = new Border
        {
            Child = count, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Padding = new Thickness(5, 1, 5, 1), CornerRadius = new CornerRadius(8)
        }.WithBackground("Accent");
        stack.Children.Add(badge);
        return stack;
    }

    private static DockPanel FileRow(FileReference file)
    {
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8), Opacity = file.Missing ? 0.55 : 1 };
        var image = Icon(file, 38);
        image.Margin = new Thickness(0, 0, 6, 0);
        DockPanel.SetDock(image, Dock.Left);
        row.Children.Add(image);
        row.Children.Add(FileLabels(file, compact: false));
        return row;
    }

    private static Image Icon(FileReference file, double size) => new()
    {
        Source = FileTypes.Image(FileTypes.ForName(file.Name), file.Missing),
        Width = size, Height = size, Stretch = Stretch.Uniform, IsHitTestVisible = false
    };

    private static StackPanel FileLabels(FileReference file, bool compact)
    {
        var title = Trimmed(file.Name, 13, file.Missing ? "Muted" : "Ink");
        title.FontWeight = FontWeights.SemiBold;
        if (file.Missing) title.TextDecorations = TextDecorations.Strikethrough;
        var info = Trimmed(file.Summary(compact), compact ? 10.5 : 11, "Muted");
        info.ToolTip = file.Path;
        if (!compact) { info.TextTrimming = TextTrimming.None; info.TextWrapping = TextWrapping.Wrap; }
        return new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { title, info } };
    }

    private static TextBlock Trimmed(string value, double size, string color)
    {
        var text = Ui.Text(value, size, color);
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        text.TextWrapping = TextWrapping.NoWrap;
        return text;
    }
}
