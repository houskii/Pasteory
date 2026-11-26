using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed partial class SettingsWindow
{
    private readonly Dictionary<Guid, Action> linkSessionRows = [];

    private void BuildLinkRules(Panel layout)
    {
        var sessions = SettingsCard(layout, "Pasteory sign-in sessions");
        linkSessionRows.Clear();
        foreach (var rule in LinkTitles.BuiltInSignIns.Select(preset =>
            app.Settings.LinkSignIns.FirstOrDefault(item => item.Id == preset.Id) ?? preset)
            .Concat(app.Settings.LinkSignIns.Where(rule => !LinkTitles.IsBuiltInSignIn(rule))))
            sessions.Children.Add(BuildLinkSessionRow(rule));
        sessions.Children.Add(Row("Site rules", Ui.Button("Add sign-in rule…", () => EditSignIn(null), "PrimaryButton"),
            "Each rule uses a separate browser profile. Automatic refresh runs when link resolution is enabled."));

        var fallbacks = SettingsCard(layout, "Fallback rules");
        foreach (var rule in app.Settings.LinkFallbacks)
        {
            var actions = new WrapPanel();
            AddAction(actions, "Edit", () =>
            {
                if (rule.Route is not null) EditRouteFallback(rule);
                else EditFallback(rule);
            });
            actions.Children.Add(Ui.IconButton(Glyph.Close, "Remove fallback rule", () =>
            {
                if (app.SaveSettings(app.Settings with { LinkFallbacks = app.Settings.LinkFallbacks.Where(item => item != rule).ToArray() }))
                    Select(SettingsPage.Links, rebuild: true);
            }));
            fallbacks.Children.Add(Row(rule.Route is { Name.Length: > 0 } route ? route.Name : rule.Title, actions, rule.Pattern));
        }
        var addFallback = new WrapPanel();
        AddAction(addFallback, "Add fallback rule…", () => EditRouteFallback(null));
        AddAction(addFallback, "Add regular expression…", () => EditFallback(null));
        fallbacks.Children.Add(Row("When no useful title is found", addFallback));

        var resolved = app.Clips.Where(clip => clip.TrashedAt is null && clip.Kind == ClipKind.Link &&
            clip.LinkDetails is { LastResolvedAt: not null, Title: not null })
            .OrderByDescending(clip => clip.LinkDetails!.LastResolvedAt).Take(100).ToArray();
        if (resolved.Length > 0)
        {
            var recent = SettingsCard(layout, "Resolved links");
            foreach (var clip in resolved)
            {
                var details = clip.LinkDetails!;
                string description = Labels.Format("Last successful resolution {0}", details.LastResolvedAt!.Value.ToLocalTime().ToString("g")) +
                    " · " + Labels.Get(details.Status);
                if (Uri.TryCreate(clip.Text, UriKind.Absolute, out var url))
                    description = LinkTitles.DisplayUrl(url).Replace("%E2%80%A2", "•") + Environment.NewLine + description;
                recent.Children.Add(Row(details.Title!, Ui.Button("Retry", async () =>
                {
                    await app.ResolveLinkAsync(clip);
                    Select(SettingsPage.Links, rebuild: true);
                }), description));
            }
        }

        var failed = app.Clips.Where(clip => clip.TrashedAt is null && clip.Kind == ClipKind.Link &&
            clip.LinkDetails is { Status: not "Resolved", Route: not null }).OrderByDescending(clip => clip.LinkDetails!.AttemptedAt).ToArray();
        if (failed.Length == 0) return;
        var history = SettingsCard(layout, "Unresolved routes");
        foreach (var group in failed.GroupBy(clip => clip.LinkDetails!.Route!, StringComparer.Ordinal).Take(40))
        {
            var clips = group.ToArray();
            var links = new StackPanel { Margin = new Thickness(8, 5, 0, 3) };
            var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
            AddAction(actions, "Create fallback rule", () => EditFallback(null, LinkTitles.RulePattern(group.Key)));
            AddAction(actions, "Retry route", async () =>
            {
                foreach (var clip in clips)
                {
                    if (app.Exiting) return;
                    await app.ResolveLinkAsync(clip);
                }
                Select(SettingsPage.Links, rebuild: true);
            });
            links.Children.Add(actions);
            foreach (var clip in clips.Take(40))
            {
                var title = ClipCard.Short(clip.DisplayTitle, 72, 1);
                string status = Labels.Get(clip.LinkDetails!.Status);
                if (Uri.TryCreate(clip.Text, UriKind.Absolute, out var url))
                    status += " · " + LinkTitles.DisplayUrl(url).Replace("%E2%80%A2", "•");
                links.Children.Add(Row(title, Ui.Button("Retry", async () =>
                {
                    await app.ResolveLinkAsync(clip);
                    Select(SettingsPage.Links, rebuild: true);
                }), status));
            }
            var route = new Expander
            {
                Header = group.Key + " · " + Labels.Format("{0} links", clips.Length),
                Content = links, Margin = new Thickness(0, 0, 0, 8)
            };
            route.SetResourceReference(ForegroundProperty, "Ink");
            history.Children.Add(route);
        }
    }

    internal void UpdateLinkSessionRows()
    {
        if (current != SettingsPage.Links || !IsVisible) return;
        foreach (var update in linkSessionRows.Values) update();
    }

    private FrameworkElement BuildLinkSessionRow(LinkSignInRule rule)
    {
        LinkSignInRule Current() => app.FindLinkSignInRule(rule.Id) ?? rule;
        var row = new StackPanel { Margin = new Thickness(0, 3, 0, 12) };
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, MaxWidth = 440 };
        var refresh = Ui.Button("Refresh now", async () => await app.RefreshLinkSessionAsync(rule.Id));
        refresh.Margin = new Thickness(5, 0, 0, 2);
        actions.Children.Add(refresh);
        var signIn = Ui.Button("Sign in…", async () =>
        {
            var requested = Current();
            if (!await app.LinkSessions.ShowAsync(app.DataDirectory, requested, this)) return;
            if (app.FindLinkSignInRule(rule.Id) is not { } latest || latest.SignInUrl != requested.SignInUrl) return;
            if (!app.SaveLinkSignInRule(latest with { Enabled = true, Refresh = latest.Refresh.Reset(DateTimeOffset.UtcNow) })) return;
            UpdateLinkSessionRows();
            int count = await app.ResolveMatchingLinksAsync(latest.Pattern);
            SetStatus(Labels.Format("Retried {0} links.", count));
            if (current == SettingsPage.Links) Select(SettingsPage.Links, rebuild: true);
        });
        signIn.Margin = new Thickness(5, 0, 0, 2);
        actions.Children.Add(signIn);
        var clear = Ui.Button("Clear session", async () =>
        {
            if (!ClipMenus.Confirm(this, "Clear this Pasteory sign-in session?")) return;
            try
            {
                var requested = Current();
                await app.LinkSessions.ClearAsync(app.DataDirectory, requested, new WindowInteropHelper(this).Handle);
                if (app.FindLinkSignInRule(rule.Id) is not { } latest || latest.SignInUrl != requested.SignInUrl) return;
                if (app.SaveLinkSignInRule(latest with { Enabled = false, Refresh = latest.Refresh.Reset(null) })) UpdateLinkSessionRows();
            }
            catch (Exception error) when (LinkSignIn.WebError(error)) { SetStatus(error.Message); }
        });
        clear.Margin = new Thickness(5, 0, 0, 2);
        actions.Children.Add(clear);
        if (!LinkTitles.IsBuiltInSignIn(rule))
        {
            AddAction(actions, "Edit", () => EditSignIn(Current()));
            actions.Children.Add(Ui.IconButton(Glyph.Close, "Remove sign-in rule", async () =>
            {
                if (!ClipMenus.Confirm(this, "Remove this sign-in rule and clear its session?")) return;
                try
                {
                    await app.LinkSessions.ClearAsync(app.DataDirectory, Current(), new WindowInteropHelper(this).Handle);
                    if (app.SaveSettings(app.Settings with { LinkSignIns = app.Settings.LinkSignIns.Where(item => item.Id != rule.Id).ToArray() }) &&
                        current == SettingsPage.Links) Select(SettingsPage.Links, rebuild: true);
                }
                catch (Exception error) when (LinkSignIn.WebError(error)) { SetStatus(error.Message); }
            }));
        }
        string address = LinkTitles.IsBuiltInSignIn(rule) && Uri.TryCreate(rule.SignInUrl, UriKind.Absolute, out var uri) ? uri.Host : rule.Pattern;
        row.Children.Add(Row(rule.Name, actions, address));

        var schedule = new WrapPanel { Margin = new Thickness(0, 0, 0, 5) };
        var automaticLabel = Ui.Text(Labels.Get("Automatic session refresh"), 11);
        automaticLabel.VerticalAlignment = VerticalAlignment.Center;
        schedule.Children.Add(automaticLabel);
        var automatic = new CheckBox { Margin = new Thickness(8, 0, 18, 0), VerticalAlignment = VerticalAlignment.Center };
        automatic.SetResourceReference(StyleProperty, "SettingsSwitch");
        AutomationProperties.SetName(automatic, Labels.Get("Automatic session refresh"));
        schedule.Children.Add(automatic);
        var intervalLabel = Ui.Text(Labels.Get("Refresh interval"), 11);
        intervalLabel.VerticalAlignment = VerticalAlignment.Center;
        schedule.Children.Add(intervalLabel);
        var interval = new ComboBox
        {
            ItemsSource = LinkSessionRefresh.Intervals.Select(days => new SessionIntervalOption(days, Labels.Format("{0} days", days))).ToArray(),
            DisplayMemberPath = nameof(SessionIntervalOption.Name), SelectedValuePath = nameof(SessionIntervalOption.Days),
            Margin = new Thickness(8, 0, 0, 0), MinHeight = 24, MinWidth = 86
        };
        AutomationProperties.SetName(interval, Labels.Get("Refresh interval"));
        schedule.Children.Add(interval);
        row.Children.Add(schedule);
        var status = Ui.Text("", 11, "Muted");
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        row.Children.Add(status);

        void UpdateVisuals()
        {
            var latest = Current();
            var state = latest.Refresh;
            bool running = app.IsRefreshingLinkSession(rule.Id);
            signIn.Content = Labels.Get(latest.Enabled ? "Sign in again…" : "Sign in…");
            clear.Visibility = latest.Enabled ? Visibility.Visible : Visibility.Collapsed;
            refresh.IsEnabled = latest.Enabled && !running;
            automatic.IsChecked = state.Automatic;
            interval.SelectedValue = LinkSessionRefresh.Intervals.Contains(state.IntervalDays) ? state.IntervalDays : 14;
            var lines = new List<string>();
            if (state.LastSignedInAt is { } signed)
                lines.Add(Labels.Format("Last sign-in {0}", signed.ToLocalTime().ToString("g")));
            else lines.Add(Labels.Get(latest.Enabled ? "Session ready" : "Sign-in required"));
            if (state.LastAttemptAt is { } attempted)
            {
                string result = running ? "Refreshing session…" : state.Outcome switch
                {
                    LinkSessionOutcome.PageLoaded => "Session page loaded",
                    LinkSessionOutcome.NeedsSignIn => "Sign in again to resume refresh",
                    LinkSessionOutcome.Blocked => "Session refresh blocked",
                    LinkSessionOutcome.Failed => "Session refresh failed",
                    _ => "Session refresh unfinished"
                };
                lines.Add(Labels.Format("Last refresh {0} · {1}", attempted.ToLocalTime().ToString("g"), Labels.Get(result)));
            }
            if (app.Settings.ResolveLinks && latest.Enabled && state.NextRefreshAt() is { } next)
                lines.Add(Labels.Format("Next refresh {0}", next.ToLocalTime().ToString("g")));
            status.Text = string.Join(Environment.NewLine, lines);
        }
        linkSessionRows[rule.Id] = UpdateVisuals;
        UpdateVisuals();
        automatic.Click += (_, _) =>
        {
            var latest = Current();
            if (app.SaveLinkSignInRule(latest with { Refresh = latest.Refresh with { Automatic = automatic.IsChecked == true } }))
                _ = app.CheckDueLinkSessionsAsync();
            UpdateVisuals();
        };
        interval.SelectionChanged += (_, _) =>
        {
            var latest = Current();
            if (interval.SelectedValue is not int days || days == latest.Refresh.IntervalDays) return;
            if (app.SaveLinkSignInRule(latest with { Refresh = latest.Refresh with { IntervalDays = days } }))
                _ = app.CheckDueLinkSessionsAsync();
            UpdateVisuals();
        };
        return row;
    }

    private sealed record SessionIntervalOption(int Days, string Name)
    {
        public override string ToString() => Name;
    }

    private static void AddAction(Panel target, string name, Action act)
    {
        var button = Ui.Button(name, act);
        button.Margin = new Thickness(0, 0, 6, 0);
        target.Children.Add(button);
    }

    private void EditSignIn(LinkSignInRule? rule) => LibraryEditors.ShowModal(this, "Add sign-in rule…", close =>
    {
        var form = new StackPanel();
        var name = Ui.Field("Name", rule?.Name ?? "", 80);
        var pattern = Ui.Field("URL regular expression", rule?.Pattern ?? "", 500);
        var start = Ui.Field("Sign-in address", rule?.SignInUrl ?? "", 4096);
        var matches = Ui.Text("", 11, "Muted");
        Ui.AddField(form, "Name", name);
        Ui.AddField(form, "URL regular expression", pattern);
        Ui.AddField(form, "Sign-in address", start);
        form.Children.Add(matches);
        void ShowMatches()
        {
            string expression = NormalizePattern(pattern.Text);
            if (!ValidPattern(expression))
            {
                matches.Text = Labels.Get("Enter a valid regular expression matching host and path.");
                return;
            }
            int count = app.Clips.Count(clip => clip.Kind == ClipKind.Link && clip.TrashedAt is null &&
                clip.LinkDetails?.Status != "Resolved" && Uri.TryCreate(clip.Text?.Trim(), UriKind.Absolute, out var uri) &&
                LinkResolver.MatchRule(expression, uri) is not null);
            matches.Text = Labels.Format("{0} unresolved links match", count);
        }
        pattern.TextChanged += (_, _) => ShowMatches();
        ShowMatches();
        return LibraryEditors.Wrap(rule is null ? "Add sign-in rule…" : "Edit sign-in rule", form, name, () =>
        {
            string expression = NormalizePattern(pattern.Text);
            if (string.IsNullOrWhiteSpace(name.Text) || !ValidPattern(expression) ||
                !Uri.TryCreate(start.Text.Trim(), UriKind.Absolute, out var uri) || !LinkResolver.Allowed(uri))
            {
                matches.Text = Labels.Get("Enter a name, valid rule and web address.");
                return false;
            }
            var latest = rule is null ? null : app.FindLinkSignInRule(rule.Id);
            bool sameAddress = latest?.SignInUrl == uri.AbsoluteUri;
            var next = new LinkSignInRule(rule?.Id ?? Guid.NewGuid(), name.Text.Trim(), expression, uri.AbsoluteUri,
                sameAddress && latest is { Enabled: true })
            {
                Refresh = latest is null ? new() : sameAddress ? latest.Refresh : latest.Refresh.Reset(null)
            };
            if (!app.SaveLinkSignInRule(next)) return false;
            Select(SettingsPage.Links, rebuild: true);
            return true;
        }, close);
    }, 480, 390);

    private void EditFallback(LinkFallbackRule? rule, string? initialPattern = null) => LibraryEditors.ShowModal(this, "Fallback rules", close =>
    {
        var form = new StackPanel();
        var pattern = Ui.Field("URL regular expression", rule?.Pattern ?? initialPattern ?? "", 500);
        var title = Ui.Field("Title format", rule?.Title ?? "", 220);
        var help = Ui.Text(Labels.Get("Match the host and path. Use $1 for the first capture group."), 11, "Muted");
        Ui.AddField(form, "URL regular expression", pattern);
        Ui.AddField(form, "Title format", title);
        form.Children.Add(help);
        return LibraryEditors.Wrap(rule is null ? "Add fallback rule…" : "Edit fallback rule", form, pattern, () =>
        {
            string expression = NormalizePattern(pattern.Text);
            if (!ValidPattern(expression) || string.IsNullOrWhiteSpace(title.Text))
            {
                help.Text = Labels.Get("Enter a valid regular expression and title.");
                return false;
            }
            var rules = app.Settings.LinkFallbacks.ToList();
            var next = new LinkFallbackRule(expression, title.Text.Trim());
            int index = rule is null ? -1 : rules.IndexOf(rule);
            if (index < 0) rules.Add(next); else rules[index] = next;
            if (!app.SaveSettings(app.Settings with { LinkFallbacks = rules.ToArray() })) return false;
            Select(SettingsPage.Links, rebuild: true);
            return true;
        }, close);
    }, 480, 330);

    private void EditRouteFallback(LinkFallbackRule? rule) => LibraryEditors.ShowModal(this, "Fallback rules", close =>
    {
        var form = new StackPanel();
        var route = rule?.Route;
        var name = Ui.Field("Rule name", route?.Name ?? "", 100);
        var host = Ui.Field("Host pattern", route?.Host ?? "", 253);
        var path = Ui.Field("Path template", route?.Path ?? "/", 300);
        var query = Ui.Field("Required query keys", string.Join(", ", route?.RequiredQueryKeys ?? []), 260);
        var title = Ui.Field("Title format", rule?.Title ?? "", 220);
        Ui.AddField(form, "Rule name", name);
        Ui.AddField(form, "Host pattern", host);
        Ui.AddField(form, "Path template", path);
        Ui.AddField(form, "Required query keys", query);
        Ui.AddField(form, "Title format", title);
        var enabled = new CheckBox { Content = Labels.Get("Enabled"), IsChecked = route?.Enabled != false,
            Margin = new Thickness(0, 6, 0, 0) };
        form.Children.Add(enabled);
        var help = Ui.Text(Labels.Get("Use {id} in a path and {{path.id}} in the title."), 11, "Muted");
        help.Margin = new Thickness(0, 8, 0, 0);
        form.Children.Add(help);
        return LibraryEditors.Wrap(rule is null ? "Add fallback rule…" : "Edit fallback rule", form, name, () =>
        {
            string matchHost = host.Text.Trim().ToLowerInvariant();
            string apex = matchHost.StartsWith("*.", StringComparison.Ordinal) ? matchHost[2..] : matchHost;
            string matchPath = path.Text.Trim();
            if (name.Text.Trim().Length == 0 || Uri.CheckHostName(apex) == UriHostNameType.Unknown ||
                !matchPath.StartsWith('/') || matchPath.Contains('?') || string.IsNullOrWhiteSpace(title.Text))
            {
                help.Text = Labels.Get("Enter a name, host, path and title.");
                return false;
            }
            var keys = query.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct().ToArray();
            var next = new LinkFallbackRule(matchHost + matchPath, title.Text.Trim(), new(route?.Id ?? Guid.NewGuid(),
                name.Text.Trim(), matchHost, matchPath, keys, enabled.IsChecked == true, route?.Priority ?? 100));
            var rules = app.Settings.LinkFallbacks.ToList();
            int index = rule is null ? -1 : rules.IndexOf(rule);
            if (index < 0) rules.Add(next); else rules[index] = next;
            if (!app.SaveSettings(app.Settings with { LinkFallbacks = rules.ToArray() })) return false;
            Select(SettingsPage.Links, rebuild: true);
            return true;
        }, close);
    }, 500, 530);

    private static string NormalizePattern(string raw) => Regex.Replace(raw.Trim(), @"^\^?https?://", "^", RegexOptions.IgnoreCase);

    private static bool ValidPattern(string value)
    {
        if (value.Length == 0) return false;
        try { _ = new Regex(value, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(120)); return true; }
        catch (ArgumentException) { return false; }
    }
}
