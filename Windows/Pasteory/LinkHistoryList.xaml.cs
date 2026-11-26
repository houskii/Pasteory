using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;

namespace Pasteory.Windows;

public partial class LinkHistoryList : UserControl
{
    private LinkHistoryEntry[] shown = [];
    private LinkHistoryCard[] cards = [];

    internal LinkHistoryList()
    {
        InitializeComponent();
    }

    internal Action<LinkHistoryEntry>? Retry { get; init; }
    internal Action<LinkHistoryEntry>? SignIn { get; init; }
    internal Action<FrameworkElement, LinkHistoryEntry>? More { get; init; }

    internal void Show(LinkHistoryEntry[] entries, Func<LinkHistoryEntry, bool> isBusy, Func<Uri, bool> canSignIn)
    {
        if (Records.ItemsSource is not null && shown.SequenceEqual(entries))
        {
            foreach (var card in cards) card.UpdateBusy(isBusy(card.Entry));
            return;
        }
        shown = entries;
        var selected = (Records.SelectedItem as LinkHistoryCard)?.Entry.Key;
        var rows = new List<object>();
        var rendered = new List<LinkHistoryCard>();
        foreach (var day in entries.GroupBy(entry => LinkHistory.Day(entry.ActivityAt)))
        {
            rows.Add(new LinkHistoryHeading(day.Key.ToString("D"), Labels.Format("{0} links", day.Count())));
            foreach (var entry in day)
            {
                var card = new LinkHistoryCard(entry, isBusy(entry), canSignIn);
                rendered.Add(card);
                rows.Add(card);
            }
        }
        cards = rendered.ToArray();
        Records.ItemsSource = rows;
        if (selected is not null) Records.SelectedItem = cards.FirstOrDefault(card => card.Entry.Key == selected);
        Empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnRetry(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: LinkHistoryCard card }) Retry?.Invoke(card.Entry);
    }

    private void OnSignIn(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: LinkHistoryCard card }) SignIn?.Invoke(card.Entry);
    }

    private void OnMore(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: LinkHistoryCard card } source) More?.Invoke(source, card.Entry);
    }
}

internal sealed record LinkHistoryHeading(string Date, string Count)
{
    public string AccessibleName => Date + " · " + Count;
    public bool IsHeading => true;
}

internal sealed class LinkHistoryCard(LinkHistoryEntry entry, bool resolving, Func<Uri, bool> canSignIn) : INotifyPropertyChanged
{
    private bool busy = resolving;
    public LinkHistoryEntry Entry { get; } = entry;
    public bool IsHeading => false;
    public string AccessibleName => Entry.Title + " · " + Status;
    public string Status => Labels.Get(Entry.Status);
    public string Sources => (Entry.Applications.Length == 0 ? Labels.Get("Source app unknown") : string.Join(", ", Entry.Applications)) + " · " + Entry.Host;
    public string Times => string.Join(Environment.NewLine,
        Labels.Format("Added {0}", Entry.AddedAt.ToLocalTime().ToString("g")),
        (Entry.Details is { } details ? Labels.Format("Latest attempt {0}", details.AttemptedAt.ToLocalTime().ToString("G")) :
            Labels.Get("Latest attempt unavailable")) + " · " + Labels.Get(Entry.Details?.Source ?? "URL fallback")) +
        (Entry.LastResolvedAt is { } success ? Environment.NewLine + Labels.Format("Last successful resolution {0}", success.ToLocalTime().ToString("g")) : "");
    public string Diagnostics => LinkHistory.Diagnostics(Entry.Details?.HttpStatus, Entry.Details?.DurationMilliseconds);
    public bool RetainsPreviousTitle => Entry.RetainsPreviousTitle;
    public bool HasIssue => Entry.Status != "Resolved";
    public bool CanRetry => !busy;
    public string RetryLabel => Labels.Get(busy ? "Resolving…" : "Retry resolution");
    public string SignInLabel => Labels.Get(HasIssue && canSignIn(Entry.Url) ? "Sign in and resolve" : "Configure sign-in…");

    public event PropertyChangedEventHandler? PropertyChanged;

    internal void UpdateBusy(bool value)
    {
        if (busy == value) return;
        busy = value;
        PropertyChanged?.Invoke(this, new(nameof(CanRetry)));
        PropertyChanged?.Invoke(this, new(nameof(RetryLabel)));
    }
}
