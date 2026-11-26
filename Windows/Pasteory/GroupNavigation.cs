using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed record GroupNavigationAction(string Setting, string Title, string Default, int Position = -1, string? Profile = null);

internal static class GroupNavigation
{
    internal static readonly string[] Profiles = ["Common groups", "AI groups", "Minimal", "All groups"];
    internal static string Placement(LocalSettings settings) => settings.QuickGroupPlacement is "Top" or "Left" or "Right" ?
        settings.QuickGroupPlacement : settings.GroupSidebar ? "Left" : "Top";

    internal static readonly GroupNavigationAction[] Positions =
    [
        new("Navigation.All", "All clips", "Alt+Oem3", 0),
        .. Enumerable.Range(1, 9).Select(index => new GroupNavigationAction(
            $"Navigation.Group{index}", Labels.Format("Group position {0}", index), $"Alt+{index}", index))
    ];

    internal static IEnumerable<GroupNavigationAction> Views => Profiles.Select((profile, index) => new GroupNavigationAction(
        $"Navigation.View.{profile}", Labels.Format("Switch to {0} view", Labels.Get(profile)), $"Ctrl+Alt+{index + 1}", Profile: profile));

    internal static string Text(LocalSettings settings, GroupNavigationAction action) =>
        Shortcuts.ConfiguredText(settings, action.Setting, action.Default);

    internal static string Hint(LocalSettings settings, int position)
    {
        if (position < 0 || position >= Positions.Length) return "";
        string text = Text(settings, Positions[position]);
        return Shortcut.TryParse(text, out var shortcut) ? shortcut.ToString() : text;
    }

    internal static string ProfileTitle(string profile) => Labels.Get(profile switch
    {
        "Common groups" => "Common view", "AI groups" => "AI", "Minimal" => "Minimal", _ => "All groups view"
    });

    internal static FrameworkElement Row(string glyph, string name, string hint, string color, bool ai)
    {
        var row = new DockPanel();
        var icon = ai ? Ui.Text("AI", 10, color, strong: true) : Ui.Icon(glyph, 13, color);
        icon.Width = 23;
        icon.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        if (hint.Length > 0)
        {
            var shortcut = Ui.Text(hint, 9, color);
            shortcut.Opacity = .74;
            shortcut.VerticalAlignment = VerticalAlignment.Center;
            shortcut.Margin = new Thickness(5, 0, 0, 0);
            DockPanel.SetDock(shortcut, Dock.Right);
            row.Children.Add(shortcut);
        }
        var caption = Ui.Text(name, 13, color);
        caption.TextWrapping = TextWrapping.NoWrap;
        caption.TextTrimming = TextTrimming.CharacterEllipsis;
        caption.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(caption);
        return row;
    }

    internal static GroupNavigationAction? Match(LocalSettings settings, Key key, ModifierKeys modifiers)
    {
        if (modifiers == ModifierKeys.None) return null;
        var pressed = new Shortcut(key, modifiers);
        foreach (var action in Positions.Concat(Views))
        {
            string text = settings.Shortcuts.GetValueOrDefault(action.Setting, action.Default);
            if (Shortcut.TryParse(text, out var shortcut) && shortcut == pressed && Text(settings, action).Length > 0) return action;
        }
        return null;
    }

    internal static ClipCollection[] Visible(string profile, IEnumerable<ClipCollection> ordered,
        IReadOnlyList<ClipCollection> rankedAi, bool library, Guid? selected = null)
    {
        if (profile == "Minimal") return [];
        if (profile == "AI groups") return rankedAi.ToArray();
        var values = ordered.ToArray();
        IEnumerable<ClipCollection> ai = profile == "All groups" ? rankedAi : rankedAi.Take(3);
        if (selected is { } id && values.FirstOrDefault(group => group.Id == id && group.IsAi) is { } active)
            ai = ai.Append(active).DistinctBy(group => group.Id);
        var manual = values.Where(group => !group.IsAi);
        if (library) manual = manual.OrderBy(group => group.IsSmart);
        return ai.Concat(manual).ToArray();
    }
}
