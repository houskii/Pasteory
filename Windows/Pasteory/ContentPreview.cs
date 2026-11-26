using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using Pasteory.Core;

namespace Pasteory.Windows;

internal static class ContentPreview
{
    internal static void Show(App app, Clip clip, Window owner)
    {
        var window = new Window
        {
            Title = clip.DisplayTitle.Length > 0 ? clip.DisplayTitle : Labels.Get("Preview"),
            Owner = owner, Width = 670, Height = 480, MinWidth = 320, MinHeight = 260,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false
        };
        var body = new DockPanel { Margin = new Thickness(16) };
        var top = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, 0, 8) };
        DockPanel.SetDock(top, Dock.Top);
        body.Children.Add(top);
        string text = clip.PlainText ?? "";
        var raw = TextBoxFor(text, clip.Kind == ClipKind.Code);
        var host = new ContentControl { Content = raw, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch };
        var markdown = GetMarkdown(text);
        if (clip.Kind == ClipKind.Text && markdown is not null)
        {
            var viewer = new FlowDocumentScrollViewer { Document = markdown, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            host.Content = viewer;
            var toggle = new Button { Content = Labels.Get("Show original"), Margin = new Thickness(0, 0, 8, 0) };
            toggle.Click += (_, _) =>
            {
                bool showOriginal = host.Content == viewer;
                host.Content = showOriginal ? raw : viewer;
                toggle.Content = Labels.Get(showOriginal ? "Show formatting" : "Show original");
            };
            top.Children.Add(toggle);
        }
        top.Children.Add(Ui.Button("Copy", () => _ = app.UseClipAsync(clip, paste: false, plainText: true), "PrimaryButton"));
        body.Children.Add(host);
        window.Content = body;
        window.PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) window.Close(); };
        window.ShowDialog();
    }

    internal static TextBox TextBoxFor(string text, bool code = false)
    {
        var raw = Ui.Field("Preview", text);
        raw.IsReadOnly = true;
        raw.AcceptsReturn = true;
        raw.TextWrapping = TextWrapping.Wrap;
        raw.VerticalContentAlignment = VerticalAlignment.Top;
        raw.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        if (code) raw.FontFamily = new System.Windows.Media.FontFamily("Consolas");
        return raw;
    }

    private static FlowDocument? GetMarkdown(string text)
    {
        const string fence = "\u0060\u0060\u0060";
        var lines = text.Replace("\r\n", "\n").Split('\n');
        if (!lines.Any(line => line.StartsWith("# ", StringComparison.Ordinal) ||
            line.StartsWith("## ", StringComparison.Ordinal) || line.StartsWith(fence, StringComparison.Ordinal))) return null;
        var document = new FlowDocument { PagePadding = new Thickness(9), FontSize = 14 };
        document.SetResourceReference(FlowDocument.ForegroundProperty, "Ink");
        bool code = false;
        foreach (var line in lines)
        {
            if (line.StartsWith(fence, StringComparison.Ordinal)) { code = !code; continue; }
            int heading = line.TakeWhile(character => character == '#').Count();
            bool isHeading = !code && heading is >= 1 and <= 6 && line.Length > heading && line[heading] == ' ';
            var paragraph = new Paragraph(new Run(isHeading ? line[(heading + 1)..] :
                !code && line.StartsWith("- ", StringComparison.Ordinal) ? "• " + line[2..] : line))
            {
                Margin = new Thickness(0, isHeading ? 8 : 0, 0, isHeading ? 5 : 2),
                FontSize = isHeading ? Math.Max(15, 25 - heading * 2) : code ? 13 : 14
            };
            if (isHeading) paragraph.FontWeight = FontWeights.SemiBold;
            if (code) paragraph.FontFamily = new System.Windows.Media.FontFamily("Consolas");
            document.Blocks.Add(paragraph);
        }
        return document;
    }
}
