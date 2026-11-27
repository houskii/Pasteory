using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed record MacBackupAiArchive(Dictionary<Guid, MacBackupAiGroup> Groups, SavedStory[] Stories, AiUse[] Usage)
{
    internal static MacBackupAiArchive Empty { get; } = new([], [], []);
}
internal sealed record MacBackupAiGroup(Guid Id, string Definition, string Overview, bool Retained, Guid[] ExcludedClipIds,
    int DefinitionVersion = 1, bool DefinitionIsManual = false, bool NameIsManual = false, bool WindowsLocked = false);

internal static class MacBackupAiState
{
    private sealed record Evidence(Guid ClipId, string Quote);
    private sealed record Section(string Title, string Text, Evidence[] Evidence);
    private sealed record Report(Guid Id, string Title, string Introduction, Section[] RecentWork, Section[] Observations,
        string Encouragement, DateTimeOffset PeriodStart, DateTimeOffset PeriodEnd, DateTimeOffset GeneratedAt, int SourceCount);
    private sealed record Usage(Guid Id, Guid RunId, DateTimeOffset Date, string RequestedModel, int InputTokens,
        int OutputTokens, int? CachedInputTokens, int? ReasoningTokens, bool Estimated, bool Succeeded, string Trigger, bool? Automatic);

    internal static MacBackupAiArchive Read(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        var state = document.RootElement;
        var groups = new Dictionary<Guid, MacBackupAiGroup>();
        if (state.TryGetProperty("groups", out var entries) && entries.ValueKind == JsonValueKind.Array)
        {
            // Swift Codable represents a dictionary with UUID keys as alternating keys and values.
            var fields = entries.EnumerateArray().ToArray();
            for (int index = 0; index + 1 < fields.Length; index += 2)
            {
                Guid id = fields[index].GetGuid();
                var group = fields[index + 1].Deserialize<MacBackupAiGroup>(AiFile.Wire);
                if (group is not null && group.Id == id) groups.TryAdd(id, group);
            }
        }
        var stories = state.TryGetProperty("stories", out var reports) ? reports.Deserialize<Report[]>(AiFile.Wire) ?? [] : [];
        var usage = state.TryGetProperty("usage", out var calls) ? calls.Deserialize<Usage[]>(AiFile.Wire) ?? [] : [];
        return new(groups, stories.Select(ToStory).ToArray(), usage.Select(ToUse).ToArray());
    }

    internal static object Export(HistoryStore store, AiTasks ai)
    {
        var groups = new List<object>();
        var memberships = store.Clips.Where(clip => clip.Kind != ClipKind.Aggregate)
            .SelectMany(clip => clip.CollectionIds.Select(group => (Group: group, clip.Id))).ToLookup(entry => entry.Group, entry => entry.Id);
        foreach (var group in store.Collections.Where(group => group.IsAi))
        {
            var members = memberships[group.Id].ToArray();
            groups.Add(group.Id);
            groups.Add(new
            {
                group.Id, group.Name, group.Definition, group.Overview, group.DefinitionVersion, group.DefinitionIsManual,
                group.NameIsManual, group.Retained, windowsLocked = group.Locked,
                excludedClipIDs = group.ExcludedClips ?? [],
                memberIDs = members, aiMemberIDs = members, overviewMemberFingerprint = "", revision = 1
            });
        }
        return new
        {
            schemaVersion = 1, groups, summaries = Array.Empty<object>(), changes = Array.Empty<object>(),
            usage = ai.Usage.Select(call => new
            {
                id = StableUseId(call), runID = call.Task, date = MacBackupWriter.Date(call.At), requestedModel = call.Model,
                inputTokens = call.Input, outputTokens = call.Output, cachedInputTokens = call.Cached, reasoningTokens = call.Reasoning,
                call.Estimated, succeeded = call.Outcome == "Completed", trigger = call.Kind == "incremental" ? "new" : call.Kind,
                automatic = call.Kind is "incremental" or "idle" or "review" or "weekly" or "first story"
            }).ToArray(),
            payloadHolders = new Dictionary<string, string>(), stories = ai.Stories.Select(ExportStory).ToArray()
        };
    }

    internal static Guid StableUseId(AiUse call) => call.RecordId ??
        MacBackupWriter.StableId(FormattableString.Invariant($"{call.Task:N}:{call.At.UtcTicks}:{call.Model}:{call.Input}:{call.Output}:{call.Outcome}"));

    private static SavedStory ToStory(Report report) => new(report.Id, report.GeneratedAt, DateOnly.FromDateTime(report.PeriodStart.LocalDateTime),
        DateOnly.FromDateTime(report.PeriodEnd.LocalDateTime), new(report.Title, report.Introduction, report.Encouragement,
            report.RecentWork.Select(ToSection).ToArray(), report.Observations.Select(ToSection).ToArray()), report.SourceCount);

    private static StorySection ToSection(Section section) => new(section.Title, section.Text,
        section.Evidence.Select(item => new AiQuote(item.ClipId, item.Quote)).ToArray());

    private static AiUse ToUse(Usage call) => new(call.RunId, call.Date, call.RequestedModel,
        call.Trigger == "new" ? "incremental" : call.Trigger, Math.Max(0, call.InputTokens), Math.Max(0, call.OutputTokens),
        Math.Clamp(call.CachedInputTokens ?? 0, 0, Math.Max(0, call.InputTokens)),
        Math.Clamp(call.ReasoningTokens ?? 0, 0, Math.Max(0, call.OutputTokens)), call.Estimated,
        call.Succeeded ? "Completed" : "Failed", call.Id);

    private static object ExportStory(SavedStory report) => new
    {
        report.Id, report.Story.Title, introduction = report.Story.Summary,
        recentWork = report.Story.Work.Select(ExportSection).ToArray(), observations = report.Story.Observations.Select(ExportSection).ToArray(),
        report.Story.Encouragement, periodStart = MacBackupWriter.Date(new DateTimeOffset(report.From.ToDateTime(TimeOnly.MinValue))),
        periodEnd = MacBackupWriter.Date(new DateTimeOffset(report.Through.ToDateTime(TimeOnly.MinValue))),
        generatedAt = MacBackupWriter.Date(report.GeneratedAt), report.SourceCount, sourceRevisions = Array.Empty<object>()
    };

    private static object ExportSection(StorySection section) => new
    {
        section.Title, text = section.Detail, evidence = section.References.Select(item => new { clipID = item.ClipId, item.Quote }).ToArray()
    };
}
