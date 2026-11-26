namespace Pasteory.Core;

public enum ActivityKind { Copy, Paste, Open, Edit }
public sealed record ClipUse(ActivityKind Kind, DateTimeOffset At);
public sealed record ActivityPreferences(double HalfLifeHours = 48, double CopyBoost = .4, double PasteBoost = .8,
    int TopMembers = 3, double TopWeight = .75, int RetainDays = 7, int CompressDays = 14, int ArchiveDays = 60);

public static class ClipActivity
{
    private static readonly TimeSpan History = TimeSpan.FromDays(366);
    private const int Limit = 4096;

    public static Clip Record(Clip clip, ActivityKind kind, DateTimeOffset at)
    {
        var old = clip.Uses.Length > 0 ? clip.Uses : Infer(clip);
        return clip with { Uses = old.Where(item => at - item.At <= History).Append(new ClipUse(kind, at))
            .OrderBy(item => item.At).TakeLast(Limit).ToArray() };
    }

    public static DateTimeOffset LastUsed(Clip clip)
    {
        var last = clip.CapturedAt;
        if (clip.LastPastedAt is { } pasted && pasted > last) last = pasted;
        foreach (var use in clip.Uses) if (use.At > last) last = use.At;
        return last;
    }

    public static double Percentage(Clip clip, ActivityPreferences preferences, DateTimeOffset now)
    {
        var start = clip.CreatedAt ?? clip.CapturedAt;
        var events = clip.Uses.Length == 0 ? Infer(clip) : clip.Uses;
        double boost = 0;
        DateTimeOffset boostAt = start;
        foreach (var use in events)
        {
            double amount = use.Kind switch
            {
                ActivityKind.Copy when use.At > start => preferences.CopyBoost,
                ActivityKind.Paste => preferences.PasteBoost,
                _ => 0
            };
            if (amount <= 0 || now - use.At > History) continue;
            boost *= Math.Pow(2, -Math.Max(0, (use.At - boostAt).TotalDays) / 7);
            boost = Math.Min(3, boost + amount);
            boostAt = use.At;
        }
        double age = Math.Max(0, (now - LastUsed(clip)).TotalHours);
        double coefficient = 1 + boost * Math.Pow(2, -Math.Max(0, (now - boostAt).TotalDays) / 7);
        return 100 * Math.Pow(2, -age / (Math.Clamp(preferences.HalfLifeHours, 1, 8760) * coefficient));
    }

    public static string Stage(Clip clip, ActivityPreferences settings, DateTimeOffset now)
    {
        if (clip.ArchivedAt is not null) return "Archived";
        if (clip.Pinned || clip.Favorite) return "Active";
        return (now - LastUsed(clip)).TotalDays >= settings.RetainDays ? "Retained" : "Active";
    }

    private static ClipUse[] Infer(Clip clip)
    {
        DateTimeOffset created = clip.CreatedAt ?? clip.CapturedAt;
        var copied = clip.Captures.Where(capture => capture.CapturedAt > created).Select(capture => capture.CapturedAt).ToList();
        if (clip.CopyCount > 1 && clip.CapturedAt > created && !copied.Contains(clip.CapturedAt)) copied.Add(clip.CapturedAt);
        var events = copied.Select(time => new ClipUse(ActivityKind.Copy, time));
        if (clip.LastPastedAt is { } pasted) events = events.Append(new ClipUse(ActivityKind.Paste, pasted));
        return events.OrderBy(use => use.At).TakeLast(Limit).ToArray();
    }
}
