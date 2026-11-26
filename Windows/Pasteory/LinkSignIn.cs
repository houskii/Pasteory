using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed class LinkSignIn
{
    private sealed record PageMetadata(string? Title, string? DocumentTitle, bool HasLoginForm);
    private sealed record LoadedPage(Uri Url, int Status, bool Succeeded, string? Title, bool NeedsSignIn, bool Blocked = false);
    private readonly SemaphoreSlim queue = new(1);
    private int interactiveWindows;
    private TaskCompletionSource? cacheClearance;
    internal bool IsBusy => interactiveWindows != 0 || queue.CurrentCount == 0;
    internal event Action? BecameIdle;

    internal async Task<bool> ShowAsync(string root, LinkSignInRule rule, Window owner)
    {
        if (cacheClearance is { } clearing) await clearing.Task;
        interactiveWindows++;
        try { return await ShowWindowAsync(root, rule, owner); }
        finally
        {
            interactiveWindows--;
            SignalIdle();
        }
    }

    private async Task<bool> ShowWindowAsync(string root, LinkSignInRule rule, Window owner)
    {
        if (!Uri.TryCreate(rule.SignInUrl, UriKind.Absolute, out var uri) || !LinkResolver.Allowed(uri)) return false;
        var web = new WebView2();
        var window = new Window
        {
            Title = Labels.Get("Pasteory sign-in session") + " · " + rule.Name, Owner = owner, Width = 930, Height = 660,
            MinWidth = 500, MinHeight = 440, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false
        };
        var layout = new DockPanel();
        var toolbar = new DockPanel { Margin = new Thickness(11, 7, 11, 7) };
        var done = new Button { Content = Labels.Get("Finish sign-in"), IsEnabled = false };
        done.SetResourceReference(FrameworkElement.StyleProperty, "PrimaryButton");
        var status = Ui.Text(uri.GetLeftPart(UriPartial.Authority), 12, "Muted");
        status.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(done, Dock.Right);
        toolbar.Children.Add(done);
        toolbar.Children.Add(status);
        DockPanel.SetDock(toolbar, Dock.Top);
        layout.Children.Add(toolbar);
        layout.Children.Add(web);
        window.Content = layout;
        var result = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        window.Closed += (_, _) => { web.Dispose(); result.TrySetResult(false); };
        done.Click += (_, _) => { result.TrySetResult(true); window.Close(); };
        window.Show();
        try
        {
            var environment = await CreateEnvironment(root, rule);
            if (result.Task.IsCompleted) return false;
            await web.EnsureCoreWebView2Async(environment);
            if (result.Task.IsCompleted) return false;
            var core = web.CoreWebView2;
            Configure(core, interactive: true);
            core.SourceChanged += (_, _) =>
            {
                if (Uri.TryCreate(core.Source, UriKind.Absolute, out var current) && LinkResolver.Allowed(current))
                    status.Text = current.GetLeftPart(UriPartial.Authority);
            };
            core.NavigationCompleted += (_, e) => done.IsEnabled = e.IsSuccess;
            core.Navigate(uri.AbsoluteUri);
        }
        catch (Exception error) when (WebError(error))
        {
            if (result.Task.IsCompleted) return false;
            status.Text = Labels.Get("WebView2 could not start.");
            toolbar.ToolTip = error.Message;
        }
        return await result.Task;
    }

    internal async Task<LinkDetails> ResolveAsync(string root, LinkSignInRule rule, Uri uri, nint parent, CancellationToken cancel)
    {
        var page = await LoadPageAsync(root, rule, uri, parent, refresh: false, cancel);
        if (page is { NeedsSignIn: true } || page?.Status is 401 or 403)
            return new("Sign-in required", null, DateTimeOffset.UtcNow, "Pasteory session", "Login or error page");
        if (page is not { Succeeded: true, Status: < 400 })
            return new("Could not resolve the link", null, DateTimeOffset.UtcNow, "Pasteory session");
        return LinkResolver.AssessTitle(page.Title, page.Url, "Pasteory session");
    }

    internal async Task<LinkSessionOutcome> RefreshAsync(string root, LinkSignInRule rule, Uri uri, nint parent, CancellationToken cancel)
    {
        var page = await LoadPageAsync(root, rule, uri, parent, refresh: true, cancel);
        if (page?.Blocked == true) return LinkSessionOutcome.Blocked;
        if (page is { NeedsSignIn: true } || page?.Status == 401) return LinkSessionOutcome.NeedsSignIn;
        return page is { Succeeded: true, Status: < 400 } && !string.IsNullOrWhiteSpace(page.Title)
            ? LinkSessionOutcome.PageLoaded : LinkSessionOutcome.Failed;
    }

    private async Task<LoadedPage?> LoadPageAsync(string root, LinkSignInRule rule, Uri uri, nint parent, bool refresh,
        CancellationToken cancel)
    {
        if (!LinkResolver.Allowed(uri)) return new(uri, 0, false, null, false, Blocked: true);
        await queue.WaitAsync(cancel);
        CoreWebView2Controller? controller = null;
        try
        {
            var environment = await CreateEnvironment(root, rule);
            controller = await environment.CreateCoreWebView2ControllerAsync(parent);
            controller.IsVisible = false;
            var core = controller.CoreWebView2;
            var result = new TaskCompletionSource<CoreWebView2NavigationCompletedEventArgs?>(TaskCreationOptions.RunContinuationsAsynchronously);
            bool blocked = false;
            Configure(core, interactive: false, onBlocked: () =>
            {
                blocked = true;
                result.TrySetResult(null);
            });
            core.NavigationCompleted += (_, args) => result.TrySetResult(args);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(TimeSpan.FromSeconds(14));
            if (refresh)
                core.NavigateWithWebResourceRequest(environment.CreateWebResourceRequest(uri.AbsoluteUri, "GET", null,
                    "Cache-Control: no-cache\r\nPragma: no-cache"));
            else core.Navigate(uri.AbsoluteUri);
            var response = await result.Task.WaitAsync(timeout.Token);
            if (response is { IsSuccess: true, HttpStatusCode: < 400 }) await Task.Delay(refresh ? 900 : 350, timeout.Token);
            Uri final = Uri.TryCreate(core.Source, UriKind.Absolute, out var loaded) ? loaded : uri;
            if (blocked || response is null) return new(final, 0, false, null, false, Blocked: true);
            if (!response.IsSuccess || response.HttpStatusCode >= 400)
                return new(final, response.HttpStatusCode, false, null, LinkResolver.IsSignInPage(null, final));
            const string inspect = """
                (() => ({
                    Title: (document.querySelector('meta[property="og:title"]')?.content || document.title || '').slice(0, 1024),
                    DocumentTitle: (document.title || '').slice(0, 1024),
                    HasLoginForm: [...document.querySelectorAll('input[type="password"]')].some(input => input.getClientRects().length > 0)
                }))()
                """;
            string selected = await core.ExecuteScriptAsync(inspect).WaitAsync(timeout.Token);
            var metadata = JsonSerializer.Deserialize<PageMetadata>(selected);
            bool needsSignIn = metadata?.HasLoginForm == true || LinkResolver.IsSignInPage(metadata?.DocumentTitle, final);
            return new(final, response.HttpStatusCode, true, metadata?.Title, needsSignIn);
        }
        catch (Exception error) when (WebError(error) || error is JsonException ||
            error is OperationCanceledException && !cancel.IsCancellationRequested)
        {
            return null;
        }
        finally
        {
            try { controller?.Close(); }
            finally { queue.Release(); SignalIdle(); }
        }
    }

    internal async Task ClearAsync(string root, LinkSignInRule rule, nint parent)
    {
        await queue.WaitAsync();
        CoreWebView2Controller? controller = null;
        try
        {
            if (!Directory.Exists(Folder(root, rule))) return;
            var environment = await CreateEnvironment(root, rule);
            controller = await environment.CreateCoreWebView2ControllerAsync(parent);
            controller.IsVisible = false;
            await controller.CoreWebView2.Profile.ClearBrowsingDataAsync();
        }
        finally
        {
            try { controller?.Close(); }
            finally { queue.Release(); SignalIdle(); }
        }
    }

    internal async Task<int?> ClearNetworkCachesAsync(string root, nint parent, CancellationToken cancellation)
    {
        await queue.WaitAsync(cancellation);
        try
        {
            if (interactiveWindows != 0) return null;
            cacheClearance = new(TaskCreationOptions.RunContinuationsAsynchronously);
            int cleaned = 0;
            foreach (string folder in ExistingProfiles(root))
            {
                cancellation.ThrowIfCancellationRequested();
                var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: folder);
                var controller = await environment.CreateCoreWebView2ControllerAsync(parent);
                try
                {
                    controller.IsVisible = false;
                    await controller.CoreWebView2.Profile.ClearBrowsingDataAsync(CoreWebView2BrowsingDataKinds.DiskCache);
                    cleaned++;
                }
                finally { controller.Close(); }
            }
            return cleaned;
        }
        finally
        {
            cacheClearance?.TrySetResult();
            cacheClearance = null;
            queue.Release();
        }
    }

    internal static long NetworkCacheBytes(string root)
    {
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint
        };
        return ExistingProfiles(root).SelectMany(profile => Directory.EnumerateFiles(profile, "*", options).Where(path =>
            Path.GetRelativePath(profile, path).Split(Path.DirectorySeparatorChar).SkipLast(1)
                .Any(part => part is "Cache" or "Code Cache"))).Sum(LocalStorage.AllocatedBytes);
    }

    private static IEnumerable<string> ExistingProfiles(string root)
    {
        string sessions = Path.Combine(root, "web-sessions");
        var parent = new DirectoryInfo(sessions);
        if (!parent.Exists || parent.Attributes.HasFlag(FileAttributes.ReparsePoint)) yield break;
        foreach (var folder in parent.EnumerateDirectories())
        {
            if (Guid.TryParseExact(folder.Name, "N", out _) && !folder.Attributes.HasFlag(FileAttributes.ReparsePoint))
                yield return folder.FullName;
        }
    }

    private void SignalIdle()
    {
        if (!IsBusy) BecameIdle?.Invoke();
    }

    private static Task<CoreWebView2Environment> CreateEnvironment(string root, LinkSignInRule rule) =>
        CoreWebView2Environment.CreateAsync(userDataFolder: Folder(root, rule));
    private static string Folder(string root, LinkSignInRule rule) => Path.Combine(root, "web-sessions", rule.Id.ToString("N"));

    internal static bool WebError(Exception error) => error is COMException or WebView2RuntimeNotFoundException or
        InvalidOperationException or ArgumentException or IOException or UnauthorizedAccessException;

    private static void Configure(CoreWebView2 core, bool interactive, Action? onBlocked = null)
    {
        core.Settings.IsWebMessageEnabled = false;
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = interactive;
        core.NavigationStarting += (_, args) =>
        {
            if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) && LinkResolver.Allowed(uri)) return;
            args.Cancel = true;
            onBlocked?.Invoke();
        };
        core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
        core.DownloadStarting += (_, args) => { args.Cancel = true; args.Handled = true; };
        core.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            if (interactive && Uri.TryCreate(args.Uri, UriKind.Absolute, out var target) && LinkResolver.Allowed(target))
                core.Navigate(target.AbsoluteUri);
        };
    }
}
