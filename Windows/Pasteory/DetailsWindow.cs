using System.Windows;
using System.Windows.Controls;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed class DetailsWindow : Window
{
    private readonly TextBox title;
    private readonly TextBox group;
    private readonly TextBox note;

    internal string ClipTitle => title.Text.Trim();
    internal string ClipGroup => group.Text.Trim();
    internal string ClipNote => note.Text.Trim();

    internal DetailsWindow(Clip clip)
    {
        Title = Labels.Get("Edit details");
        Width = 420;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;

        var panel = new StackPanel { Margin = new Thickness(20) };
        title = AddField(panel, "Title", clip.Title, 120);
        group = AddField(panel, "Group", clip.Group, 80);
        note = AddField(panel, "Note", clip.Note, 4000);
        note.Height = 96;
        note.AcceptsReturn = true;
        note.TextWrapping = TextWrapping.Wrap;
        note.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var save = new Button { Content = Labels.Get("Save"), IsDefault = true };
        save.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(save);
        buttons.Children.Add(new Button { Content = Labels.Get("Cancel"), IsCancel = true });
        panel.Children.Add(buttons);
        Content = panel;
        Loaded += (_, _) => title.Focus();
    }

    private static TextBox AddField(StackPanel panel, string label, string text, int maxLength)
    {
        var field = new TextBox { Text = text, MaxLength = maxLength, Margin = new Thickness(0, 3, 0, 12) };
        panel.Children.Add(new Label { Content = Labels.Get(label), Target = field, Padding = new Thickness(0) });
        panel.Children.Add(field);
        return field;
    }
}
