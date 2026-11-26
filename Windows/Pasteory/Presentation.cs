using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Pasteory.Core;

namespace Pasteory.Windows;

internal static class Glyph
{
    internal const string Search = "\uE721", Settings = "\uE713", Pin = "\uE840", Group = "\uE8B7",
        Smart = "\uE945", AllGroups = "\uE8FD", Tools = "\uE90F", Library = "\uE7B8",
        Favorite = "\uE734", Recent = "\uE823", Archive = "\uE7B8", Trash = "\uE74D",
        Privacy = "\uE72E", Shortcut = "\uE765", Open = "\uE8A7", Link = "\uE71B",
        Storage = "\uEDA2", Diagnostic = "\uE9D9", Info = "\uE946", Story = "\uE82D",
        Text = "\uE8E9", Image = "\uEB9F", Color = "\uE790", Code = "\uE943", Files = "\uE8A5",
        Mixed = "\uE81E", Add = "\uE710", Close = "\uE711";

    internal static string ForKind(ClipKind kind) => kind switch
    {
        ClipKind.Link => Link, ClipKind.Image => Image, ClipKind.Files => Files, ClipKind.Color => Color,
        ClipKind.Code => Code, ClipKind.Mixed or ClipKind.Aggregate => Mixed, _ => Text
    };
}

internal static class Theme
{
    private static readonly Dictionary<string, (string First, string Second)> Accents = new()
    {
        ["BlueViolet"] = ("#4A61F5", "#8C40E8"), ["Blue"] = ("#1473E0", "#1FA6ED"),
        ["Purple"] = ("#8740DE", "#B061F0"), ["Pink"] = ("#D63385", "#F563A1"),
        ["Orange"] = ("#E86319", "#F59C29"), ["Green"] = ("#149461", "#29BA82"),
        ["Graphite"] = ("#576170", "#7A8596")
    };

    internal static IEnumerable<string> Colors => Accents.Keys;
    internal static Brush Swatch(string key) => new SolidColorBrush(Parse(Accents[key].First));

    internal static void Apply(ResourceDictionary resources, LocalSettings settings)
    {
        bool dark = settings.Appearance == "Dark" || settings.Appearance == "System" &&
            Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1) is 0;
        (string first, string second) = Accents.GetValueOrDefault(settings.Theme, Accents["BlueViolet"]);
        var accent = Parse(first);
        var end = Parse(second);
        var surface = Parse(dark ? "#29292E" : "#FEFEFF");
        var panel = Parse(dark ? "#222227" : "#E0E0E2");
        var colors = new (string Key, string Light, string Dark)[]
        {
            ("Canvas", "#F6F7FB", "#1E1E23"), ("Workspace", "#F6F7FB", "#1E1E23"),
            ("Detail", "#F4F5FC", "#222229"), ("Nav", "#FDFDFE", "#222227"),
            ("SubNav", "#E8E8EA", "#25252B"), ("SoftSurface", "#F0F0F3", "#37373E"),
            ("Ink", "#242426", "#F0F0F4"), ("Muted", "#656568", "#B5B5C2"), ("Quiet", "#76767B", "#AAAAAF"),
            ("Line", "#E6E6ED", "#3C3C46"), ("CodeBackground", "#F0EAFB", "#332747"),
            ("CodeInk", "#7438DC", "#CAA0FF"), ("LinkInk", "#0769DB", "#83BFFF"),
            ("Danger", "#BE3441", "#FF9AA6")
        };
        foreach (var (key, light, darkColor) in colors) Set(key, Parse(dark ? darkColor : light));
        Set("Surface", surface);
        Set("Panel", panel);
        Set("Accent", accent);
        Set("AccentInk", Mix(accent, dark ? ColorsWhite : ColorsBlack, dark ? .38 : .16));
        Set("AccentTint", Mix(surface, accent, dark ? .20 : .12));
        Set("PanelTint", Mix(panel, accent, .23));
        resources["AccentGradient"] = new LinearGradientBrush(accent, end, 0);

        void Set(string key, Color color) => resources[key] = new SolidColorBrush(color);
    }

    private static readonly Color ColorsWhite = System.Windows.Media.Colors.White;
    private static readonly Color ColorsBlack = System.Windows.Media.Colors.Black;
    private static Color Parse(string hex) => (Color)ColorConverter.ConvertFromString(hex);
    private static Color Mix(Color basis, Color tint, double amount) =>
        Color.FromRgb((byte)(basis.R + (tint.R - basis.R) * amount),
            (byte)(basis.G + (tint.G - basis.G) * amount), (byte)(basis.B + (tint.B - basis.B) * amount));
}

