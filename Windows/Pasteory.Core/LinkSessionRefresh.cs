namespace Pasteory.Core;

public enum LinkSessionOutcome { PageLoaded, NeedsSignIn, Failed, Blocked }

public sealed record LinkSessionRefresh
{
    public static IReadOnlyList<int> Intervals { get; } = Array.AsReadOnly(new[] { 3, 7, 14, 30 });

    public int IntervalDays { get; init; } = 14;
    public bool Automatic { get; init; } = true;
    public DateTimeOffset? ScheduledFrom { get; init; }
    public DateTimeOffset? LastSignedInAt { get; init; }
    public DateTimeOffset? LastAttemptAt { get; init; }
    public DateTimeOffset? LastRefreshedAt { get; init; }
    public LinkSessionOutcome? Outcome { get; init; }

    public LinkSessionRefresh Reset(DateTimeOffset? signedInAt) => this with
    {
        ScheduledFrom = signedInAt, LastSignedInAt = signedInAt, LastAttemptAt = null, LastRefreshedAt = null, Outcome = null
    };

    public DateTimeOffset? NextRefreshAt()
    {
        if (!Automatic || ScheduledFrom is not { } start || Outcome is LinkSessionOutcome.NeedsSignIn or LinkSessionOutcome.Blocked)
            return null;
        var anchor = LastRefreshedAt is { } refreshed && refreshed > start ? refreshed : start;
        var due = anchor.AddDays(Intervals.Contains(IntervalDays) ? IntervalDays : 14);
        return LastAttemptAt is { } attempted && attempted >= due ? attempted.AddHours(1) : due;
    }
}
