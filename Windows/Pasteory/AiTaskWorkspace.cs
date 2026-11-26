using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed record AiTaskManifest(AiJob Job, string Model, string Reasoning, int TargetGroupCount,
    bool ShareResources, string TaskKind);
internal sealed record AiAssignment(string Item, string[] GroupKeys, string? Reason);
internal sealed record AiPlanGroup(string Key, string Name, string Definition, Guid? ExistingGroupId,
    string? Overview, string[]? OverviewSources);
internal sealed record AiOrganizationResult(Guid TaskId, AiPlanGroup[] Groups, AiAssignment[]? Assignments);
internal sealed record AiStoryResult(Guid TaskId, StoryDraft Story);
internal sealed record AiAgentState(int Rounds, JsonElement[][] Exchanges, Dictionary<string, AiAssignment> Assignments,
    string? Result = null);

internal sealed class AiTaskWorkspace(string directory)
{
    internal string Directory { get; } = directory;
    internal string FilePath(string name) => Path.Combine(Directory, name);

    internal static string ItemKey(int index) => "i" + (index + 1).ToString(CultureInfo.InvariantCulture);
    internal static JsonElement Message(string role, string content) => JsonSerializer.SerializeToElement(new { role, content });

    internal void Prepare(AiJob job, AiPreferences prefs, string prompt, AiInput[] items,
        ClipCollection[] groups, string[] reservedNames, Dictionary<Guid, AiResource[]> resources, string[] encouragements)
    {
        AiFile.Save(FilePath("items.json"), items);
        AiFile.Save(FilePath("existing/groups.json"), groups);
        AiFile.Save(FilePath("existing/reserved-names.json"), reservedNames);
        AiFile.Save(FilePath("existing/resources.json"), resources);
        if (job.Kind == "story")
            AiFile.Save(FilePath("existing/previous-encouragements.json"), encouragements);
        AiFile.Save(FilePath("task.json"), new AiTaskManifest(job, prefs.Model, prefs.Reasoning, prefs.TargetGroupCount,
            prefs.ShareResources, job.Trigger == "incremental" ? "incremental_classification" : job.Kind));
        AiFile.Save(FilePath("plan.schema.json"), Schema(job));
        AiFile.Write(FilePath("PROMPT.md"), stream => stream.Write(Encoding.UTF8.GetBytes(prompt)));
    }

    internal AiAgentState LoadState() => AiFile.Load<AiAgentState>(FilePath("agent-state.json")) ?? new(0, [], []);

    internal void SaveState(AiAgentState state, object trace)
    {
        AiFile.Save(FilePath($"trace/round-{state.Rounds:D5}.json"), trace);
        if (state.Assignments.Count > 0) AiFile.Save(FilePath("scratch/assignments.json"), state.Assignments);
        AiFile.Save(FilePath("agent-state.json"), state);
    }

    internal void SavePlan(string content)
    {
        int first = content.IndexOf('{'), last = content.LastIndexOf('}');
        if (first < 0 || last < first) throw new InvalidDataException("The model returned no structured result.");
        try
        {
            using var document = JsonDocument.Parse(content.AsMemory(first, last - first + 1));
            AiFile.Save(FilePath("output/plan.json"), document.RootElement);
        }
        catch (JsonException) { throw new InvalidDataException("The model returned an invalid analysis format."); }
    }

