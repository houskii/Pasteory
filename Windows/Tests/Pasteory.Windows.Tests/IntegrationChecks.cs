using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Pasteory.Core;
using Pasteory.Windows;

internal static partial class Program
{
    private static async Task CheckChromeBridgeAsync(string executable)
    {
        string root = Directory.CreateTempSubdirectory("Pasteory-Chrome-QA-").FullName;
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        var captured = new TaskCompletionSource<ChromeSelection>(TaskCreationOptions.RunContinuationsAsynchronously);
        new LocalSettings { IncludeBrowserContext = true, Language = "English" }.Save(root);
        Task reading = ChromeBridge.ReceiveAsync(root, item => { captured.TrySetResult(item); return Task.CompletedTask; }, stop.Token);
        try
        {
            var start = new ProcessStartInfo(Path.GetFullPath(executable))
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true
            };
            start.ArgumentList.Add("--chrome-native-messaging-host");
            start.ArgumentList.Add("--data-root");
            start.ArgumentList.Add(root);
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start the native messaging host.");
            try
            {
                using var config = await Exchange(new { type = "getConfig", requestId = "config" });
                Check(config.RootElement.GetProperty("chromeEnabled").GetBoolean(), "Native messaging host reads app privacy settings");
                Check(ChromeBridge.Status(root) is { Registered: false, LastContact: not null },
                    "A native messaging handshake records contact in the isolated data directory");
                using var ack = await Exchange(new
                {
                    type = "capture", requestId = "capture", payload = new
                    {
                        capturedAt = DateTimeOffset.UtcNow, selectedText = "Synthetic browser selection",
                        url = "https://example.com/synthetic", pageTitle = "Test page", adapter = new { repository = "demo" }
                    }
                });
                Check(ack.RootElement.GetProperty("ok").GetBoolean(), "Native messaging host acknowledges the bounded context message");
                var context = await captured.Task.WaitAsync(stop.Token);
                var clip = new Clip { Source = "chrome", Text = context.Text };
                Check(context.Matches(clip, clip.CapturedAt) && context.Details["repository"] == "demo" &&
                    !context.Matches(clip with { Source = "Other" }, clip.CapturedAt),
                    "Forward Chrome context and match it only to a corresponding capture");
                process.StandardInput.Close();
                await process.WaitForExitAsync(stop.Token);
                Console.WriteLine("The packaged Chrome bridge completed a native messaging round trip.");

                async Task<JsonDocument> Exchange(object message)
                {
                    var input = process.StandardInput.BaseStream;
                    var payload = JsonSerializer.SerializeToUtf8Bytes(message);
                    var header = new byte[4];
                    BinaryPrimitives.WriteInt32LittleEndian(header, payload.Length);
                    await input.WriteAsync(header, stop.Token);
                    await input.WriteAsync(payload, stop.Token);
                    await input.FlushAsync(stop.Token);
                    var output = process.StandardOutput.BaseStream;
                    await output.ReadExactlyAsync(header, stop.Token);
                    int length = BinaryPrimitives.ReadInt32LittleEndian(header);
                    Check(length is > 0 and < 16384, "Native messaging response stays within bounds");
                    var data = new byte[length];
                    await output.ReadExactlyAsync(data, stop.Token);
                    return JsonDocument.Parse(data);
                }
            }
            finally
            {
                if (!process.HasExited)
                {
                    process.Kill();
                    process.WaitForExit(3000);
                }
            }
        }
        finally
        {
            await stop.CancelAsync();
            await reading;
            Directory.Delete(root, recursive: true);
        }
    }

    private static void CheckLinkEngine(string? executable)
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var frame = new DispatcherFrame();
        var test = dispatcher.InvokeAsync(() => TestLinkEngineAsync(executable)).Task.Unwrap();
        _ = test.ContinueWith(_ => dispatcher.BeginInvoke(new Action(() => frame.Continue = false)),
            CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
        Dispatcher.PushFrame(frame);
        test.GetAwaiter().GetResult();
    }

    private static async Task TestLinkEngineAsync(string? executable)
    {
        string root = Directory.CreateTempSubdirectory("Pasteory-WebView-QA-").FullName;
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(44));
        using var server = new TcpListener(IPAddress.Loopback, 0);
        server.Start();
        int port = ((IPEndPoint)server.LocalEndpoint).Port;
        int cacheRequests = 0;
        int requests = 0;
        int blockedRequests = 0;

        async Task RespondAsync(TcpClient connection)
        {
            using (connection)
            using (var requestDeadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token))
            {
                requestDeadline.CancelAfter(TimeSpan.FromSeconds(5));
                var token = requestDeadline.Token;
                try
                {
                    await using var stream = connection.GetStream();
                    using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
                    string? first = await reader.ReadLineAsync(token);
                    if (first?.Split(' ', 3) is not { Length: 3 } request) return;
                    Interlocked.Increment(ref requests);
                    string? line;
                    bool hasSession = false;
                    while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync(token)))
                        hasSession |= line.Contains("pasteory_qa=1", StringComparison.Ordinal);
                    string path = request[1];
                    bool signin = path == "/session";
                    bool cacheable = path == "/cache";
                    if (path == "/logout") Interlocked.Increment(ref blockedRequests);
                    if (cacheable) Interlocked.Increment(ref cacheRequests);
                    int status = path switch
                    {
                        "/redirect-to-action" => 302, "/unavailable" => 503, "/timed-out" => 504, "/missing" => 404,
                        "/forbidden" => 403, "/private" when !hasSession => 401, _ => 200
                    };
                    string title = path switch
                    {
                        "/verification" => "Checking your browser", "/session" => "Sign-in test fixture",
                        "/private" => "Authenticated sample", _ => "Anonymous sample"
                    };
                    const string type = "Content-Type: text/html; charset=utf-8\r\n";
                    string form = path == "/account" ? "<form><input type='password' aria-label='Synthetic test field'></form>" : "";
                    var body = Encoding.UTF8.GetBytes($"<!doctype html><title>{title}</title>{form}");
                    string cookie = signin ? "Set-Cookie: pasteory_qa=1; Path=/; Max-Age=120\r\n" : "";
                    string cache = cacheable ? "Cache-Control: public, max-age=3600\r\n" : "Cache-Control: no-store\r\n";
                    string location = status == 302 ? "Location: /logout\r\n" : "";
                    var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {(status == 200 ? "OK" : "Fixture")}\r\n{type}{cookie}{cache}{location}Content-Length: {body.Length}\r\nConnection: close\r\n\r\n");
                    await stream.WriteAsync(head, token);
                    await stream.WriteAsync(body, token);
                }
                catch (Exception error) when (error is OperationCanceledException or IOException) { }
            }
        }
        var serve = Task.Run(async () =>
        {
            // Chromium can open a connection before it is ready to send a request.
            var connections = new List<Task>();
            try
            {
                while (!stop.IsCancellationRequested)
                    connections.Add(RespondAsync(await server.AcceptTcpClientAsync(stop.Token)));
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
            await Task.WhenAll(connections);
        });
        var host = new Window { Width = 1, Height = 1, ShowInTaskbar = false, ShowActivated = false, Opacity = 0 };
        try
        {
            string url = $"http://127.0.0.1:{port}";
            var policy = new LinkAccessPolicy { FixtureOrigin = new(url) };
            var anonymous = new LinkResolver(policy);
            var normal = new LinkResolver(new());
            Check((await normal.ResolveAsync(url + "/public", stop.Token)) is { Status: "Link blocked by policy", HttpStatus: null } &&
                (await anonymous.ResolveAsync(url + "/%6Cogout", stop.Token)).Status == "Link blocked by policy" &&
                Volatile.Read(ref requests) == 0, "Block the local origin and encoded action paths before any HTTP request");
            Check(!policy.Allows(new Uri("https://[::ffff:192.168.0.1]/")) &&
                !policy.Allows(new Uri("https://[fd12:abcd::1]/")) && !policy.Allows(new Uri("https://intranet.local./")) &&
                !policy.Allows(new Uri("https://example.invalid/unsubscribe")), "Apply local address and unsafe path policies outside the fixture origin");
            var publicTitle = await anonymous.ResolveAsync(url + "/public", stop.Token);
            Check(publicTitle is { Title: "Anonymous sample", HttpStatus: 200, DurationMilliseconds: >= 0 }, "Resolve anonymous title with status and timing");
            (string Path, string Status, int Http)[] failures = [("private", "Sign-in required", 401), ("forbidden", "Access forbidden", 403),
                ("missing", "Page not found", 404), ("timed-out", "Request timed out", 504), ("unavailable", "Link network error", 503),
                ("verification", "Web verification required", 200), ("redirect-to-action", "Link blocked by policy", 302)];
            foreach (var (path, issue, status) in failures)
            {
                var failure = await anonymous.ResolveAsync(url + "/" + path, stop.Token);
                Check(failure.Status == issue && failure.HttpStatus == status && failure.DurationMilliseconds is >= 0,
                    "Report the HTTP diagnostic for " + path);
            }
            Check(Volatile.Read(ref blockedRequests) == 0, "Reject blocked redirects without requesting their destination");
            var sessions = new LinkSignIn(policy);
            nint hwnd = new WindowInteropHelper(host).EnsureHandle();
            var rule = new LinkSignInRule(Guid.NewGuid(), "QA", "127", url + "/session", true);
            await sessions.ResolveAsync(root, rule, new Uri(url + "/session"), hwnd, stop.Token);
            var authenticated = await sessions.ResolveAsync(root, rule, new Uri(url + "/private"), hwnd, stop.Token);
            Check(authenticated is { Title: "Authenticated sample", HttpStatus: 200, DurationMilliseconds: >= 0 },
                "Keep WebView2 site cookies in the isolated profile and record the response diagnostic");
            Check((await sessions.ResolveAsync(root, rule, new Uri(url + "/missing"), hwnd, stop.Token)) is
                { Status: "Page not found", HttpStatus: 404, DurationMilliseconds: >= 0 }, "Diagnose WebView2 HTTP errors");
            var redirected = await sessions.ResolveAsync(root, rule, new Uri(url + "/redirect-to-action"), hwnd, stop.Token);
            int actions = Volatile.Read(ref blockedRequests);
            Check(redirected is { Status: "Link blocked by policy", HttpStatus: 302 } && actions == 0,
                $"Apply the access boundary to WebView2 redirects (status {redirected.Status}, HTTP {redirected.HttpStatus}, {actions} action requests)");
            var cacheUrl = new Uri(url + "/cache");
            await sessions.ResolveAsync(root, rule, cacheUrl, hwnd, stop.Token);
            await sessions.ResolveAsync(root, rule, cacheUrl, hwnd, stop.Token);
            Check(Volatile.Read(ref cacheRequests) == 1 && LinkSignIn.NetworkCacheBytes(root) > 0, "Use and measure the WebView2 network cache");
            Check(await sessions.ClearNetworkCachesAsync(root, hwnd, stop.Token) == 1, "Clear network cache for the managed profile");
            await sessions.ResolveAsync(root, rule, cacheUrl, hwnd, stop.Token);
            Check(Volatile.Read(ref cacheRequests) == 2 && (await sessions.ResolveAsync(root, rule, new Uri(url + "/private"), hwnd, stop.Token)).Title == "Authenticated sample",
                "Refetch a cached page while keeping the authenticated session");
            Check((await anonymous.ResolveAsync(url + "/private", stop.Token)).Status == "Sign-in required", "Separate anonymous link requests from WebView2 cookies");
            Check(await sessions.RefreshAsync(root, rule, cacheUrl, hwnd, stop.Token) == LinkSessionOutcome.PageLoaded &&
                Volatile.Read(ref cacheRequests) == 3, "Contact the site for session refresh even when its page is cached");
            (Uri Address, LinkSessionOutcome Expected)[] refreshes = [(new(url + "/private"), LinkSessionOutcome.PageLoaded),
                (new(url + "/account"), LinkSessionOutcome.NeedsSignIn), (new(url + "/unavailable"), LinkSessionOutcome.Failed),
                (new("file:///test.html"), LinkSessionOutcome.Blocked)];
            foreach (var (address, expected) in refreshes)
            {
                var actual = await sessions.RefreshAsync(root, rule, address, hwnd, stop.Token);
                Check(actual == expected, $"Refresh {address.AbsolutePath}: expected {expected}, got {actual}");
            }
            Console.WriteLine("Anonymous title resolution, WebView2 login, cache clearance and session refresh checks passed.");
            if (executable is not null) await CheckPackagedLinkRefreshAsync(executable, root, url, rule, stop.Token);
        }
        finally
        {
            host.Close();
            await stop.CancelAsync();
            await serve;
            try { Directory.Delete(root, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static async Task CheckPackagedLinkRefreshAsync(string executable, string root, string url, LinkSignInRule signedIn,
        CancellationToken cancel)
    {
        var now = DateTimeOffset.UtcNow;
        var due = new LinkSessionRefresh().Reset(now.AddDays(-16));
        var valid = signedIn with { SignInUrl = url + "/private", Refresh = due };
        var expired = valid with { Id = Guid.NewGuid(), Name = "Expired session" };
        var unavailable = valid with { Id = Guid.NewGuid(), Name = "Temporary failure", SignInUrl = url + "/unavailable" };
        var later = valid with { Id = Guid.NewGuid(), Name = "Future session", Refresh = due.Reset(now) };
        var legacy = new LinkSignInRule(Guid.NewGuid(), "Existing session", "127", url + "/private", true);
        new LocalSettings { ResolveLinks = true, AutomaticWebCacheCleanup = false, LinkSignIns = [valid, expired, unavailable, later, legacy] }.Save(root);
        var start = new ProcessStartInfo(Path.GetFullPath(executable)) { UseShellExecute = false, CreateNoWindow = true };
        foreach (string arg in new[] { "--data-root", root, "--no-hotkey", "--no-capture", "--tray", "--qa-link-origin", url }) start.ArgumentList.Add(arg);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not launch scheduled session refresh test.");
        try
        {
            while (!cancel.IsCancellationRequested)
            {
                Check(!process.HasExited, "The packaged app stays running while refreshing sessions");
                LocalSettings? observed;
                using (var settings = new FileStream(Path.Combine(root, "settings.json"), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    observed = JsonSerializer.Deserialize<LocalSettings>(settings);
                var results = observed!.LinkSignIns.ToDictionary(rule => rule.Id, rule => rule.Refresh);
                if (results[unavailable.Id].Outcome is not null)
                {
                    Check(results[valid.Id] is { Outcome: LinkSessionOutcome.PageLoaded, LastRefreshedAt: not null } &&
                        results[expired.Id].Outcome == LinkSessionOutcome.NeedsSignIn && results[expired.Id].NextRefreshAt() is null &&
                        results[unavailable.Id].Outcome == LinkSessionOutcome.Failed &&
                        results[unavailable.Id].NextRefreshAt() == results[unavailable.Id].LastAttemptAt?.AddHours(1) &&
                        results[later.Id].LastAttemptAt is null && results[legacy.Id] is { ScheduledFrom: not null, LastSignedInAt: null, LastAttemptAt: null },
                        "Persist startup outcomes, keep browser profiles separate, and schedule legacy connections without inventing a sign-in time");
                    Console.WriteLine("The portable app refreshed due sessions on startup and persisted the per-site schedules and outcomes.");
                    return;
                }
                await Task.Delay(150, cancel);
            }
            throw new InvalidOperationException("The packaged session refresh did not finish.");
        }
        finally
        {
            if (!process.HasExited) { process.Kill(); process.WaitForExit(3000); }
        }
    }
}
