using System;
using System.Collections.Generic;
using System.Linq;
using Pasteory.Core;

namespace Pasteory.Windows;

public partial class App
{
    private IReadOnlyList<Clip>? activitySource;
    private ActivityPreferences? activityPreferences;
    private DateTimeOffset activityTime;
    private readonly Dictionary<Guid, (double Score, int Percentile)> activityRank = [];

    internal (double Score, int Percentile)? ClipRank(Clip clip) =>
        ComputeActivity().TryGetValue(clip.Id, out var value) ? value : null;

    internal IEnumerable<ClipCollection> RankedAiGroups()
    {
        var rank = ComputeActivity();
        var options = Settings.Ai.Activity;
        var lists = new Dictionary<Guid, List<double>>();
        foreach (var clip in Clips)
        {
            if (!rank.TryGetValue(clip.Id, out var item)) continue;
            foreach (Guid group in clip.CollectionIds)
            {
                if (!lists.TryGetValue(group, out var members)) lists[group] = members = [];
                members.Add(item.Score);
            }
        }
        return Collections.Where(group => group.IsAi).OrderByDescending(group => group.Locked)
            .ThenByDescending(group => lists.TryGetValue(group.Id, out var members) ? Score(members) : 0);

        double Score(List<double> members) => options.TopWeight * members.OrderDescending().Take(Math.Max(1, options.TopMembers)).Average() +
            (1 - options.TopWeight) * members.Average();
    }

    private Dictionary<Guid, (double Score, int Percentile)> ComputeActivity()
    {
        var now = DateTimeOffset.Now;
        var options = Settings.Ai.Activity;
        var source = Clips;
        if (ReferenceEquals(source, activitySource) && activityPreferences == options && now - activityTime < TimeSpan.FromMinutes(5))
            return activityRank;
        activitySource = source;
        activityPreferences = options;
        activityTime = now;
        activityRank.Clear();
        var scores = source.Where(clip => clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate)
            .Select(clip => (clip.Id, Score: Math.Round(ClipActivity.Percentage(clip, options, now), 2)))
            .OrderByDescending(entry => entry.Score).ToArray();
        int count = 0;
        foreach (var group in scores.GroupBy(entry => entry.Score))
        {
            count += group.Count();
            int percentile = (int)Math.Ceiling(100d * count / scores.Length);
            foreach (var entry in group) activityRank[entry.Id] = (entry.Score, percentile);
        }
        return activityRank;
    }
}
