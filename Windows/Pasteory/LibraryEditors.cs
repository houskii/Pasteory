using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed record EditorView(FrameworkElement Content, IInputElement InitialFocus, Action? Submit = null);

internal static class LibraryEditors
{
    internal static EditorView ClipInfo(App app, Clip clip, bool focusGroups, Action close)
    {
        var form = new StackPanel();
        var title = Ui.Field("Title", clip.Title, 160);
        var note = Ui.Field("Note", clip.Note, 16000);
        note.AcceptsReturn = true;
        note.TextWrapping = TextWrapping.Wrap;
        note.MinHeight = 76;
        note.MaxHeight = 145;
        note.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        note.VerticalContentAlignment = VerticalAlignment.Top;
        Ui.AddField(form, "Title", title);
        Ui.AddField(form, "Note", note);
        var checks = GroupChecks(app, clip, form);
        WireGroupKeys(checks.Select(entry => entry.Check).ToArray());
        bool Save() => app.EditClip(clip.Id, next => next with
        {
            Title = title.Text.Trim(), Note = note.Text.Trim(), Group = "",
            CollectionIds = [.. checks.Where(entry => entry.Check.IsChecked == true).Select(entry => entry.Id),
                .. next.CollectionIds.Where(id => app.Collections.Any(group => group.Id == id && group.IsAi))]
        });
        return Wrap("Edit information", form, focusGroups && checks.Count > 0 ? checks[0].Check : title, Save, close);
    }

    private static void WireGroupKeys(CheckBox[] checks)
    {
        for (int index = 0; index < checks.Length; index++)
        {
            int current = index;
            checks[index].PreviewKeyDown += (_, e) =>
            {
                if (e.Key is not (Key.Up or Key.Down)) return;
                checks[(current + (e.Key == Key.Down ? 1 : checks.Length - 1)) % checks.Length].Focus();
                e.Handled = true;
            };
        }
    }

    internal static List<(Guid Id, CheckBox Check)> GroupChecks(App app, Clip clip, StackPanel form)
    {
        var checks = app.Collections.Where(group => !group.IsSmart && !group.IsAi).Select(group =>
            (group.Id, new CheckBox { Content = group.Name, IsChecked = clip.CollectionIds.Contains(group.Id) })).ToList();
        if (checks.Count == 0) return checks;
        var groups = new StackPanel();
        foreach (var (_, check) in checks) groups.Children.Add(check);
        Ui.AddField(form, "Groups", groups);
        return checks;
    }

    internal static EditorView Group(App app, ClipCollection? existing, bool smart, Action close, Action<Guid>? selected = null)
    {
        var form = new StackPanel();
        var name = Ui.Field("Name", existing?.Name ?? "", 80);
        Ui.AddField(form, "Name", name);
        RuleEditor? editor = null;
        if (smart)
        {
            editor = new RuleEditor(app, existing?.Rules);
            form.Children.Add(editor.Content);
        }
        bool Save()
        {
            var saved = app.SaveCollection(existing?.Id, name.Text, editor?.Rules);
            if (saved is null) return false;
            selected?.Invoke(saved.Id);
            return true;
        }
        return Wrap(existing is null ? smart ? "New smart group" : "New group" : smart ? "Edit smart group" : "Rename group",
            form, name, Save, close);
    }

    internal static EditorView Aggregation(App app, Clip? existing, IEnumerable<Guid> members, string name,
        string? origin, bool chooseMembers, Action close, Action<Guid> selected)
    {
        var form = new StackPanel();
        Guid[] initial = members.Distinct().ToArray();
        form.Children.Add(Ui.Text(Labels.Format("{0} items", initial.Length), 12, "Muted"));
        var title = Ui.Field("Title", name, 160);
        var note = Ui.Field("Note", existing?.Note ?? "", 16000);
        Ui.AddField(form, "Title", title);
        Ui.AddField(form, "Note", note);
        var candidates = chooseMembers ? app.Clips.Where(clip => clip.Kind != ClipKind.Aggregate && clip.TrashedAt is null).ToArray() : [];
        var choices = new List<(Guid Id, CheckBox Check)>();
        if (chooseMembers)
        {
            var list = new StackPanel();
            foreach (var candidate in candidates)
            {
                string text = candidate.DisplayTitle.Length > 0 ? candidate.DisplayTitle : candidate.PlainText ?? Labels.Get(candidate.Kind.ToString());
                var check = new CheckBox { Content = ClipCard.Short(text, 90, 1), IsChecked = initial.Contains(candidate.Id) };
                list.Children.Add(check);
                choices.Add((candidate.Id, check));
            }
            Ui.AddField(form, "Members", list);
        }
        bool Save()
        {
            var saved = app.SaveAggregation(existing?.Id, title.Text, note.Text,
                chooseMembers ? choices.Where(item => item.Check.IsChecked == true).Select(item => item.Id) : initial, origin);
            if (saved is null) return false;
            selected(saved.Id);
            return true;
        }
        return Wrap(existing is null ? "Aggregate clips" : "Edit aggregation", form, title, Save, close);
    }

