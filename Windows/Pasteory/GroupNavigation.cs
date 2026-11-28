using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed record GroupNavigationAction(string Setting, string Title, string Default, int Position = -1, string? Profile = null);

internal static class GroupNavigation
{
    internal const double MinSidebarWidth = 180;
    internal const double MaxSidebarWidth = 320;
    internal const double MinPanelContentWidth = 340;
    internal const double MaxPanelContentWidth = 520;

    internal static readonly string[] Profiles = ["Common groups", "AI groups", "Minimal", "All groups"];
    internal static string Placement(LocalSettings settings) => settings.QuickGroupPlacement is "Top" or "Left" or "Right" ?
        settings.QuickGroupPlacement : settings.GroupSidebar ? "Left" : "Top";
    internal static double SidebarWidth(LocalSettings settings) => Math.Clamp(settings.GroupSidebarWidth, MinSidebarWidth, MaxSidebarWidth);
    internal static int RecommendationCount(LocalSettings settings) => Math.Clamp(settings.Ai.RecommendedGroupCount, 1, 8);
    internal static int RowHeight(LocalSettings settings) => settings.CompactGroupRows ? 28 : 34;
    internal static bool Matches(ClipCollection group, string query) => group.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
        group.Definition.Contains(query, StringComparison.CurrentCultureIgnoreCase);

    internal static string ProfileForGroup(LocalSettings settings, ClipCollection group)
    {
        if (group.IsAi && (settings.GroupDisplay == "Minimal" || settings.GroupDisplay == "Common groups" && !settings.RecommendAiGroups))
            return "AI groups";
        if (!group.IsAi && settings.GroupDisplay is "Minimal" or "AI groups") return "Common groups";
        return settings.GroupDisplay;
    }

    internal static double PanelContentWidth(LocalSettings settings)
    {
        // Older sidebars used 144 units plus an 8-unit margin in the overall width.
        double previous = Placement(settings) != "Top" && settings.PanelWidth >= 516 ? settings.PanelWidth - 152 : settings.PanelWidth;
        return Math.Clamp(settings.PanelContentWidth ?? previous, MinPanelContentWidth, MaxPanelContentWidth);
    }

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

    internal static Border ProfileStrip(App app)
    {
        var strip = new UniformGrid { Rows = 1 };
        foreach (string profile in Profiles)
        {
            bool selected = app.Settings.GroupDisplay == profile;
            if (profile == "All groups" && !selected) continue;
            string title = profile == "Common groups" ? "Common" : profile == "All groups" ? "All" : ProfileTitle(profile);
            var button = Ui.Button(title, () => app.SetGroupProfile(profile));
            button.FontSize = 12;
            button.MinHeight = 25;
            button.Padding = new Thickness(2);
            button.ToolTip = Labels.Get(profile);
            button.SetResourceReference(Control.BackgroundProperty, selected ? "AccentTint" : "TransparentBrush");
            button.SetResourceReference(Control.ForegroundProperty, selected ? "AccentInk" : "Ink");
            strip.Children.Add(button);
        }
        return new Border { Child = strip, Padding = new Thickness(3), CornerRadius = new CornerRadius(8) }.WithBackground("SoftSurface");
    }

    internal static FrameworkElement Row(string glyph, string name, string hint, string color, bool ai, string? activity = null, int unread = 0)
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
        if (unread > 0)
        {
            var badge = new Border
            {
                Child = Ui.Text(Labels.Get("New content"), 9, "AccentInk", strong: true), CornerRadius = new CornerRadius(5),
                Padding = new Thickness(4, 1, 4, 1), Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
                ToolTip = Labels.Format("{0} new clips", unread)
            }.WithBackground("AccentTint");
            DockPanel.SetDock(badge, Dock.Right);
            row.Children.Add(badge);
        }
        if (activity is not null)
        {
            var score = Ui.Text(activity, 10, color);
            score.Opacity = .82;
            score.VerticalAlignment = VerticalAlignment.Center;
            score.Margin = new Thickness(5, 0, 0, 0);
            DockPanel.SetDock(score, Dock.Right);
            row.Children.Add(score);
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

    internal static ClipCollection[] Visible(LocalSettings settings, IEnumerable<ClipCollection> ordered,
        IReadOnlyList<ClipCollection> rankedAi, bool library, Guid? selected = null)
    {
        string profile = settings.GroupDisplay;
        if (profile == "Minimal") return [];
        if (profile == "AI groups") return rankedAi.ToArray();
        var values = ordered.ToArray();
        IEnumerable<ClipCollection> ai = settings.RecommendAiGroups ? rankedAi.Take(RecommendationCount(settings)) : [];
        if (profile == "All groups") ai = rankedAi;
        if (settings.RecommendAiGroups && selected is { } id && values.FirstOrDefault(group => group.Id == id && group.IsAi) is { } active)
            ai = ai.Append(active).DistinctBy(group => group.Id);
        var manual = values.Where(group => !group.IsAi);
        if (library) manual = manual.OrderBy(group => group.IsSmart);
        return ai.Concat(manual).ToArray();
    }
}
