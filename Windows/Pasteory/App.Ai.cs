using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Pasteory.Core;

namespace Pasteory.Windows;

public partial class App
{
    internal AiTasks Ai { get; private set; } = null!;
    internal CancellationToken AppToken => lifetime.Token;
    internal bool CanUndoAi => history.CanUndoAi;
    internal bool CanManageAiGroups => !Exiting && !compressingContent && !Ai.Running &&
        Ai.Review is null && Ai.Job(false)?.Status != "Paused";
    private DateTimeOffset lastAutoOrganization;
    private DateOnly? lastIdleDay;
    private DateOnly? idleLimitReached;
    private DateTimeOffset idleRunStarted;
    private bool systemSuspended;

    internal async Task RunAiAsync(bool story, string trigger, bool resume = false, IReadOnlySet<Guid>? queued = null,
        bool automatic = false, AiGroupSnapshot[]? replacing = null)
    {
        try
        {
            if (trigger is "idle" or "review" || resume && Ai.Job(story)?.Trigger is "idle" or "review")
                idleRunStarted = DateTimeOffset.Now;
            bool chinese = Labels.Get("Settings") != "Settings";
            if (resume) await Ai.ResumeAsync(Settings.Ai, Clips, Collections, story, chinese, lifetime.Token, automatic);
            else await Ai.AnalyzeAsync(Settings.Ai, Clips, Collections, story, trigger, chinese, lifetime.Token, queued, replacing);
            if (!story && automatic && Settings.Ai.AppendExistingAiGroups && Ai.Review is { } plan &&
                Ai.Job(false) is { Trigger: "incremental" or "idle" } task && task.Id == plan.Id)
                AppendToExistingThemes(plan);
            if (Ai.Job(story)?.Error is { Length: > 0 } error && !automatic) Notify(error);
            else if (Ai.Job(story)?.Status == "No eligible clips") Notify("No eligible clips");
        }
        catch (Exception error) when (AiTasks.Expected(error)) { Notify(error.Message); }
    }

    internal void ApplyAiPlan(AiReviewedPlan review, IEnumerable<string> names, Action<string> showError)
    {
        if (Ai.Review?.Id != review.Id) return;
        if (Ai.Running || compressingContent)
        {
            showError("Wait for the current task to finish.");
            return;
        }
        bool regroup = review.Replacing is not null;
        if (regroup && history.UndoableAiTask == review.Id)
        {
            FinishReview();
            return;
        }
        var selected = names.ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (regroup && !review.Proposal.Groups.All(group => selected.Contains(group.Name)))
        {
            showError("Regrouping plans are applied together.");
            return;
        }
        var (approved, stale) = ValidateAiClips(review, review.Proposal.Groups.Where(group => selected.Contains(group.Name)));
        if (regroup && stale.Count > 0)
        {
            showError("The content in this plan changed. Generate a new regrouping plan.");
            return;
        }
        int count = 0;
        if (!ChangeHistory(() => count = history.ApplyAiTopics(approved, review.Id, review.Replacing), showError) || !FinishReview(stale)) return;
        Notify(review.Replacing is { Length: > 0 } replaced ? Labels.Format("Replaced {0} AI groups and organized {1} clips.", replaced.Length, count) :
            Labels.Format("Organized {0} clips.", count));
        if (stale.Count > 0) Notify(Labels.Format("Skipped {0} clips that changed.", stale.Count));

        bool FinishReview(HashSet<Guid>? requeue = null)
        {
            try
            {
                if (requeue is not null) Ai.Requeue(requeue);
                Ai.ClearReview(applied: true);
                return true;
            }
            catch (Exception error) when (AiTasks.Expected(error)) { showError(error.Message); return false; }
        }
    }

