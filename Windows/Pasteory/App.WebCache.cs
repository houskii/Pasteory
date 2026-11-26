using System;
using System.Threading.Tasks;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Pasteory.Windows;

public partial class App
{
    private const long WebCacheLimit = 100_000_000;
    private readonly DispatcherTimer webCacheIdle = new() { Interval = TimeSpan.FromSeconds(2) };
    private bool webCacheChecking;
    private bool manualWebCacheRequest;
    internal bool IsClearingWebCache { get; private set; }
    internal bool WebCacheWaiting => manualWebCacheRequest;
    internal event Action? WebCacheChanged;

    private void StartWebCache()
    {
        LinkSessions.BecameIdle += ScheduleWebCacheCheck;
        webCacheIdle.Tick += (_, _) =>
        {
            webCacheIdle.Stop();
            _ = CheckWebCacheAsync();
        };
        ScheduleWebCacheCheck();
    }

    private void StopWebCache()
    {
        webCacheIdle.Stop();
        LinkSessions.BecameIdle -= ScheduleWebCacheCheck;
    }

    private void ScheduleWebCacheCheck()
    {
        if (Exiting || !Settings.AutomaticWebCacheCleanup && !manualWebCacheRequest) return;
        webCacheIdle.Stop();
        webCacheIdle.Start();
    }

    internal void RequestWebCacheCleanup()
    {
        if (IsClearingWebCache || manualWebCacheRequest || Exiting) return;
        manualWebCacheRequest = true;
        WebCacheChanged?.Invoke();
        _ = CheckWebCacheAsync();
    }

    private async Task CheckWebCacheAsync()
    {
        if (Exiting || webCacheChecking || LinkSessions.IsBusy ||
            !manualWebCacheRequest && !Settings.AutomaticWebCacheCleanup) return;
        webCacheChecking = true;
        bool report = manualWebCacheRequest;
        try
        {
            long size = manualWebCacheRequest ? 0 : await Task.Run(() => LinkSignIn.NetworkCacheBytes(dataDirectory), lifetime.Token);
            if (Exiting || LinkSessions.IsBusy) return;
            report = manualWebCacheRequest;
            var now = DateTimeOffset.UtcNow;
            bool due = Settings.AutomaticWebCacheCleanup && size > 0 && (size > WebCacheLimit ||
                Settings.LastWebCacheCleanup is not { } previous || now - previous >= TimeSpan.FromDays(1));
            if (!manualWebCacheRequest && !due) return;

            manualWebCacheRequest = false;
            IsClearingWebCache = true;
            WebCacheChanged?.Invoke();
            nint parent = new WindowInteropHelper(window).EnsureHandle();
            int? profiles = await LinkSessions.ClearNetworkCachesAsync(dataDirectory, parent, lifetime.Token);
            if (Exiting) return;
            if (profiles is null)
            {
                manualWebCacheRequest = report;
                return;
            }
            if (profiles > 0) SaveSettings(Settings with { LastWebCacheCleanup = DateTimeOffset.UtcNow });
            if (report) Notify(profiles > 0 ? "Web cache cleared." : "No web cache to clear.");
        }
        catch (OperationCanceledException) when (Exiting) { }
        catch (Exception error) when (LinkSignIn.WebError(error))
        {
            report |= manualWebCacheRequest;
            manualWebCacheRequest = false;
            if (report && !Exiting) Notify(error.Message);
        }
        finally
        {
            IsClearingWebCache = false;
            webCacheChecking = false;
            WebCacheChanged?.Invoke();
        }
    }
}