    internal static AiProposal Validate(AiOrganizationResult result, AiJob job, AiInput[] items,
        AiAgentState state, ClipCollection[] existing, string[] reservedNames)
    {
        if (result.TaskId != job.Id || result.Groups is null || result.Groups.Length > 8)
            throw new InvalidDataException("Use the supplied taskId and at most eight groups.");
        var catalog = existing.ToDictionary(group => group.Id);
        var keys = new HashSet<string>(StringComparer.Ordinal);
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var reserved = reservedNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var reused = new HashSet<Guid>();
        var groups = new List<AiPlanGroup>();
        foreach (var group in result.Groups)
        {
            if (group is null || group.Key is not { Length: > 0 and <= 40 } || !keys.Add(group.Key) ||
                string.IsNullOrWhiteSpace(group.Name) || group.Name.Trim().Length > 40 ||
                string.IsNullOrWhiteSpace(group.Definition) || group.Definition.Length > 2000 || group.Overview?.Length > 2000)
                throw new InvalidDataException("Group keys must be unique and every group needs a name and definition.");
            string name = group.Name.Trim();
            if (group.ExistingGroupId is { } id)
            {
                if (!catalog.TryGetValue(id, out var current) || current.Locked || !reused.Add(id))
                    throw new InvalidDataException("Reuse only the listed unlocked existingGroupId values.");
                name = current.Name;
            }
            else if (reserved.Contains(name) || existing.Any(item => item.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException("Reuse an existing group by its ID or choose an unused name.");
            if (!names.Add(name)) throw new InvalidDataException("Group names must be unique.");
            groups.Add(group with { Name = name });
        }
        int created = groups.Count(group => group.ExistingGroupId is null);
        if (created > 0 && existing.Length + created > 8)
            throw new InvalidDataException("Existing and newly created groups together may total at most eight.");

        var available = items.Select((item, index) => (Key: ItemKey(index), item.Id))
            .ToDictionary(item => item.Key, item => item.Id, StringComparer.Ordinal);
        var assignments = new Dictionary<string, AiAssignment>(state.Assignments, StringComparer.Ordinal);
        var direct = new HashSet<string>(StringComparer.Ordinal);
        foreach (var assignment in result.Assignments ?? [])
        {
            if (assignment?.Item is null || !direct.Add(assignment.Item))
                throw new InvalidDataException("Every item may have only one final assignment.");
            assignments[assignment.Item] = assignment;
        }
        if (assignments.Count != available.Count || assignments.Keys.Any(key => !available.ContainsKey(key)))
            throw new InvalidDataException($"Classify all {items.Length} items. There are {assignments.Keys.Count(available.ContainsKey)} valid item keys.");

        var memberships = keys.ToDictionary(key => key, _ => new List<Guid>(), StringComparer.Ordinal);
        var unassigned = new List<AiUnassigned>();
        int assigned = 0;
        foreach (var entry in assignments)
        {
            var decision = entry.Value;
            Guid id = available[entry.Key];
            if (decision.GroupKeys is null || decision.GroupKeys.Distinct().Count() != decision.GroupKeys.Length ||
                decision.GroupKeys.Any(key => key is null || !keys.Contains(key)))
                throw new InvalidDataException($"Use only declared group keys for {entry.Key}.");
            if (decision.GroupKeys.Length == 0)
            {
                if (string.IsNullOrWhiteSpace(decision.Reason))
                    throw new InvalidDataException($"Provide the reason {entry.Key} is unassigned.");
                unassigned.Add(new(id, AiTasks.Compact(decision.Reason.Trim(), 1000)));
                continue;
            }
            assigned++;
            foreach (string key in decision.GroupKeys) memberships[key].Add(id);
        }
        if (assigned >= 18 && existing.Length + created < 6)
            throw new InvalidDataException("When there are at least eighteen assigned items, use six to eight coherent themes.");

        var topics = groups.Select(group =>
        {
            List<Guid> members = memberships[group.Key];
            if (members.Count == 0 || group.ExistingGroupId is null && members.Count < 3)
                throw new InvalidDataException("Every group needs members and every new theme needs at least three distinct items.");
            if (group.ExistingGroupId is { } id && catalog[id].ExcludedClips is { Length: > 0 } excluded &&
                members.Any(excluded.Contains))
                throw new InvalidDataException("A suggested group membership conflicts with an item exclusion.");
            string overview = group.Overview?.Trim() ?? "";
            var sources = group.OverviewSources ?? [];
            var memberSet = members.ToHashSet();
            if (overview.Length > 0 && (sources.Length == 0 || sources.Distinct().Count() != sources.Length ||
                sources.Any(key => key is null || !available.TryGetValue(key, out Guid source) || !memberSet.Contains(source))))
                throw new InvalidDataException("Supply distinct member item keys as overviewSources for each overview.");
            if (job.Trigger is "incremental" or "review" && group.ExistingGroupId is not null) overview = "";
            return new AiTopicProposal(group.Name, overview, members.ToArray(), group.ExistingGroupId,
                group.Definition, overview.Length == 0 ? [] : sources.Select(key => available[key]).ToArray(),
                CreateOnly: group.ExistingGroupId is null,
                ExpectedDefinition: group.ExistingGroupId is { } existingId ? catalog[existingId].Definition : null);
        }).ToArray();
        return new(topics, unassigned.ToArray());
    }

    private static object Schema(AiJob job)
    {
        bool story = job.Kind == "story";
        var quote = Object(new { clipId = Uuid(), quote = String(650) }, "clipId", "quote");
        var section = Object(new { title = String(140), detail = String(700), references = Array(quote, 5) },
            "title", "detail", "references");
        var draft = Object(new
        {
            title = String(120), summary = String(2500), encouragement = String(700),
            work = Array(section, 12), observations = Array(section, 12)
        }, "title", "summary", "encouragement", "work", "observations");
        var group = Object(new
        {
            key = String(40), name = String(40), definition = String(2000),
            existingGroupId = new { type = new[] { "string", "null" }, format = "uuid" },
            overview = String(2000), overviewSources = Array(String(32), job.Total)
        }, "key", "name", "definition");
        var assignment = Object(new { item = String(32), groupKeys = Array(String(40), 8), reason = String(1000) },
            "item", "groupKeys");
        var taskId = new Dictionary<string, object> { ["const"] = job.Id };
        return story ? Object(new { taskId, story = draft }, "taskId", "story") :
            Object(new { taskId, groups = Array(group, 8), assignments = Array(assignment, job.Total) }, "taskId", "groups");

        static object Object(object properties, params string[] required) => new { type = "object", properties, required };
        static object String(int maximum) => new { type = "string", maxLength = maximum };
        static object Uuid() => new { type = "string", format = "uuid" };
        static object Array(object items, int maximum) => new { type = "array", items, maxItems = maximum };
    }
}