    private void AppendToExistingThemes(AiReviewedPlan review)
    {
        var available = Collections.Where(group => group.IsAi && !group.Locked).ToDictionary(group => group.Id);
        bool CanAppend(AiTopicProposal topic) => topic.ExistingGroupId is { } id && available.TryGetValue(id, out var current) &&
            (topic.ExpectedDefinition is null || topic.ExpectedDefinition == current.Definition);
        var existing = review.Proposal.Groups.Where(CanAppend).ToArray();
        if (existing.Length == 0) return;
        var remaining = review.Proposal.Groups.Where(group => !CanAppend(group) || group.Overview.Length > 0).ToArray();
        var (approved, stale) = ValidateAiClips(review, existing.Select(group => group with { Overview = "", OverviewSources = [] }));
        if (!ChangeHistory(() => history.ApplyAiTopics(approved, remaining.Length == 0 ? review.Id : null))) return;
        Ai.Requeue(stale);
        if (remaining.Length == 0) Ai.ClearReview(applied: true);
        else Ai.TrimReview(review, remaining);
    }

    private (AiTopicProposal[] Topics, HashSet<Guid> Stale) ValidateAiClips(AiReviewedPlan review, IEnumerable<AiTopicProposal> groups)
    {
        var stale = new HashSet<Guid>();
        var lookup = Clips.ToDictionary(clip => clip.Id);
        bool legacy = Ai.Job(story: false) is not { Format: > 0 };
        bool Eligible(Guid id)
        {
            bool valid = lookup.TryGetValue(id, out var clip) && review.Versions.TryGetValue(id, out var expected) &&
                AiTasks.MatchesVersion(clip, Settings.Ai, expected, legacy);
            if (!valid) stale.Add(id);
            return valid;
        }
        if (review.Replacing is not null)
        {
            foreach (Guid id in review.Versions.Keys) Eligible(id);
            return (groups.ToArray(), stale);
        }
        var approved = groups.Select(group =>
        {
            Guid[] members = group.Members.Where(Eligible).ToArray();
            bool overviewValid = group.OverviewSources?.All(members.Contains) != false;
            return group with { Members = members, Overview = overviewValid ? group.Overview : "",
                OverviewSources = overviewValid ? group.OverviewSources : [] };
        }).ToArray();
        return (approved, stale);
    }

    internal void UndoAi()
    {
        if (Ai.Running || compressingContent || !CanUndoAi) return;
        var task = history.UndoableAiTask;
        if (!ChangeHistory(history.UndoAiTopics)) return;
        try { if (task is { } id) Ai.RecordUndo(id); }
        catch (Exception error) when (AiTasks.Expected(error)) { Notify(error.Message); }
        Notify("AI organization undone.");
    }
    internal void ToggleAiGroupLock(ClipCollection group) => ChangeHistory(() => history.SetAiGroupLocked(group.Id, !group.Locked));
    internal bool EditAiGroup(ClipCollection group, string name, string definition, bool retained, Action<string> showError) =>
        ChangeHistory(() => history.UpdateAiGroup(group, name, definition, retained), showError);
    internal void ExcludeFromAiGroup(ClipCollection group, Clip clip) => ChangeHistory(() => history.RemoveFromAiTopic(group.Id, clip.Id));
    internal void ToggleAiCompression(ClipCollection group) =>
        ChangeHistory(() => history.SetAiGroupCompression(group.Id, !group.PackPayloads));

    internal bool ClearAiGroups(AiGroupSnapshot[] selection, Action<string>? showError = null)
    {
        if (selection.Length == 0) return false;
        if (!CanManageAiGroups)
        {
            (showError ?? Notify)("Review or continue the current AI task first.");
            return false;
        }
        if (!ChangeHistory(() => history.ApplyAiTopics([], replacing: selection), showError)) return false;
        Notify(Labels.Format("Cleared {0} AI groups. You can undo this change.", selection.Length));
        return true;
    }

