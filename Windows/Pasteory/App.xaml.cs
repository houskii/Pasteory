using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;
using Pasteory.Core;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace Pasteory.Windows;

public partial class App : Application
{
    private string dataDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pasteory");
    private HistoryStore history = null!;
    private HistoryWindow window = null!;
    private SettingsWindow? settingsWindow;
    private Forms.NotifyIcon? tray;
    private Forms.ToolStripMenuItem? pauseMenuItem;
    private Drawing.Icon? icon;
    private HwndSource? messages;
    private Mutex? instance;
    private EventWaitHandle? openRequest;
    private RegisteredWaitHandle? openRegistration;
    private bool ownsInstance;
    private bool listening;
    private bool hotkeyAvailable;
    private bool disableHotkey;
    private bool disableCapture;
    private bool isolated;
    internal bool AutomationWindow { get; private set; }
    private bool pasting;
    private uint observedSequence;
    private nint pasteTarget;
    private uint pasteTargetProcess;
    internal bool Exiting { get; private set; }
    internal LocalSettings Settings { get; private set; } = new();
    internal IReadOnlyList<Clip> Clips => history?.Clips ?? [];
    internal IReadOnlyList<ClipCollection> Collections => history?.Collections ?? [];
    internal IReadOnlyList<Guid> SearchClipIds(string query, System.Threading.CancellationToken cancellation) =>
        history?.SearchIds(query, cancellation: cancellation) ?? [];
    internal string DataDirectory => dataDirectory;
    internal bool ShortcutAvailable => hotkeyAvailable;
    internal bool CaptureAvailable => listening;
    private readonly DispatcherTimer maintenance = new() { Interval = TimeSpan.FromHours(1) };
    private readonly DispatcherTimer aiTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly CancellationTokenSource lifetime = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        int dataArgument = Array.IndexOf(e.Args, "--data-root");
        isolated = dataArgument >= 0 && dataArgument + 1 < e.Args.Length && Path.IsPathFullyQualified(e.Args[dataArgument + 1]);
        if (isolated) dataDirectory = Path.GetFullPath(e.Args[dataArgument + 1]);
        if (e.Args.Contains(ChromeBridge.Origin, StringComparer.Ordinal) ||
            e.Args.Contains("--chrome-native-messaging-host", StringComparer.Ordinal))
        {
            _ = RunChromeHostAsync();
            return;
        }
        int restartIndex = Array.LastIndexOf(e.Args, "--restart-after");
        if (restartIndex >= 0 && restartIndex + 1 < e.Args.Length && int.TryParse(e.Args[restartIndex + 1], out int previous))
        {
            try
            {
                using var process = Process.GetProcessById(previous);
                if (process.ProcessName.Equals("Pasteory", StringComparison.OrdinalIgnoreCase)) process.WaitForExit(4000);
            }
            catch (ArgumentException) { }
        }
        disableHotkey = e.Args.Contains("--no-hotkey", StringComparer.Ordinal);
        disableCapture = e.Args.Contains("--no-capture", StringComparer.Ordinal);
        AutomationWindow = isolated && e.Args.Contains("--automation-window", StringComparer.Ordinal);
        Updates = new WindowsUpdates(dataDirectory);
        if (Updates.InstalledNewer() is { } newer && TryLaunchReplacement(newer, waitForExit: false))
        {
            Shutdown();
            return;
        }
        using var identity = WindowsIdentity.GetCurrent();
        string user = identity.User?.Value ?? Environment.UserName;
        if (isolated)
            user += "." + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
                System.Text.Encoding.UTF8.GetBytes(dataDirectory.ToUpperInvariant())))[..20];
        openRequest = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\Pasteory.Open." + user);
        instance = new Mutex(false, "Global\\Pasteory.History." + user);
        ownsInstance = Acquire(instance);
        if (!ownsInstance)
        {
            openRequest.Set();
            Shutdown();
            return;
        }

        try
        {
            Directory.CreateDirectory(dataDirectory);
            Settings = LocalSettings.Load(dataDirectory);
            Labels.Language = Settings.Language;
            Theme.Apply(Resources, Settings);
            history = new HistoryStore(dataDirectory, maxClips: 10_000, maxBytes: 1024L * 1024 * 1024, archiveOverflow: true);
            history.RunMaintenance(DateTimeOffset.Now, Settings.ArchiveAfterDays);
            history.UpdateLinkDetails(LinkFallback);
            Ai = new AiTasks(dataDirectory);
        }
        catch (Exception error) when (IsLocalError(error) || error is JsonException or InvalidDataException)
        {
            MessageBox.Show(Labels.Format("Local data could not be opened at {0}.", dataDirectory) +
                Environment.NewLine + error.Message, "Pasteory", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }

        window = new HistoryWindow(this);
        if (AutomationWindow) window.ShowInTaskbar = true;
        MainWindow = window;
        SystemEvents.UserPreferenceChanged += OnSystemPreferenceChanged;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        CreateTray();
        messages = new HwndSource(new HwndSourceParameters("Pasteory clipboard messages") { ParentWindow = new nint(-3) });
        messages.AddHook(ReceiveMessage);
        observedSequence = NativeMethods.GetClipboardSequenceNumber();
        listening = !disableCapture && NativeMethods.AddClipboardFormatListener(messages.Handle) != 0;
        RegisterShortcut();
        maintenance.Tick += (_, _) =>
        {
            ChangeHistory(() => history.RunMaintenance(DateTimeOffset.Now, Settings.ArchiveAfterDays));
            CheckUpdateIfDue();
            ScheduleWebCacheCheck();
            _ = CheckDueLinkSessionsAsync();
        };
        maintenance.Start();
        StartWebCache();
        _ = RecognizePendingImagesAsync();
        aiTimer.Tick += (_, _) => AiTick();
        aiTimer.Start();
        _ = ChromeBridge.ReceiveAsync(dataDirectory, ChromeEventAsync, lifetime.Token);

        openRegistration = ThreadPool.RegisterWaitForSingleObject(openRequest, (_, _) =>
            Dispatcher.BeginInvoke(new Action(OpenFromTray)), null, Timeout.Infinite, executeOnlyOnce: false);

        bool previewOnboarding = AutomationWindow && e.Args.Contains("--show-onboarding");
        if (e.Args.Contains("--show-library")) OpenSettings(SettingsPage.Library);
        else if (!e.Args.Contains("--tray") && !Settings.CompletedOnboarding && (!isolated || previewOnboarding))
            new WelcomeWindow(this, () => window.Present(keepVisibleForAutomation: previewOnboarding)).Show();
        else if (!e.Args.Contains("--tray")) window.Present(keepVisibleForAutomation: isolated && e.Args.Contains("--show-panel"));
        CheckUpdateIfDue();
        StartLinkSessionRefresh();
    }

    private async Task RunChromeHostAsync()
    {
        await ChromeBridge.RunHostAsync(dataDirectory);
        Shutdown();
    }

    private void OnSystemPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (!Exiting && Settings.Appearance == "System") Dispatcher.BeginInvoke(() => Theme.Apply(Resources, Settings));
    }

    private static bool Acquire(Mutex mutex)
    {
        try { return mutex.WaitOne(0); }
        catch (AbandonedMutexException) { return true; }
    }

    private void CreateTray()
    {
        using var iconStream = GetResourceStream(new Uri("Assets/Pasteory.ico", UriKind.Relative)).Stream;
        icon = new Drawing.Icon(iconStream);
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(Labels.Get("Open quick panel"), null, (_, _) => OpenFromTray());
        menu.Items.Add(Labels.Get("Open library"), null, (_, _) => OpenSettings(SettingsPage.Library));
        pauseMenuItem = (Forms.ToolStripMenuItem)menu.Items.Add("", null, (_, _) =>
            SaveSettings(Settings with { Paused = !Settings.Paused }));
        menu.Items.Add(Labels.Get("Settings"), null, (_, _) => OpenSettings());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Labels.Get("Quit"), null, (_, _) => Shutdown());
        tray = new Forms.NotifyIcon { Icon = icon, Text = "Pasteory", ContextMenuStrip = menu, Visible = true };
        tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) OpenFromTray(); };
    }

    private nint ReceiveMessage(nint handle, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == NativeMethods.ClipboardUpdated)
        {
            _ = CaptureAsync();
            handled = true;
        }
        else if (message == NativeMethods.HotKeyPressed && wParam == NativeMethods.HotKeyId)
        {
            if (window.IsActive)
            {
                window.Dismiss(restoreTarget: true);
            }
            else
            {
                RememberPasteTarget();
                _ = ShowAfterCaptureAsync();
            }
            handled = true;
        }
        return 0;
    }

    private async Task ShowAfterCaptureAsync()
    {
        await CaptureAsync();
        if (!Exiting) window.Present();
    }

    private async Task CaptureAsync()
    {
        uint sequence = NativeMethods.GetClipboardSequenceNumber();
        if (sequence == 0 || sequence == observedSequence) return;
        observedSequence = sequence;
        if (Settings.Paused || disableCapture) return;

        var (source, path) = NativeMethods.ClipboardOwner();
        if (Settings.ShouldIgnore(source)) return;

        for (int attempt = 0; attempt < 5; attempt++)
        {
            if (Exiting || Settings.Paused || Settings.ShouldIgnore(source) ||
                sequence != NativeMethods.GetClipboardSequenceNumber()) return;
            (Clip Clip, byte[]? Image)? capture;
            try
            {
                var data = Clipboard.GetDataObject();
                capture = data is null ? null : ClipboardFormats.Read(data, source);
            }
            catch (ExternalException)
            {
                if (attempt < 4) await Task.Delay(35);
                continue;
            }
            catch (Exception error) when (error is ArgumentException or NotSupportedException or FormatException or IOException)
            {
                return;
            }

            if (capture is { } item && sequence == NativeMethods.GetClipboardSequenceNumber())
            {
                Clip clip = item.Clip with { SourcePath = path };
                if (clip.Kind == ClipKind.Files)
                    clip = clip with { FileIdentity = await Task.Run(() => FileFingerprint(clip.Files)) };
                if (Exiting || Settings.Paused || Settings.ShouldIgnore(source)) return;
                var sourceContext = ReadSourceContext(clip, out nint chatWindow);
                clip = clip with { Captures = [sourceContext], OcrPending = item.Image is not null && Settings.RecognizeImages };
                if (clip.Kind == ClipKind.Link) clip = clip with { LinkDetails = LinkFallback(clip) };
                Clip? saved = null;
                ChangeHistory(() =>
                {
                    if (!history.Capture(clip, item.Image, out saved))
                        Notify("The history limit was reached. Unpin or unfavorite a clip to make room.");
                });
                if (saved is not null)
                {
                    _ = EnrichLinkAsync(saved);
                    if (saved.OcrPending) _ = RecognizePendingImagesAsync();
                    if (chatWindow != 0) _ = EnrichChatAsync(saved.Id, sourceContext, chatWindow);
                }
            }
            return;
        }
    }

    private void RememberPasteTarget()
    {
        nint current = NativeMethods.GetForegroundWindow();
        uint process = NativeMethods.ProcessId(current);
        if (process == 0 || process == Environment.ProcessId) return;
        pasteTarget = current;
        pasteTargetProcess = process;
    }

    internal void RestoreFocus()
    {
        if (pasteTarget != 0 && NativeMethods.ProcessId(pasteTarget) == pasteTargetProcess)
            NativeMethods.SetForegroundWindow(pasteTarget);
    }

    private void OpenFromTray()
    {
        if (Exiting) return;
        if (!window.IsActive) RememberPasteTarget();
        _ = ShowAfterCaptureAsync();
    }

    internal async Task UseClipAsync(Clip clip, bool paste, bool plainText, ClipboardItem? original = null)
    {
        if (pasting || clip.Kind == ClipKind.Aggregate || clip.TrashedAt is not null) return;
        if (plainText && original is null && string.IsNullOrEmpty(clip.PlainClipboardText))
        {
            Notify("This clip has no plain text.");
            return;
        }
        uint writtenSequence;
        try
        {
            DataObject data;
            if (original is null)
            {
                byte[]? image = clip.HasImage && !plainText ? history.ReadImage(clip) : null;
                data = ClipboardFormats.Create(clip, plainText, image);
            }
            else
            {
                var item = MacClipboardFormats.Project(original, history.ReadRepresentation, includeImage: !plainText);
                if (item.IsEmpty)
                {
                    Notify("This clipboard format could not be opened on Windows.");
                    return;
                }
                data = ClipboardFormats.Create(clip with
                {
                    Text = item.Text, Html = item.Html, Rtf = item.Rtf, Files = item.Files,
                    Note = "", RecognizedText = null, OcrInNote = false,
                    ImageFormat = item.Image?.Format ?? ClipImageFormat.Png
                }, plainText, item.Image?.Bytes);
                if (plainText && !data.GetDataPresent(DataFormats.UnicodeText, false))
                {
                    Notify("This clip has no plain text.");
                    return;
                }
            }
            Clipboard.SetDataObject(data, copy: true);
            writtenSequence = NativeMethods.GetClipboardSequenceNumber();
            if (!NativeMethods.OwnsClipboard())
            {
                Notify("The clipboard changed. Try again.");
                return;
            }
            observedSequence = writtenSequence;
        }
        catch (ExternalException)
        {
            Notify("The clipboard is busy. Try again.");
            return;
        }
        catch (Exception error) when (IsLocalError(error) || error is ArgumentException or NotSupportedException or InvalidDataException)
        {
            Notify(clip.HasImage ? "The saved image could not be opened." : error.Message);
            return;
        }

        if (!paste)
        {
            Notify("Clipboard copied.");
            return;
        }

        nint target = pasteTarget;
        uint process = pasteTargetProcess;
        if (target == 0)
        {
            Notify("Copied. Press Ctrl+V in the destination app to paste.");
            return;
        }

        pasting = true;
        try
        {
            window.Dismiss(restoreTarget: false);
            settingsWindow?.Hide();
            NativeMethods.SetForegroundWindow(target);
            for (int attempt = 0; attempt < 20; attempt++)
            {
                if (Exiting || window.IsVisible) return;
                if (writtenSequence != NativeMethods.GetClipboardSequenceNumber() || !NativeMethods.OwnsClipboard())
                {
                    Notify("The clipboard changed. Try again.");
                    return;
                }
                if (target == NativeMethods.GetForegroundWindow() && process == NativeMethods.ProcessId(target) &&
                    !NativeMethods.ModifiersHeld())
                {
                    if (NativeMethods.SendPaste())
                    {
                        ChangeHistory(() => history.RecordPaste(clip.Id));
                        return;
                    }
                    break;
                }
                await Task.Delay(25);
            }
            Notify("Copied. Press Ctrl+V in the destination app to paste.");
        }
        finally { pasting = false; }
    }

    internal byte[] ReadImage(Clip clip) => history.ReadImage(clip);
    private bool ChangeHistory(Action change)
    {
        try
        {
            var previous = history.Clips;
            change();
            try { Ai?.ObserveClips(Settings.Ai, previous, history.Clips); }
            catch (Exception error) when (AiTasks.Expected(error)) { Notify(error.Message); }
            if (window.IsVisible) window.Refresh();
            if (settingsWindow?.IsVisible == true) settingsWindow.RefreshLibrary();
            return true;
        }
        catch (Exception error) when (IsLocalError(error) || error is ArgumentException)
        {
            Notify(error.Message);
            return false;
        }
    }

    internal void OpenSettings(SettingsPage? page = null)
    {
        if (Exiting) return;
        if (settingsWindow?.IsActive != true) RememberPasteTarget();
        settingsWindow ??= new SettingsWindow(this);
        settingsWindow.Present(page);
    }

    internal void OpenDataFolder()
    {
        try { Process.Start(new ProcessStartInfo(dataDirectory) { UseShellExecute = true }); }
        catch (Exception error) when (IsLocalError(error) || error is System.ComponentModel.Win32Exception)
        {
            Notify(error.Message);
        }
    }

    internal bool SaveSettings(LocalSettings next)
    {
        bool shortcutChanged = Shortcuts.Text(Settings, Command.ShowPanel) != Shortcuts.Text(next, Command.ShowPanel);
        bool groupViewChanged = Settings.GroupDisplay != next.GroupDisplay ||
            !Settings.Shortcuts.SequenceEqual(next.Shortcuts);
        bool pausedChanged = Settings.Paused != next.Paused;
        bool themeChanged = Settings.Theme != next.Theme || Settings.Appearance != next.Appearance;
        bool linkRulesChanged = !Settings.LinkFallbacks.SequenceEqual(next.LinkFallbacks);
        bool enableWebCacheCleanup = !Settings.AutomaticWebCacheCleanup && next.AutomaticWebCacheCleanup;
        bool enableImageOcr = !Settings.RecognizeImages && next.RecognizeImages;
        bool linkRefreshChanged = Settings.ResolveLinks != next.ResolveLinks;
        bool aiScopeChanged = Settings.Ai.Enabled != next.Ai.Enabled || Settings.Ai.ShareNotes != next.Ai.ShareNotes ||
            Settings.Ai.ShareOcr != next.Ai.ShareOcr || Settings.Ai.ShareSource != next.Ai.ShareSource ||
            Settings.Ai.ShareResources != next.Ai.ShareResources || Settings.Ai.Endpoint != next.Ai.Endpoint ||
            Settings.Ai.Model != next.Ai.Model;
        bool startupChanged = Settings.StartAtLogin != next.StartAtLogin && !isolated;
        try
        {
            if (startupChanged) SetStartAtLogin(next.StartAtLogin);
            next.Save(dataDirectory);
        }
        catch (Exception error) when (IsLocalError(error) || error is System.Security.SecurityException)
        {
            if (startupChanged) TryRestoreStartAtLogin();
            Notify(error.Message);
            return false;
        }
        Settings = next;
        if (enableWebCacheCleanup) ScheduleWebCacheCheck();
        if (enableImageOcr) _ = RecognizePendingImagesAsync();
        if (linkRefreshChanged)
        {
            settingsWindow?.UpdateLinkSessionRows();
            if (next.ResolveLinks) _ = CheckDueLinkSessionsAsync();
        }
        if (linkRulesChanged) ChangeHistory(() => history.UpdateLinkDetails(LinkFallback));
        if (aiScopeChanged) Ai?.Pause();
        if (themeChanged) Theme.Apply(Resources, Settings);
        if (pausedChanged) observedSequence = NativeMethods.GetClipboardSequenceNumber();
        if (window.IsVisible) window.Refresh();
        if (groupViewChanged && settingsWindow?.IsVisible == true) settingsWindow.RefreshLibrary();
        if (shortcutChanged) RegisterShortcut();
        else RefreshStatus();
        return true;
    }

    internal bool SetGroupProfile(string profile) => Settings.GroupDisplay == profile ||
        GroupNavigation.Profiles.Contains(profile) && SaveSettings(Settings with { GroupDisplay = profile });

    private void RegisterShortcut()
    {
        if (messages is null) return;
        if (hotkeyAvailable) NativeMethods.UnregisterHotKey(messages.Handle, NativeMethods.HotKeyId);
        hotkeyAvailable = false;
        if (!disableHotkey && Shortcut.TryParse(Shortcuts.Text(Settings, Command.ShowPanel), out var binding))
        {
            uint modifiers = NativeMethods.NoRepeat;
            if (binding.Modifiers.HasFlag(ModifierKeys.Control)) modifiers |= NativeMethods.Control;
            if (binding.Modifiers.HasFlag(ModifierKeys.Shift)) modifiers |= NativeMethods.Shift;
            if (binding.Modifiers.HasFlag(ModifierKeys.Alt)) modifiers |= NativeMethods.Alt;
            if (binding.Modifiers.HasFlag(ModifierKeys.Windows)) modifiers |= NativeMethods.Win;
            hotkeyAvailable = NativeMethods.RegisterHotKey(messages.Handle, NativeMethods.HotKeyId, modifiers,
                (uint)KeyInterop.VirtualKeyFromKey(binding.Key)) != 0;
        }
        RefreshStatus();
    }

    private void RefreshStatus()
    {
        if (tray is not null) tray.Text = Settings.Paused ? $"Pasteory · {Labels.Get("Capture paused")}" : "Pasteory";
        if (pauseMenuItem is not null)
            pauseMenuItem.Text = Labels.Get(Settings.Paused ? "Resume clipboard capture" : "Pause clipboard capture");
        if (window.IsVisible && !listening && !disableCapture)
            window.SetStatus(Labels.Get("Clipboard monitoring could not start. Restart Pasteory to retry."));
        else if (window.IsVisible && Settings.Paused)
            window.SetStatus(Labels.Get("Capture paused"));
        else if (window.IsVisible && !hotkeyAvailable && !disableHotkey && Shortcuts.Text(Settings, Command.ShowPanel).Length > 0)
            window.SetStatus(Labels.Get("The global shortcut is unavailable. Open history from the tray or change the shortcut in Settings."));
    }

    internal void Notify(string message)
    {
        window.SetStatus(Labels.Get(message));
        if (settingsWindow?.IsVisible == true) settingsWindow.SetStatus(Labels.Get(message));
        else if (!window.IsVisible && tray is not null)
            tray.ShowBalloonTip(2500, "Pasteory", Labels.Get(message), Forms.ToolTipIcon.Info);
    }

    internal static bool IsLocalError(Exception error) => error is IOException or UnauthorizedAccessException;

    protected override void OnExit(ExitEventArgs e)
    {
        Exiting = true;
        maintenance.Stop();
        StopWebCache();
        aiTimer.Stop();
        lifetime.Cancel();
        SystemEvents.UserPreferenceChanged -= OnSystemPreferenceChanged;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        openRegistration?.Unregister(null);
        openRequest?.Dispose();
        if (messages is not null)
        {
            if (hotkeyAvailable) NativeMethods.UnregisterHotKey(messages.Handle, NativeMethods.HotKeyId);
            if (listening) NativeMethods.RemoveClipboardFormatListener(messages.Handle);
            messages.Dispose();
        }
        if (tray is not null)
        {
            tray.Visible = false;
            tray.ContextMenuStrip?.Dispose();
            tray.Dispose();
        }
        icon?.Dispose();
        if (ownsInstance) instance?.ReleaseMutex();
        instance?.Dispose();
        base.OnExit(e);
    }
}
