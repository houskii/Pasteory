using System;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed partial class SettingsWindow
{
    private void BuildLinkRules(Panel layout)
    {
        var sessions = SettingsCard(layout, "Pasteory sign-in sessions");
        foreach (var rule in LinkTitles.BuiltInSignIns.Select(preset =>
            app.Settings.LinkSignIns.FirstOrDefault(item => item.Id == preset.Id) ?? preset)
            .Concat(app.Settings.LinkSignIns.Where(rule => !LinkTitles.IsBuiltInSignIn(rule))))
        {
            var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
            AddAction(actions, rule.Enabled ? "Sign in again…" : "Sign in…", async () =>
            {
                if (!await app.LinkSessions.ShowAsync(app.DataDirectory, rule, this)) return;
                var next = app.Settings with
                {
                    LinkSignIns = [.. app.Settings.LinkSignIns.Where(item => item.Id != rule.Id), rule with { Enabled = true }]
                };
                if (!app.SaveSettings(next)) return;
                Select(SettingsPage.Links, rebuild: true);
                int count = await app.ResolveMatchingLinksAsync(rule.Pattern);
                SetStatus(Labels.Format("Retried {0} links.", count));
            });
            if (!LinkTitles.IsBuiltInSignIn(rule)) AddAction(actions, "Edit", () => EditSignIn(rule));
            if (rule.Enabled)
            {
                AddAction(actions, "Clear session", async () =>
                {
                    if (!ClipMenus.Confirm(this, "Clear this Pasteory sign-in session?")) return;
                    try
                    {
                        await app.LinkSessions.ClearAsync(app.DataDirectory, rule, new WindowInteropHelper(this).Handle);
                        if (app.SaveSettings(app.Settings with { LinkSignIns = app.Settings.LinkSignIns.Select(item =>
                            item.Id == rule.Id ? item with { Enabled = false } : item).ToArray() }))
                            Select(SettingsPage.Links, rebuild: true);
                    }
                    catch (Exception error) when (LinkSignIn.WebError(error)) { SetStatus(error.Message); }
                });
            }
            if (!LinkTitles.IsBuiltInSignIn(rule)) actions.Children.Add(Ui.IconButton(Glyph.Close, "Remove sign-in rule", async () =>
            {
                if (!ClipMenus.Confirm(this, "Remove this sign-in rule and clear its session?")) return;
                try
                {
                    await app.LinkSessions.ClearAsync(app.DataDirectory, rule, new WindowInteropHelper(this).Handle);
                    if (app.SaveSettings(app.Settings with { LinkSignIns = app.Settings.LinkSignIns.Where(item => item.Id != rule.Id).ToArray() }))
                        Select(SettingsPage.Links, rebuild: true);
                }
                catch (Exception error) when (LinkSignIn.WebError(error)) { SetStatus(error.Message); }
            }));
            sessions.Children.Add(Row(rule.Name, actions, Labels.Get(rule.Enabled ? "Session ready" : "Sign-in required") +
                " · " + (LinkTitles.IsBuiltInSignIn(rule) ? new Uri(rule.SignInUrl).Host : rule.Pattern)));
        }
        sessions.Children.Add(Row("Site rules", Ui.Button("Add sign-in rule…", () => EditSignIn(null), "PrimaryButton"),
            "Pasteory uses a separate browser profile for each sign-in rule."));

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
            var next = new LinkSignInRule(rule?.Id ?? Guid.NewGuid(), name.Text.Trim(), expression, uri.AbsoluteUri,
                rule is { Enabled: true } && rule.SignInUrl == uri.AbsoluteUri);
            var rules = app.Settings.LinkSignIns.ToList();
            int position = rules.FindIndex(item => item.Id == next.Id);
            if (position < 0) rules.Add(next); else rules[position] = next;
            if (!app.SaveSettings(app.Settings with { LinkSignIns = rules.ToArray() })) return false;
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