    internal async Task RegroupAiAsync(AiRegroupScope scope, AiGroupSnapshot[] replacing, IReadOnlySet<Guid> inputIds)
    {
        if (!ReadyForGroupAnalysis() || inputIds.Count == 0) return;
        if (!AiGroupSnapshot.IsCurrent(Collections, Clips, replacing))
        {
            Notify("The selected AI groups changed. Refresh the selection and try again.");
            return;
        }
        if (!OpenAiTaskPage()) return;
        string trigger = scope switch { AiRegroupScope.Recent => "manual-regroup-recent", AiRegroupScope.Library => "manual-regroup-all", _ => "manual-regroup" };
        await RunAiAsync(false, trigger, queued: inputIds, replacing: replacing);
        if (settingsWindow?.IsActive == true && Ai.Review?.Replacing is not null) settingsWindow.ShowReview();
    }

    internal async Task ReviewThemeAsync(ClipCollection group)
    {
        if (!ReadyForGroupAnalysis() || !OpenAiTaskPage()) return;
        await RunAiAsync(false, "manual-review",
            queued: Clips.Where(clip => clip.CollectionIds.Contains(group.Id)).Select(clip => clip.Id).ToHashSet());
    }

    internal bool OpenAiTaskPage()
    {
        if (!SaveSettings(Settings with { LastAiTab = 3 })) return false;
        OpenSettings(SettingsPage.Ai);
        return true;
    }

    private bool ReadyForGroupAnalysis()
    {
        if (!CanManageAiGroups)
        {
            Notify("Review or continue the current AI task first.");
            return false;
        }
        if (!Settings.Ai.Enabled || !Ai.CanConnect(Settings.Ai))
        {
            Notify("Configure and enable AI analysis to begin.");
            return false;
        }
        return true;
    }

    private void AiTick()
    {
        var prefs = Settings.Ai;
        TimeSpan idle = NativeMethods.IdleTime();
        var now = DateTimeOffset.Now;
        bool idleWindow = now.Hour >= prefs.IdleStartHour && now.Hour < prefs.IdleEndHour;
        bool nightly = Ai.ActiveJob?.Trigger is "idle" or "review";
        if (Ai.Running)
        {
            if (!prefs.Enabled || !prefs.Story && Ai.ActiveJob?.Kind == "story" ||
                !prefs.IdleOrganize && nightly || !prefs.WeeklyThemeReview && Ai.ActiveJob?.Trigger == "review" ||
                !prefs.AutoOrganize && Ai.ActiveJob?.Trigger == "incremental")
                Ai.SuspendBackground();
            else if (nightly && now - idleRunStarted >= TimeSpan.FromMinutes(10))
            {
                idleLimitReached = DateOnly.FromDateTime(now.Date);
                Ai.SuspendBackground();
            }
            else if ((nightly || Ai.ActiveJob?.Trigger == "weekly") &&
                (idle < TimeSpan.FromMinutes(5) || NativeMethods.BatterySaver() || nightly && !idleWindow))
                Ai.SuspendBackground();
            return;
        }
        if (isolated || systemSuspended || !prefs.Enabled || !Ai.CanConnect(prefs) || NativeMethods.BatterySaver() ||
            Ai.TodayTokens >= prefs.DailyTokens) return;
        bool allowedNew = Ai.TodayAutomaticTasks < prefs.DailyAutomaticTasks;

        var last = Ai.Stories.FirstOrDefault();
        var storyJob = Ai.Job(story: true);
        TimeSpan sinceStoryAttempt = now - (storyJob?.UpdatedAt ?? DateTimeOffset.MinValue);
        if (prefs.Story && storyJob is { Status: "Paused", PausedByUser: false, Trigger: "weekly" or "first story" } &&
            (storyJob.Trigger == "first story" || idle >= TimeSpan.FromMinutes(5)) &&
            (storyJob.Error is null || sinceStoryAttempt >= TimeSpan.FromHours(1)))
        {
            _ = RunAiAsync(true, "", resume: true, automatic: true);
            return;
        }
        if (prefs.Story && allowedNew && storyJob?.Status != "Paused" && sinceStoryAttempt >= TimeSpan.FromHours(1) &&
            (last is null || (last.Sharing is null || now - last.GeneratedAt >= TimeSpan.FromDays(7)) && idle >= TimeSpan.FromMinutes(5)) &&
            Clips.Any(clip => AiTasks.ParticipatesInStory(clip, now.AddDays(-7), now) && AiTasks.Project(clip, prefs) is not null))
        {
            _ = RunAiAsync(true, last is null ? "first story" : "weekly", automatic: true);
            return;
        }
        if (Ai.Review is not null) return;
        if (Ai.Job(story: false) is { Status: "Paused" } paused)
        {
            if (prefs.IdleOrganize && !paused.PausedByUser && (paused.Trigger == "idle" || paused.Trigger == "review" && prefs.WeeklyThemeReview) &&
                idleWindow &&
                Ai.TonightTokens < prefs.NightlyTokens &&
                idleLimitReached != DateOnly.FromDateTime(now.Date) &&
                idle >= TimeSpan.FromMinutes(5) && (paused.Error is null || now - lastAutoOrganization > TimeSpan.FromHours(1)))
            {
                lastAutoOrganization = now;
                _ = RunAiAsync(false, "", resume: true, automatic: true);
            }
            else if (prefs.AutoOrganize && !paused.PausedByUser && paused.Trigger == "incremental" &&
                now - (paused.UpdatedAt ?? lastAutoOrganization) >= TimeSpan.FromHours(1))
                _ = RunAiAsync(false, "", resume: true, automatic: true);
            return;
        }
        if (!allowedNew) return;
        if (prefs.IdleOrganize && idleWindow && Ai.TonightTokens == 0 && idle >= TimeSpan.FromMinutes(5) &&
            lastIdleDay != DateOnly.FromDateTime(now.Date))
        {
            lastIdleDay = DateOnly.FromDateTime(now.Date);
            var reviewScope = prefs.WeeklyThemeReview && now - (Ai.LastAutomaticReview ?? DateTimeOffset.MinValue) >= TimeSpan.FromDays(7) ?
                LowActivityThemeClips(now) : null;
            if (reviewScope is { Count: > 0 }) _ = RunAiAsync(false, "review", queued: reviewScope, automatic: true);
            else _ = RunAiAsync(false, "idle", automatic: true);
        }
        else if (prefs.AutoOrganize && now - lastAutoOrganization >= TimeSpan.FromMinutes(5))
        {
            try
            {
                if (Ai.DueIncremental(prefs, Clips, now) is { } pending)
                {
                    lastAutoOrganization = now;
                    _ = RunAiAsync(false, "incremental", queued: pending, automatic: true);
                }
            }
            catch (Exception error) when (AiTasks.Expected(error)) { Notify(error.Message); }
        }
    }

