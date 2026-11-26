using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text.RegularExpressions;
using Pasteory.Core;

namespace Pasteory.Windows;

internal static partial class LinkTitles
{
    private sealed record Rule(string Host, string Path, string Title, string? QueryKey = null);
    private static readonly Rule[] BuiltIn =
    [
        new("bits.bytedance.net", "/devops/{projectID}/code/detail/{mergeRequestID}", "BITS MR · {mergeRequestID}"),
        new("code.byted.org", "/{group}/{project}/merge_requests/{mergeRequestID}", "{project} MR · !{mergeRequestID}"),
        new("bits.bytedance.net", "/space/legacy/build/logs", "报告流水线 · {jobId}", "jobId"),
        new("cloud.bytedance.net", "/tos/bucket/{bucketID}/overview", "TOS Bucket · {bucketID}"),
        new("*.larkoffice.com", "/wiki/{wikiToken}", "飞书 Wiki · {wikiToken}"),
        new("www.zhihu.com", "/question/{questionID}/answer/{answerID}", "知乎回答 · {answerID}"),
        new("mp.weixin.qq.com", "/s/{articleToken}", "微信公众号文章")
    ];
    private static readonly string[] Sensitive = ["token", "code", "ticket", "sign", "auth", "session", "key", "credential"];
    internal static IReadOnlyList<LinkSignInRule> BuiltInSignIns { get; } =
    [
        new(new("601866b8-819a-4e5d-ad13-ff5f6f760ac2"), "BITS", @"^bits\.bytedance\.net(?:/|$)", "https://bits.bytedance.net/"),
        new(new("31a7e958-d0b2-445d-a7ff-cf44d89c2284"), "Feishu", @"^(?:[^./]+\.)*larkoffice\.com(?:/|$)", "https://bytedance.larkoffice.com/"),
        new(new("b45cc1d9-2a5d-44d2-9336-fdc95346b9a1"), "Codebase", @"^code\.byted\.org(?:/|$)", "https://code.byted.org/")
    ];
    internal static bool IsBuiltInSignIn(LinkSignInRule rule) => BuiltInSignIns.Any(preset => preset.Id == rule.Id);

    internal static LinkDetails? UpdateFallback(Clip clip, IReadOnlyList<LinkFallbackRule> userRules)
    {
        if (!Uri.TryCreate(clip.Text?.Trim(), UriKind.Absolute, out var url) || !LinkResolver.Allowed(url))
            return clip.LinkDetails;
        var current = clip.LinkDetails ?? new("Not attempted", null, clip.CapturedAt);
        var (title, source, route) = Fallback(url, userRules);
        bool legacyFallback = current.LastResolvedAt is null && current.Quality == "Fallback title";
        return current with
        {
            Title = legacyFallback ? null : current.Title,
            LastResolvedAt = current.LastResolvedAt ?? (current.Status == "Resolved" ? current.AttemptedAt : null),
            FallbackTitle = title,
            FallbackSource = source,
            Route = route
        };
    }

    internal static LinkDetails RecordAttempt(Clip clip, LinkDetails result, IReadOnlyList<LinkFallbackRule> rules)
    {
        var current = UpdateFallback(clip, rules) ?? new LinkDetails("Not attempted", null, clip.CapturedAt);
        bool resolved = result.Status == "Resolved" && !string.IsNullOrEmpty(result.Title);
        var attempt = new LinkAttempt(result.Status, result.AttemptedAt, result.Source, result.Quality);
        return result with
        {
            Title = resolved ? result.Title : current.Title,
            LastResolvedAt = resolved ? result.AttemptedAt : current.LastResolvedAt,
            FallbackTitle = current.FallbackTitle,
            FallbackSource = current.FallbackSource,
            Route = current.Route,
            Attempts = [attempt, .. (current.Attempts ?? []).Take(31)]
        };
    }

