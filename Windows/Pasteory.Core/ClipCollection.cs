namespace Pasteory.Core;

public sealed record ClipCollection(Guid Id, string Name, SmartRules? Rules = null, bool IsAi = false,
    string Overview = "", bool Locked = false, Guid[]? ExcludedClips = null, bool PackPayloads = false)
{
    public bool IsSmart => Rules is not null;
}

public enum RuleField
{
    Kind, Text, Title, Note, Source, LinkHost, FileExtension, Favorite, Pinned, Priority, CopiedWithinDays, Conversion,
    SourceConfidence, CreatedAt, ByteSize, CopyCount
}
public enum RuleComparison
{
    Contains, Equals, StartsWith, EndsWith, DoesNotContain, DoesNotEqual, MatchesRegex, Before, After, GreaterThan, LessThan
}

public sealed record SmartCondition(RuleField Field, RuleComparison Comparison, string Value)
{
    public bool Matches(Clip clip, DateTimeOffset now)
    {
        if (Field == RuleField.CopiedWithinDays)
        {
            bool matches = int.TryParse(Value, out int days) && days is >= 1 and <= 36500 &&
                clip.CapturedAt.ToLocalTime().Date >= now.ToLocalTime().Date.AddDays(1 - days);
            return Comparison == RuleComparison.DoesNotEqual ? !matches : matches;
        }
        if (Field == RuleField.CreatedAt && Comparison is RuleComparison.Before or RuleComparison.After)
        {
            var created = clip.CreatedAt ?? clip.CapturedAt;
            DateTimeOffset target;
            if (double.TryParse(Value, System.Globalization.CultureInfo.InvariantCulture, out double days) &&
                double.IsFinite(days) && Math.Abs(days) < 36500) target = now.AddDays(-days);
            else if (!DateTimeOffset.TryParse(Value, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind, out target)) return false;
            return Comparison == RuleComparison.Before ? created < target : created > target;
        }

        IEnumerable<string> values = Field switch
        {
            RuleField.Kind => [clip.Kind.ToString()],
            RuleField.Title => [clip.DisplayTitle],
            RuleField.Note => [clip.Note],
            RuleField.Source => clip.Captures.Select(eventItem => eventItem.Source).Prepend(clip.Source).Append(clip.SourceIdentifier ?? ""),
            RuleField.SourceConfidence => [clip.SourceConfidence],
            RuleField.ByteSize => [clip.Size.ToString(System.Globalization.CultureInfo.InvariantCulture)],
            RuleField.CopyCount => [clip.CopyCount.ToString(System.Globalization.CultureInfo.InvariantCulture)],
            RuleField.LinkHost => Uri.TryCreate(clip.Text?.Trim(), UriKind.Absolute, out var link) ? [link.IdnHost] : [],
            RuleField.FileExtension => clip.Files.Select(file => Path.GetExtension(file).TrimStart('.')),
            RuleField.Favorite => [clip.Favorite.ToString()],
            RuleField.Pinned => [clip.Pinned.ToString()],
            RuleField.Priority => [clip.Priority.ToString()],
            RuleField.Conversion => clip.Conversions.Length == 0 ? ["None"]
                : clip.Conversions.Select(conversion => conversion.Tool.ToString()).Prepend("Any"),
            _ => [clip.PlainText ?? "", clip.RecognizedText ?? ""],
        };
        const StringComparison ignoreCase = StringComparison.OrdinalIgnoreCase;
        return Comparison switch
        {
            RuleComparison.Equals => values.Any(value => value.Equals(Value, ignoreCase)),
            RuleComparison.DoesNotEqual => !values.Any(value => value.Equals(Value, ignoreCase)),
            RuleComparison.StartsWith => values.Any(value => value.StartsWith(Value, ignoreCase)),
            RuleComparison.EndsWith => values.Any(value => value.EndsWith(Value, ignoreCase)),
            RuleComparison.DoesNotContain => !values.Any(value => value.Contains(Value, ignoreCase)),
            RuleComparison.MatchesRegex => values.Any(value => MatchesRegex(value, Value)),
            RuleComparison.GreaterThan => values.Any(value => CompareNumber(value, Value, greater: true)),
            RuleComparison.LessThan => values.Any(value => CompareNumber(value, Value, greater: false)),
            _ => values.Any(value => value.Contains(Value, ignoreCase))
        };
    }

    private static bool CompareNumber(string raw, string expected, bool greater) =>
        double.TryParse(raw, System.Globalization.CultureInfo.InvariantCulture, out double value) &&
        double.TryParse(expected, System.Globalization.CultureInfo.InvariantCulture, out double threshold) &&
        (greater ? value > threshold : value < threshold);

    private static bool MatchesRegex(string text, string pattern)
    {
        if (pattern.Length > 512) return false;
        try { return System.Text.RegularExpressions.Regex.IsMatch(text.AsSpan(0, Math.Min(text.Length, 500_000)), pattern,
            System.Text.RegularExpressions.RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(75)); }
        catch (Exception error) when (error is ArgumentException or System.Text.RegularExpressions.RegexMatchTimeoutException) { return false; }
    }
}

public sealed record SmartRules(bool MatchAll, SmartCondition[] Conditions, SmartRules[] Groups)
{
    public bool Matches(Clip clip, DateTimeOffset now)
    {
        var results = Conditions.Select(condition => condition.Matches(clip, now))
            .Concat(Groups.Select(group => group.Matches(clip, now)));
        return MatchAll ? results.All(matched => matched) : results.Any(matched => matched);
    }

    public bool IsValid()
    {
        int remaining = 50;
        return Validate(this, 1);

        bool Validate(SmartRules group, int depth)
        {
            if (depth > 5 || group.Conditions.Length + group.Groups.Length == 0) return false;
            remaining -= group.Conditions.Length;
            return remaining >= 0 && group.Conditions.All(condition => !string.IsNullOrWhiteSpace(condition.Value)) &&
                group.Groups.All(child => Validate(child, depth + 1));
        }
    }
}
