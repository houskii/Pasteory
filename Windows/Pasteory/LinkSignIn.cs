using System;
using System.IO;
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
    private readonly SemaphoreSlim queue = new(1);

    internal async Task<bool> ShowAsync(string root, LinkSignInRule rule, Window owner)
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
        await queue.WaitAsync(cancel);
        CoreWebView2Controller? controller = null;
        try
        {
            var environment = await CreateEnvironment(root, rule);
            controller = await environment.CreateCoreWebView2ControllerAsync(parent);
            controller.IsVisible = false;
            var core = controller.CoreWebView2;
            Configure(core, interactive: false);
            var result = new TaskCompletionSource<CoreWebView2NavigationCompletedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
            core.NavigationCompleted += (_, args) => result.TrySetResult(args);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(TimeSpan.FromSeconds(14));
            core.Navigate(uri.AbsoluteUri);
            var response = await result.Task.WaitAsync(timeout.Token);
            if (!response.IsSuccess || response.HttpStatusCode >= 400)
                return new(response.HttpStatusCode is 401 or 403 ? "Sign-in required" : "Could not resolve the link", null,
                    DateTimeOffset.UtcNow, "Pasteory session");
            await Task.Delay(350, timeout.Token);
            string selected = await core.ExecuteScriptAsync(
                "document.querySelector('meta[property=\"og:title\"]')?.content || document.title || ''").WaitAsync(timeout.Token);
            string? title = JsonSerializer.Deserialize<string>(selected);
            return LinkResolver.AssessTitle(title, Uri.TryCreate(core.Source, UriKind.Absolute, out var final) ? final : uri,
                "Pasteory session");
        }
        catch (Exception error) when (WebError(error) || error is JsonException ||
            error is OperationCanceledException && !cancel.IsCancellationRequested)
        {
            return new("Could not resolve the link", null, DateTimeOffset.UtcNow, "Pasteory session");
        }
        finally
        {
            controller?.Close();
            queue.Release();
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
            controller?.Close();
            queue.Release();
        }
    }

    private static Task<CoreWebView2Environment> CreateEnvironment(string root, LinkSignInRule rule) =>
        CoreWebView2Environment.CreateAsync(userDataFolder: Folder(root, rule));
    private static string Folder(string root, LinkSignInRule rule) => Path.Combine(root, "web-sessions", rule.Id.ToString("N"));

    internal static bool WebError(Exception error) => error is COMException or WebView2RuntimeNotFoundException or
        InvalidOperationException or ArgumentException or IOException or UnauthorizedAccessException;

    private static void Configure(CoreWebView2 core, bool interactive)
    {
        core.Settings.IsWebMessageEnabled = false;
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = interactive;
        core.NavigationStarting += (_, args) =>
            args.Cancel = !Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) || !LinkResolver.Allowed(uri);
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
