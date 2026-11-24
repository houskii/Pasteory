using System;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Pasteory.Core;

namespace Pasteory.Windows;

public partial class HistoryWindow : Window
{
    private readonly App app;
    private bool refreshing;
    private Guid? selectionBeforeFiltering;

    internal HistoryWindow(App app)
    {
        this.app = app;
        InitializeComponent();
        PreviewKeyDown += HandleKeys;
        Closing += HideInsteadOfClose;
    }

    internal void Present()
    {
        if (!IsVisible)
        {
            refreshing = true;
            Query.Clear();
            History.SelectedItem = null;
            selectionBeforeFiltering = null;
            refreshing = false;
        }
        Refresh();
        if (History.SelectedItem is { } row) History.ScrollIntoView(row);
        Show();
        Activate();
        Query.Focus();
        Query.SelectAll();
    }

    internal void SetStatus(string message) => Status.Text = message;

    internal void Refresh()
    {
        string? previousGroup = (Groups.SelectedItem as GroupFilter)?.Name;
        var filters = app.Clips.Select(clip => clip.Group)
            .Where(name => name.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(name => name, StringComparer.CurrentCultureIgnoreCase)
            .Select(name => new GroupFilter(name)).Prepend(new GroupFilter(null)).ToArray();
        refreshing = true;
        Groups.ItemsSource = filters;
        Groups.SelectedItem = filters.FirstOrDefault(filter =>
            string.Equals(filter.Name, previousGroup, StringComparison.OrdinalIgnoreCase)) ?? filters[0];
        refreshing = false;
        ApplyFilters();
    }

    private Clip? Selected => (History.SelectedItem as HistoryRow)?.Clip;

    private void FilterChanged(object sender, RoutedEventArgs e)
    {
        if (!refreshing && IsLoaded) ApplyFilters();
    }

    private void ApplyFilters()
    {
        var selected = Selected?.Id ?? selectionBeforeFiltering;
        string? group = (Groups.SelectedItem as GroupFilter)?.Name;
        var results = app.Clips.Where(clip => (FavoritesOnly.IsChecked != true || clip.Favorite) &&
                (group is null || clip.Group.Equals(group, StringComparison.OrdinalIgnoreCase)) &&
                clip.Matches(Query.Text))
            .OrderByDescending(clip => clip.Pinned)
            .ThenByDescending(clip => clip.CapturedAt)
            .Select(clip => new HistoryRow(clip)).ToArray();
        refreshing = true;
        History.ItemsSource = results;
        History.SelectedItem = results.FirstOrDefault(row => row.Clip.Id == selected) ?? results.FirstOrDefault();
        EmptyMessage.Text = results.Length > 0 ? "" : Labels.Get(app.Clips.Count == 0
            ? "Copy something to start your history." : "No clips match.");
        refreshing = false;
        ShowSelected();
    }

    private void SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!refreshing && IsLoaded) ShowSelected();
    }

    private void ShowSelected()
    {
        var clip = Selected;
        if (clip is not null) selectionBeforeFiltering = clip.Id;
        EditActions.IsEnabled = CopyActions.IsEnabled = clip is not null;
        TextCopyButton.IsEnabled = clip?.PlainText is { Length: > 0 };
        Details.Text = clip is null ? "" : ClipContext(clip);
        Pinned.IsChecked = clip?.Pinned == true;
        Favorite.IsChecked = clip?.Favorite == true;
        ImagePreview.Source = null;
        ImagePreview.Visibility = Visibility.Collapsed;
        Preview.Visibility = Visibility.Visible;
        Preview.Text = clip is null ? Labels.Get("Select a clip to preview it.")
            : clip.PlainText ?? (clip.Kind == ClipKind.Image ? "" : Labels.Get("Rich text"));
        if (clip?.Kind != ClipKind.Image) return;
        try
        {
            ImagePreview.Source = ClipboardFormats.DecodePreview(app.ReadImage(clip));
            ImagePreview.Visibility = Visibility.Visible;
            Preview.Visibility = Visibility.Collapsed;
        }
        catch (Exception error) when (App.IsLocalError(error) || error is NotSupportedException or ArgumentException)
        {
            Preview.Text = Labels.Get("The saved image could not be opened.");
        }
    }

    private void HandleKeys(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Hide();
        }
        else if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control)
        {
            Query.Focus();
            Query.SelectAll();
        }
        else if (Query.IsKeyboardFocused && e.Key is Key.Up or Key.Down)
        {
            if (History.Items.Count > 0)
            {
                History.SelectedIndex = Math.Clamp(History.SelectedIndex + (e.Key == Key.Up ? -1 : 1),
                    0, History.Items.Count - 1);
                History.ScrollIntoView(History.SelectedItem);
            }
        }
        else if (Keyboard.FocusedElement is TextBox box &&
                 e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control && box.SelectionLength > 0)
        {
            return;
        }
        else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control && Selected is { } copied)
        {
            _ = app.UseClipAsync(copied, paste: false, plainText: false);
        }
        else if ((Query.IsKeyboardFocused || History.IsKeyboardFocusWithin) && Selected is { } clip &&
                 (e.Key == Key.Enter || e.SystemKey == Key.Enter && Keyboard.Modifiers == ModifierKeys.Alt))
        {
            bool plainText = Keyboard.Modifiers == ModifierKeys.Alt;
            if (!plainText || clip.PlainText is { Length: > 0 })
                _ = app.UseClipAsync(clip, paste: true, plainText: plainText);
        }
        else return;
        e.Handled = true;
    }

    private void HideInsteadOfClose(object? sender, CancelEventArgs e)
    {
        if (app.Exiting) return;
        e.Cancel = true;
        Hide();
    }

    private void OpenSettings(object sender, RoutedEventArgs e) => app.OpenSettings();

    private void OpenSelected(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is FrameworkElement { DataContext: HistoryRow row })
            _ = app.UseClipAsync(row.Clip, paste: true, plainText: false);
    }

    private void PasteSelected(object sender, RoutedEventArgs e)
    {
        if (Selected is { } clip) _ = app.UseClipAsync(clip, paste: true, plainText: false);
    }

    private void CopySelected(object sender, RoutedEventArgs e)
    {
        if (Selected is { } clip) _ = app.UseClipAsync(clip, paste: false, plainText: false);
    }

    private void CopyAsText(object sender, RoutedEventArgs e)
    {
        if (Selected is { } clip) _ = app.UseClipAsync(clip, paste: false, plainText: true);
    }

    private void ToggleDetails(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } clip) return;
        app.EditClip(clip, clip.Title, clip.Note, clip.Group, Pinned.IsChecked == true, Favorite.IsChecked == true);
        ShowSelected();
    }

    private void EditDetails(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } clip) return;
        var dialog = new DetailsWindow(clip) { Owner = this };
        if (dialog.ShowDialog() == true)
            app.EditClip(clip, dialog.ClipTitle, dialog.ClipNote, dialog.ClipGroup, clip.Pinned, clip.Favorite);
    }

    private void DeleteClip(object sender, RoutedEventArgs e)
    {
        if (Selected is { } clip &&
            MessageBox.Show(this, Labels.Get("Delete this clip from history?"), "Pasteory",
                MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) == MessageBoxResult.Yes)
            app.DeleteClip(clip);
    }

    private static string ClipContext(Clip clip) => string.Join("  ·  ", new[]
    {
        Labels.Get(clip.Kind.ToString()), clip.Source, clip.Group, clip.CapturedAt.ToLocalTime().ToString("g"),
        clip.Pinned ? Labels.Get("Pinned") : "", clip.Favorite ? Labels.Get("Favorite") : ""
    }.Where(value => value.Length > 0));

    private sealed record GroupFilter(string? Name)
    {
        public override string ToString() => Name ?? Labels.Get("All groups");
    }

    private sealed record HistoryRow(Clip Clip)
    {
        public string Caption { get; } = FirstLine(Clip.Title.Length > 0 ? Clip.Title :
            Clip.Kind == ClipKind.Files ? string.Join(", ", Clip.Files.Select(System.IO.Path.GetFileName)) :
            Clip.Text?.TrimStart() ?? Labels.Get(Clip.Kind == ClipKind.Text ? "Rich text" : Clip.Kind.ToString()));

        public string Context => ClipContext(Clip);

        private static string FirstLine(string value)
        {
            int boundary = value.IndexOfAny(['\r', '\n']);
            if (boundary >= 0) value = value[..boundary];
            return value.Length <= 180 ? value : value[..180] + "…";
        }
    }
}