internal static class Ui
{
    internal static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);
    internal static TextBlock Text(string text, double size = 13, string color = "Ink", bool strong = false)
    {
        var label = new TextBlock
        {
            Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap,
            FontWeight = strong ? FontWeights.SemiBold : FontWeights.Normal
        };
        label.SetResourceReference(TextBlock.ForegroundProperty, color);
        return label;
    }

    internal static TextBlock Icon(string glyph, double size = 14, string color = "Muted")
    {
        var label = Text(glyph, size, color);
        label.FontFamily = (FontFamily)Application.Current.FindResource("IconFont");
        label.TextWrapping = TextWrapping.NoWrap;
        return label;
    }

    internal static Button Button(string text, Action select, string? style = null)
    {
        var button = new Button { Content = Labels.Get(text) };
        if (style is not null) button.SetResourceReference(FrameworkElement.StyleProperty, style);
        button.Click += (_, _) => select();
        return button;
    }

    internal static Button IconButton(string glyph, string label, Action select)
    {
        var button = Button(glyph, select, "IconButton");
        button.ToolTip = Labels.Get(label);
        AutomationProperties.SetName(button, Labels.Get(label));
        return button;
    }

    internal static Border Section(FrameworkElement content)
    {
        var card = new Border { Child = content };
        card.SetResourceReference(FrameworkElement.StyleProperty, "SectionCard");
        return card;
    }

    internal static TextBlock SectionTitle(string key) => Text(Labels.Get(key), 12, "Muted", strong: true);

    internal static FrameworkElement WithIcon(string glyph, string label, string color = "Ink")
    {
        var row = new DockPanel();
        var icon = Icon(glyph, 14, color);
        icon.Width = 24;
        icon.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        var text = Text(label, 13, color);
        text.TextWrapping = TextWrapping.NoWrap;
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        text.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(text);
        return row;
    }

    internal static TextBox Field(string label, string value, int maxLength = 0)
    {
        var box = new TextBox { Text = value, MaxLength = maxLength };
        AutomationProperties.SetName(box, Labels.Get(label));
        return box;
    }

    internal static void AddField(Panel panel, string label, FrameworkElement field)
    {
        var title = SectionTitle(label);
        title.Margin = new Thickness(0, 9, 0, 4);
        panel.Children.Add(title);
        panel.Children.Add(field);
    }
}

internal sealed class ClipCard
{
    private readonly App app;
    private readonly int? matchCount;
    private readonly int memberCount;
    private readonly bool expanded;

    internal ClipCard(App app, Clip clip, int memberCount, bool expanded, int? matchCount, Guid? parent)
    {
        this.app = app;
        this.memberCount = memberCount;
        this.expanded = expanded;
        this.matchCount = matchCount;
        Clip = clip;
        Parent = parent;
    }

    public Clip Clip { get; }
    public Guid? Parent { get; }
    public bool IsChild => Parent is not null;
    public string Source => Clip.Kind == ClipKind.Aggregate ? Labels.Get("Aggregation") :
        Clip.Source.Equals("explorer", StringComparison.OrdinalIgnoreCase) ? Labels.Get("Explorer") : Clip.Source;
    public string Glyph => Windows.Glyph.ForKind(Clip.Kind);
    public string Chevron => Clip.Kind == ClipKind.Aggregate ? expanded ? "⌄" : "›" : "";
    public bool HasTitle => Clip.DisplayTitle.Length > 0 && Clip.Kind != ClipKind.Aggregate;
    public string Title => "◆  " + Clip.DisplayTitle;
    public string Note => "▫  " + Short(Clip.Note, 100, 1);
    public bool HasNote => Clip.Note.Length > 0;
    public bool IsFile => Clip.Files.Length > 0 && !Clip.HasImage;
    public bool IsCode => Clip.Kind == ClipKind.Code;
    public bool IsLink => Clip.Kind == ClipKind.Link;
    public bool IsColor => Clip.Kind == ClipKind.Color;
    public int CompactHeight => Clip.Kind switch
    {
        ClipKind.Code or ClipKind.Files => 94, ClipKind.Image or ClipKind.Mixed => 88, ClipKind.Link => 84, _ => 74
    };
    public int LibraryHeight => Clip.Kind switch
    {
        ClipKind.Code or ClipKind.Files => 104, ClipKind.Image or ClipKind.Mixed => 95, ClipKind.Link => 92, _ => 84
    };
    public bool HasThumbnail => Clip.HasImage && Thumbnail is not null;
    public ImageSource? Thumbnail => Clip.HasImage ? app.ClipThumbnail(Clip) : null;
    public ImageSource? AppIcon => app.SourceIcon(Clip.SourcePath);
    public Brush? ColorSwatch => IsColor && TextTools.TryColor(Clip.Text, out var value)
        ? new SolidColorBrush(Color.FromArgb(value.A, value.R, value.G, value.B)) : null;

