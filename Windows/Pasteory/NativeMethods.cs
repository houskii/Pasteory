using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Pasteory.Windows;

internal static partial class NativeMethods
{
    internal const int ClipboardUpdated = 0x031D;
    internal const int HotKeyPressed = 0x0312;
    internal const int HotKeyId = 1;
    internal const uint Control = 0x0002;
    internal const uint Alt = 0x0001;
    internal const uint Shift = 0x0004;
    internal const uint Win = 0x0008;
    internal const uint NoRepeat = 0x4000;
    internal const ushort V = 0x56;

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial int AddClipboardFormatListener(nint window);

    [LibraryImport("user32.dll")]
    internal static partial int RemoveClipboardFormatListener(nint window);

    [LibraryImport("user32.dll")]
    internal static partial uint GetClipboardSequenceNumber();

    [LibraryImport("user32.dll")]
    private static partial nint GetClipboardOwner();

    [LibraryImport("user32.dll")]
    internal static partial nint GetForegroundWindow();

    [LibraryImport("user32.dll")]
    internal static partial int SetForegroundWindow(nint window);

    [LibraryImport("user32.dll")]
    internal static partial int SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);

    [LibraryImport("user32.dll")]
    internal static partial nint MonitorFromPoint(ScreenPoint point, uint flags);

    [LibraryImport("shcore.dll")]
    internal static partial int GetDpiForMonitor(nint monitor, int type, out uint x, out uint y);

    [LibraryImport("user32.dll")]
    internal static partial int GetWindowRect(nint window, out ScreenRect rectangle);

    [StructLayout(LayoutKind.Sequential)]
    internal readonly record struct ScreenPoint(int X, int Y);

    [StructLayout(LayoutKind.Sequential)]
    internal struct ScreenRect
    {
        internal int Left, Top, Right, Bottom;
    }

    [LibraryImport("user32.dll", EntryPoint = "GetWindowTextW", StringMarshalling = StringMarshalling.Utf16)]
    private static unsafe partial int GetWindowText(nint window, char* value, int capacity);

    internal static unsafe string WindowTitle(nint window)
    {
        const int capacity = 512;
        char* buffer = stackalloc char[capacity];
        int count = GetWindowText(window, buffer, capacity);
        return count > 0 ? new string(buffer, 0, count) : "";
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetWindowThreadProcessId(nint window, out uint processId);

    [LibraryImport("user32.dll")]
    internal static partial int RegisterHotKey(nint window, int id, uint modifiers, uint key);

    [LibraryImport("user32.dll")]
    internal static partial int UnregisterHotKey(nint window, int id);

    [LibraryImport("user32.dll")]
    private static partial short GetAsyncKeyState(int key);

    [LibraryImport("user32.dll")]
    private static partial int GetLastInputInfo(ref LastInput data);

    [LibraryImport("kernel32.dll")]
    private static partial int GetSystemPowerStatus(out PowerStatus data);

    internal static TimeSpan IdleTime()
    {
        var state = new LastInput { Size = 8 };
        return GetLastInputInfo(ref state) == 0 ? TimeSpan.Zero :
            TimeSpan.FromMilliseconds(unchecked((uint)Environment.TickCount - state.Tick));
    }

    internal static bool BatterySaver() => GetSystemPowerStatus(out var status) != 0 && status.Saver != 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct LastInput { public uint Size, Tick; }
    [StructLayout(LayoutKind.Sequential)]
    private struct PowerStatus { public byte Ac, Battery, Percent, Saver; public uint Life, FullLife; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, [In] Input[] inputs, int size);

    internal static uint ProcessId(nint window)
    {
        GetWindowThreadProcessId(window, out uint processId);
        return processId;
    }

    internal static bool OwnsClipboard() => ProcessId(GetClipboardOwner()) == Environment.ProcessId;

    internal static string ClipboardOwnerName() => ClipboardOwner().Name;

    internal static (string Name, string? Path) ClipboardOwner()
    {
        uint id = ProcessId(GetClipboardOwner());
        if (id == 0) return ("", null);
        try
        {
            using var process = Process.GetProcessById((int)id);
            string name = process.ProcessName;
            try { return (name, process.MainModule?.FileName); }
            catch (System.ComponentModel.Win32Exception) { return (name, null); }
            catch (InvalidOperationException) { return (name, null); }
        }
        catch (ArgumentException) { return ("", null); }
        catch (InvalidOperationException) { return ("", null); }
        catch (System.ComponentModel.Win32Exception) { return ("", null); }
    }

    internal static bool ModifiersHeld() =>
        Down(0x10) || Down(0x11) || Down(0x12) || Down(0x5B) || Down(0x5C);

    private static bool Down(int key) => GetAsyncKeyState(key) < 0;

    internal static bool SendPaste()
    {
        const ushort control = 0x11;
        const uint release = 0x0002;
        Input[] events = [Key(control), Key(V), Key(V, release), Key(control, release)];
        int size = Marshal.SizeOf<Input>();
        uint sent = SendInput((uint)events.Length, events, size);
        if (sent is 1 or 2 or 3)
        {
            Input[] releases = sent == 2 ? [events[2], events[3]] : [events[3]];
            SendInput((uint)releases.Length, releases, size);
        }
        return sent == events.Length;
    }

    private static Input Key(ushort key, uint flags = 0) =>
        new() { Type = 1, Data = new() { Keyboard = new() { Key = key, Flags = flags } } };

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputData Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputData
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort Key;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X;
        public int Y;
        public uint Data;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }
}