    private HashSet<Guid> LowActivityThemeClips(DateTimeOffset now)
    {
        var active = Clips.Where(clip => clip.TrashedAt is null && ClipActivity.LastUsed(clip) >= now.AddDays(-7))
            .SelectMany(clip => clip.CollectionIds).ToHashSet();
        active.UnionWith(RankedAiGroups().Take(GroupNavigation.RecommendationCount(Settings)).Select(group => group.Id));
        var eligible = Collections.Where(group => group.IsAi && !group.Locked && !active.Contains(group.Id))
            .Select(group => group.Id).ToHashSet();
        return Clips.Where(clip => clip.CollectionIds.Any(eligible.Contains)).Select(clip => clip.Id).ToHashSet();
    }

    private void OnPowerModeChanged(object sender, Microsoft.Win32.PowerModeChangedEventArgs args) =>
        _ = Dispatcher.BeginInvoke(new Action(() =>
        {
            if (Exiting) return;
            if (args.Mode == Microsoft.Win32.PowerModes.Resume)
            {
                systemSuspended = false;
                ResetClipboardObservation();
                _ = CheckDueLinkSessionsAsync();
            }
            if (args.Mode != Microsoft.Win32.PowerModes.Suspend) return;
            systemSuspended = true;
            ResetClipboardObservation();
            if (Ai.ActiveJob?.Trigger is "weekly" or "first story" or "idle" or "review" or "incremental") Ai.SuspendBackground();
        }));
}
