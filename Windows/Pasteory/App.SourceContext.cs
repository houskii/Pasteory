using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using Pasteory.Core;

namespace Pasteory.Windows;

public partial class App
{
    private readonly List<ChromeSelection> chromeSelections = [];

    private CaptureEvent ReadSourceContext(Clip clip)
    {
        var capture = new CaptureEvent(clip.CapturedAt, clip.Source);
        if (Settings.IncludeBrowserContext && clip.Source.Equals("chrome", StringComparison.OrdinalIgnoreCase))
        {
            chromeSelections.RemoveAll(entry => (DateTimeOffset.UtcNow - entry.Time).Duration().TotalSeconds > 6);
            int match = chromeSelections.FindLastIndex(entry => entry.Matches(clip, clip.CapturedAt));
            if (match >= 0)
            {
                capture = chromeSelections[match].Apply(capture);
                chromeSelections.RemoveAt(match);
            }
        }
        if (Settings.IncludeChatContext && clip.Source.ToLowerInvariant() is "wechat" or "weixin" or "feishu" or "lark")
        {
            nint handle = NativeMethods.GetForegroundWindow();
            uint processId = NativeMethods.ProcessId(handle);
            try
            {
                using var foreground = Process.GetProcessById((int)processId);
                if (!foreground.ProcessName.Equals(clip.Source, StringComparison.OrdinalIgnoreCase)) return capture;
                string title = NativeMethods.WindowTitle(handle).Trim();
                if (title.Length > 0 && !new[] { "WeChat", "Weixin", "Lark", "Feishu", "微信", "飞书" }
                    .Contains(title, StringComparer.OrdinalIgnoreCase))
                    capture = capture with { Context = title };
            }
            catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        return capture;
    }

    private Task ChromeEventAsync(ChromeSelection selection) => Dispatcher.InvokeAsync(() =>
    {
        if (Exiting || Settings.Paused || !Settings.IncludeBrowserContext || Settings.ShouldIgnore("chrome")) return;
        foreach (var clip in Clips.Take(12))
        {
            var capture = clip.Captures.FirstOrDefault();
            if (capture is null || capture.Url is not null || !selection.Matches(clip, capture.CapturedAt)) continue;
            UpdateClip(clip.Id, current => current with { Captures = [selection.Apply(capture), .. current.Captures.Skip(1)] });
            return;
        }
        if (chromeSelections.Count >= 16) chromeSelections.RemoveAt(0);
        chromeSelections.Add(selection);
    }).Task;

    internal void PrepareChromeExtension()
    {
        try
        {
            string executable = Environment.ProcessPath ?? throw new IOException("Pasteory executable is unavailable.");
            if (isolated) throw new IOException(Labels.Get("Prepare Chrome from the regular Pasteory session."));
            if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                executable = Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location)!, "Pasteory.exe");
            string folder = ChromeBridge.Register(dataDirectory, executable);
            OpenInShell(folder);
            if (Settings.BrowserPath is { } browser && Path.GetFileName(browser).Equals("chrome.exe", StringComparison.OrdinalIgnoreCase))
                StartApp(browser, "chrome://extensions");
            Notify(Labels.Format("Chrome extension prepared at {0}", folder));
        }
        catch (Exception error) when (IsLocalError(error) || error is System.Security.SecurityException or System.ComponentModel.Win32Exception)
        { Notify(error.Message); }
    }
}