    public string FileExtension => Clip.Files.Length > 1 ? $"+{Clip.Files.Length}" :
        Clip.Files.Length == 1 ? Path.GetExtension(Clip.Files[0]).TrimStart('.').ToUpperInvariant() : "";
    public bool HasFileDetails => IsFile && Clip.Files.Length == 1;
    public string FileDetails
    {
        get
        {
            if (!HasFileDetails) return "";
            string path = Clip.Files[0];
            string folder = Path.GetDirectoryName(path) ?? "";
            if (folder.Length > 36) folder = folder[..14] + "…" + folder[^20..];
            try
            {
                if (!path.StartsWith(@"\\", StringComparison.Ordinal) && new FileInfo(path) is { Exists: true } file)
                    return $"{folder}  {Bytes(file.Length)}";
            }
            catch (Exception error) when (App.IsLocalError(error) || error is ArgumentException) { }
            return folder;
        }
    }

    public string Body
    {
        get
        {
            if (Clip.Kind == ClipKind.Aggregate) return Clip.Title.Length > 0 ? Clip.Title : Labels.Get("Aggregation");
            if (Clip.HasImage)
            {
                if (!string.IsNullOrWhiteSpace(Clip.RecognizedText)) return Short(Clip.RecognizedText, 140, 3);
                string dimensions = Clip.ImageWidth > 0 ? $"{Clip.ImageWidth} × {Clip.ImageHeight}" : Labels.Get("Image");
                string label = Clip.Kind == ClipKind.Mixed ? Labels.Get("Mixed content") : "PNG";
                return $"{label}\n{dimensions}\n{Bytes(Clip.ImageSize)}";
            }
            if (Clip.Files.Length > 1) return Labels.Format("{0} files", Clip.Files.Length) + "\n" +
                Short(string.Join(", ", Clip.Files.Take(3).Select(Path.GetFileName)), 96, 1);
            if (Clip.Files.Length == 1)
            {
                string file = Clip.Files[0];
                return Path.GetFileName(file);
            }
            return Short(Clip.Text ?? Labels.Get("Rich text"), 240, IsCode ? 3 : IsLink ? 2 : 1);
        }
    }

    public string Metadata
    {
        get
        {
            if (Clip.Kind == ClipKind.Aggregate) return matchCount is { } matched
                ? Labels.Format("{0} / {1} matches", matched, memberCount) : Labels.Format("{0} items", memberCount);
            return $"{Clip.CapturedAt.ToLocalTime():MM-dd HH:mm}   " + Labels.Format("Copy ×{0} · Paste ×{1}",
                Count(Clip.CopyCount), Count(Clip.PasteCount));
        }
    }

    internal static string Short(string text, int max, int lines)
    {
        string prefix = text.Length > max ? text[..max] : text;
        var chunks = prefix.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        return string.Join("\n", chunks.Take(lines)) + (text.Length > max || chunks.Length > lines ? "…" : "");
    }

    internal static string Bytes(long bytes) => bytes switch
    {
        >= 1_000_000_000 => $"{bytes / 1_000_000_000d:F1} GB",
        >= 1_000_000 => $"{bytes / 1_000_000d:F1} MB",
        >= 1_000 => $"{bytes / 1_000d:F1} KB",
        _ => $"{bytes} B"
    };

    private static string Count(int count) => count >= 1000 ? $"{count / 1000d:F1}K" : count.ToString(CultureInfo.CurrentCulture);
}
