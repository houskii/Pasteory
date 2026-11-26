using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using Pasteory.Core;

namespace Pasteory.Windows;

internal static partial class ChatContext
{
    private static int probing;

    internal static bool IsChatApp(string source) =>
        LocalSettings.SourceApplication(source) is SourceCaptureApplication.WeChat or SourceCaptureApplication.Feishu;

    internal static async Task<CaptureEvent?> InspectAsync(nint window, CaptureEvent capture, CancellationToken cancellation)
    {
        if (window == 0 || Interlocked.CompareExchange(ref probing, 1, 0) != 0) return null;
        var probe = Task.Run(() =>
        {
            try { return Inspect(window, capture); }
            catch (Exception error) when (error is ElementNotAvailableException or InvalidOperationException or
                ArgumentException or COMException or UnauthorizedAccessException) { return null; }
            finally { Volatile.Write(ref probing, 0); }
        });
        try { return await probe.WaitAsync(TimeSpan.FromMilliseconds(325), cancellation).ConfigureAwait(false); }
        catch (TimeoutException) { return null; }
    }

    private static CaptureEvent? Inspect(nint window, CaptureEvent capture)
    {
        bool weChat = LocalSettings.SourceApplication(capture.Source) == SourceCaptureApplication.WeChat;
        var root = AutomationElement.FromHandle(window);
        string[] titleIds = weChat ? ["current_chat_name_label", "ChatHeaderTitle"] : ["chatWindow_chatName"];
        var headerTitle = FindNamed(root, titleIds);
        if (headerTitle is null || string.IsNullOrWhiteSpace(headerTitle.Current.Name)) return null;
        string title = headerTitle.Current.Name.Trim();
        var header = TreeWalker.RawViewWalker.GetParent(headerTitle);
        int? participants = null;
        bool callOrBot = false;
        if (header is not null)
        {
            if (!weChat && FindNamed(header, ["chatNewWindow_count"], budget: 45) is { } count &&
                CountText().Match(count.Current.Name) is { Success: true } match &&
                int.TryParse(match.Value, out int number)) participants = number;
            callOrBot = FindNamed(header, weChat ? ["voip_button"] : ["chatWindow_botCount"], budget: 45) is not null;
        }
        return FromHeader(capture, title, participants, callOrBot, weChat);
    }

    internal static CaptureEvent FromHeader(CaptureEvent capture, string title, int? participants, bool callOrBot, bool weChat)
    {
        var bracketed = CountSuffix().Match(title);
        if (bracketed.Success && int.TryParse(bracketed.Groups[1].Value, out int count))
        {
            participants ??= count;
            title = title[..bracketed.Index].TrimEnd();
        }
        if (title.Length == 0) return capture;
        var details = capture.Details is null ? new Dictionary<string, string>() : new(capture.Details);
        details["conversationType"] = weChat ? participants is > 1 ? "group" : callOrBot ? "direct" : "unknown"
            : participants is > 2 || callOrBot ? "group" : participants is 2 ? "direct" : "unknown";
        if (participants is { } value) details["participantCount"] = value.ToString(System.Globalization.CultureInfo.InvariantCulture);
        details["strategy"] = weChat ? "wechat.uia.conversation.v1" : "lark.uia.conversation.v1";
        return capture with { Context = ClipCard.Short(title, 256, 1), Details = details };
    }

    private static AutomationElement? FindNamed(AutomationElement root, string[] identities, int budget = 1500)
    {
        var deadline = Stopwatch.StartNew();
        var walker = TreeWalker.RawViewWalker;
        var pending = new Stack<AutomationElement>();
        pending.Push(root);
        while (pending.Count > 0 && budget-- > 0 && deadline.ElapsedMilliseconds < 270)
        {
            var node = pending.Pop();
            var info = node.Current;
            if (Array.Exists(identities, id => id == info.AutomationId || id == info.ClassName))
                return node;
            for (var child = walker.GetFirstChild(node); child is not null && pending.Count < budget &&
                deadline.ElapsedMilliseconds < 270; child = walker.GetNextSibling(child))
                pending.Push(child);
        }
        return null;
    }

    [GeneratedRegex(@"[(（]\s*([0-9]+)\s*[)）]\s*$")]
    private static partial Regex CountSuffix();

    [GeneratedRegex(@"[0-9]+")]
    private static partial Regex CountText();
}
