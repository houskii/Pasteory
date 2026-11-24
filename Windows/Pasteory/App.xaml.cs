using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using Pasteory.Core;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace Pasteory.Windows;

public partial class App : Application
{
    private readonly string dataDirectory = Path.Combine(
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
    private bool pasting;
    private uint observedSequence;
    private nint pasteTarget;
    private uint pasteTargetProcess;
    internal bool Exiting { get; private set; }
    internal LocalSettings Settings { get; private set; } = new();
    internal IReadOnlyList<Clip> Clips => history.Clips;
    private string Shortcut => Settings.UseAlternateShortcut ? "Ctrl+Alt+V" : "Ctrl+Shift+V";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        using var identity = WindowsIdentity.GetCurrent();
        string user = identity.User?.Value ?? Environment.UserName;
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
            history = new HistoryStore(dataDirectory);
        }
        catch (Exception error) when (IsLocalError(error) || error is JsonException)
        {
            MessageBox.Show(Labels.Format("Local data could not be opened at {0}.", dataDirectory) +
                Environment.NewLine + error.Message, "Pasteory", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }

        window = new HistoryWindow(this);
        MainWindow = window;
        CreateTray();
        messages = new HwndSource(new HwndSourceParameters("Pasteory clipboard messages") { ParentWindow = new nint(-3) });
        messages.AddHook(ReceiveMessage);
        observedSequence = NativeMethods.GetClipboardSequenceNumber();
        listening = NativeMethods.AddClipboardFormatListener(messages.Handle) != 0;
        RegisterShortcut();

        openRegistration = ThreadPool.RegisterWaitForSingleObject(openRequest, (_, _) =>
            Dispatcher.BeginInvoke(new Action(OpenFromTray)), null, Timeout.Infinite, executeOnlyOnce: false);

        OpenFromTray();
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
        menu.Items.Add(Labels.Get("Open history"), null, (_, _) => OpenFromTray());
        pauseMenuItem = (Forms.ToolStripMenuItem)menu.Items.Add("", null, (_, _) =>
            SaveSettings(Settings with { Paused = !Settings.Paused }));
        menu.Items.Add(Labels.Get("Settings"), null, (_, _) =>
        {
            OpenFromTray();
            OpenSettings();
        });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Labels.Get("Quit"), null, (_, _) => Shutdown());
        tray = new Forms.NotifyIcon { Icon = icon, Text = "Pasteory", ContextMenuStrip = menu, Visible = true };
        tray.MouseDoubleClick += (_, _) => OpenFromTray();
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
            if (settingsWindow is not null)
            {
                settingsWindow.Activate();
            }
            else if (window.IsActive)
            {
                window.Hide();
            }
            else
            {
                RememberPasteTarget();
                window.Present();
            }
            handled = true;
        }
        return 0;
    }

    private async Task CaptureAsync()
    {
        uint sequence = NativeMethods.GetClipboardSequenceNumber();
        if (sequence == 0 || sequence == observedSequence) return;
        observedSequence = sequence;
        if (Settings.Paused) return;

        string source = NativeMethods.ClipboardOwnerName();
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
                ChangeHistory(() =>
                {
                    if (!history.Capture(item.Clip, item.Image))
                        Notify("The history limit was reached. Unpin or unfavorite a clip to make room.");
                });
            }
            return;
        }
    }

    private void RememberPasteTarget()
    {
        pasteTarget = NativeMethods.GetForegroundWindow();
        pasteTargetProcess = NativeMethods.ProcessId(pasteTarget);
        if (pasteTargetProcess == 0 || pasteTargetProcess == Environment.ProcessId) pasteTarget = 0;
    }

    private void OpenFromTray()
    {
        if (Exiting) return;
        if (settingsWindow is not null)
        {
            settingsWindow.Activate();
            return;
        }
        if (!window.IsActive) pasteTarget = 0;
        window.Present();
    }

    internal async Task UseClipAsync(Clip clip, bool paste, bool plainText)
    {
        if (pasting) return;
        if (plainText && string.IsNullOrEmpty(clip.PlainText)) return;
        uint writtenSequence;
        try
        {
            byte[]? image = clip.Kind == ClipKind.Image && !plainText ? history.ReadImage(clip) : null;
            Clipboard.SetDataObject(ClipboardFormats.Create(clip, plainText, image), copy: true);
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
        catch (Exception error) when (IsLocalError(error) || error is ArgumentException or NotSupportedException)
        {
            Notify(clip.Kind == ClipKind.Image ? "The saved image could not be opened." : error.Message);
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
            window.Hide();
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
                    if (NativeMethods.SendPaste()) return;
                    break;
                }
                await Task.Delay(25);
            }
            Notify("Copied. Press Ctrl+V in the destination app to paste.");
        }
        finally { pasting = false; }
    }

    internal byte[] ReadImage(Clip clip) => history.ReadImage(clip);
    internal void EditClip(Clip clip, string title, string note, string group, bool pinned, bool favorite) =>
        ChangeHistory(() =>
        {
            if (!history.Edit(clip, title, note, group, pinned, favorite))
                Notify("The history limit was reached. Shorten the title, group, or note.");
        });
    internal void DeleteClip(Clip clip) => ChangeHistory(() => history.Delete(clip));
    internal void ClearUnprotected() => ChangeHistory(history.ClearUnprotected);

    private void ChangeHistory(Action change)
    {
        try
        {
            change();
            if (window.IsVisible) window.Refresh();
        }
        catch (Exception error) when (IsLocalError(error))
        {
            Notify(error.Message);
        }
    }

    internal void OpenSettings()
    {
        if (settingsWindow is not null) return;
        settingsWindow = new SettingsWindow(this) { Owner = window };
        try { settingsWindow.ShowDialog(); }
        finally { settingsWindow = null; }
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
        try { next.Save(dataDirectory); }
        catch (Exception error) when (IsLocalError(error))
        {
            Notify(error.Message);
            return false;
        }
        bool shortcutChanged = Settings.UseAlternateShortcut != next.UseAlternateShortcut;
        bool pausedChanged = Settings.Paused != next.Paused;
        Settings = next;
        if (pausedChanged) observedSequence = NativeMethods.GetClipboardSequenceNumber();
        if (shortcutChanged) RegisterShortcut();
        else RefreshStatus();
        return true;
    }

    private void RegisterShortcut()
    {
        if (messages is null) return;
        if (hotkeyAvailable) NativeMethods.UnregisterHotKey(messages.Handle, NativeMethods.HotKeyId);
        uint modifier = Settings.UseAlternateShortcut ? NativeMethods.Alt : NativeMethods.Shift;
        hotkeyAvailable = NativeMethods.RegisterHotKey(messages.Handle, NativeMethods.HotKeyId,
            NativeMethods.Control | modifier | NativeMethods.NoRepeat, NativeMethods.V) != 0;
        RefreshStatus();
    }

    private void RefreshStatus()
    {
        if (tray is not null) tray.Text = Settings.Paused ? $"Pasteory · {Labels.Get("Capture paused")}" : "Pasteory";
        if (pauseMenuItem is not null)
            pauseMenuItem.Text = Labels.Get(Settings.Paused ? "Resume clipboard capture" : "Pause clipboard capture");
        window.SetStatus(!listening ? Labels.Get("Clipboard monitoring could not start. Restart Pasteory to retry.") :
            hotkeyAvailable ? Labels.Format(Settings.Paused ? "Capture paused · {0}" : "Capture active · {0}", Shortcut) :
            Labels.Get("The global shortcut is unavailable. Open history from the tray or change the shortcut in Settings."));
    }

    private void Notify(string message)
    {
        window.SetStatus(Labels.Get(message));
        if (!window.IsVisible && tray is not null)
            tray.ShowBalloonTip(2500, "Pasteory", Labels.Get(message), Forms.ToolTipIcon.Info);
    }

    internal static bool IsLocalError(Exception error) => error is IOException or UnauthorizedAccessException;

    protected override void OnExit(ExitEventArgs e)
    {
        Exiting = true;
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
