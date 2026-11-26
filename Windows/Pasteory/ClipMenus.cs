using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Pasteory.Core;

namespace Pasteory.Windows;

internal static class ClipMenus
{
    internal static ContextMenu Tools(App app, Clip? clip)
    {
        var menu = new ContextMenu();
        AddTools(menu, app, clip);
        menu.Opened += (_, _) =>
        {
            if (menu.Items.Count > 0 && menu.Items[0] is MenuItem first) first.Focus();
        };
        return menu;
    }

    private static void AddTools(ItemsControl menu, App app, Clip? clip)
    {
        foreach (var tool in Enum.GetValues<TextTool>())
            Add(menu, ToolLabel(tool), () => app.ConvertClip(clip!, tool), enabled: clip?.PlainText is { Length: > 0 });
    }

    internal static string ToolLabel(TextTool tool) => tool switch
    {
        TextTool.Base64Encode => "Base64 encode", TextTool.Base64Decode => "Base64 decode", TextTool.Md5 => "MD5",
        TextTool.RgbaToHex => "RGBA → HEX", TextTool.HexToRgba => "HEX → RGBA",
        TextTool.UrlEncode => "URL encode", _ => "URL decode"
    };

    internal static ContextMenu ForClip(App app, ClipCard row, Window owner,
        Action edit, Action groups, Action aggregate, Action activate)
    {
        var menu = new ContextMenu();
        var clip = row.Clip;
        if (clip.TrashedAt is not null)
        {
            Add(menu, "Restore", () => app.RestoreClip(clip));
            Add(menu, "Delete permanently", () =>
            {
                if (Confirm(owner, "Delete this clip permanently?")) app.EraseClip(clip);
            });
            return menu;
        }

        if (clip.Kind == ClipKind.Aggregate)
        {
            Add(menu, "Expand aggregation", activate, Shortcuts.Text(app.Settings, Command.Expand));
            Add(menu, "Edit aggregation", aggregate);
            Add(menu, "Favorite all members", () => app.FavoriteMembers(clip));
        }
        else
        {
            Add(menu, "Open", activate, Shortcuts.Text(app.Settings, Command.OpenClip));
            Add(menu, "Paste", () => _ = app.UseClipAsync(clip, true, false), Shortcuts.Text(app.Settings, Command.Paste));
            Add(menu, "Copy", () => _ = app.UseClipAsync(clip, false, false), Shortcuts.Text(app.Settings, Command.Copy));
            Add(menu, "Paste as plain text", () => _ = app.UseClipAsync(clip, true, true),
                Shortcuts.Text(app.Settings, Command.PastePlain), clip.PlainText is { Length: > 0 });
            Add(menu, "Copy as text", () => _ = app.UseClipAsync(clip, false, true),
                Shortcuts.Text(app.Settings, Command.CopyPlain), clip.PlainText is { Length: > 0 });
            var tools = new MenuItem { Header = Labels.Get("Quick actions"), IsEnabled = clip.PlainText is { Length: > 0 } };
            AddTools(tools, app, clip);
            menu.Items.Add(tools);
        }
        menu.Items.Add(new Separator());
        Add(menu, "Edit information", edit, Shortcuts.Text(app.Settings, Command.Edit));
        Add(menu, "Set groups", groups, Shortcuts.Text(app.Settings, Command.AssignGroups));
        Add(menu, clip.Favorite ? "Remove favorite" : "Favorite", () => app.ToggleFavorite(clip),
            Shortcuts.Text(app.Settings, Command.Favorite));
        Add(menu, clip.Pinned ? "Unpin" : "Pin", () => app.TogglePin(clip), Shortcuts.Text(app.Settings, Command.Pin));
        Add(menu, clip.ArchivedAt is null ? "Archive clip" : "Move out of archive", () => app.ToggleArchive(clip));
        if (clip.Kind != ClipKind.Aggregate && app.Settings.Ai.Enabled)
            Add(menu, clip.ExcludeFromAi ? "Include in AI analysis" : "Exclude from AI analysis",
                () => app.UpdateClip(clip.Id, current => current with { ExcludeFromAi = !current.ExcludeFromAi }));
        if (row.Parent is { } parent) Add(menu, "Remove from aggregation", () => app.RemoveMember(parent, clip.Id));
        menu.Items.Add(new Separator());
        Add(menu, "Move to Trash", () => app.TrashClip(clip), Shortcuts.Text(app.Settings, Command.Trash));
        return menu;
    }

    internal static ContextMenu ForGroup(ClipCollection group, Action edit, Action delete)
    {
        var menu = new ContextMenu();
        Add(menu, group.IsSmart ? "Edit smart group" : "Rename group", edit);
        Add(menu, "Delete group", delete);
        return menu;
    }

    internal static void Add(ItemsControl menu, string label, Action onClick, string? key = null, bool enabled = true)
    {
        var item = new MenuItem { Header = Labels.Get(label), InputGestureText = key ?? "", IsEnabled = enabled };
        item.Click += (_, _) => onClick();
        menu.Items.Add(item);
    }

    internal static bool Confirm(Window owner, string text) => MessageBox.Show(owner, Labels.Get(text), "Pasteory",
        MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) == MessageBoxResult.Yes;
}
