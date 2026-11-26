using System;
using System.Collections.Generic;
using System.Linq;
using Pasteory.Core;

namespace Pasteory.Windows;

internal enum LinkHistorySection { All, Pending, Resolved, Rules, Connections }
internal enum LinkHistoryPeriod { All, Today, LastSevenDays, SelectedDay }
internal enum LinkHistoryIssue { All, NeedsLogin, CannotAccess }

internal sealed record LinkHistoryEntry(Clip Clip, Uri Url, string Title, string Address, string[] Applications,
    DateTimeOffset AddedAt, LinkDetails? Details, DateTimeOffset? LastResolvedAt)
{
    internal string Key => Clip.LinkResourceKey!;
    public string Status => Details?.Status ?? "Not attempted";
    public string Host => Url.IdnHost;
    internal DateTimeOffset ActivityAt => Details?.AttemptedAt ?? AddedAt;
    internal bool NeedsLogin => Status is "Sign-in required" or "Web verification required";
    public bool CannotAccess => Status is "Access forbidden" or "Page not found" or "Link blocked by policy";
    internal bool RetainsPreviousTitle => LastResolvedAt is not null && Status is not ("Resolved" or "Not attempted");
}

internal static class LinkHistory
{
    internal static (string Title, DateTimeOffset At)? LastSuccess(IEnumerable<Clip> clips)
    {
        (string Title, DateTimeOffset At)? latest = null;
        foreach (var clip in clips)
        {
            if (clip.LinkDetails is not { Title: { Length: > 0 } title } details) continue;
            DateTimeOffset? at = details.LastResolvedAt ?? (details.Status == "Resolved" ? details.AttemptedAt : null);
            if (at is { } resolved && (latest is null || resolved > latest.Value.At)) latest = (title, resolved);
        }
        return latest;
    }

    internal static LinkHistoryEntry[] Build(IReadOnlyList<Clip> clips) => clips
        .Where(clip => clip.TrashedAt is null && clip.LinkResourceKey is not null)
        .GroupBy(clip => clip.LinkResourceKey!, StringComparer.Ordinal)
        .Select(group =>
        {
            var copies = group.OrderByDescending(clip => clip.CapturedAt).ThenBy(clip => clip.Id).ToArray();
            var clip = copies[0];
            var url = new Uri(clip.Text!.Trim());
            string address = ClipCard.Short(LinkTitles.DisplayUrl(url).Replace("%E2%80%A2", "•", StringComparison.Ordinal), 512, 1);
            var details = copies.Select(item => item.LinkDetails).OfType<LinkDetails>().Where(item => item.Status != "Not attempted")
                .MaxBy(item => item.AttemptedAt);
            var success = LastSuccess(copies);
            string title = success?.Title ?? clip.LinkDetails?.FallbackTitle ?? clip.DisplayTitle;
            if (title.Length == 0) title = url.IdnHost;
            string[] apps = copies.SelectMany(item => item.Captures.Select(capture => capture.Source).Prepend(item.Source))
                .Where(source => !string.IsNullOrWhiteSpace(source)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            return new LinkHistoryEntry(clip, url, title, address, apps, copies.Min(item => item.CreatedAt ?? item.CapturedAt), details, success?.At);
        }).OrderByDescending(entry => entry.ActivityAt).ThenBy(entry => entry.Key, StringComparer.Ordinal).ToArray();

    internal static DateOnly Day(DateTimeOffset value) => DateOnly.FromDateTime(value.LocalDateTime);

    internal static string Diagnostics(int? status, int? durationMilliseconds)
    {
        var parts = new List<string>(2);
        if (status is { } http) parts.Add($"HTTP {http}");
        if (durationMilliseconds is { } duration) parts.Add(Labels.Format("{0:F2} s elapsed", duration / 1000d));
        return string.Join(" · ", parts);
    }

    internal static IEnumerable<LinkHistoryEntry> Filter(IEnumerable<LinkHistoryEntry> entries, LinkHistorySection section,
        LinkHistoryPeriod period, DateOnly selectedDay, LinkHistoryIssue issue, string search, DateTimeOffset now)
    {
        string query = search.Trim();
        var today = Day(now);
        var weekStart = today.AddDays(-6);
        return entries.Where(entry => (section switch
        {
            LinkHistorySection.Resolved => entry.Status == "Resolved",
            LinkHistorySection.Pending => entry.Status != "Resolved",
            _ => true
        }) && (issue switch
        {
            LinkHistoryIssue.NeedsLogin => entry.NeedsLogin,
            LinkHistoryIssue.CannotAccess => entry.CannotAccess,
            _ => true
        }) && (period switch
        {
            LinkHistoryPeriod.Today => Day(entry.ActivityAt) == today,
            LinkHistoryPeriod.LastSevenDays => Day(entry.ActivityAt) >= weekStart && Day(entry.ActivityAt) <= today,
            LinkHistoryPeriod.SelectedDay => Day(entry.ActivityAt) == selectedDay,
            _ => true
        }) && (query.Length == 0 || entry.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
            entry.Address.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
            entry.Applications.Any(app => app.Contains(query, StringComparison.CurrentCultureIgnoreCase))));
    }
}
