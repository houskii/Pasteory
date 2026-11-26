using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Interop;
using Pasteory.Core;

namespace Pasteory.Windows;

public partial class App
{
    private readonly HashSet<Guid> refreshingLinkSessions = [];
    private bool checkingLinkSessions;

    private void StartLinkSessionRefresh()
    {
        var rules = Settings.LinkSignIns;
        var now = DateTimeOffset.UtcNow;
        if (rules.Any(rule => rule.Enabled && rule.Refresh.ScheduledFrom is null))
        {
            var migrated = rules.Select(rule => rule.Enabled && rule.Refresh.ScheduledFrom is null
                ? rule with { Refresh = rule.Refresh with { ScheduledFrom = now } } : rule).ToArray();
            SaveSettings(Settings with { LinkSignIns = migrated });
        }
        _ = CheckDueLinkSessionsAsync();
    }

    internal LinkSignInRule? FindLinkSignInRule(Guid id) => Settings.LinkSignIns.FirstOrDefault(rule => rule.Id == id) ??
        LinkTitles.BuiltInSignIns.FirstOrDefault(rule => rule.Id == id);

    internal bool IsRefreshingLinkSession(Guid id) => refreshingLinkSessions.Contains(id);

    internal bool SaveLinkSignInRule(LinkSignInRule rule)
    {
        var current = Settings.LinkSignIns;
        var updated = current.Any(item => item.Id == rule.Id) ? current.Select(item => item.Id == rule.Id ? rule : item).ToArray() :
            [.. current, rule];
        return SaveSettings(Settings with { LinkSignIns = updated });
    }

    internal async Task CheckDueLinkSessionsAsync()
    {
        if (Exiting || !Settings.ResolveLinks || checkingLinkSessions || LinkSessions.IsBusy) return;
        checkingLinkSessions = true;
        try
        {
            foreach (Guid id in Settings.LinkSignIns.Where(rule => rule.Enabled).Select(rule => rule.Id).ToArray())
            {
                if (Exiting || !Settings.ResolveLinks || LinkSessions.IsBusy) return;
                await RefreshLinkSessionAsync(id, dueOnly: true);
            }
        }
        finally { checkingLinkSessions = false; }
    }

    internal async Task RefreshLinkSessionAsync(Guid id, bool dueOnly = false)
    {
        if (Exiting || FindLinkSignInRule(id) is not { Enabled: true } rule) return;
        var started = DateTimeOffset.UtcNow;
        if (dueOnly && (rule.Refresh.NextRefreshAt() is not { } due || due > started)) return;
        if (!refreshingLinkSessions.Add(id)) return;
        try
        {
            if (!SaveLinkSignInRule(rule with { Refresh = rule.Refresh with { LastAttemptAt = started } })) return;
            settingsWindow?.UpdateLinkSessionRows();
            LinkSessionOutcome result = LinkSessionOutcome.Blocked;
            if (Uri.TryCreate(rule.SignInUrl, UriKind.Absolute, out var uri) && LinkResolver.Allowed(uri))
            {
                nint parent = new WindowInteropHelper(window).EnsureHandle();
                result = await LinkSessions.RefreshAsync(dataDirectory, rule, uri, parent, lifetime.Token);
            }
            if (Exiting || FindLinkSignInRule(id) is not { Enabled: true } latest ||
                latest.SignInUrl != rule.SignInUrl || latest.Refresh.LastAttemptAt != started) return;
            SaveLinkSignInRule(latest with
            {
                Refresh = latest.Refresh with
                {
                    Outcome = result,
                    LastRefreshedAt = result == LinkSessionOutcome.PageLoaded ? DateTimeOffset.UtcNow : latest.Refresh.LastRefreshedAt
                }
            });
        }
        catch (OperationCanceledException) when (Exiting) { }
        finally
        {
            refreshingLinkSessions.Remove(id);
            if (!Exiting) settingsWindow?.UpdateLinkSessionRows();
        }
    }
}
