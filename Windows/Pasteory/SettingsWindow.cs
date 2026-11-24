using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed class SettingsWindow : Window
{
    internal SettingsWindow(App app)
    {
        Title = Labels.Get("Settings");
        Width = 490;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;

        var panel = new StackPanel { Margin = new Thickness(20) };
        var paused = new CheckBox
        {
            Content = Labels.Get("Pause clipboard capture"), IsChecked = app.Settings.Paused,
            Margin = new Thickness(0, 0, 0, 10)
        };
        var alternate = new CheckBox
        {
            Content = Labels.Get("Use Ctrl+Alt+V instead of Ctrl+Shift+V"),
            IsChecked = app.Settings.UseAlternateShortcut, Margin = new Thickness(0, 0, 0, 16)
        };
        var ignored = new TextBox
        {
            Text = string.Join(Environment.NewLine, app.Settings.IgnoredApps),
            AcceptsReturn = true, MaxLength = 4000, Height = 86, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Margin = new Thickness(0, 3, 0, 12)
        };
        panel.Children.Add(paused);
        panel.Children.Add(alternate);
        panel.Children.Add(new Label
        {
            Target = ignored, Padding = new Thickness(0),
            Content = Labels.Get("Excluded process names, one per line (for example KeePassXC)")
        });
        panel.Children.Add(ignored);

        var dataActions = new WrapPanel { Margin = new Thickness(0, 0, 0, 10) };
        var clear = new Button { Content = Labels.Get("Clear unpinned and unfavorited history") };
        clear.Click += (_, _) =>
        {
            if (MessageBox.Show(this, Labels.Get("Clear all clips that are neither pinned nor favorited?"),
                "Pasteory", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) == MessageBoxResult.Yes)
                app.ClearUnprotected();
        };
        var folder = new Button { Content = Labels.Get("Open data folder") };
        folder.Click += (_, _) => app.OpenDataFolder();
        dataActions.Children.Add(clear);
        dataActions.Children.Add(folder);
        panel.Children.Add(dataActions);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var save = new Button { Content = Labels.Get("Save"), IsDefault = true };
        save.Click += (_, _) =>
        {
            string[] ignoredApps = ignored.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(name => name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                    ? Path.GetFileNameWithoutExtension(name) : name)
                .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (app.SaveSettings(new LocalSettings
            {
                Paused = paused.IsChecked == true,
                UseAlternateShortcut = alternate.IsChecked == true,
                IgnoredApps = ignoredApps
            })) DialogResult = true;
        };
        buttons.Children.Add(save);
        buttons.Children.Add(new Button { Content = Labels.Get("Cancel"), IsCancel = true });
        panel.Children.Add(buttons);
        Content = panel;
    }
}
