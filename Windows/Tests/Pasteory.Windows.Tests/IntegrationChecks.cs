using System;
using System.Buffers.Binary;
using System.Diagnostics;
using System.IO;
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

    private static void CheckLinkEngine()
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var frame = new DispatcherFrame();
        var test = dispatcher.InvokeAsync(TestLinkEngineAsync).Task.Unwrap();
        _ = test.ContinueWith(_ => dispatcher.BeginInvoke(new Action(() => frame.Continue = false)),
            CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
        Dispatcher.PushFrame(frame);
        test.GetAwaiter().GetResult();
    }

    private static async Task TestLinkEngineAsync()
    {
        string root = Directory.CreateTempSubdirectory("Pasteory-WebView-QA-").FullName;
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(24));
        using var server = new TcpListener(IPAddress.Loopback, 0);
        server.Start();
        int port = ((IPEndPoint)server.LocalEndpoint).Port;
        var serve = Task.Run(async () =>
        {
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    using var connection = await server.AcceptTcpClientAsync(stop.Token);
                    await using var stream = connection.GetStream();
                    using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
                    string? first = await reader.ReadLineAsync(stop.Token);
                    if (first is null) continue;
                    string? line;
                    bool hasSession = false;
                    while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync(stop.Token)))
                        hasSession |= line.Contains("pasteory_qa=1", StringComparison.Ordinal);
                    bool signin = first.StartsWith("GET /session ", StringComparison.Ordinal);
                    bool needsSession = first.StartsWith("GET /private ", StringComparison.Ordinal);
                    int status = needsSession && !hasSession ? 401 : 200;
                    string title = signin ? "Sign-in test fixture" : needsSession ? "Authenticated sample" : "Anonymous sample";
                    const string type = "Content-Type: text/html; charset=utf-8\r\n";
                    var body = Encoding.UTF8.GetBytes($"<!doctype html><title>{title}</title>");
                    string cookie = signin ? "Set-Cookie: pasteory_qa=1; Path=/; Max-Age=120\r\n" : "";
                    var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {(status == 200 ? "OK" : "Unauthorized")}\r\n{type}{cookie}Content-Length: {body.Length}\r\nConnection: close\r\n\r\n");
                    await stream.WriteAsync(head, stop.Token);
                    await stream.WriteAsync(body, stop.Token);
                }
            }
            catch (Exception error) when (error is OperationCanceledException or IOException) { }
        });
        var host = new Window { Width = 1, Height = 1, ShowInTaskbar = false, ShowActivated = false, Opacity = 0 };
        try
        {
            string url = $"http://127.0.0.1:{port}";
            var anonymous = new LinkResolver();
            var publicTitle = await anonymous.ResolveAsync(url + "/public", stop.Token);
            Check(publicTitle.Title == "Anonymous sample", "Resolve anonymous title by HTTP");
            Check((await anonymous.ResolveAsync(url + "/private", stop.Token)).Status == "Sign-in required", "Detect an authenticated page");
            var sessions = new LinkSignIn();
            nint hwnd = new WindowInteropHelper(host).EnsureHandle();
            var rule = new LinkSignInRule(Guid.NewGuid(), "QA", "127", url + "/session", true);
            await sessions.ResolveAsync(root, rule, new Uri(url + "/session"), hwnd, stop.Token);
            var authenticated = await sessions.ResolveAsync(root, rule, new Uri(url + "/private"), hwnd, stop.Token);
            Check(authenticated.Title == "Authenticated sample", "Keep WebView2 site cookies in the isolated resolution profile");
            Check((await anonymous.ResolveAsync(url + "/private", stop.Token)).Status == "Sign-in required", "Separate anonymous link requests from WebView2 cookies");
            Console.WriteLine("Anonymous and isolated WebView2 link resolution passed.");
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
}