    internal static EditorView Wrap(string heading, FrameworkElement body, IInputElement focus, Func<bool> save, Action close,
        string submitLabel = "Save")
    {
        var layout = new DockPanel { Margin = new Thickness(14) };
        KeyboardNavigation.SetTabNavigation(layout, KeyboardNavigationMode.Cycle);
        var title = Ui.Text(Labels.Get(heading), 17, strong: true);
        title.Margin = new Thickness(0, 0, 0, 8);
        DockPanel.SetDock(title, Dock.Top);
        layout.Children.Add(title);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 11, 0, 0) };
        var cancel = Ui.Button("Cancel", close);
        cancel.Margin = new Thickness(0, 0, 7, 0);
        buttons.Children.Add(cancel);
        void Submit() { if (save()) close(); }
        buttons.Children.Add(Ui.Button(submitLabel, Submit, "PrimaryButton"));
        DockPanel.SetDock(buttons, Dock.Bottom);
        layout.Children.Add(buttons);
        layout.Children.Add(new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        return new EditorView(new Border
        {
            CornerRadius = new CornerRadius(14), Child = layout, VerticalAlignment = VerticalAlignment.Stretch
        }.WithBackground("Surface"), focus, Submit);
    }

    internal static Border WithBackground(this Border border, string key)
    {
        border.SetResourceReference(Border.BackgroundProperty, key);
        return border;
    }

    internal static void ShowModal(Window owner, string heading, Func<Action, EditorView> create, double width = 520, double height = 540)
    {
        var window = new Window
        {
            Owner = owner, Title = Labels.Get(heading), Width = width, Height = height,
            MinWidth = 320, MinHeight = 320, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.CenterOwner
        };
        var editor = create(window.Close);
        window.Content = editor.Content;
        window.Loaded += (_, _) => Keyboard.Focus(editor.InitialFocus);
        window.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { window.Close(); e.Handled = true; }
            else if (e.Key == Key.Enter && editor.Submit is not null && Keyboard.Modifiers == ModifierKeys.None &&
                Keyboard.FocusedElement is not Button and not ComboBox)
            {
                editor.Submit();
                e.Handled = true;
            }
        };
        window.ShowDialog();
    }
}

internal sealed class RuleEditor
{
    private readonly App app;
    private readonly StackPanel results = new();
    private readonly RuleGroup root;

    internal FrameworkElement Content { get; }
    internal SmartRules Rules => root.Value;

