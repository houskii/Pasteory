using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Pasteory.Windows;

public partial class App
{
    internal WindowsUpdates Updates { get; private set; } = null!;
    private bool checkingUpdates;
    private DateTimeOffset lastAutomaticCheck;

    private void CheckUpdateIfDue()
    {
        var now = DateTimeOffset.Now;
        if (isolated || !Settings.CheckUpdatesDaily || now - lastAutomaticCheck < TimeSpan.FromHours(1) ||
            Settings.LastUpdateCheck is { } last && now - last < TimeSpan.FromDays(1)) return;
        lastAutomaticCheck = now;
        _ = CheckUpdatesAsync(manual: false);
    }

    internal async Task CheckUpdatesAsync(bool manual, Window? owner = null)
    {
        if (checkingUpdates) return;
        checkingUpdates = true;
        if (manual) Notify("Checking for updates…");
        try
        {
            var offer = await Updates.CheckAsync(lifetime.Token);
            if (Exiting) return;
            SaveSettings(Settings with { LastUpdateCheck = DateTimeOffset.Now });
            if (manual && offer is not null && owner is not null) ShowUpdate(owner);
            else if (manual) Notify("No Windows update is available.");
        }
        catch (Exception error) when (WindowsUpdates.IsUpdateError(error) || error is OperationCanceledException)
        {
            if (manual && !Exiting) Notify(Labels.Get("Update check failed.") + " " + error.Message);
        }
        finally { checkingUpdates = false; }
    }

    internal void ShowUpdate(Window owner)
    {
        if (Updates.Available is not { } offer) return;
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var dialog = new Window
        {
            Owner = owner, Title = Labels.Get("Pasteory update"), Width = 560, Height = 455,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false
        };
        var layout = new DockPanel { Margin = new Thickness(16) };
        var title = Ui.Text(Labels.Format("Pasteory {0} → {1}", WindowsUpdates.CurrentVersion.ToString(3), offer.Version), 19, strong: true);
        title.Margin = new Thickness(0, 0, 0, 9);
        DockPanel.SetDock(title, Dock.Top);
        layout.Children.Add(title);
        var footer = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(footer, Dock.Bottom);
        layout.Children.Add(footer);
        var status = Ui.Text("", 11, "Muted");
        footer.Children.Add(status);
        var progress = new ProgressBar { Minimum = 0, Maximum = 1, Height = 5, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 4, 0, 0) };
        footer.Children.Add(progress);
        var controls = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        footer.Children.Add(controls);
        bool installing = false;
        var later = Ui.Button("Later", () => { if (installing) cancel.Cancel(); else dialog.Close(); });
        later.Margin = new Thickness(0, 0, 7, 0);
        controls.Children.Add(later);
        var install = new Button { Content = Labels.Get("Download and install") };
        install.SetResourceReference(FrameworkElement.StyleProperty, "PrimaryButton");
        controls.Children.Add(install);
        layout.Children.Add(new ScrollViewer { Content = Ui.Text(offer.Notes), VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        dialog.Content = layout;
        dialog.Closing += (_, e) =>
        {
            if (!installing) return;
            cancel.Cancel();
            e.Cancel = true;
        };
        install.Click += async (_, _) =>
        {
            installing = true;
            install.IsEnabled = false;
            later.Content = Labels.Get("Cancel");
            status.Text = Labels.Get("Downloading and verifying…");
            progress.Visibility = Visibility.Visible;
            try
            {
                string executable = await Updates.StageAsync(offer, new Progress<double>(value => progress.Value = value), cancel.Token);
                if (!TryLaunchReplacement(executable, waitForExit: true)) throw new System.IO.IOException("Could not launch the staged update.");
                installing = false;
                dialog.Close();
                Shutdown();
            }
            catch (Exception error) when (WindowsUpdates.IsUpdateError(error) || error is OperationCanceledException)
            {
                installing = false;
                if (cancel.IsCancellationRequested) { dialog.Close(); return; }
                status.Text = error.Message;
                install.IsEnabled = true;
                later.Content = Labels.Get("Later");
            }
        };
        dialog.ShowDialog();
    }
}
