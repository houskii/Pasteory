using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed partial class LinkResolver
{
    private readonly HashSet<Guid> running = [];
    private readonly SemaphoreSlim concurrency = new(2);
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, AutomaticDecompression = DecompressionMethods.All,
        MaxResponseHeadersLength = 32
    }) { Timeout = Timeout.InfiniteTimeSpan };

    internal bool TryStart(Guid id) => running.Add(id);
    internal void Finish(Guid id) => running.Remove(id);

    internal async Task<LinkDetails> ResolveAsync(string input, CancellationToken cancellation)
    {
        if (!Uri.TryCreate(input.Trim(), UriKind.Absolute, out var uri) || !Allowed(uri))
            return Failure("Invalid link");
        await concurrency.WaitAsync(cancellation);
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
                if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } location &&
                    Uri.TryCreate(uri, location, out var destination) && Allowed(destination))
                {
                    uri = destination;
                    continue;
                }
                if (!response.IsSuccessStatusCode) return Failure(response.StatusCode switch
                {
                    HttpStatusCode.Unauthorized => "Sign-in required", HttpStatusCode.Forbidden => "Access forbidden",
                    HttpStatusCode.NotFound => "Page not found", _ => $"HTTP {(int)response.StatusCode}"
                });
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
                return AssessTitle(ReadTitle(encoding.GetString(bytes, 0, size)), uri, "Anonymous");
            }
            return Failure("Too many redirects");
        }
        catch (Exception error) when (error is HttpRequestException or IOException ||
            error is OperationCanceledException && !cancellation.IsCancellationRequested)
        {
            return Failure("Could not resolve the link");
        }
        finally { concurrency.Release(); }
    }

    internal static bool Allowed(Uri uri) => uri.Scheme is "http" or "https" && uri.UserInfo.Length == 0;
    private static LinkDetails Failure(string status) => new(status, null, DateTimeOffset.UtcNow);

    internal static string? ReadTitle(string html)
    {
        foreach (Match meta in MetaTags().Matches(html))
        {
            var attributes = Attributes().Matches(meta.Value);
            string? type = null, content = null;
            foreach (Match item in attributes)
            {
                string value = item.Groups[2].Success ? item.Groups[2].Value : item.Groups[3].Value;
                if (item.Groups[1].Value.Equals("content", StringComparison.OrdinalIgnoreCase)) content = value;
                if (item.Groups[1].Value is "property" or "name") type = value.ToLowerInvariant();
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
        if (string.IsNullOrEmpty(title)) return Failure("No page title");
        if (LoginTitle().IsMatch(title) || LoginRoute().IsMatch(finalUrl.AbsolutePath))
            return new("Sign-in required", null, DateTimeOffset.UtcNow, source, "Login or error page");
        string brand = finalUrl.Host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? finalUrl.Host[4..] : finalUrl.Host;
        if (finalUrl.AbsolutePath.Length > 1 && (title.Equals(brand, StringComparison.OrdinalIgnoreCase) ||
            title.Equals(brand.Split('.')[0], StringComparison.OrdinalIgnoreCase)))
            return new("Generic page title", null, DateTimeOffset.UtcNow, source, "Generic");
        return new("Resolved", title, DateTimeOffset.UtcNow, source, "Distinctive");
    }

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
    [GeneratedRegex(@"^\s*(?:sign in|log in|login|access denied|forbidden|just a moment|请登录|登录|访问受限)(?:\s|$|[|·–—-])",
        RegexOptions.IgnoreCase)]
    private static partial Regex LoginTitle();
    [GeneratedRegex(@"(?:^|/)(?:login|signin|sign-in|oauth/authorize)(?:/|$)", RegexOptions.IgnoreCase)]
    private static partial Regex LoginRoute();
}