    internal RuleEditor(App app, SmartRules? existing)
    {
        this.app = app;
        root = new RuleGroup(existing, Refresh, 1, null);
        var layout = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        layout.Children.Add(root.Layout);
        var resultLabel = Ui.SectionTitle("Matching preview");
        resultLabel.Margin = new Thickness(0, 12, 0, 6);
        layout.Children.Add(resultLabel);
        layout.Children.Add(new ScrollViewer { Content = results, MaxHeight = 168, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = layout;
        Refresh();
    }

    private void Refresh()
    {
        if (root is null) return;
        results.Children.Clear();
        SmartRules rules = Rules;
        if (!rules.IsValid())
        {
            results.Children.Add(Ui.Text(Labels.Get("Enter a value for each rule."), 12, "Muted"));
            return;
        }
        var now = DateTimeOffset.Now;
        var matches = app.Clips.Where(clip => clip.TrashedAt is null && clip.Kind != ClipKind.Aggregate && rules.Matches(clip, now)).ToList();
        results.Children.Add(Ui.Text(Labels.Format("{0} results", matches.Count), 12, "Muted"));
        foreach (var clip in matches)
        {
            var row = new StackPanel { Margin = new Thickness(0, 5, 0, 1) };
            if (clip.DisplayTitle.Length > 0) row.Children.Add(Ui.Text(clip.DisplayTitle, 12, "AccentInk", strong: true));
            row.Children.Add(Ui.Text(ClipCard.Short(clip.PlainText ?? Labels.Get(clip.Kind.ToString()), 200, 3), 12));
            results.Children.Add(row);
        }
    }

    private sealed class RuleGroup
    {
        private readonly int depth;
        private readonly Action change;
        private readonly CheckBox all;
        private readonly StackPanel rules = new();
        private readonly List<ConditionRow> conditions = [];
        private readonly List<(RuleGroup Group, Border Frame)> groups = [];
        internal StackPanel Layout { get; } = new();
        internal SmartRules Value => new(all.IsChecked == true, conditions.Select(item => item.Value).ToArray(),
            groups.Select(item => item.Group.Value).ToArray());

        internal RuleGroup(SmartRules? value, Action change, int depth, Action? remove)
        {
            this.depth = depth;
            this.change = change;
            var header = new DockPanel();
            all = new CheckBox { Content = Labels.Get("Match all rules"), IsChecked = value?.MatchAll ?? true };
            all.Click += (_, _) => change();
            if (remove is not null)
            {
                var delete = Ui.IconButton(Glyph.Close, "Remove rule group", remove);
                DockPanel.SetDock(delete, Dock.Right);
                header.Children.Add(delete);
            }
            header.Children.Add(all);
            Layout.Children.Add(header);
            Layout.Children.Add(rules);
            var controls = new WrapPanel { Margin = new Thickness(0, 4, 0, 3) };
            var add = Ui.Button("Add rule", () => { AddCondition(null); change(); });
            add.Margin = new Thickness(0, 0, 6, 0);
            controls.Children.Add(add);
            if (depth < 5) controls.Children.Add(Ui.Button("Add rule group", () => { AddGroup(null); change(); }));
            Layout.Children.Add(controls);

            foreach (var condition in value?.Conditions ?? []) AddCondition(condition);
            foreach (var group in value?.Groups ?? []) AddGroup(group);
            if (value is null) AddCondition(null);
        }

        private void AddCondition(SmartCondition? value)
        {
            ConditionRow? row = null;
            row = new ConditionRow(value, change, () =>
            {
                conditions.Remove(row!);
                rules.Children.Remove(row!.Layout);
                change();
            });
            conditions.Add(row);
            rules.Children.Add(row.Layout);
        }

        private void AddGroup(SmartRules? value)
        {
            (RuleGroup Group, Border Frame) item = default;
            var child = new RuleGroup(value, change, depth + 1, () =>
            {
                groups.Remove(item);
                rules.Children.Remove(item.Frame);
                change();
            });
            var frame = new Border { BorderThickness = new Thickness(2, 0, 0, 0), Padding = new Thickness(9, 2, 0, 3),
                Margin = new Thickness(4, 5, 0, 2), Child = child.Layout };
            frame.SetResourceReference(Border.BorderBrushProperty, "AccentTint");
            item = (child, frame);
            groups.Add(item);
            rules.Children.Add(frame);
        }
    }

    private sealed class ConditionRow
    {
        private readonly ComboBox field;
        private readonly ComboBox comparison;
        private readonly ContentControl valueHost = new();
        private FrameworkElement editor = null!;
        internal FrameworkElement Layout { get; }
        internal SmartCondition Value => new((RuleField)(this.field.SelectedValue ?? RuleField.Text),
            (RuleComparison)(comparison.SelectedValue ?? RuleComparison.Contains),
            editor is ComboBox picker ? (string?)picker.SelectedValue ?? "" : ((TextBox)editor).Text);

        internal ConditionRow(SmartCondition? value, Action change, Action delete)
        {
            field = Select(Enum.GetValues<RuleField>(), value?.Field ?? RuleField.Text);
            comparison = Select(Enum.GetValues<RuleComparison>(), value?.Comparison ?? RuleComparison.Contains);
            var toolbar = new DockPanel();
            var remove = Ui.IconButton(Glyph.Close, "Remove rule", delete);
            DockPanel.SetDock(remove, Dock.Right);
            toolbar.Children.Add(remove);
            var pickers = new Grid();
            pickers.ColumnDefinitions.Add(new ColumnDefinition());
            pickers.ColumnDefinitions.Add(new ColumnDefinition());
            field.Margin = new Thickness(0, 0, 5, 0);
            Grid.SetColumn(comparison, 1);
            pickers.Children.Add(field);
            pickers.Children.Add(comparison);
            toolbar.Children.Add(pickers);
            var row = new StackPanel { Margin = new Thickness(0, 4, 0, 5) };
            row.Children.Add(toolbar);
            valueHost.Margin = new Thickness(0, 3, 0, 0);
            row.Children.Add(valueHost);
            Layout = row;
            SetValueEditor(value?.Value, change);
            field.SelectionChanged += (_, _) =>
            {
                SetValueEditor(null, change);
                change();
            };
            comparison.SelectionChanged += (_, _) => change();
        }

        private void SetValueEditor(string? initial, Action change)
        {
            string[]? options = ((RuleField?)field.SelectedValue) switch
            {
                RuleField.Kind => Enum.GetNames<ClipKind>().Where(value => value != "Aggregate").ToArray(),
                RuleField.Conversion => ["Any", .. Enum.GetNames<TextTool>(), "None"],
                RuleField.Favorite or RuleField.Pinned => ["True", "False"],
                RuleField.Priority => Enum.GetNames<ClipPriority>(), _ => null
            };
            if (options is null)
            {
                var box = Ui.Field("Value", initial ?? "", 500);
                box.TextChanged += (_, _) => change();
                editor = box;
            }
            else
            {
                comparison.SelectedValue = comparison.SelectedValue is RuleComparison.DoesNotEqual
                    ? RuleComparison.DoesNotEqual : RuleComparison.Equals;
                var picker = Select(options, initial ?? options[0]);
                picker.SelectionChanged += (_, _) => change();
                editor = picker;
            }
            valueHost.Content = editor;
        }

        private static ComboBox Select<T>(T[] values, T selected) => new()
        {
            ItemsSource = values.Select(value => new { Value = value, Title = Labels.Get(value!.ToString()!) }).ToArray(),
            DisplayMemberPath = "Title", SelectedValuePath = "Value", SelectedValue = selected, MinHeight = 25
        };
    }
}