    private static (string Title, string Source, string Route) Fallback(Uri url, IReadOnlyList<LinkFallbackRule> rules)
    {
        var query = QueryItems(url);
        string[] segments = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.UnescapeDataString).ToArray();
        string? inferred = null;
        string? builtInTitle = null;
        foreach (var rule in BuiltIn)
        {
            if (Match(rule, url, segments, query) is not { } matched) continue;
            inferred = rule.Path;
            builtInTitle = matched;
            break;
        }
        inferred ??= "/" + string.Join("/", segments.Select((value, index) =>
            VariableSegment(value) ? "{segment" + (index + 1) + "}" : value));
        string route = url.IdnHost + inferred;

        // Match captures against the redacted query so a title template cannot display a query credential.
        var safeUrl = new Uri(DisplayUrl(url));
        foreach (var rule in rules)
        {
            var match = LinkResolver.MatchRule(rule.Pattern, safeUrl);
            string? title = null;
            try { if (match is not null) title = LinkResolver.NormalizeTitle(match.Result(rule.Title)); }
            catch (ArgumentException) { }
            if (title is not null) return (Uri.UnescapeDataString(title), "User fallback", route);
        }
        if (builtInTitle is not null) return (builtInTitle, "Built-in fallback", route);
        string host = url.IdnHost.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? url.IdnHost[4..] : url.IdnHost;
        string? last = segments.LastOrDefault();
        return (last is null ? host : host + " · " + ClipCard.Short(last, 48, 1), "URL fallback", route);
    }

    private static string? Match(Rule rule, Uri url, string[] segments, Dictionary<string, string> query)
    {
        bool wildcard = rule.Host.StartsWith("*.", StringComparison.Ordinal);
        string host = wildcard ? rule.Host[2..] : rule.Host;
        if (url.IdnHost != host && (!wildcard || !url.IdnHost.EndsWith("." + host, StringComparison.Ordinal))) return null;
        string[] template = rule.Path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (template.Length != segments.Length) return null;
        var values = new Dictionary<string, string>();
        for (int index = 0; index < segments.Length; index++)
        {
            if (template[index].StartsWith('{')) values[template[index][1..^1]] = segments[index];
            else if (template[index] != segments[index]) return null;
        }
        if (rule.QueryKey is { } key)
        {
            if (!query.TryGetValue(key, out var value) || value.Length == 0) return null;
            values[key] = SensitiveName(key) ? "••••" : value;
        }
        return LinkResolver.NormalizeTitle(Template().Replace(rule.Title, match => values.GetValueOrDefault(match.Groups[1].Value, "")));
    }

    private static bool VariableSegment(string value) =>
        value.All(char.IsDigit) || Guid.TryParse(value, out _) || value.Length >= 20 &&
            value.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_');

    private static Dictionary<string, string> QueryItems(Uri url)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string item in url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            string[] pair = item.Split('=', 2);
            string key = WebUtility.UrlDecode(pair[0]);
            values.TryAdd(key, pair.Length == 2 ? WebUtility.UrlDecode(pair[1]) : "");
        }
        return values;
    }

    internal static string DisplayUrl(Uri url)
    {
        var builder = new UriBuilder(url) { Fragment = "" };
        var query = QueryItems(url);
        if (query.Count == 0) return builder.Uri.AbsoluteUri;
        builder.Query = string.Join("&", query.Select(entry => Uri.EscapeDataString(entry.Key) + "=" +
            Uri.EscapeDataString(SensitiveName(entry.Key) ? "••••" : entry.Value)));
        return builder.Uri.AbsoluteUri;
    }

    internal static string RulePattern(string route)
    {
        string path = route.Split('?', 2)[0];
        return "^" + string.Concat(path.Split('/').Select((part, index) => (index == 0 ? "" : "/") +
            (part.StartsWith('{') && part.EndsWith('}') ? "([^/?]+)" :
                Regex.Escape(index == 0 ? part : Uri.EscapeDataString(part))))) + "/?(?:\\?|$)";
    }

    private static bool SensitiveName(string key) => Sensitive.Any(value => key.Contains(value, StringComparison.OrdinalIgnoreCase));

    [GeneratedRegex(@"\{([a-zA-Z][a-zA-Z0-9]*)\}")]
    private static partial Regex Template();
}
