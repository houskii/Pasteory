using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Input;
using Pasteory.Core;

namespace Pasteory.Windows;

internal enum Command
{
    ShowPanel, OpenClip, Search, Paste, Copy, PastePlain, CopyPlain, Favorite, Pin, Edit,
    AssignGroups, NewGroup, Aggregate, Expand, Collapse, Tools, Trash, Library, Settings, Close
}

internal readonly record struct Shortcut(Key Key, ModifierKeys Modifiers)
{
    public override string ToString()
    {
        var modifiers = new[] { (ModifierKeys.Control, "Ctrl"), (ModifierKeys.Alt, "Alt"),
            (ModifierKeys.Shift, "Shift"), (ModifierKeys.Windows, "Win") };
        string key = Key switch
        {
            Key.OemComma => ",", Key.Oem3 => "\u0060", Key.Back => "Backspace", Key.Space => "Space",
            Key.Up => "↑", Key.Down => "↓", Key.Left => "←", Key.Right => "→",
            >= Key.D0 and <= Key.D9 => ((int)(Key - Key.D0)).ToString(), _ => Key.ToString()
        };
        var pressed = Modifiers;
        return Key == Key.None ? "" : string.Join("+", modifiers.Where(item => pressed.HasFlag(item.Item1))
            .Select(item => item.Item2).Append(key));
    }

    internal static bool TryParse(string text, out Shortcut shortcut)
    {
        shortcut = default;
        var pieces = text.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (pieces.Length == 0) return false;
        ModifierKeys modifiers = ModifierKeys.None;
        foreach (string piece in pieces.SkipLast(1))
        {
            ModifierKeys parsed = piece.ToLowerInvariant() switch
            {
                "ctrl" or "control" => ModifierKeys.Control, "shift" => ModifierKeys.Shift,
                "alt" => ModifierKeys.Alt, "win" or "windows" => ModifierKeys.Windows, _ => ModifierKeys.None
            };
            if (parsed == ModifierKeys.None || modifiers.HasFlag(parsed)) return false;
            modifiers |= parsed;
        }
        string token = pieces[^1] switch
        {
            "," => "OemComma", "\u0060" => "Oem3", "Backspace" => "Back", "↑" => "Up", "↓" => "Down", "←" => "Left", "→" => "Right",
            var item when item.Length == 1 && item[0] is >= '0' and <= '9' => "D" + item,
            var item => item
        };
        if (!Enum.TryParse(token, true, out Key key) || !Enum.IsDefined(key) || KeyInterop.VirtualKeyFromKey(key) == 0 ||
            key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
                or Key.LWin or Key.RWin or Key.Escape or Key.Tab) return false;
        shortcut = new(key, modifiers);
        return true;
    }
}

internal static class Shortcuts
{
    internal static readonly (Command Action, string Title, string Default)[] Entries =
    [
        (Command.ShowPanel, "Open quick panel", "Ctrl+Shift+V"),
        (Command.OpenClip, "Open selected clip", "Space"),
        (Command.Search, "Search", "Ctrl+F"),
        (Command.Paste, "Paste", "Enter"), (Command.Copy, "Copy", "Ctrl+C"),
        (Command.PastePlain, "Paste as plain text", "Alt+Enter"), (Command.CopyPlain, "Copy as text", "Ctrl+Alt+C"),
        (Command.Favorite, "Toggle favorite", "Ctrl+Shift+F"), (Command.Pin, "Toggle pin", "Ctrl+T"),
        (Command.Edit, "Edit information", "Ctrl+E"), (Command.AssignGroups, "Set groups", "Ctrl+G"),
        (Command.NewGroup, "New group", "Ctrl+Shift+N"), (Command.Aggregate, "Aggregate clips", "Ctrl+B"),
        (Command.Expand, "Expand aggregation", "Ctrl+↓"), (Command.Collapse, "Collapse aggregation", "Ctrl+↑"),
        (Command.Tools, "Quick actions", "Ctrl+Shift+K"), (Command.Trash, "Move to Trash", "Ctrl+Backspace"),
        (Command.Library, "Open library", "Ctrl+L"), (Command.Settings, "Settings", "Ctrl+,"),
        (Command.Close, "Close quick panel", "Ctrl+W")
    ];

    internal static readonly (string Title, Command[] Actions)[] Sections =
    [
        ("Global shortcut", [Command.ShowPanel]),
        ("Paste and copy", [Command.Paste, Command.Copy, Command.PastePlain, Command.CopyPlain]),
        ("Opening clips", [Command.OpenClip]),
        ("Search", [Command.Search]),
        ("Organize the selected clip", [Command.Tools, Command.Favorite, Command.Pin, Command.Edit, Command.AssignGroups,
            Command.NewGroup, Command.Aggregate, Command.Expand, Command.Collapse, Command.Trash]),
        ("Windows and pages", [Command.Library, Command.Settings, Command.Close])
    ];

    internal static string Text(LocalSettings settings, Command action) => ConfiguredText(settings, action.ToString(),
        action == Command.ShowPanel && settings.UseAlternateShortcut ? "Ctrl+Alt+V" : Entries.First(entry => entry.Action == action).Default);

    internal static string ConfiguredText(LocalSettings settings, string setting, string fallback)
    {
        if (settings.Shortcuts.TryGetValue(setting, out var configured)) return configured;
        return Shortcut.TryParse(fallback, out var shortcut) && settings.Shortcuts.Any(entry => entry.Key != setting &&
            Shortcut.TryParse(entry.Value, out var other) && other == shortcut) ? "" : fallback;
    }

    internal static bool Match(LocalSettings settings, Command action, Key key, ModifierKeys modifiers) =>
        Shortcut.TryParse(Text(settings, action), out var binding) && binding == new Shortcut(key, modifiers);
}
