using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media.Imaging;

namespace Pasteory.Windows;

internal sealed class WelcomeWindow : Window
{
    internal WelcomeWindow(App app, Action showPanel)
    {
        SetResourceReference(StyleProperty, typeof(Window));
        Title = Labels.Get("Welcome to Pasteory");
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/Pasteory.ico"));
        Width = Math.Min(760, SystemParameters.WorkArea.Width);
        Height = Math.Min(530, SystemParameters.WorkArea.Height);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ResizeMode = ResizeMode.CanMinimize;

        var layout = new StackPanel { Margin = new Thickness(26), VerticalAlignment = VerticalAlignment.Center };
        layout.Children.Add(new Image { Source = Icon, Width = 84, Height = 84 });
        var heading = Ui.Text(Title, 29, strong: true);
        heading.Margin = new Thickness(0, 10, 0, 4);
        heading.TextAlignment = TextAlignment.Center;
        layout.Children.Add(heading);
        var tagline = Ui.Text(Labels.Get("Pasteory learns from what you copied."), 15, "Muted");
        tagline.TextAlignment = TextAlignment.Center;
        layout.Children.Add(tagline);

        string shortcut = Shortcuts.Text(app.Settings, Command.ShowPanel);
        var features = new UniformGrid { Columns = 3, Margin = new Thickness(0, 22, 0, 8) };
        features.Children.Add(Feature(Glyph.Storage, "Stored locally", Labels.Get("Pasteory saves clips on this PC.")));
        features.Children.Add(Feature(Glyph.Privacy, "Clipboard privacy", Labels.Get("Protected clipboard data and common password managers are ignored by default.")));
        features.Children.Add(Feature(Glyph.Shortcut, "Find and paste", app.ShortcutAvailable
            ? Labels.Format("Press {0} to search and paste from your history.", shortcut)
            : Labels.Get("Open the quick panel from the tray to search and paste from your history.")));
        layout.Children.Add(features);

        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center };
        var test = Ui.Button(app.ShortcutAvailable ? Labels.Format("Test {0}", shortcut) : "Test quick panel", showPanel);
        test.Margin = new Thickness(0, 0, 8, 0);
        actions.Children.Add(test);
        var start = Ui.Button("Get started", () =>
        {
            if (!app.SaveSettings(app.Settings with { CompletedOnboarding = true })) return;
            Close();
            showPanel();
        }, "PrimaryButton");
        start.IsDefault = true;
        start.MinWidth = 120;
        actions.Children.Add(start);
        layout.Children.Add(actions);
        var status = Ui.Text(Labels.Get(app.CaptureAvailable && !app.Settings.Paused
            ? "Pasteory saves new copies as you work. You can pause capture from the tray."
            : "You can manage clipboard capture from the tray."), 12, "Muted");
        status.Margin = new Thickness(0, 14, 0, 0);
        status.TextAlignment = TextAlignment.Center;
        layout.Children.Add(status);
        Content = new ScrollViewer { Content = layout, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private static Border Feature(string glyph, string title, string description)
    {
        var body = new StackPanel { MinHeight = 105 };
        body.Children.Add(Ui.Icon(glyph, 20, "AccentInk"));
        var heading = Ui.Text(Labels.Get(title), 14, strong: true);
        heading.Margin = new Thickness(0, 9, 0, 5);
        body.Children.Add(heading);
        body.Children.Add(Ui.Text(description, 12, "Muted"));
        var card = Ui.Section(body);
        card.Margin = new Thickness(4, 0, 4, 10);
        return card;
    }
}
