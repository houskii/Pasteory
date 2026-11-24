using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows.Markup;

namespace Pasteory.Windows;

[MarkupExtensionReturnType(typeof(string))]
public sealed class LabelExtension(string text) : MarkupExtension
{
    public override object ProvideValue(IServiceProvider serviceProvider) => Labels.Get(text);
}

internal static class Labels
{
    private static readonly bool Chinese = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh";

    private static readonly Dictionary<string, string> Translations = new()
    {
        ["Clipboard history"] = "剪贴板历史",
        ["Search clips"] = "搜索剪贴板",
        ["Search"] = "搜索",
        ["All groups"] = "所有分组",
        ["Favorites only"] = "只看收藏",
        ["All clips"] = "全部内容",
        ["No clips match."] = "没有匹配的内容。",
        ["Copy something to start your history."] = "复制一些内容，即可开始记录。",
        ["Select a clip to preview it."] = "请选择一条内容预览。",
        ["Text"] = "文本",
        ["Link"] = "链接",
        ["Image"] = "图片",
        ["Files"] = "文件",
        ["Rich text"] = "富文本",
        ["Pinned"] = "置顶",
        ["Favorite"] = "收藏",
        ["Edit details"] = "编辑详情",
        ["Delete"] = "删除",
        ["Paste"] = "粘贴",
        ["Copy"] = "复制",
        ["Copy as text"] = "复制为纯文本",
        ["Enter  Paste    Ctrl+C  Copy    Esc  Hide"] = "Enter 粘贴    Ctrl+C 复制    Esc 隐藏",
        ["Title"] = "标题",
        ["Group"] = "分组",
        ["Note"] = "备注",
        ["Save"] = "保存",
        ["Cancel"] = "取消",
        ["Settings"] = "设置",
        ["Pause clipboard capture"] = "暂停剪贴板记录",
        ["Resume clipboard capture"] = "恢复剪贴板记录",
        ["Use Ctrl+Alt+V instead of Ctrl+Shift+V"] = "使用 Ctrl+Alt+V 代替 Ctrl+Shift+V",
        ["Excluded process names, one per line (for example KeePassXC)"] = "排除的进程名，每行一个（例如 KeePassXC）",
        ["Clear unpinned and unfavorited history"] = "清除未置顶、未收藏的历史",
        ["Open data folder"] = "打开数据目录",
        ["Open history"] = "打开历史",
        ["Quit"] = "退出",
        ["Capture paused"] = "记录已暂停",
        ["Capture active · {0}"] = "正在记录 · {0}",
        ["Capture paused · {0}"] = "记录已暂停 · {0}",
        ["Clipboard monitoring could not start. Restart Pasteory to retry."] = "无法启动剪贴板监听，请重启 Pasteory 后重试。",
        ["The global shortcut is unavailable. Open history from the tray or change the shortcut in Settings."] = "全局快捷键不可用。可从托盘打开历史，或在设置中切换快捷键。",
        ["Clipboard copied."] = "已复制到剪贴板。",
        ["Copied. Press Ctrl+V in the destination app to paste."] = "已复制。请在目标应用按 Ctrl+V 粘贴。",
        ["The clipboard changed. Try again."] = "剪贴板内容已改变，请重试。",
        ["The history limit was reached. Shorten the title, group, or note."] = "历史记录已达上限，请缩短标题、分组名或备注。",
        ["The clipboard is busy. Try again."] = "剪贴板正忙，请重试。",
        ["The history limit was reached. Unpin or unfavorite a clip to make room."] = "历史记录已达上限，请取消一条记录的置顶或收藏以腾出空间。",
        ["Delete this clip from history?"] = "从历史记录删除这条内容？",
        ["Clear all clips that are neither pinned nor favorited?"] = "清除所有未置顶且未收藏的内容？",
        ["The saved image could not be opened."] = "无法打开已保存的图片。",
        ["Local data could not be opened at {0}."] = "无法打开本地数据，路径为 {0}。",
    };

    internal static string Get(string english) =>
        Chinese && Translations.TryGetValue(english, out var translation) ? translation : english;

    internal static string Format(string english, string value) => string.Format(Get(english), value);
}
