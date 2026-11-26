using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;

namespace Pasteory.Windows;

internal partial class ApplicationPicker : Window
{
    private readonly App app;
    private readonly Func<DesktopApplication, bool> isSelected;
    private readonly CancellationTokenSource lifetime = new();
    private ApplicationOption[]? choices;
    private DesktopApplication? selection;

    private ApplicationPicker(App app, Window owner, string title, Func<DesktopApplication, bool> isSelected)
    {
        this.app = app;
        this.isSelected = isSelected;
        InitializeComponent();
        Owner = owner;
        Title = Heading.Text = Labels.Get(title);
        Icon = owner.Icon ?? app.MainWindow?.Icon;
        ShowInTaskbar = app.AutomationWindow;
        Loaded += OnLoaded;
        Closed += (_, _) => { lifetime.Cancel(); lifetime.Dispose(); };
    }

    internal static DesktopApplication? Choose(App app, Window owner, string title, Func<DesktopApplication, bool>? selected = null)
    {
        var picker = new ApplicationPicker(app, owner, title, selected ?? (_ => false));
        return picker.ShowDialog() == true ? picker.selection : null;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        Search.Focus();
        var cancel = lifetime.Token;
        string?[] configured = [app.Settings.BrowserPath, app.Settings.ImageViewerPath, app.Settings.CodeEditorPath];
        string[] extraPaths = app.Clips.Select(clip => clip.SourcePath).Concat(configured)
            .Concat(app.Settings.FileRules.Select(rule => rule.ApplicationPath))
            .OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        try
        {
            var found = await DesktopApplicationCatalog.DiscoverAsync(extraPaths, cancel);
            if (cancel.IsCancellationRequested) return;
            choices = found.Select(application => new ApplicationOption(app, application, isSelected(application))).ToArray();
            UpdateResults();
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested) { }
    }

    private void Filter(object sender, TextChangedEventArgs e) => UpdateResults();

    private void UpdateResults()
    {
        if (SearchHint is null) return;
        SearchHint.Visibility = Search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (choices is null) return;
        string query = Search.Text.Trim();
        var matching = query.Length == 0 ? choices : choices.Where(option => option.Application.Matches(query)).ToArray();
        Applications.ItemsSource = matching;
        Status.Visibility = matching.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Status.Text = Labels.Get(choices.Length == 0 ? "No installed apps were found." : "No apps match your search.");
    }

    private void ChooseFromList(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: ApplicationOption option }) Confirm(option.Application);
    }

    private void ChooseWithKeyboard(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Applications.SelectedItem is ApplicationOption option)
        {
            e.Handled = true;
            Confirm(option.Application);
        }
    }

    private void Browse(object sender, RoutedEventArgs e)
    {
        var picker = new OpenFileDialog
        {
            Title = Labels.Get("Choose app…"), Filter = $"{Labels.Get("Windows applications")} (*.exe)|*.exe", CheckFileExists = true
        };
        if (picker.ShowDialog(this) != true) return;
        if (DesktopApplicationCatalog.Reference(picker.FileName) is { } selected) Confirm(selected);
        else
        {
            Status.Visibility = Visibility.Visible;
            Status.Text = Labels.Get("Choose an available Windows application.");
        }
    }

    private void Confirm(DesktopApplication application)
    {
        selection = application;
        DialogResult = true;
    }

    private sealed class ApplicationOption(App app, DesktopApplication application, bool selected)
    {
        public DesktopApplication Application { get; } = application;
        public string Name => Application.Name;
        public string Executable => System.IO.Path.GetFileName(Application.Path);
        public string Path => Application.Path;
        public ImageSource? Icon => app.SourceIcon(Path);
        public bool ShowDefaultIcon => Icon is null;
        public bool Selected => selected;
    }
}
