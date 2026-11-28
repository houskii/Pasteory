using System;
using System.Collections.Generic;
using System.Linq;
using Pasteory.Core;

namespace Pasteory.Windows;

public partial class App
{
    private AiGroupReading? aiGroupReading;
    private HashSet<Guid> deferredQuick = [];
    private HashSet<Guid> deferredLibrary = [];

    internal int UnreadAiGroup(Guid? id)
    {
        if (id is not { } group || aiGroupReading is null) return 0;
        aiGroupReading.Update(Clips, Collections);
        return aiGroupReading.Unread(group);
    }

    internal void OpenAiGroup(Guid? id)
    {
        if (id is not { } group || aiGroupReading is null) return;
        try
        {
            aiGroupReading.Update(Clips, Collections);
            if (!aiGroupReading.Open(group, DateTimeOffset.UtcNow)) return;
            if (window.IsVisible) window.RefreshAiGroupBadges();
            settingsWindow?.RefreshAiGroupBadges();
        }
        catch (Exception error) when (AiTasks.Expected(error)) { Notify(error.Message); }
    }

    internal IReadOnlySet<Guid> DeferredOrganization(bool quick) => quick ? deferredQuick : deferredLibrary;

    internal void LeaveUngrouped(bool quick)
    {
        if (quick) deferredQuick = [];
        else deferredLibrary = [];
    }

    internal void ShowOrganizationResults()
    {
        if (deferredQuick.Count == 0 && deferredLibrary.Count == 0) return;
        deferredQuick = [];
        deferredLibrary = [];
        if (window.IsVisible) window.Refresh();
        settingsWindow?.RefreshLibrary();
    }

    private void DeferOrganization(IReadOnlyList<Clip> before)
    {
        bool quick = window.ReadingUngrouped;
        bool library = settingsWindow?.ReadingUngrouped == true;
        if ((!quick && !library) || ReferenceEquals(before, Clips)) return;
        var aiGroups = Collections.Where(group => group.IsAi).Select(group => group.Id).ToHashSet();
        if (aiGroups.Count == 0) return;
        var ungrouped = before.Where(clip => ClipListing.IsUngrouped(clip, aiGroups)).Select(clip => clip.Id).ToHashSet();
        var additions = Clips.Where(clip => ungrouped.Contains(clip.Id) && clip.CollectionIds.Any(aiGroups.Contains)).Select(clip => clip.Id).ToArray();
        if (additions.Length == 0) return;
        if (quick) deferredQuick = [.. deferredQuick, .. additions];
        if (library) deferredLibrary = [.. deferredLibrary, .. additions];
    }
}
