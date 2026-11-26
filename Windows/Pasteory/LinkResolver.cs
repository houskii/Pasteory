using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed partial class LinkResolver(LinkAccessPolicy access)
{
    private readonly HashSet<string> running = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim concurrency = new(2);
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, AutomaticDecompression = DecompressionMethods.All,
        MaxResponseHeadersLength = 32
    }) { Timeout = Timeout.InfiniteTimeSpan };

    internal bool TryStart(string key) => running.Add(key);
    internal bool IsRunning(string key) => running.Contains(key);
    internal void Finish(string key) => running.Remove(key);

    internal async Task<LinkDetails> ResolveAsync(string input, CancellationToken cancellation)
    {
        if (!Uri.TryCreate(input.Trim(), UriKind.Absolute, out var uri) || !LinkAccessPolicy.IsWebAddress(uri))
            return new("Invalid link", null, DateTimeOffset.UtcNow);
        if (!access.Allows(uri)) return new("Link blocked by policy", null, DateTimeOffset.UtcNow, "Anonymous", DurationMilliseconds: 0);
        await concurrency.WaitAsync(cancellation);
        var elapsed = Stopwatch.StartNew();
        int? httpStatus = null;
        LinkDetails Complete(LinkDetails details) => details with { HttpStatus = httpStatus, DurationMilliseconds = (int)elapsed.ElapsedMilliseconds };
        LinkDetails Failure(string status) => Complete(new(status, null, DateTimeOffset.UtcNow, "Anonymous"));
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            timeout.CancelAfter(TimeSpan.FromSeconds(8));
            for (int hop = 0; hop < 5; hop++)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, uri);
                request.Headers.Accept.ParseAdd("text/html,application/xhtml+xml;q=0.9");
                request.Headers.UserAgent.ParseAdd("Pasteory/1.0");
                using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                httpStatus = (int)response.StatusCode;
                if (httpStatus is >= 300 and < 400 && response.Headers.Location is { } location && Uri.TryCreate(uri, location, out var destination))
                {
                    if (!access.Allows(destination)) return Failure("Link blocked by policy");
                    uri = destination;
                    continue;
                }
                if (HttpFailure(httpStatus) is { } failure) return Failure(failure);
                if (IsVerificationPage(null, uri)) return Failure("Web verification required");
                string? type = response.Content.Headers.ContentType?.MediaType;
                if (type is not null && type is not ("text/html" or "application/xhtml+xml")) return Failure("No page title");
                await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
                var bytes = new byte[256 * 1024];
                int size = await stream.ReadAtLeastAsync(bytes, bytes.Length, false, timeout.Token);
                var encoding = Encoding.UTF8;
                if (response.Content.Headers.ContentType?.CharSet?.Trim('"') is { Length: > 0 } charset)
                {
                    try { encoding = Encoding.GetEncoding(charset); }
                    catch (ArgumentException) { }
                }
                return Complete(AssessTitle(ReadTitle(encoding.GetString(bytes, 0, size)), uri, "Anonymous"));
            }
            return Failure("Too many redirects");
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { return Failure("Request timed out"); }
        catch (Exception error) when (error is HttpRequestException or IOException)
        {
            return Failure("Link network error");
        }
        finally { concurrency.Release(); }
    }

    internal static string? HttpFailure(int? status) => status switch
    {
        null or 0 or >= 200 and < 300 => null,
        401 => "Sign-in required", 403 => "Access forbidden", 404 => "Page not found",
        408 or 504 => "Request timed out", _ => "Link network error"
    };

    internal static string? ReadTitle(string html)
    {
        foreach (Match meta in MetaTags().Matches(html))
        {
            var attributes = Attributes().Matches(meta.Value);
            string? type = null, content = null;
            foreach (Match item in attributes)
            {
                string value = item.Groups[2].Success ? item.Groups[2].Value : item.Groups[3].Value;
                switch (item.Groups[1].Value.ToLowerInvariant())
                {
                    case "content": content = value; break;
                    case "property" or "name": type = value.ToLowerInvariant(); break;
                }
            }
            if (content is not null && type is "og:title" or "twitter:title") return NormalizeTitle(WebUtility.HtmlDecode(content));
        }
        var match = Title().Match(html);
        return match.Success ? NormalizeTitle(WebUtility.HtmlDecode(match.Groups[1].Value)) : null;
    }

    internal static string? NormalizeTitle(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        string title = Whitespace().Replace(raw, " ").Trim();
        return title.Length == 0 ? null : title[..Math.Min(title.Length, 220)];
    }

    internal static LinkDetails AssessTitle(string? candidate, Uri finalUrl, string source)
    {
        string? title = NormalizeTitle(candidate);
        if (IsVerificationPage(title, finalUrl))
            return new("Web verification required", null, DateTimeOffset.UtcNow, source, "Login or error page");
        if (IsSignInPage(title, finalUrl))
            return new("Sign-in required", null, DateTimeOffset.UtcNow, source, "Login or error page");
        if (string.IsNullOrEmpty(title)) return new("No page title", null, DateTimeOffset.UtcNow, source);
        if (ForbiddenTitle().IsMatch(title)) return new("Access forbidden", null, DateTimeOffset.UtcNow, source, "Login or error page");
        string brand = finalUrl.Host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? finalUrl.Host[4..] : finalUrl.Host;
        bool shell = title.Equals(brand, StringComparison.OrdinalIgnoreCase) ||
            title.Equals(brand.Split('.')[0], StringComparison.OrdinalIgnoreCase) ||
            brand == "cloud.bytedance.net" && (title.Equals("ByteCloud", StringComparison.OrdinalIgnoreCase) ||
                title.Equals("ByteCloud Console", StringComparison.OrdinalIgnoreCase));
        if (finalUrl.AbsolutePath.Length > 1 && shell)
            return new("Generic page title", null, DateTimeOffset.UtcNow, source, "Generic");
        return new("Resolved", title, DateTimeOffset.UtcNow, source, "Distinctive");
    }

    internal static bool IsSignInPage(string? title, Uri url) =>
        LoginRoute().IsMatch(url.AbsolutePath) || title is not null && LoginTitle().IsMatch(title);

    internal static bool IsVerificationPage(string? title, Uri url) =>
        url.IdnHost == "mp.weixin.qq.com" && url.AbsolutePath.Contains("appmsgcaptcha", StringComparison.OrdinalIgnoreCase) ||
        title is not null && VerificationTitle().IsMatch(title);

    internal static Match? MatchRule(string pattern, Uri link)
    {
        try
        {
            var match = Regex.Match(link.IdnHost + link.PathAndQuery, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant,
                TimeSpan.FromMilliseconds(120));
            return match.Success ? match : null;
        }
        catch (Exception error) when (error is ArgumentException or RegexMatchTimeoutException) { return null; }
    }

    [GeneratedRegex(@"<title(?:\s[^>]*)?>\s*([^<]{1,3000})</title\s*>", RegexOptions.IgnoreCase)]
    private static partial Regex Title();
    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();
    [GeneratedRegex(@"<meta\b[^>]{1,2000}>", RegexOptions.IgnoreCase)]
    private static partial Regex MetaTags();
    [GeneratedRegex(@"([-\w]+)\s*=\s*(?:""([^""]*)""|'([^']*)')", RegexOptions.IgnoreCase)]
    private static partial Regex Attributes();
    [GeneratedRegex(@"^\s*(?:sign in|log in|login|authentication required|请登录|登录|统一身份认证)(?:\s|$|[|·–—-])",
        RegexOptions.IgnoreCase)]
    private static partial Regex LoginTitle();
    [GeneratedRegex(@"^\s*(?:just a moment|checking your browser|安全验证|请完成安全验证)(?:\s|$|[.!|·–—-])", RegexOptions.IgnoreCase)]
    private static partial Regex VerificationTitle();
    [GeneratedRegex(@"^\s*(?:access denied|forbidden|访问受限|没有访问权限)(?:\s|$|[.!|·–—-])", RegexOptions.IgnoreCase)]
    private static partial Regex ForbiddenTitle();
    [GeneratedRegex(@"(?:^|/)(?:login|login\.html|log-in|signin|sign-in|oauth/authorize)(?:/|$)", RegexOptions.IgnoreCase)]
    private static partial Regex LoginRoute();
}
