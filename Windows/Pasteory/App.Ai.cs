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
    private DateTimeOffset lastAutoOrganization;
    private DateTimeOffset lastAutoStory;
    private DateOnly? lastIdleDay;
    private DateOnly? idleLimitReached;
    private DateTimeOffset idleRunStarted;

    internal async Task RunAiAsync(bool story, string trigger, bool resume = false)
    {
        try
        {
            if (trigger == "idle" || resume && Ai.Job(story)?.Trigger == "idle") idleRunStarted = DateTimeOffset.Now;
            if (resume) await Ai.ResumeAsync(Settings.Ai, Clips, story, lifetime.Token);
            else await Ai.AnalyzeAsync(Settings.Ai, Clips, Collections, story, trigger, Labels.Get("Settings") != "Settings", lifetime.Token);
            if (Ai.ActiveJob?.Error is { Length: > 0 } error) Notify(error);
            else if (Ai.ActiveJob?.Status == "No eligible clips") Notify("No eligible clips");
        }
        catch (Exception error) when (AiTasks.Expected(error)) { Notify(error.Message); }
    }

    internal void ApplyAiPlan(AiReviewedPlan review, IEnumerable<string> names)
    {
        var selected = names.ToHashSet(StringComparer.OrdinalIgnoreCase);
        int stale = 0;
        var lookup = Clips.ToDictionary(clip => clip.Id);
        bool Eligible(Guid id)
        {
            bool valid = lookup.TryGetValue(id, out var clip) && review.Versions.TryGetValue(id, out var expected) &&
                AiTasks.Project(clip, Settings.Ai)?.Version == expected;
            if (!valid) stale++;
            return valid;
        }
        var approved = review.Proposal.Groups.Where(group => selected.Contains(group.Name)).Select(group =>
            group with { Members = group.Members.Where(Eligible).ToArray() }).ToArray();
        int count = 0;
        if (!ChangeHistory(() => count = history.ApplyAiTopics(approved))) return;
        try { Ai.ClearReview(); }
        catch (Exception error) when (AiTasks.Expected(error)) { Notify(error.Message); return; }
        Notify(Labels.Format("Organized {0} clips.", count));
        if (stale > 0) Notify(Labels.Format("Skipped {0} clips that changed.", stale));
    }

    internal void UndoAi() => ChangeHistory(history.UndoAiTopics);
    internal void ToggleAiGroupLock(ClipCollection group) => ChangeHistory(() => history.SetAiGroupLocked(group.Id, !group.Locked));
    internal void ExcludeFromAiGroup(ClipCollection group, Clip clip) => ChangeHistory(() => history.RemoveFromAiTopic(group.Id, clip.Id));
    internal void ToggleAiCompression(ClipCollection group) =>
        ChangeHistory(() => history.SetAiGroupCompression(group.Id, !group.PackPayloads));

    private void AiTick()
    {
        var prefs = Settings.Ai;
        TimeSpan idle = NativeMethods.IdleTime();
        var now = DateTimeOffset.Now;
        if (Ai.Running)
        {
            if (!prefs.Enabled) Ai.Pause();
            else if (Ai.ActiveJob?.Trigger == "idle" && now - idleRunStarted >= TimeSpan.FromMinutes(10))
            {
                idleLimitReached = DateOnly.FromDateTime(now.Date);
                Ai.SuspendBackground();
            }
            else if (Ai.ActiveJob?.Trigger is "weekly" or "idle" &&
                (idle < TimeSpan.FromMinutes(5) || NativeMethods.BatterySaver() || Ai.ActiveJob.Trigger == "idle" && now.Hour != 1))
                Ai.SuspendBackground();
            return;
        }
        if (isolated || !prefs.Enabled || !Ai.CanConnect(prefs) || NativeMethods.BatterySaver() || Ai.TodayTokens >= prefs.DailyTokens) return;
        bool allowedNew = Ai.TodayAutomaticTasks < prefs.DailyAutomaticTasks;

        var last = Ai.Stories.FirstOrDefault();
        var storyJob = Ai.Job(story: true);
        if (prefs.Story && storyJob is { Status: "Paused", PausedByUser: false, Trigger: "weekly" or "first story" } &&
            (storyJob.Trigger == "first story" || idle >= TimeSpan.FromMinutes(5)) &&
            (storyJob.Error is null || now - lastAutoStory > TimeSpan.FromHours(1)))
        {
            lastAutoStory = now;
            _ = RunAiAsync(true, "", resume: true);
            return;
        }
        if (prefs.Story && allowedNew && storyJob?.Status != "Paused" && now - lastAutoStory > TimeSpan.FromHours(1) &&
            (last is null || now - last.GeneratedAt > TimeSpan.FromDays(7) && idle >= TimeSpan.FromMinutes(5)))
        {
            lastAutoStory = now;
            _ = RunAiAsync(true, last is null ? "first story" : "weekly");
            return;
        }
        if (Ai.Review is not null) return;
        if (Ai.Job(story: false) is { Status: "Paused" } paused)
        {
            if (prefs.IdleOrganize && !paused.PausedByUser && paused.Trigger == "idle" && now.Hour == 1 &&
                idleLimitReached != DateOnly.FromDateTime(now.Date) &&
                idle >= TimeSpan.FromMinutes(5) && (paused.Error is null || now - lastAutoOrganization > TimeSpan.FromHours(1)))
            {
                lastAutoOrganization = now;
                _ = RunAiAsync(false, "", resume: true);
            }
            return;
        }
        if (!allowedNew) return;
        if (prefs.IdleOrganize && now.Hour == 1 && idle >= TimeSpan.FromMinutes(5) && lastIdleDay != DateOnly.FromDateTime(now.Date))
        {
            lastIdleDay = DateOnly.FromDateTime(now.Date);
            _ = RunAiAsync(false, "idle");
        }
        else if (prefs.AutoOrganize && now - lastAutoOrganization > TimeSpan.FromMinutes(5) &&
            Clips.Any(clip => clip.CapturedAt >= now.AddMinutes(-15) && clip.CapturedAt <= now.AddSeconds(-30)))
        {
            lastAutoOrganization = now;
            _ = RunAiAsync(false, "incremental");
        }
    }
}
