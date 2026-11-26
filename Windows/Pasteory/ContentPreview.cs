using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using Markdig.Syntax;
using Pasteory.Core;

namespace Pasteory.Windows;

internal static class ContentPreview
{
    private const int MaximumCharacters = 64_000;

    internal static void Show(App app, Clip clip, Window owner)
    {
        var window = new Window
        {
            Title = clip.DisplayTitle.Length > 0 ? clip.DisplayTitle : Labels.Get("Text preview"),
            Owner = owner, Width = Math.Min(820, SystemParameters.WorkArea.Width),
            Height = Math.Min(650, SystemParameters.WorkArea.Height), MinWidth = 320, MinHeight = 260,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = app.AutomationWindow
        };
        var body = new DockPanel { Margin = new Thickness(16) };
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        var copy = Ui.Button("Copy original", () => _ = app.UseClipAsync(clip, paste: false, plainText: true), "PrimaryButton");
        copy.Margin = new Thickness(0, 0, 7, 0);
        actions.Children.Add(copy);
        actions.Children.Add(Ui.Button("Close", window.Close));
        DockPanel.SetDock(actions, Dock.Right);
        top.Children.Add(actions);
        var title = Ui.Text(Labels.Get("Text preview"), 16, strong: true);
        title.VerticalAlignment = VerticalAlignment.Center;
        top.Children.Add(title);
        DockPanel.SetDock(top, Dock.Top);
        body.Children.Add(top);
        body.Children.Add(Create(app, clip));
        window.Content = body;
        window.PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) window.Close(); };
        window.ShowDialog();
    }

    internal static FrameworkElement Create(App app, Clip clip, Action? expand = null)
    {
        string text = clip.PlainText ?? "";
        int length = Math.Min(MaximumCharacters, text.Length);
        if (length < text.Length && char.IsHighSurrogate(text[length - 1])) length--;
        string source = text[..length];
        var raw = TextBoxFor(source, clip.Kind == ClipKind.Code);
        raw.BorderThickness = new Thickness(0);
        raw.Padding = new Thickness(6);
        var layout = new DockPanel();
        if (length < text.Length)
        {
            var notice = Ui.Text(Labels.Format("Showing the first {0:N0} characters. Copy original keeps the full text.", MaximumCharacters), 11, "Muted");
            notice.Margin = new Thickness(0, 5, 0, 0);
            DockPanel.SetDock(notice, Dock.Bottom);
            layout.Children.Add(notice);
        }
        var formatted = new TabItem { Header = "Markdown", IsEnabled = false };
        var original = new TabItem { Header = Labels.Get("Original"), Content = raw };
        var tabs = new TabControl();
        tabs.SetResourceReference(FrameworkElement.StyleProperty, "SettingsSegmentedTabs");
        AutomationProperties.SetName(tabs, Labels.Get("Text format"));
        tabs.Items.Add(formatted);
        tabs.Items.Add(original);
        tabs.SelectedItem = original;
        if (expand is not null)
        {
            var header = new Grid();
            header.Children.Add(tabs);
            var button = Ui.IconButton("\uE740", "Expand text preview", expand);
            button.HorizontalAlignment = HorizontalAlignment.Right;
            button.VerticalAlignment = VerticalAlignment.Top;
            header.Children.Add(button);
            layout.Children.Add(header);
        }
        else layout.Children.Add(tabs);

        MarkdownDocument? markdown = null;
        tabs.Loaded += async (_, _) =>
        {
            if (markdown is not null) return;
            var parsed = await MarkdownPreview.ParseAsync(clip.Id, source);
            if (!tabs.IsLoaded || markdown is not null) return;
            markdown = parsed;
            formatted.IsEnabled = true;
            if (MarkdownPreview.LooksFormatted(parsed)) tabs.SelectedItem = formatted;
        };
        tabs.SelectionChanged += (_, _) =>
        {
            if (tabs.SelectedItem != formatted || markdown is null || formatted.Content is not null) return;
            formatted.Content = new FlowDocumentScrollViewer
            {
                Document = MarkdownPreview.Render(markdown, OpenLink), VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                IsToolBarVisible = false, IsSelectionEnabled = true
            };
        };
        return layout;

        void OpenLink(Uri uri)
        {
            try { App.OpenInShell(uri.AbsoluteUri); }
            catch (Exception error) when (error is Win32Exception or InvalidOperationException) { app.Notify(error.Message); }
        }
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

}
